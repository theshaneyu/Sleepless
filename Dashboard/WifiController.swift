// WifiController.swift. Reads and switches the Mac's Wi-Fi for the phone dashboard.
//
// macOS hides every network name (the current one and scan results) from apps without
// Location Services access, so the dashboard asks for it once. Switching joins with a password
// Sleepless saved itself (see WifiPasswords), then proves the new network reaches the internet.
// If it doesn't within verifyTimeout (wrong password, a captive portal, no uplink), the Mac
// rejoins the network it came from, because the phone usually reached it through that one.
import CoreLocation
import CoreWLAN
import Foundation

private let switchDelay: TimeInterval = 1.5      // lets the 202 reach the phone before the link drops
private let verifyTimeout: TimeInterval = 45
private let revertAttempts = 3
private let internetProbe = URL(string: "https://captive.apple.com/hotspot-detect.html")!

struct WifiNetwork: Encodable, Sendable {
    let ssid: String
    let saved: Bool
    let inRange: Bool
    let rssi: Int?
    let current: Bool
}

struct WifiSwitchState: Encodable, Sendable {
    enum Phase: String, Encodable, Sendable { case switching, verifying, done, reverting, reverted, failed }
    enum Reason: String, Encodable, Sendable { case joinFailed, noInternet }   // why it left the target
    let phase: Phase
    let target: String
    let from: String?
    let reason: Reason?
    let updatedAt: Date

    var inProgress: Bool { [.switching, .verifying, .reverting].contains(phase) }
}

// Blocking CoreWLAN and network calls. Never called on the main thread.
private enum WifiRadio {
    static var interface: CWInterface? { CWWiFiClient.shared().interface() }

    static func signalBySSID() -> [String: Int] {
        let found = (try? interface?.scanForNetworks(withSSID: nil)) ?? []
        return found.reduce(into: [:]) { best, network in
            guard let ssid = network.ssid else { return }
            best[ssid] = max(best[ssid] ?? Int.min, network.rssiValue)
        }
    }

    // A hotspot can take a scan or two to show up, so a miss is retried before giving up.
    static func join(_ ssid: String, password: String?) -> String? {
        guard let interface else { return "No Wi-Fi interface." }
        var failure = "\(ssid) isn\u{2019}t in range."
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 2) }
            guard let network = (try? interface.scanForNetworks(withName: ssid))?.max(by: { $0.rssiValue < $1.rssiValue })
            else { continue }
            do {
                try interface.associate(to: network, password: password?.isEmpty == false ? password : nil)
                return nil
            } catch {
                failure = "Couldn\u{2019}t join \(ssid) (error \((error as NSError).code))."
            }
        }
        return failure
    }

    // Only the real Apple page counts: a captive portal answers with its own login page instead.
    static func waitForInternet(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        while Date() < deadline {
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var ok = false
            session.dataTask(with: internetProbe) { data, _, _ in
                ok = data.flatMap { String(data: $0, encoding: .utf8) }?.contains("Success") == true
                done.signal()
            }.resume()
            done.wait()
            if ok { return true }
            Thread.sleep(forTimeInterval: 2)
        }
        return false
    }
}

@MainActor
final class WifiController: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let worker = DispatchQueue(label: "com.sleepless.wifi")
    private(set) var switchState: WifiSwitchState?
    var onChange: (() -> Void)?

    override init() {
        super.init()
        locationManager.delegate = self
    }

    var locationAuthorized: Bool { locationManager.authorizationStatus == .authorizedAlways }

    func requestLocationAccess() {
        guard locationManager.authorizationStatus == .notDetermined else { return }
        locationManager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.onChange?() }
    }

    var currentSSID: String? { WifiRadio.interface?.ssid() }
    var currentRSSI: Int? { currentSSID == nil ? nil : WifiRadio.interface?.rssiValue() }

    var knownSSIDs: [String] {
        (WifiRadio.interface?.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []).compactMap(\.ssid)
    }

    // Saved networks always, plus any other known network in range so the phone can tell you
    // which password to save next.
    func networks(completion: @escaping @MainActor ([WifiNetwork]) -> Void) {
        let saved = WifiPasswords.savedSSIDs()
        let known = Set(knownSSIDs)
        let current = currentSSID
        worker.async {
            let signal = WifiRadio.signalBySSID()
            let listed = saved.union(known.filter { signal[$0] != nil })
            let result = listed.map { ssid in
                WifiNetwork(ssid: ssid, saved: saved.contains(ssid), inRange: signal[ssid] != nil || ssid == current,
                            rssi: signal[ssid], current: ssid == current)
            }.sorted { ($0.current ? 1 : 0, $0.rssi ?? Int.min) > ($1.current ? 1 : 0, $1.rssi ?? Int.min) }
            Task { @MainActor in completion(result) }
        }
    }

    func requestSwitch(to target: String, completion: @escaping @MainActor (Result<WifiSwitchState, WifiSwitchRefusal>) -> Void) {
        let from = currentSSID
        let saved = WifiPasswords.savedSSIDs()
        let busy = switchState?.inProgress == true
        if let refusal = wifiSwitchRefusal(target: target, current: from, saved: saved, inRange: [target], busy: busy) {
            return completion(.failure(refusal))   // everything but range, which needs a scan
        }

        update(.switching, target: target, from: from)
        let started = switchState!
        worker.async { [weak self] in
            let targetPassword = WifiPasswords.read(ssid: target)
            let fromPassword = from.flatMap(WifiPasswords.read)
            let visible = (try? WifiRadio.interface?.scanForNetworks(withName: target))?.isEmpty == false
            let refusal: WifiSwitchRefusal? =
                if targetPassword == nil { .noSavedPassword(target) }
                else if let from, fromPassword == nil { .noWayBack(from) }
                else if !visible { .notInRange(target) }
                else { nil }
            Task { @MainActor [weak self] in
                guard let refusal else { return completion(.success(started)) }
                self?.switchState = nil
                self?.onChange?()
                completion(.failure(refusal))
            }
            guard refusal == nil else { return }
            Thread.sleep(forTimeInterval: switchDelay)
            let report: @Sendable (WifiSwitchState.Phase, WifiSwitchState.Reason?) -> Void = { [weak self] phase, reason in
                Task { @MainActor [weak self] in self?.update(phase, target: target, from: from, reason: reason) }
            }
            Self.performSwitch(target: target, password: targetPassword, from: from, fromPassword: fromPassword,
                               report: report)
        }
    }

    private nonisolated static func performSwitch(target: String, password: String?, from: String?, fromPassword: String?,
                                                  report: @Sendable (WifiSwitchState.Phase, WifiSwitchState.Reason?) -> Void) {
        let reason: WifiSwitchState.Reason
        if let failure = WifiRadio.join(target, password: password) {
            NSLog("Sleepless: Wi-Fi switch to %@ failed: %@", target, failure)
            reason = .joinFailed
        } else {
            report(.verifying, nil)
            if WifiRadio.waitForInternet(timeout: verifyTimeout) { return report(.done, nil) }
            reason = .noInternet
        }
        // With no previous network there is nothing to go back to; macOS picks a known one itself.
        guard let from else { return report(.failed, reason) }
        report(.reverting, reason)
        for _ in 0..<revertAttempts {
            if WifiRadio.join(from, password: fromPassword) == nil, WifiRadio.waitForInternet(timeout: verifyTimeout) {
                return report(.reverted, reason)
            }
            Thread.sleep(forTimeInterval: 5)
        }
        report(.failed, reason)
    }

    private func update(_ phase: WifiSwitchState.Phase, target: String, from: String?, reason: WifiSwitchState.Reason? = nil) {
        switchState = WifiSwitchState(phase: phase, target: target, from: from, reason: reason, updatedAt: Date())
        NSLog("Sleepless: Wi-Fi switch to %@ (from %@): %@ %@", target, from ?? "none", phase.rawValue, reason?.rawValue ?? "")
        onChange?()
    }
}
