import Testing
@testable import SleeplessCore

@Suite struct AppEnergyTests {
    let orbstack = RunningApp(pid: 100, id: "dev.kdrag0n.MacVirt", name: "OrbStack", bundleID: "dev.kdrag0n.MacVirt")
    let chrome = RunningApp(pid: 200, id: "com.google.Chrome", name: "Google Chrome", bundleID: "com.google.Chrome")

    func rank(_ apps: [RunningApp], before: [Int32: UInt64], after: [ProcessEnergySample]) -> [AppEnergy] {
        rankAppsByPower(apps: apps, before: before, after: after, seconds: 2, sleeplessPID: 999)
    }

    // The VM of a container app runs as a system XPC service; it must still count as the app's.
    @Test func helpersAreBilledToTheirResponsibleApp() {
        let after = [ProcessEnergySample(pid: 100, responsiblePID: 100, energyNanojoules: 2_000_000_000),
                     ProcessEnergySample(pid: 101, responsiblePID: 100, energyNanojoules: 10_000_000_000),
                     ProcessEnergySample(pid: 201, responsiblePID: 200, energyNanojoules: 3_000_000_000),
                     ProcessEnergySample(pid: 300, responsiblePID: 300, energyNanojoules: 50_000_000_000)]
        let before: [Int32: UInt64] = [100: 0, 101: 0, 201: 1_000_000_000, 300: 0]
        let ranked = rank([chrome, orbstack], before: before, after: after)
        #expect(ranked.map(\.id) == ["dev.kdrag0n.MacVirt", "com.google.Chrome"])
        #expect(ranked.map(\.watts) == [6, 1])
    }

    @Test func aProcessStartedOrReusedInTheWindowCountsItsWholeCounter() {
        let after = [ProcessEnergySample(pid: 201, responsiblePID: 200, energyNanojoules: 4_000_000_000)]
        #expect(rank([chrome], before: [:], after: after).first?.watts == 2)
        #expect(rank([chrome], before: [201: 9_000_000_000], after: after).first?.watts == 2)
    }

    @Test func theAppsTheDashboardDependsOnAreProtected() {
        let apps = [RunningApp(pid: 1, id: "com.stablyai.orca", name: "Orca", bundleID: "com.stablyai.orca"),
                    RunningApp(pid: 2, id: "io.tailscale.ipn.macos", name: "Tailscale", bundleID: "io.tailscale.ipn.macos"),
                    RunningApp(pid: 999, id: "com.example.Sleepless", name: "Sleepless", bundleID: "com.example.Sleepless"),
                    chrome]
        let protection = Dictionary(uniqueKeysWithValues: rank(apps, before: [:], after: []).map { ($0.name, $0.protection) })
        #expect(protection == ["Orca": .agents, "Tailscale": .tailscale, "Sleepless": .sleepless, "Google Chrome": nil])
    }
}
