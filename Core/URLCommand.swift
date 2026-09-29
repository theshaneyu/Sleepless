// URLCommand.swift. What a `sleepless://` URL may ask the app to do. Any web page or process
// can open a URL, so only the safe direction — letting the Mac sleep again — is reachable
// this way. There is deliberately no command that keeps the Mac awake.
import Foundation

let urlScheme = "sleepless"

enum URLCommand: Equatable {
    case turnOff

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == urlScheme else { return nil }
        switch url.host?.lowercased() {
        case "off": self = .turnOff
        default: return nil
        }
    }
}
