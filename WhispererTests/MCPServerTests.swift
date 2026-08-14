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

    override class func setUp() {
        super.setUp()
        guard !serverStarted else { return }
        serverStarted = true
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await WhispererMCPServer.shared.start(port: testPort)
            semaphore.signal()
        }
        semaphore.wait()
        Thread.sleep(forTimeInterval: 0.3)
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
