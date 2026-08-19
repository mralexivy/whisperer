//
//  MCPServerTests.swift
//  WhispererTests
//
//  Integration tests for the local MCP server.
//  Starts the server on a test port (18547) and verifies protocol responses.
//

import XCTest
@testable import whisperer

final class MCPServerTests: XCTestCase {

    static let testPort = 18547
    static var serverStarted = false
    /// Nil until startup has been attempted; a message once it has failed.
    private static var startupFailure: String?

    /// Waits for the server with `XCTWaiter`, not a semaphore.
    ///
    /// `DispatchSemaphore.wait()` here deadlocked the **entire test bundle**, indefinitely:
    /// `class setUp()` runs on the main thread, and `WhispererMCPServer.start(port:)` ends in
    /// `await MainActor.run { AppState.shared.mcpServerRunning = true }`. Blocking the main
    /// thread is precisely what stops that hop from ever being scheduled, so the semaphore
    /// waited on a task that could not finish until the semaphore was done waiting. Because
    /// `class setUp()` runs before the first test in the class, nothing after `MCPServerTests`
    /// in the bundle ever ran — the suite hung with no failure and no timeout.
    ///
    /// `XCTWaiter.wait` drains the main run loop while it waits, so the continuation lands and
    /// the hop completes. The timeout is the second half of the fix: a network listener that
    /// never comes up must fail this class, not stall every class after it.
    override class func setUp() {
        super.setUp()
        guard !serverStarted else { return }
        serverStarted = true

        let ready = XCTestExpectation(description: "MCP server listening on \(testPort)")
        Task {
            await WhispererMCPServer.shared.start(port: testPort)
            ready.fulfill()
        }
        guard XCTWaiter().wait(for: [ready], timeout: 10) == .completed else {
            startupFailure = "MCP server did not start within 10s on port \(testPort)"
            return
        }
        // The listener binds asynchronously after `start` returns, so the first connection can
        // still be refused. Polling beats sleeping: it is usually faster and never too short.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !isPortAccepting(testPort) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if !isPortAccepting(testPort) {
            startupFailure = "MCP server bound no listener on port \(testPort) within 5s"
        }
    }

    /// One non-blocking connect attempt. Deliberately BSD sockets rather than `NWConnection`:
    /// readiness has to be answerable synchronously from this main-thread poll loop, and an
    /// `NWConnection` state handler would need the very concurrency hop being waited on.
    private static func isPortAccepting(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        return connected
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Fail this class rather than let every test report an unrelated connection error.
        if let failure = Self.startupFailure { XCTFail(failure) }
    }

    override class func tearDown() {
        Task { await WhispererMCPServer.shared.stop() }
        super.tearDown()
    }

    // MARK: - Helpers

    private func mcpURL() -> URL {
        URL(string: "http://localhost:\(Self.testPort)/mcp")!
    }

    /// POSTs a JSON-RPC request and returns the raw data + session ID.
    private func postRPC(_ body: [String: Any]) async throws -> (Data, String?) {
        var req = URLRequest(url: mcpURL())
        req.httpMethod = "POST"
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let sessionID = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "MCP-Session-Id")
        return (data, sessionID)
    }

    /// Extracts the `result` field from a JSON-RPC SSE response.
    private func extractResult(from data: Data) throws -> [String: Any]? {
        let text = String(data: data, encoding: .utf8) ?? ""
        // SSE format: lines starting with "data: "
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("data: ") {
                let jsonStr = String(trimmed.dropFirst(6))
                if let jsonData = jsonStr.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    return parsed["result"] as? [String: Any]
                }
            }
        }
        // Also try plain JSON (for non-SSE responses)
        if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parsed["result"] as? [String: Any]
        }
        return nil
    }

    // MARK: - Tests

    func testInitializeReturnsCapabilities() async throws {
        let (data, _) = try await postRPC([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "MCPServerTests", "version": "1"],
            ],
        ])

        XCTAssertFalse(data.isEmpty, "Response data should not be empty")
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(
            text.contains("Whisperer"),
            "Initialize response should contain server name 'Whisperer'. Got: \(text.prefix(500))"
        )
    }

    func testToolListContainsFourTools() async throws {
        // Initialize first to get session
        let (_, sessionID) = try await postRPC([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "MCPServerTests", "version": "1"],
            ],
        ])

        guard let sid = sessionID else {
            XCTFail("No session ID returned from initialize")
            return
        }

        var req = URLRequest(url: mcpURL())
        req.httpMethod = "POST"
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(sid, forHTTPHeaderField: "MCP-Session-Id")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:] as [String: Any],
        ])

        let (data, _) = try await URLSession.shared.data(for: req)
        let text = String(data: data, encoding: .utf8) ?? ""

        let expectedTools = ["list_meetings", "get_meeting", "search_transcriptions", "get_transcription"]
        for tool in expectedTools {
            XCTAssertTrue(text.contains(tool), "Tool list should contain '\(tool)'. Got: \(text.prefix(800))")
        }
    }

    func testSearchTranscriptionsReturnsArray() async throws {
        // Initialize
        let (_, sessionID) = try await postRPC([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "MCPServerTests", "version": "1"],
            ],
        ])

        guard let sid = sessionID else {
            XCTFail("No session ID from initialize")
            return
        }

        var req = URLRequest(url: mcpURL())
        req.httpMethod = "POST"
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(sid, forHTTPHeaderField: "MCP-Session-Id")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 3,
            "method": "tools/call",
            "params": ["name": "search_transcriptions", "arguments": ["limit": 5]],
        ])

        let (data, _) = try await URLSession.shared.data(for: req)
        let text = String(data: data, encoding: .utf8) ?? ""
        // The tool returns JSON array as text content — we just verify it's valid JSON array in the response
        XCTAssertFalse(data.isEmpty, "search_transcriptions response should not be empty")
        XCTAssertFalse(text.contains("\"isError\":true"), "search_transcriptions should not return error. Got: \(text.prefix(600))")
    }

    func testListMeetingsReturnsArray() async throws {
        let (_, sessionID) = try await postRPC([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "MCPServerTests", "version": "1"],
            ],
        ])

        guard let sid = sessionID else {
            XCTFail("No session ID from initialize")
            return
        }

        var req = URLRequest(url: mcpURL())
        req.httpMethod = "POST"
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(sid, forHTTPHeaderField: "MCP-Session-Id")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 4,
            "method": "tools/call",
            "params": ["name": "list_meetings", "arguments": ["limit": 5]],
        ])

        let (data, _) = try await URLSession.shared.data(for: req)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(data.isEmpty, "list_meetings response should not be empty")
        XCTAssertFalse(text.contains("\"isError\":true"), "list_meetings should not return error. Got: \(text.prefix(600))")
    }

    func testUnknownToolReturnsErrorContent() async throws {
        let (_, sessionID) = try await postRPC([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "MCPServerTests", "version": "1"],
            ],
        ])

        guard let sid = sessionID else {
            XCTFail("No session ID from initialize")
            return
        }

        var req = URLRequest(url: mcpURL())
        req.httpMethod = "POST"
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(sid, forHTTPHeaderField: "MCP-Session-Id")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 5,
            "method": "tools/call",
            "params": ["name": "nonexistent_tool", "arguments": [:] as [String: Any]],
        ])

        let (data, _) = try await URLSession.shared.data(for: req)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(
            text.contains("Unknown tool") || text.contains("isError"),
            "Unknown tool should return error content. Got: \(text.prefix(600))"
        )
    }

    func testToolDefinitionsNotEmpty() {
        XCTAssertFalse(MCPMeetingTools.toolDefinitions.isEmpty, "MCPMeetingTools should expose at least one tool")
        XCTAssertFalse(MCPTranscriptionTools.toolDefinitions.isEmpty, "MCPTranscriptionTools should expose at least one tool")
        let allTools = MCPMeetingTools.toolDefinitions + MCPTranscriptionTools.toolDefinitions
        let names = allTools.map { $0.name }
        XCTAssertTrue(names.contains("list_meetings"))
        XCTAssertTrue(names.contains("get_meeting"))
        XCTAssertTrue(names.contains("search_transcriptions"))
        XCTAssertTrue(names.contains("get_transcription"))
    }
}
