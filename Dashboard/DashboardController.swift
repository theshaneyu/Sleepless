// DashboardController.swift. The phone dashboard: battery, Wi-Fi and Sleepless state on one
// page, served to the phone through `tailscale serve`. Like Remote Control it runs only while
// the Mac is kept awake and its switch is on, so every auto-off path takes it down too.
//
// One-time setup (`tailscale serve` keeps it across restarts):
//   /Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg 47800
import AppKit
import Foundation

struct RemoteControlSnapshot: Encodable {
    let repo: String
    let state: String
}

struct SleeplessSnapshot: Encodable {
    let on: Bool
    let floorPercent: Int
    let lowPowerMode: Bool
    let autoOffAt: Date?
    let remoteControl: [RemoteControlSnapshot]
}

@MainActor
protocol DashboardHost: AnyObject {
    func dashboardSleeplessSnapshot() -> SleeplessSnapshot
    func dashboardTurnOff()
}

private struct TailscaleSelf: Sendable {
    let host: String
    let login: String
}

private let tailscaleCandidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                                   "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]

// The Mac's own MagicDNS name and owner login, straight from the Tailscale CLI.
private func readTailscaleSelf() -> Result<TailscaleSelf, DashboardProblem> {
    guard let cli = tailscaleCandidates.first(where: FileManager.default.isExecutableFile) else {
        return .failure(.tailscaleMissing)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cli)
    process.arguments = ["status", "--json"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return .failure(.tailscaleMissing) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["BackendState"] as? String == "Running",
          let me = json["Self"] as? [String: Any],
          let dnsName = me["DNSName"] as? String, !dnsName.isEmpty,
          let userID = me["UserID"] as? Int,
          let users = json["User"] as? [String: Any],
          let user = users[String(userID)] as? [String: Any],
          let login = user["LoginName"] as? String else { return .failure(.tailscaleDown) }
    let host = dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
    return .success(TailscaleSelf(host: host, login: login))
}

enum DashboardProblem: Error, Equatable {
    case tailscaleMissing, tailscaleDown, listener(String)

    var message: String {
        switch self {
        case .tailscaleMissing: "Tailscale isn\u{2019}t installed."
        case .tailscaleDown: "Tailscale isn\u{2019}t connected."
        case .listener(let reason): "Couldn\u{2019}t start: \(reason)"
        }
    }
}

@MainActor
final class DashboardController {
    let wifi = WifiController()
    weak var host: DashboardHost?
    var onChange: (() -> Void)?

    private var server: DashboardServer?
    private var access: DashboardAccess?
    private var resolving = false
    private(set) var problem: DashboardProblem?

    init() {
        wifi.onChange = { [weak self] in self?.onChange?() }
    }

    var isRunning: Bool { server != nil }
    var url: String? { access.map { "https://\($0.host)" } }

    func sync(shouldRun: Bool) {
        guard shouldRun else { return stop() }
        wifi.requestLocationAccess()
        if server == nil { start() }
        if access == nil { resolveTailscale() }   // retried on every sync until Tailscale is up
    }

    private func start() {
        let server = DashboardServer(
            handler: { [weak self] request, respond in
                guard let self else { return respond(.text(503, "Sleepless is shutting down.")) }
                self.handle(request, respond: respond)
            },
            onFailure: { [weak self] reason in
                self?.problem = .listener(reason)
                self?.stop(keepProblem: true)
            })
        do {
            try server.start()
            self.server = server
            problem = nil
        } catch {
            problem = .listener(error.localizedDescription)
        }
        onChange?()
    }

    private func stop(keepProblem: Bool = false) {
        server?.stop()
        server = nil
        if !keepProblem { problem = nil }
        onChange?()
    }

    private func resolveTailscale() {
        guard !resolving else { return }
        resolving = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = readTailscaleSelf()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.resolving = false
                switch result {
                case .success(let me):
                    self.access = DashboardAccess(host: me.host, ownerLogin: me.login)
                    if self.problem == .tailscaleDown || self.problem == .tailscaleMissing { self.problem = nil }
                case .failure(let problem):
                    self.problem = problem
                }
                self.onChange?()
            }
        }
    }

    // MARK: - Routes

    private func handle(_ request: HTTPRequest, respond: @escaping @Sendable (HTTPResponse) -> Void) {
        guard let access else { return respond(.text(503, problem?.message ?? "Tailscale isn\u{2019}t ready yet.")) }
        if case .forbidden(let reason) = access.check(request) { return respond(.text(403, reason)) }

        switch (request.method, request.path) {
        case ("GET", "/"):
            respond(HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(dashboardPage.utf8)))
        case ("GET", "/manifest.webmanifest"):
            respond(HTTPResponse(status: 200, contentType: "application/manifest+json", body: Data(dashboardManifest.utf8)))
        case ("GET", "/icon.png"):
            respond(HTTPResponse(status: 200, contentType: "image/png", body: appIconPNG))
        case ("GET", "/api/status"):
            respond(json(200, status()))
        case ("GET", "/api/wifi/networks"):
            wifi.networks { respond(json(200, ["networks": $0])) }
        case ("POST", "/api/wifi/switch"):
            guard let body = try? JSONDecoder().decode([String: String].self, from: request.body),
                  let ssid = body["ssid"], !ssid.isEmpty else { return respond(.text(400, "Expected {\"ssid\": \"...\"}.")) }
            wifi.requestSwitch(to: ssid) { result in
                switch result {
                case .success(let state): respond(json(202, state))
                case .failure(let refusal): respond(json(409, ["error": refusal.message]))
                }
            }
        case ("POST", "/api/sleepless/off"):
            respond(json(202, ["ok": true]))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.host?.dashboardTurnOff() }
        case (_, "/"), (_, "/api/status"), (_, "/api/wifi/networks"), (_, "/api/wifi/switch"), (_, "/api/sleepless/off"):
            respond(.text(405, "Method not allowed"))
        default:
            respond(.text(404, "Not found"))
        }
    }

    private struct Status: Encodable {
        struct Wifi: Encodable {
            let current: String?
            let rssi: Int?
            let locationAuthorized: Bool
            let lastSwitch: WifiSwitchState?
        }
        let machine: String
        let battery: BatterySnapshot?
        let sleepless: SleeplessSnapshot?
        let wifi: Wifi
    }

    private func status() -> Status {
        Status(machine: Host.current().localizedName ?? "Mac",
               battery: readBattery(),
               sleepless: host?.dashboardSleeplessSnapshot(),
               wifi: .init(current: wifi.currentSSID, rssi: wifi.currentRSSI,
                           locationAuthorized: wifi.locationAuthorized, lastSwitch: wifi.switchState))
    }

    private lazy var appIconPNG: Data = {
        let size = NSSize(width: 180, height: 180)
        let image = NSImage(size: size, flipped: false) { rect in
            NSApp.applicationIconImage.draw(in: rect)
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }()
}

private func json<T: Encodable>(_ status: Int, _ value: T) -> HTTPResponse {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
    return HTTPResponse(status: status, contentType: "application/json", body: body)
}
