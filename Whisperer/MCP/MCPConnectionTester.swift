//
//  MCPConnectionTester.swift
//  Whisperer
//
//  "Test connection" for the MCP page: talks to the running server exactly like a
//  client would — GET /health, POST initialize, POST tools/list, DELETE the session —
//  and reports which step failed.
//

import Foundation

nonisolated struct MCPConnectionTestResult: Equatable, Sendable {
    let success: Bool
    /// One line per step, e.g. "Health ✓", "Initialize ✓ (Whisperer 1.4)".
    let steps: [String]
    /// Short summary for the UI.
    let message: String
}

nonisolated enum MCPConnectionTester {

    static func run(info: MCPConnectionInfo, timeout: TimeInterval = 8) async -> MCPConnectionTestResult {
        var steps: [String] = []
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.connectionProxyDictionary = [:]   // never route localhost through a proxy
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        func fail(_ message: String) -> MCPConnectionTestResult {
            MCPConnectionTestResult(success: false, steps: steps, message: message)
        }

        // 1. Health
        guard let healthURL = URL(string: info.healthURL), let mcpURL = URL(string: info.url) else {
            return fail("The connection URL is not valid")
        }
        do {
            let (data, response) = try await session.data(from: healthURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["ok"] as? Bool == true else {
                return fail("Health check returned HTTP \(status)")
            }
            steps.append("Health check passed")
        } catch {
            return fail("Server not reachable: \(error.localizedDescription)")
        }

        // 2. Initialize (JSON response mode, like a plain HTTP client)
        let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"whisperer-connection-test","version":"1"}}}"#
        let initResult = await post(session, url: mcpURL, body: initBody, sessionID: nil, token: info.token)
        guard initResult.status == 200 else {
            if initResult.status == 401 { return fail("Unauthorized — the access token was rejected") }
            return fail("Initialize failed: \(initResult.error ?? "HTTP \(initResult.status)")")
        }
        guard let initJSON = initResult.json,
              let result = initJSON["result"] as? [String: Any],
              let serverInfo = result["serverInfo"] as? [String: Any] else {
            return fail("Initialize returned an unexpected response")
        }
        let name = serverInfo["name"] as? String ?? "server"
        let version = serverInfo["version"] as? String ?? ""
        steps.append("Initialized \(name) \(version)".trimmingCharacters(in: .whitespaces))

        // 3. tools/list in that session
        let sid = initResult.sessionID
        let listResult = await post(session, url: mcpURL,
                                    body: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                                    sessionID: sid, token: info.token)
        guard listResult.status == 200,
              let tools = (listResult.json?["result"] as? [String: Any])?["tools"] as? [[String: Any]] else {
            return fail("tools/list failed: \(listResult.error ?? "HTTP \(listResult.status)")")
        }
        steps.append("\(tools.count) tools available")

        // 4. Clean up the session so the test does not occupy a slot.
        if let sid {
            var del = URLRequest(url: mcpURL)
            del.httpMethod = "DELETE"
            del.setValue(sid, forHTTPHeaderField: "MCP-Session-Id")
            if let token = info.token { del.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            _ = try? await session.data(for: del)
        }

        return MCPConnectionTestResult(success: true, steps: steps,
                                       message: "Connected — \(tools.count) tools available")
    }

    private struct PostResult {
        var status: Int = 0
        var json: [String: Any]?
        var sessionID: String?
        var error: String?
    }

    private static func post(_ session: URLSession, url: URL, body: String,
                             sessionID: String?, token: String?) async -> PostResult {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = Data(body.utf8)
        var out = PostResult()
        do {
            let (data, response) = try await session.data(for: req)
            let http = response as? HTTPURLResponse
            out.status = http?.statusCode ?? 0
            out.sessionID = http?.value(forHTTPHeaderField: "MCP-Session-Id")
            out.json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if out.status != 200 {
                out.error = ((out.json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(out.status)"
            }
        } catch {
            out.error = error.localizedDescription
        }
        return out
    }
}
