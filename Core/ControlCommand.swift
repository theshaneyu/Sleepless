import Foundation

enum ControlCommand: String, Sendable {
    case on, off, toggle, status

    func stateChange(current: Bool) -> Bool? {
        switch self {
        case .on: current ? nil : true
        case .off: current ? false : nil
        case .toggle: !current
        case .status: nil
        }
    }
}

enum CLIInvocation: Equatable {
    case help
    case command(ControlCommand)

    init?(arguments: [String]) {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
            self = .help
        } else if arguments.count == 1, let command = ControlCommand(rawValue: arguments[0]) {
            self = .command(command)
        } else {
            return nil
        }
    }
}

struct ControlReply: Codable, Sendable {
    let on: Bool
    let autoOffMinutes: Int
    let autoOffAt: Date?
    var error: String?
}
