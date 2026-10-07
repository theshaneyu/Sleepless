// DashboardHTTP.swift. Just enough HTTP/1.1 for the phone dashboard: one request per
// connection, a Content-Length body, then the server closes. `tailscale serve` is the only
// client that should ever reach it, so anything fancier is out of scope by design.
import Foundation

let dashboardMaxRequestBytes = 64 * 1024

struct HTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    let headers: [String: String]   // keys lowercased
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

enum HTTPParseResult: Equatable, Sendable {
    case needMore
    case invalid
    case request(HTTPRequest)
}

func parseHTTPRequest(_ data: Data) -> HTTPParseResult {
    guard data.count <= dashboardMaxRequestBytes else { return .invalid }
    let separator = Data("\r\n\r\n".utf8)
    guard let headerEnd = data.range(of: separator) else { return .needMore }
    guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }

    let lines = head.components(separatedBy: "\r\n")
    let requestLine = lines[0].split(separator: " ")
    guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { return .invalid }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    let length = headers["content-length"].map { Int($0) } ?? 0
    guard let length, length >= 0 else { return .invalid }
    let bodyStart = headerEnd.upperBound
    guard data.count - bodyStart >= length else { return .needMore }

    let target = String(requestLine[1])
    let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
    return .request(HTTPRequest(method: String(requestLine[0]), path: path, headers: headers,
                                body: data.subdata(in: bodyStart..<(bodyStart + length))))
}

struct HTTPResponse: Sendable {
    let status: Int
    let contentType: String
    let body: Data
    var extraHeaders: [(String, String)] = []
    var cacheControl = "no-store"

    static func text(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: \(cacheControl)\r\n"
        head += "Connection: close\r\n"
        for (name, value) in extraHeaders { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}
