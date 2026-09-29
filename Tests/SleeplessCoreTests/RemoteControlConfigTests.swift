import Testing
@testable import SleeplessCore

@Suite struct RemoteControlConfigTests {
    private let repos = ["alpha", "beta", "gamma"]

    @Test(arguments: [
        (keepAwake: true, enabled: true, runs: true),
        (keepAwake: true, enabled: false, runs: false),
        (keepAwake: false, enabled: true, runs: false),
        (keepAwake: false, enabled: false, runs: false),
    ])
    func serversRunOnlyWhileBothSwitchesAreOn(keepAwake: Bool, enabled: Bool, runs: Bool) {
        let config = RemoteControlConfig(enabled: enabled, repos: repos)
        #expect(config.reposToRun(keepAwake: keepAwake) == (runs ? repos : []))
    }

    @Test func turningTheRemoteControlSwitchOffStopsEveryServer() {
        var config = RemoteControlConfig(enabled: true, repos: repos)
        config.setEnabled(false)
        #expect(config.reposToRun(keepAwake: true).isEmpty)
    }

    @Test func addingIgnoresDuplicatesAndStopsAtTheLimit() {
        var config = RemoteControlConfig(enabled: true, repos: [])
        config.addRepo("alpha")
        let duplicateAdded = config.addRepo("alpha")
        #expect(!duplicateAdded)
        for i in 2...rcMaxServers { config.addRepo("repo\(i)") }
        #expect(config.repos.count == rcMaxServers)
        #expect(!config.canAddRepo)
        let overflowAdded = config.addRepo("one-too-many")
        #expect(!overflowAdded)
        #expect(config.repos.count == rcMaxServers)
    }

    @Test func removingARepoStopsOnlyThatServer() {
        var config = RemoteControlConfig(enabled: true, repos: repos)
        config.removeRepo("beta")
        #expect(config.reposToRun(keepAwake: true) == ["alpha", "gamma"])
    }

    @Test func aFailedRepoStopsAloneUntilTheSwitchIsFlipped() {
        var config = RemoteControlConfig(enabled: true, repos: repos)
        config.markFailed("beta", reason: "not trusted")
        #expect(config.reposToRun(keepAwake: true) == ["alpha", "gamma"])
        #expect(config.enabled)
        #expect(config.indicator(for: "beta", keepAwake: true, connected: false, stopping: false) == .failed)

        config.setEnabled(false)
        config.setEnabled(true)
        #expect(config.reposToRun(keepAwake: true) == repos)
    }

    @Test func indicatorFollowsTheRunRuleAndTheLink() {
        let config = RemoteControlConfig(enabled: true, repos: repos)
        #expect(config.indicator(for: "alpha", keepAwake: false, connected: false, stopping: false) == .off)
        #expect(config.indicator(for: "alpha", keepAwake: true, connected: false, stopping: false) == .pending)
        #expect(config.indicator(for: "alpha", keepAwake: true, connected: true, stopping: false) == .connected)
    }

    @Test func aServerStillShuttingDownIsNotShownAsOff() {
        var config = RemoteControlConfig(enabled: true, repos: repos)
        config.setEnabled(false)
        #expect(config.indicator(for: "alpha", keepAwake: true, connected: false, stopping: true) == .stopping)
        #expect(config.indicator(for: "alpha", keepAwake: true, connected: false, stopping: false) == .off)
    }

    @Test func theSingleRepoFromBeforeBecomesTheFirstEntry() {
        #expect(RemoteControlConfig.load(enabled: nil, repos: nil, legacyRepo: "my-skills")
            == RemoteControlConfig(enabled: true, repos: ["my-skills"]))
        #expect(RemoteControlConfig.load(enabled: true, repos: [], legacyRepo: "my-skills").repos.isEmpty)
    }

    @Test(arguments: [
        ("·✔︎· Connected · my-skills · main\nCapacity: 0/32", true as Bool?),
        ("·|· Connecting · my-skills · main", false),
        ("·|· Reconnecting · my-skills · main", false),
        ("·✗· Disconnected · my-skills · main", false),
        ("Capacity: 1/32\nfix: Connected sessions leak", nil),
    ])
    func linkStateComesFromTheStatusLine(frame: String, connected: Bool?) {
        #expect(remoteControlLinkState(in: frame) == connected)
    }
}
