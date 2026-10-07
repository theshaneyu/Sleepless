// AppEnergy.swift. Which GUI apps are using power, for the phone dashboard. macOS keeps a
// running energy counter per process (rusage `ri_energy_nj`), so two samples a few seconds
// apart give each process's average power over that window. Helpers, renderers and XPC
// services are billed to the app responsible for them, the way Activity Monitor groups them.
// Processes no GUI app is responsible for (daemons, command-line tools) are left out.
import Foundation

struct ProcessEnergySample: Equatable, Sendable {
    let pid: Int32
    let responsiblePID: Int32
    let energyNanojoules: UInt64
}

struct RunningApp: Equatable, Sendable {
    let pid: Int32
    let id: String
    let name: String
    let bundleID: String?
}

// Apps the phone may not quit, and why.
enum AppProtection: String, Encodable, Sendable {
    case sleepless   // quitting it would end the dashboard and let the Mac sleep
    case tailscale   // the phone reaches the dashboard through it
    case agents      // the coding agents run inside it

    init?(bundleID: String?, isSleepless: Bool) {
        if isSleepless { self = .sleepless; return }
        switch bundleID {
        case "io.tailscale.ipn.macos", "io.tailscale.ipn.macsys": self = .tailscale
        case "com.stablyai.orca": self = .agents
        default: return nil
        }
    }
}

struct AppEnergy: Equatable, Sendable {
    let id: String
    let name: String
    let watts: Double
    let protection: AppProtection?
}

func rankAppsByPower(apps: [RunningApp], before: [Int32: UInt64], after: [ProcessEnergySample],
                     seconds: Double, sleeplessPID: Int32) -> [AppEnergy] {
    let appByPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    var joules: [String: Double] = [:]
    for sample in after {
        guard let app = appByPID[sample.responsiblePID] ?? appByPID[sample.pid] else { continue }
        // A process that is new in this window, or a reused pid, spent all of its counter here.
        let previous = before[sample.pid].flatMap { $0 <= sample.energyNanojoules ? $0 : nil } ?? 0
        joules[app.id, default: 0] += Double(sample.energyNanojoules - previous) / 1e9
    }

    var seen = Set<String>()
    return apps.compactMap { app -> AppEnergy? in
        guard seen.insert(app.id).inserted else { return nil }
        let isSleepless = apps.contains { $0.id == app.id && $0.pid == sleeplessPID }
        return AppEnergy(id: app.id, name: app.name, watts: (joules[app.id] ?? 0) / max(seconds, 0.001),
                         protection: AppProtection(bundleID: app.bundleID, isSleepless: isSleepless))
    }.sorted { ($0.watts, $1.name) > ($1.watts, $0.name) }
}
