//
//  MCPSessionRegistryTests.swift
//  WhispererTests
//
//  Edge cases for the bounded MCP session pool: per-client reuse, global cap,
//  LRU eviction (including sessions with open streams), DELETE, auth, unknown ids.
//

import XCTest
import MCP
@testable import whisperer

final class MCPSessionRegistryTests: XCTestCase {

    private static let port = 51999

    private func token() async -> String {
        await MainActor.run { AppState.shared.mcpBearerToken }
    }

    private func initialize(_ registry: MCPSessionRegistry,
                            client: String,
                            token: String? = nil) async -> HTTPResponse {
        let tok: String
        if let token { tok = token } else { tok = await self.token() }
        let body = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"\(client)","version":"1.0"}}}
        """
        let request = HTTPRequest(
            method: "POST",
            headers: [
                "Authorization": "Bearer \(tok)",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            ],
            body: Data(body.utf8),
            path: "/mcp")
        return await registry.route(request, lanEnabled: false, port: Self.port)
    }

    private func statusCode(_ r: HTTPResponse) -> Int { r.statusCode }

    func testReconnectsFromSameClientReuseSlots() async {
        let registry = MCPSessionRegistry()
        for _ in 0..<10 { _ = await initialize(registry, client: "claude-code") }
        let n = await registry.sessionCount(forClient: "claude-code")
        let cap = await registry.maxSessionsPerClient
        XCTAssertEqual(n, cap, "reconnect storm must not grow the pool past the per-client cap")
        await registry.shutdown()
    }

    func testReplacesOldestSessionOfSameClient() async {
        let registry = MCPSessionRegistry()
        _ = await initialize(registry, client: "claude-code")
        let first = await registry.sessionIDs(forClient: "claude-code")
        _ = await initialize(registry, client: "claude-code")
        _ = await initialize(registry, client: "claude-code")
        let now = await registry.sessionIDs(forClient: "claude-code")
        XCTAssertTrue(first.isDisjoint(with: now), "oldest session should have been replaced")
        await registry.shutdown()
    }

    func testOtherClientsAreNotEvictedByAChattyClient() async {
        let registry = MCPSessionRegistry()
        _ = await initialize(registry, client: "xcode")
        for _ in 0..<6 { _ = await initialize(registry, client: "claude-code") }
        let xcode = await registry.sessionCount(forClient: "xcode")
        XCTAssertEqual(xcode, 1)
        await registry.shutdown()
    }

    func testGlobalCapNeverRejectsAndNeverExceeded() async {
        let registry = MCPSessionRegistry()
        let cap = await registry.maxSessions
        for i in 0..<(cap * 3) {
            let r = await initialize(registry, client: "client-\(i)")
            XCTAssertNotEqual(statusCode(r), 503, "full pool must evict, not 503 (client-\(i))")
        }
        let n = await registry.sessionCount
        XCTAssertLessThanOrEqual(n, cap)
        await registry.shutdown()
    }

    func testFullPoolWithOpenStreamsStillAdmitsNewClient() async {
        let registry = MCPSessionRegistry()
        let cap = await registry.maxSessions
        var ids: [String] = []
        for i in 0..<cap {
            let r = await initialize(registry, client: "stream-\(i)")
            if let sid = r.headers[HTTPHeaderName.sessionID] { ids.append(sid) }
        }
        for sid in ids { await registry.streamOpened(id: sid) }
        let r = await initialize(registry, client: "newcomer")
        XCTAssertNotEqual(statusCode(r), 503, "regression: all-streams-open pool used to lock clients out")
        let n = await registry.sessionCount(forClient: "newcomer")
        XCTAssertEqual(n, 1)
        let total = await registry.sessionCount
        XCTAssertLessThanOrEqual(total, cap)
        await registry.shutdown()
    }

    func testEvictedSessionGets404() async {
        let registry = MCPSessionRegistry()
        let first = await initialize(registry, client: "claude-code")
        let sid = first.headers[HTTPHeaderName.sessionID]
        _ = await initialize(registry, client: "claude-code")
        _ = await initialize(registry, client: "claude-code")
        let req = HTTPRequest(
            method: "POST",
            headers: [
                "Authorization": "Bearer \(await token())",
                HTTPHeaderName.sessionID: sid ?? "missing",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            ],
            body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8),
            path: "/mcp")
        let r = await registry.route(req, lanEnabled: false, port: Self.port)
        XCTAssertEqual(statusCode(r), 404, "evicted client must get 404 so it re-initializes")
        await registry.shutdown()
    }

    func testBadTokenRejectedAndCreatesNoSession() async {
        let registry = MCPSessionRegistry()
        let r = await initialize(registry, client: "claude-code", token: "wrong")
        XCTAssertEqual(statusCode(r), 401)
        let n = await registry.sessionCount
        XCTAssertEqual(n, 0)
    }

    func testNonInitializeWithoutSessionIs400() async {
        let registry = MCPSessionRegistry()
        let req = HTTPRequest(
            method: "POST",
            headers: ["Authorization": "Bearer \(await token())",
                      "Content-Type": "application/json"],
            body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8),
            path: "/mcp")
        let r = await registry.route(req, lanEnabled: false, port: Self.port)
        XCTAssertEqual(statusCode(r), 400)
        let n = await registry.sessionCount
        XCTAssertEqual(n, 0)
    }

    func testDeleteFreesSlot() async {
        let registry = MCPSessionRegistry()
        let r = await initialize(registry, client: "claude-code")
        guard let sid = r.headers[HTTPHeaderName.sessionID] else { return XCTFail("no session id") }
        let del = HTTPRequest(
            method: "DELETE",
            headers: ["Authorization": "Bearer \(await token())", HTTPHeaderName.sessionID: sid],
            body: nil, path: "/mcp")
        _ = await registry.route(del, lanEnabled: false, port: Self.port)
        let n = await registry.sessionCount
        XCTAssertEqual(n, 0)
    }

    func testClientWithoutNameStillBoundedByGlobalCap() async {
        let registry = MCPSessionRegistry()
        let cap = await registry.maxSessions
        for _ in 0..<(cap * 2) { _ = await initialize(registry, client: "") }
        let n = await registry.sessionCount
        XCTAssertLessThanOrEqual(n, cap)
        await registry.shutdown()
    }
}
