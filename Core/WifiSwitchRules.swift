// WifiSwitchRules.swift. When the phone may move the Mac to another Wi-Fi network. The phone
// usually reaches the Mac THROUGH the network being left, so a switch that strands the Mac
// offline can't be undone from the phone. Every switch therefore needs a way back: the network
// the Mac is on now must have a saved password too, so a failed switch can rejoin it.
import Foundation

enum WifiSwitchRefusal: Error, Equatable, Sendable {
    case busy
    case alreadyConnected
    case noSavedPassword(String)
    case noWayBack(String)
    case notInRange(String)

    // What the phone gets back; it words the reason in its own language.
    var code: String {
        switch self {
        case .busy: "busy"
        case .alreadyConnected: "alreadyConnected"
        case .noSavedPassword: "noSavedPassword"
        case .noWayBack: "noWayBack"
        case .notInRange: "notInRange"
        }
    }

    var ssid: String? {
        switch self {
        case .busy, .alreadyConnected: nil
        case .noSavedPassword(let ssid), .noWayBack(let ssid), .notInRange(let ssid): ssid
        }
    }
}

// `current` is nil when the Mac isn't on Wi-Fi; then there is nothing to fall back to, and
// nothing to lose either.
func wifiSwitchRefusal(target: String, current: String?, saved: Set<String>, inRange: Set<String>,
                       busy: Bool) -> WifiSwitchRefusal? {
    if busy { return .busy }
    if target == current { return .alreadyConnected }
    guard saved.contains(target) else { return .noSavedPassword(target) }
    if let current, !saved.contains(current) { return .noWayBack(current) }
    guard inRange.contains(target) else { return .notInRange(target) }
    return nil
}
