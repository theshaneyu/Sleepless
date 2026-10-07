// DashboardServer.swift. A loopback-only HTTP listener for the phone dashboard. Binding to
// 127.0.0.1 keeps it off every real network the Mac joins (a hotspot, a café); `tailscale serve`
// is the one door in, and it adds HTTPS and the caller's identity on the way.
import Foundation
import Network

let dashboardPort: UInt16 = 47800

final class DashboardServer: @unchecked Sendable {   // all mutable state lives on `queue`
    typealias Handler = @MainActor (HTTPRequest, @escaping @Sendable (HTTPResponse) -> Void) -> Void

    private let queue = DispatchQueue(label: "com.sleepless.dashboard")
    private let handler: Handler
    private var listener: NWListener?
    private let onFailure: @MainActor (String) -> Void

    init(handler: @escaping Handler, onFailure: @escaping @MainActor (String) -> Void) {
        self.handler = handler
        self.onFailure = onFailure
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: dashboardPort)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state, let self else { return }
            let message = "Port \(dashboardPort): \(error.localizedDescription)"
            Task { @MainActor in self.onFailure(message) }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
        queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }   // no request lingers
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: dashboardMaxRequestBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let buffer = buffered + (data ?? Data())
            switch parseHTTPRequest(buffer) {
            case .needMore where !isComplete && error == nil:
                self.receive(on: connection, buffered: buffer)
            case .request(let request):
                let handler = self.handler
                Task { @MainActor in
                    handler(request) { response in
                        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
                    }
                }
            default:
                let response = HTTPResponse.text(buffer.count > dashboardMaxRequestBytes ? 413 : 400, "Bad request")
                connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
