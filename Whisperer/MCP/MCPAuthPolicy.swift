//
//  MCPAuthPolicy.swift
//  Whisperer
//
//  Access-token policy for the local MCP server, plus request-path parsing.
//
//  Threat model
//  ------------
//  With LAN access OFF (the default) the listener binds to the loopback interface only
//  (`requiredInterfaceType = .loopback`), so nothing off this Mac can reach it. The
//  remaining local attacker is a web page in the user's browser trying to reach
//  `http://localhost:<port>` — directly (CORS-less "simple" requests) or via DNS
//  rebinding. Both are stopped by the Host/Origin check (`OriginValidator.localhost`):
//  browsers always send `Origin` on cross-origin POSTs and a rebinding attack carries the
//  attacker's hostname in `Host`. Native processes running as the same user could read
//  the token out of the client config files anyway, so a token adds little against them.
//  That is why the token is OPTIONAL on loopback (default off): it was the main reason
//  clients like Codex failed to connect, and it buys no real protection there.
//
//  With LAN access ON the listener is reachable by every device on the network and the
//  Origin check is disabled (hostnames vary), so the token is ALWAYS required — the UI
//  shows the "Require access token" switch forced on.
//
//  Clients that cannot set headers may pass the token as `?token=<tok>` on the URL.
//

import Foundation

nonisolated enum MCPAuthPolicy {

    /// Name of the query parameter accepted in place of an Authorization header.
    static let tokenQueryParameter = "token"

    /// Returns true when the request may proceed.
    ///
    /// - Parameters:
    ///   - headers: raw request headers (names matched case-insensitively).
    ///   - path: the raw request target, possibly with a query string.
    ///   - expectedToken: the server's token.
    ///   - required: whether a token is required at all.
    static func isAuthorized(headers: [String: String],
                             path: String?,
                             expectedToken: String,
                             required: Bool) -> Bool {
        guard required else { return true }
        guard !expectedToken.isEmpty else { return false }

        if let provided = bearerToken(in: headers), constantTimeEquals(provided, expectedToken) {
            return true
        }
        if let provided = MCPRequestTarget(path).queryItems[tokenQueryParameter],
           constantTimeEquals(provided, expectedToken) {
            return true
        }
        return false
    }

    /// Extracts the token from `Authorization: Bearer <tok>` (case-insensitive name and scheme).
    static func bearerToken(in headers: [String: String]) -> String? {
        guard let value = headers.first(where: { $0.key.lowercased() == "authorization" })?.value
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// Generates a fresh random token (URL-safe, 32 hex chars).
    static func makeToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

// MARK: - Request target

/// A parsed HTTP request target: path without query + decoded query items.
nonisolated struct MCPRequestTarget: Equatable {
    let path: String
    let queryItems: [String: String]

    init(_ raw: String?) {
        let raw = raw ?? "/"
        if let q = raw.firstIndex(of: "?") {
            path = String(raw[..<q])
            let query = String(raw[raw.index(after: q)...])
            var items: [String: String] = [:]
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let rawKey = kv.first else { continue }
                let key = String(rawKey).removingPercentEncoding ?? String(rawKey)
                let value = kv.count > 1
                    ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1]))
                    : ""
                if items[key] == nil { items[key] = value }
            }
            queryItems = items
        } else {
            path = raw
            queryItems = [:]
        }
    }

    /// Which endpoint this target addresses.
    var route: MCPRoute {
        var p = path
        // Absolute-form targets ("http://host/mcp") — keep only the path.
        if let url = URL(string: p), url.scheme != nil { p = url.path }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        switch p.lowercased() {
        case "/mcp":      return .streamableHTTP
        case "/sse":      return .legacySSE
        case "/messages", "/message": return .legacyMessages
        case "/health":   return .health
        default:          return .notFound
        }
    }
}

nonisolated enum MCPRoute: Equatable {
    case streamableHTTP
    case legacySSE
    case legacyMessages
    case health
    case notFound
}
