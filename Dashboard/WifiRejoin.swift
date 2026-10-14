// WifiRejoin.swift. Puts the Mac back on Wi-Fi when it drops off and macOS doesn't. When an access
// point reboots (a nightly scheduled restart, say), macOS fails a few joins while it is down,
// deny-lists the network for auto-join, and leaves the Mac offline for hours after the access
// point is back. A join Sleepless asks for works like joining by hand, so it gets past that list.
//
// It acts only while the Mac is associated with nothing and Wi-Fi is powered on: a network that
// is joined but has no internet stays macOS's call, and Wi-Fi turned off stays off. The timing
// and the choice of network live in Core/WifiRejoinRules.swift.
import Foundation
import os

private let tickInterval: TimeInterval = 5   // just reads the current network

@MainActor
final class WifiRejoinWatchdog {
    struct Rejoin: Encodable, Sendable {
        let ssid: String
        let at: Date
    }

    private let wifi: WifiController
    private var ticker: Timer?
    private var previousSSID: String?
    private var nextAttemptAt: Date?
    private var failedAttempts = 0
    private var attempting = false
    private(set) var droppedAt: Date?
    private(set) var lastRejoin: Rejoin?
    var onChange: (() -> Void)?

    init(wifi: WifiController) {
        self.wifi = wifi
    }

    func sync(shouldRun: Bool) {
        guard shouldRun else { return stop() }
        guard ticker == nil else { return }
        wifi.requestLocationAccess()
        ticker = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
        settle()
    }

    // Without Location Services every network name reads as nil, which would look like a drop.
    private func tick() {
        guard wifi.locationAuthorized, wifi.powerOn else { return settle() }
        if let current = wifi.currentSSID {
            previousSSID = current
            return settle()
        }
        let now = Date()
        if droppedAt == nil {
            droppedAt = now
            nextAttemptAt = now.addingTimeInterval(wifiRejoinGrace)
            Log.wifi.notice("Wi-Fi dropped (last on \(self.previousSSID ?? "none", privacy: .public))")
            onChange?()
        }
        guard !attempting, wifi.switchState?.inProgress != true, let due = nextAttemptAt, now >= due else { return }
        attempting = true
        wifi.rejoin(previous: previousSSID) { [weak self] joined in
            guard let self else { return }
            attempting = false
            guard let droppedAt else { return }   // back online or stopped while this ran
            if let joined {
                Log.wifi.notice("Rejoined Wi-Fi \(joined, privacy: .public)")
                lastRejoin = Rejoin(ssid: joined, at: Date())
                previousSSID = joined
                return settle()
            }
            failedAttempts += 1
            let now = Date()
            let delay = wifiRejoinRetryInterval(offlineFor: now.timeIntervalSince(droppedAt))
            nextAttemptAt = now.addingTimeInterval(delay)
            Log.wifi.notice("No saved Wi-Fi network took the Mac (attempt \(self.failedAttempts)), next try in \(delay, format: .fixed(precision: 0))s")
        }
    }

    private func settle() {
        guard droppedAt != nil else { return }
        droppedAt = nil
        nextAttemptAt = nil
        failedAttempts = 0
        onChange?()
    }
}
