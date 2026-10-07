// AppEnergyMonitor.swift. Samples per-process energy for the phone's "power-hungry apps" list,
// and quits an app when asked. Nothing runs in the background: a sample is taken only when the
// page asks, and the window is the time since the previous request (the page polls every few
// seconds while it is open), so the list costs no power while nobody is looking.
import AppKit
import Darwin
import Foundation

private let quitGrace: TimeInterval = 10        // an app still running after this likely waits on a save dialog
private let forceQuitGrace: TimeInterval = 5
private let shortestWindow: TimeInterval = 2
private let longestWindow: TimeInterval = 120
private let firstWindow: TimeInterval = 1.5

private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t
// Private but stable libsystem call that Activity Monitor uses to group helpers under their app.
private let responsiblePIDFunction = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    .map { unsafeBitCast($0, to: ResponsiblePIDFunction.self) }

// Every process this user can read (others' fail silently and are skipped).
private func sampleProcessEnergy() -> [ProcessEnergySample] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return pids.prefix(Int(max(found, 0))).compactMap { pid in
        var usage = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        guard status == 0 else { return nil }
        return ProcessEnergySample(pid: pid, responsiblePID: responsiblePIDFunction?(pid) ?? pid,
                                   energyNanojoules: usage.ri_energy_nj)
    }
}

func pngData(of image: NSImage, side: CGFloat) -> Data {
    let rendered = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        image.draw(in: rect)
        return true
    }
    guard let tiff = rendered.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { return Data() }
    return png
}

struct AppsReport: Encodable {
    enum QuitPhase: String, Encodable { case quitting, notResponding }
    struct App: Encodable {
        let id: String
        let name: String
        let watts: Double
        let protection: AppProtection?
        let quit: QuitPhase?
    }
    let apps: [App]
    let windowSeconds: Double
    let macWatts: Double?   // the whole Mac's draw, only while it runs on battery
    let thermal: String
}

enum AppQuitRefusal: String { case notRunning, protected }

@MainActor
final class AppEnergyMonitor {
    private let worker = DispatchQueue(label: "com.sleepless.energy")
    private var lastSample: (at: Date, energy: [Int32: UInt64])?
    private var quits: [String: (startedAt: Date, forced: Bool)] = [:]
    private var icons: [String: Data] = [:]

    private static func id(of app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? "pid-\(app.processIdentifier)"
    }

    // The apps a person would call "open": regular and menu-bar apps, without macOS's own.
    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited && !$0.isTerminated && $0.bundleURL?.path.hasPrefix("/System/") != true
        }
    }

    func report(completion: @escaping @MainActor (AppsReport) -> Void) {
        let apps = runningApps().map {
            RunningApp(pid: $0.processIdentifier, id: Self.id(of: $0), name: $0.localizedName ?? Self.id(of: $0),
                       bundleID: $0.bundleIdentifier)
        }
        let previous = lastSample.flatMap { (shortestWindow...longestWindow).contains(-$0.at.timeIntervalSinceNow) ? $0 : nil }
        worker.async {
            var start = previous?.at ?? Date()
            var before = previous?.energy
            if before == nil {
                before = Self.energyByPID(sampleProcessEnergy())
                start = Date()
                Thread.sleep(forTimeInterval: firstWindow)
            }
            let after = sampleProcessEnergy()
            let now = Date()
            let seconds = now.timeIntervalSince(start)
            let ranked = rankAppsByPower(apps: apps, before: before ?? [:], after: after, seconds: seconds,
                                         sleeplessPID: getpid())
            let macWatts = readDischargeWatts()
            Task { @MainActor in
                self.lastSample = (now, Self.energyByPID(after))
                completion(AppsReport(apps: ranked.map { app in
                                          AppsReport.App(id: app.id, name: app.name, watts: app.watts,
                                                         protection: app.protection, quit: self.quitPhase(of: app.id))
                                      },
                                      windowSeconds: seconds, macWatts: macWatts,
                                      thermal: Self.thermalWord(ProcessInfo.processInfo.thermalState)))
            }
        }
    }

    private nonisolated static func energyByPID(_ samples: [ProcessEnergySample]) -> [Int32: UInt64] {
        Dictionary(samples.map { ($0.pid, $0.energyNanojoules) }, uniquingKeysWith: { first, _ in first })
    }

    private nonisolated static func thermalWord(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "nominal"
        }
    }

    private func quitPhase(of id: String) -> AppsReport.QuitPhase? {
        guard let quit = quits[id] else { return nil }
        guard runningApps().contains(where: { Self.id(of: $0) == id }) else {
            quits[id] = nil
            return nil
        }
        let grace = quit.forced ? forceQuitGrace : quitGrace
        return -quit.startedAt.timeIntervalSinceNow < grace ? .quitting : .notResponding
    }

    // A normal quit first, like ⌘Q: an app with unsaved work may stop at a save dialog, and the
    // phone then offers a force quit.
    func quit(id: String, force: Bool) -> AppQuitRefusal? {
        let matches = runningApps().filter { Self.id(of: $0) == id }
        guard !matches.isEmpty else { return .notRunning }
        if matches.contains(where: {
            AppProtection(bundleID: $0.bundleIdentifier, isSleepless: $0.processIdentifier == getpid()) != nil
        }) { return .protected }
        for app in matches {
            _ = force ? app.forceTerminate() : app.terminate()
        }
        quits[id] = (Date(), force)
        NSLog("Sleepless: %@ %@ from the phone dashboard", force ? "force-quit" : "quit", id)
        return nil
    }

    func icon(id: String) -> Data? {
        if let cached = icons[id] { return cached }
        guard let image = runningApps().first(where: { Self.id(of: $0) == id })?.icon else { return nil }
        let png = pngData(of: image, side: 64)
        icons[id] = png
        return png
    }
}
