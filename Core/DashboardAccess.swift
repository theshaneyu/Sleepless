// DashboardAccess.swift. Who may use the phone dashboard. The server only listens on
// 127.0.0.1, and `tailscale serve` is what carries tailnet traffic to it: serve sets the Host
// to the Mac's ts.net name and stamps the caller's Tailscale login on every request.
//
// So a request is the owner's only if it arrived through serve (ts.net Host) AND carries the
// owner's login. That shuts out web pages in a browser on this Mac, which can reach
// 127.0.0.1 but send their own Host, including DNS-rebinding tricks. A local process could
// forge both headers, but it could already run `networksetup` itself, so the dashboard grants
// it nothing new.
import Foundation

struct DashboardAccess: Equatable, Sendable {
    let host: String
    let ownerLogin: String

    enum Verdict: Equatable { case allowed, forbidden(String) }

    func check(_ request: HTTPRequest) -> Verdict {
        let requestHost = request.header("host")?.split(separator: ":").first.map(String.init) ?? ""
        guard requestHost.caseInsensitiveCompare(host) == .orderedSame else {
            return .forbidden("Open this through your Tailscale address.")
        }
        guard let login = request.header("tailscale-user-login"),
              login.caseInsensitiveCompare(ownerLogin) == .orderedSame else {
            return .forbidden("This dashboard belongs to another Tailscale user.")
        }
        guard request.method != "GET" else { return .allowed }
        // A cross-site form can't send JSON without a preflight, and the server answers no preflight.
        guard request.header("content-type")?.lowercased().hasPrefix("application/json") == true else {
            return .forbidden("Expected a JSON request.")
        }
        if let origin = request.header("origin"), origin.caseInsensitiveCompare("https://\(host)") != .orderedSame {
            return .forbidden("Cross-origin request refused.")
        }
        return .allowed
    }
}
