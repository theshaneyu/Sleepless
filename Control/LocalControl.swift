import CoreFoundation
import Darwin
import Foundation

private let controlPortName = "com.aboudjem.Sleepless.control.\(getuid())"

@MainActor
final class LocalControlServer {
    private let handler: (ControlCommand) -> ControlReply
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?

    init(handler: @escaping (ControlCommand) -> ControlReply) {
        self.handler = handler
    }

    func start() -> Bool {
        guard port == nil else { return true }
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        guard let port = CFMessagePortCreateLocal(nil, controlPortName as CFString, { _, _, data, info in
            guard let data, let info,
                  let word = String(data: data as Data, encoding: .utf8),
                  let command = ControlCommand(rawValue: word) else { return nil }
            return MainActor.assumeIsolated {
                let server = Unmanaged<LocalControlServer>.fromOpaque(info).takeUnretainedValue()
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                guard let reply = try? encoder.encode(server.handler(command)) else { return nil }
                return Unmanaged.passRetained(reply as CFData)
            }
        }, &context, nil), let source = CFMessagePortCreateRunLoopSource(nil, port, 0) else { return false }
        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
        source = nil
        port = nil
    }
}

enum SleeplessCLI {
    static let usage = """
    Usage: sleepless <on|off|toggle|status>

      on       Keep the Mac awake; preserve an existing auto-off countdown.
      off      Restore normal sleep.
      toggle   Flip the main switch.
      status   Read the current state.

    Commands start Sleepless if needed and return JSON after the app handles them.
    Exit status: 0 = success, 1 = operation failed, 64 = invalid arguments.
    """

    static func run(arguments: [String]) -> Int32 {
        guard let invocation = CLIInvocation(arguments: arguments) else {
            writeError(usage)
            return 64
        }
        guard case .command(let command) = invocation else {
            print(usage)
            return 0
        }
        do {
            let reply = try request(command)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(reply)
            print(String(decoding: data, as: UTF8.self))
            if let error = reply.error {
                writeError(error)
                return 1
            }
            return 0
        } catch {
            writeError(error.localizedDescription)
            return 1
        }
    }

    private static func request(_ command: ControlCommand) throws -> ControlReply {
        var port = CFMessagePortCreateRemote(nil, controlPortName as CFString)
        if port == nil {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 else {
                throw ControlFailure("Couldn't locate the Sleepless executable.")
            }
            let appURL = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard appURL.pathExtension == "app" else {
                throw ControlFailure("Run the CLI from a built Sleepless.app bundle.")
            }
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launcher.arguments = ["-g", appURL.path]
            launcher.standardInput = FileHandle.nullDevice
            launcher.standardOutput = FileHandle.nullDevice
            launcher.standardError = FileHandle.nullDevice
            try launcher.run()
            launcher.waitUntilExit()
            guard launcher.terminationStatus == 0 else { throw ControlFailure("Couldn't launch Sleepless.") }
            let deadline = Date().addingTimeInterval(10)
            repeat {
                port = CFMessagePortCreateRemote(nil, controlPortName as CFString)
                if port != nil { break }
                Thread.sleep(forTimeInterval: 0.05)
            } while Date() < deadline
        }
        guard let port else {
            throw ControlFailure("Sleepless isn't accepting CLI commands. Update or restart the app, then try again.")
        }
        var data: Unmanaged<CFData>?
        let result = CFMessagePortSendRequest(port, 1, Data(command.rawValue.utf8) as CFData,
                                             5, 120, CFRunLoopMode.defaultMode.rawValue, &data)
        guard result == kCFMessagePortSuccess, let data = data?.takeRetainedValue() else {
            throw ControlFailure("No reply from Sleepless (transport status \(result)). Check sleepless status before retrying toggle.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ControlReply.self, from: data as Data)
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private struct ControlFailure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
