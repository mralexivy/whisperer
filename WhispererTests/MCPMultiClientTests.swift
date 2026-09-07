//
//  MCPMultiClientTests.swift
//  WhispererTests
//
//  Integration tests verifying that multiple MCP clients can connect
//  simultaneously and that sessions are correctly isolated.
//
//  Uses a dedicated port (18548) separate from MCPServerTests (18547) so the
//  two suites can run without interfering with each other.
//
//  IMPORTANT — do NOT use DispatchSemaphore here.  See MCPServerTests.swift:19
//  for the full explanation; the same deadlock risk applies here because
//  `class setUp()` runs on the main thread.
//

import XCTest
@testable import whisperer

final class MCPMultiClientTests: XCTestCase {

    static let testPort = 18548
    static var serverStarted = false
    private static var startupFailure: String?

    override class func setUp() {
        super.setUp()
        guard !serverStarted else { return }
        serverStarted = true

        let ready = XCTestExpectation(description: "MCP multi-client server on \(testPort)")
        Task {
            await WhispererMCPServer.shared.restart(port: testPort)
            ready.fulfill()
        }
        guard XCTWaiter().wait(for: [ready], timeout: 10) == .completed else {
            startupFailure = "MCP server did not start within 10s on port \(testPort)"
            return
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !isPortAccepting(testPort) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if !isPortAccepting(testPort) {
            startupFailure = "MCP server bound no listener on port \(testPort) within 5s"
        }
    }

    private static func isPortAccepting(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        if let failure = Self.startupFailure { XCTFail(failure) }
    }

    // MARK: - Helpers

    private func mcpURL() -> URL {
        URL(string: "http://localhost:\(Self.testPort)/mcp")!
    }

    /// POSTs an initialize request and returns (data, sessionID).
    private func initialize(clientName: String) async throws -> (Data, String) {
        var req = URLRequest(url: mcpURL())
        req.httpMethod = "POST"
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": clientName, "version": "1"],
            ],
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        let sid = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "MCP-Session-Id") ?? ""
        return (data, sid)
    }

    /// POSTs a JSON-RPC request with the given session id.
    private func post(_ body: [String: Any], sessionID: String) async throws -> (Data, Int) {
        var req = URLRequest(url: mcpURL())
        req.httpMethod = "POST"
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    // MARK: - Tests

    /// Two simultaneous initialize calls must yield two distinct non-empty session ids,
    /// and neither response must be an error.
    func testTwoClientsGetDistinctSessions() async throws {
        async let (_, sid1) = initialize(clientName: "ClientA")
        async let (_, sid2) = initialize(clientName: "ClientB")

        let (s1, s2) = try await (sid1, sid2)

        XCTAssertFalse(s1.isEmpty, "ClientA should receive a session id")
        XCTAssertFalse(s2.isEmpty, "ClientB should receive a session id")
        XCTAssertNotEqual(s1, s2, "Each client must receive a distinct session id")
    }

    /// tools/list succeeds independently under each session.
    func testToolsListWorksPerSession() async throws {
        let (_, sid1) = try await initialize(clientName: "ToolListA")
        let (_, sid2) = try await initialize(clientName: "ToolListB")

        let (data1, status1) = try await post([
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:] as [String: Any],
        ], sessionID: sid1)
        let (data2, status2) = try await post([
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:] as [String: Any],
        ], sessionID: sid2)

        XCTAssertEqual(status1, 200, "tools/list for session 1 should return 200")
        XCTAssertEqual(status2, 200, "tools/list for session 2 should return 200")

        let text1 = String(data: data1, encoding: .utf8) ?? ""
        let text2 = String(data: data2, encoding: .utf8) ?? ""
        XCTAssertTrue(text1.contains("list_meetings"), "Session 1 tools/list should list tools")
        XCTAssertTrue(text2.contains("list_meetings"), "Session 2 tools/list should list tools")
    }

    /// Concurrent tool calls from two sessions both succeed.
    func testConcurrentToolCallsBothSucceed() async throws {
        let (_, sid1) = try await initialize(clientName: "ConcurrentA")
        let (_, sid2) = try await initialize(clientName: "ConcurrentB")

        async let result1 = post([
            "jsonrpc": "2.0", "id": 3,
            "method": "tools/call",
            "params": ["name": "list_meetings", "arguments": ["limit": 3]],
        ], sessionID: sid1)
        async let result2 = post([
            "jsonrpc": "2.0", "id": 3,
            "method": "tools/call",
            "params": ["name": "list_meetings", "arguments": ["limit": 3]],
        ], sessionID: sid2)

        let (r1, r2) = try await (result1, result2)
        let text1 = String(data: r1.0, encoding: .utf8) ?? ""
        let text2 = String(data: r2.0, encoding: .utf8) ?? ""

        XCTAssertFalse(text1.contains("\"isError\":true"),
                        "Session 1 list_meetings should not error. Got: \(text1.prefix(400))")
        XCTAssertFalse(text2.contains("\"isError\":true"),
                        "Session 2 list_meetings should not error. Got: \(text2.prefix(400))")
    }

    /// A request carrying a fabricated session id must receive 404.
    func testFakeSessionIDReturns404() async throws {
        let (_, _) = try await initialize(clientName: "RealClient")

        let (_, status) = try await post([
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:] as [String: Any],
        ], sessionID: "00000000-FAKE-FAKE-FAKE-000000000000")

        XCTAssertEqual(status, 404, "Fabricated session id should yield 404")
    }

    /// After DELETEing session A, session B continues to work.
    func testDeleteSessionALeavesSessionBWorking() async throws {
        let (_, sidA) = try await initialize(clientName: "DeleteA")
        let (_, sidB) = try await initialize(clientName: "SurviveB")

        // Delete session A.
        var delReq = URLRequest(url: mcpURL())
        delReq.httpMethod = "DELETE"
        delReq.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        delReq.setValue(sidA, forHTTPHeaderField: "MCP-Session-Id")
        _ = try await URLSession.shared.data(for: delReq)

        // Session B's tools/list must still work.
        let (data, status) = try await post([
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:] as [String: Any],
        ], sessionID: sidB)

        XCTAssertEqual(status, 200, "Session B should still be alive after A is deleted")
        XCTAssertTrue((String(data: data, encoding: .utf8) ?? "").contains("list_meetings"))
    }
}
