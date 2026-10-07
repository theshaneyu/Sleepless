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

    var message: String {
        switch self {
        case .busy: "A switch is already in progress."
        case .alreadyConnected: "The Mac is already on that network."
        case .noSavedPassword(let ssid): "No password saved for \(ssid). Save it in Sleepless first."
        case .noWayBack(let ssid):
            "No password saved for \(ssid), the network the Mac is on now, so it couldn\u{2019}t come back if the switch fails."
        case .notInRange(let ssid): "\(ssid) isn\u{2019}t in range. An iPhone hotspot shows up while its Personal Hotspot screen is open."
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
