// WifiRejoinRules.swift. When and where Sleepless puts the Mac back on Wi-Fi after it drops off.
// macOS gets the first 30 seconds to rejoin on its own. After that Sleepless tries networks it
// has a saved password for, starting with the one the Mac just lost.
//
// Retries keep a short, fixed pace instead of backing off, and never give up. The case they are
// tuned for is the iPhone hotspot: it only broadcasts while its Settings screen is open, so the
// Mac must find it while you hold that screen, however long after the drop you open it. The
// first 10 minutes, when you are most likely to notice the drop, get the shortest wait.
import Foundation

let wifiRejoinGrace: TimeInterval = 30

func wifiRejoinRetryInterval(offlineFor elapsed: TimeInterval) -> TimeInterval {
    elapsed < 600 ? 15 : 60
}

// `signal` holds the networks in range and their RSSI. The network the Mac was on comes first
// even when another one is stronger, then the rest from strongest to weakest.
func wifiRejoinCandidates(previous: String?, saved: Set<String>, signal: [String: Int]) -> [String] {
    let inRange = saved.filter { signal[$0] != nil }
    let others = inRange.subtracting([previous].compactMap { $0 })
        .sorted { (signal[$0]!, $1) > (signal[$1]!, $0) }
    guard let previous, inRange.contains(previous) else { return others }
    return [previous] + others
}
