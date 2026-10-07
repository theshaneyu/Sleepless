import Foundation
import Testing
@testable import SleeplessCore

@Suite struct DashboardAccessTests {
    let access = DashboardAccess(host: "mac.tail1234.ts.net", ownerLogin: "me@example.com")

    func request(_ headers: [String: String], method: String = "GET") -> HTTPRequest {
        HTTPRequest(method: method, path: "/", headers: headers, body: Data())
    }

    @Test func ownerThroughTailscaleServeIsAllowed() {
        let req = request(["host": "mac.tail1234.ts.net", "tailscale-user-login": "me@example.com"])
        #expect(access.check(req) == .allowed)
    }

    // A web page open on the Mac can reach 127.0.0.1, but not with the ts.net Host.
    @Test(arguments: ["127.0.0.1:47800", "localhost", "evil.example.com"])
    func requestsNotFromServeAreRefused(_ host: String) {
        let req = request(["host": host, "tailscale-user-login": "me@example.com"])
        #expect(access.check(req) != .allowed)
    }

    @Test func anotherTailscaleUserIsRefused() {
        #expect(access.check(request(["host": "mac.tail1234.ts.net", "tailscale-user-login": "guest@example.com"])) != .allowed)
        #expect(access.check(request(["host": "mac.tail1234.ts.net"])) != .allowed)
    }

    @Test func actionsMustBeSameOriginJSON() {
        let base = ["host": "mac.tail1234.ts.net", "tailscale-user-login": "me@example.com"]
        let form = base.merging(["content-type": "application/x-www-form-urlencoded"]) { $1 }
        let foreign = base.merging(["content-type": "application/json", "origin": "https://evil.example.com"]) { $1 }
        let own = base.merging(["content-type": "application/json", "origin": "https://mac.tail1234.ts.net"]) { $1 }
        #expect(access.check(request(form, method: "POST")) != .allowed)
        #expect(access.check(request(foreign, method: "POST")) != .allowed)
        #expect(access.check(request(own, method: "POST")) == .allowed)
    }
}

@Suite struct WifiSwitchRulesTests {
    let saved: Set<String> = ["bigcat", "Shane’s iPhone"]

    @Test func switchBetweenSavedNetworksInRange() {
        #expect(wifiSwitchRefusal(target: "bigcat", current: "Shane’s iPhone", saved: saved,
                                  inRange: ["bigcat"], busy: false) == nil)
    }

    // The phone usually reaches the Mac through the network being left: no saved password for
    // it means no way to rejoin it, so the switch must not start.
    @Test func neverLeavesANetworkItCannotComeBackTo() {
        #expect(wifiSwitchRefusal(target: "bigcat", current: "cafe", saved: saved,
                                  inRange: ["bigcat"], busy: false) == .noWayBack("cafe"))
    }

    @Test func refusesUnsavedOrOutOfRangeTargets() {
        #expect(wifiSwitchRefusal(target: "cafe", current: "bigcat", saved: saved,
                                  inRange: ["cafe"], busy: false) == .noSavedPassword("cafe"))
        #expect(wifiSwitchRefusal(target: "Shane’s iPhone", current: "bigcat", saved: saved,
                                  inRange: [], busy: false) == .notInRange("Shane’s iPhone"))
    }

    @Test func oneSwitchAtATime() {
        #expect(wifiSwitchRefusal(target: "bigcat", current: "Shane’s iPhone", saved: saved,
                                  inRange: ["bigcat"], busy: true) == .busy)
    }
}

@Suite struct DashboardHTTPTests {
    @Test func waitsForTheWholeBody() {
        let head = "POST /api/wifi/switch HTTP/1.1\r\nHost: mac\r\nContent-Length: 17\r\n\r\n"
        #expect(parseHTTPRequest(Data((head + "{\"ssid\":").utf8)) == .needMore)
        guard case .request(let req) = parseHTTPRequest(Data((head + "{\"ssid\":\"bigcat\"}").utf8)) else {
            Issue.record("expected a complete request")
            return
        }
        #expect(req.method == "POST")
        #expect(req.path == "/api/wifi/switch")
        #expect(req.header("Host") == "mac")
        #expect(String(data: req.body, encoding: .utf8) == "{\"ssid\":\"bigcat\"}")
    }
}
