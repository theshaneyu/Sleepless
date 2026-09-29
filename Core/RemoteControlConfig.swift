// RemoteControlConfig.swift. The Claude Remote Control rules, kept free of AppKit and Process
// so `swift test` can pin them down: which repos get a server, how the repo list changes,
// and what the popover's status light shows for each one.
import Foundation

let rcMaxServers = 5

enum RemoteControlIndicator: Equatable {
    case off         // not wanted right now: a switch is off
    case stopping    // no longer wanted, but its process is still shutting its sessions down
    case pending     // wanted, not reachable yet: starting, connecting, or waiting to retry
    case connected
    case failed      // a failure retrying can't fix; flipping the switch is the retry
}

struct RemoteControlConfig: Equatable {
    private(set) var enabled: Bool
    private(set) var repos: [String]
    private(set) var failures: [String: String] = [:]

    init(enabled: Bool, repos: [String]) {
        self.enabled = enabled
        self.repos = []
        repos.forEach { addRepo($0) }
    }

    // Before multi-repo support there was a single repo setting; it becomes the first entry.
    static func load(enabled: Bool?, repos: [String]?, legacyRepo: String?) -> RemoteControlConfig {
        RemoteControlConfig(enabled: enabled ?? true, repos: repos ?? legacyRepo.map { [$0] } ?? [])
    }

    var canAddRepo: Bool { repos.count < rcMaxServers }

    @discardableResult
    mutating func addRepo(_ repo: String) -> Bool {
        guard canAddRepo, !repos.contains(repo) else { return false }
        repos.append(repo)
        return true
    }

    mutating func removeRepo(_ repo: String) {
        repos.removeAll { $0 == repo }
        failures[repo] = nil
    }

    // Flipping the switch, either way, gives every failed repo another try.
    mutating func setEnabled(_ on: Bool) {
        enabled = on
        failures = [:]
    }

    mutating func markFailed(_ repo: String, reason: String) {
        guard repos.contains(repo) else { return }
        failures[repo] = reason
    }

    // The one rule every start and stop follows: servers run only while the Mac is kept awake
    // AND the Remote Control switch is on, and never for a repo that failed for good.
    func reposToRun(keepAwake: Bool) -> [String] {
        guard keepAwake, enabled else { return [] }
        return repos.filter { failures[$0] == nil }
    }

    func indicator(for repo: String, keepAwake: Bool, connected: Bool, stopping: Bool) -> RemoteControlIndicator {
        if failures[repo] != nil { return .failed }
        guard reposToRun(keepAwake: keepAwake).contains(repo) else { return stopping ? .stopping : .off }
        return connected ? .connected : .pending
    }
}

// The CLI's status line reads "·✔︎· Connected · <repo> · <branch>" once phones can reach it, and
// "Connecting", "Reconnecting" or "Disconnected" otherwise. Only a line's first word counts, so a
// session title that happens to say "connected" can't turn the light green. nil: no status line.
func remoteControlLinkState(in frame: String) -> Bool? {
    let leadWords = frame.split(separator: "\n").compactMap { line in
        line.split(whereSeparator: { !$0.isLetter }).first.map(String.init)
    }
    return leadWords.reversed().lazy.compactMap { word -> Bool? in
        switch word {
        case "Connected": return true
        case "Connecting", "Reconnecting", "Disconnected": return false
        default: return nil
        }
    }.first
}
