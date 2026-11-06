//
//  MCPClientInteropTests.swift
//  WhispererTests
//
//  Real MCP clients against the running Whisperer server — not hand-built HTTP requests.
//
//  Always on: the MCP Swift SDK's own client (`HTTPClientTransport`), an independent client
//  implementation, in streaming (SSE) and plain-JSON modes, with and without the token.
//
//  Opt-in (TEST_RUNNER_WHISPERER_LIVE_CLI=1): the installed Claude Code and Codex connect
//  using the exact config Whisperer's "Snippet" button produces, and call a tool. These use a
//  little of the signed-in plan's usage.
//

import MCP
import XCTest
@testable import whisperer

final class MCPClientInteropTests: XCTestCase {

    static let port = 18610
    private static var started = false
    private var savedRequireToken = false

    override class func setUp() {
        super.setUp()
        guard !started else { return }
        started = true
        let ready = XCTestExpectation(description: "server up")
        Task {
            await WhispererMCPServer.shared.restart(port: port)
            ready.fulfill()
        }
        _ = XCTWaiter().wait(for: [ready], timeout: 15)
        // Poll /health until the listener accepts.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let done = XCTestExpectation(description: "health")
            var ok = false
            URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)/health")!) { _, resp, _ in
                ok = (resp as? HTTPURLResponse)?.statusCode == 200
                done.fulfill()
            }.resume()
            _ = XCTWaiter().wait(for: [done], timeout: 2)
            if ok { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    override class func tearDown() {
        Task { await WhispererMCPServer.shared.stop() }
        super.tearDown()
    }

    override func setUp() async throws {
        try await super.setUp()
        savedRequireToken = await MainActor.run { AppState.shared.mcpRequireToken }
    }

    override func tearDown() async throws {
        let saved = savedRequireToken
        await MainActor.run { AppState.shared.mcpRequireToken = saved }
        try await super.tearDown()
    }

    private var endpoint: URL { URL(string: "http://localhost:\(Self.port)/mcp")! }

    private func setTokenRequired(_ on: Bool) async -> String {
        await MainActor.run {
            AppState.shared.mcpRequireToken = on
            return AppState.shared.mcpBearerToken
        }
    }

    private func sdkRoundTrip(streaming: Bool, token: String?) async throws -> [String] {
        let transport = HTTPClientTransport(
            endpoint: endpoint, streaming: streaming,
            requestModifier: { request in
                var r = request
                if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                return r
            })
        let client = Client(name: "WhispererInteropTests", version: "1.0")
        _ = try await client.connect(transport: transport)
        let (tools, _) = try await client.listTools()
        let (content, isError) = try await client.callTool(name: "list_meetings", arguments: ["limit": 1])
        XCTAssertNotEqual(isError, true, "list_meetings returned an error: \(content)")
        XCTAssertTrue(tools.allSatisfy { $0.annotations.readOnlyHint == true }, "every tool is declared read-only")
        await client.disconnect()
        return tools.map(\.name)
    }

    // MARK: - Swift SDK client

    func testSDKClientStreamableHTTPWithoutToken() async throws {
        _ = await setTokenRequired(false)
        let names = try await sdkRoundTrip(streaming: true, token: nil)
        XCTAssertTrue(names.contains("list_meetings"))
        XCTAssertTrue(names.contains("search_transcriptions"))
    }

    func testSDKClientPlainJSONModeWithoutToken() async throws {
        _ = await setTokenRequired(false)
        let names = try await sdkRoundTrip(streaming: false, token: nil)
        XCTAssertTrue(names.contains("get_meeting"))
    }

    func testSDKClientWithRequiredToken() async throws {
        let token = await setTokenRequired(true)
        let names = try await sdkRoundTrip(streaming: true, token: token)
        XCTAssertTrue(names.contains("get_transcription"))
    }

    func testSDKClientRejectedWithoutRequiredToken() async throws {
        _ = await setTokenRequired(true)
        do {
            _ = try await sdkRoundTrip(streaming: false, token: nil)
            XCTFail("a client without the token must not get through when it is required")
        } catch {
            // Expected: 401.
        }
    }

    // MARK: - Live: installed Claude Code and Codex as MCP clients

    private func liveEnabled() throws {
        guard ProcessInfo.processInfo.environment["WHISPERER_LIVE_CLI"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_WHISPERER_LIVE_CLI=1 to run installed MCP clients")
        }
    }

    private let prompt = "Call the list_meetings tool from the whisperer MCP server with limit 1. If the call succeeded, reply with exactly WHISPERER_OK. If you could not call it, reply with exactly WHISPERER_FAIL and the reason."

    #if !APP_STORE
    /// Claude Code loads the very JSON the Claude Code "Snippet" button shows.
    private func runClaude(tokenRequired: Bool) async throws {
        guard let claude = CLIDiscovery.locate(.claudeCode) else { throw XCTSkip("claude not installed") }
        let token = await setTokenRequired(tokenRequired)
        let info = MCPConnectionInfo(url: endpoint.absoluteString, token: tokenRequired ? token : nil)
        let snippet = MCPClient.claudeCode.snippet(for: info)
        let (result, _) = try await CLIProcessRunner.run(
            executable: claude,
            arguments: { dir in
                ["-p", "--mcp-config", dir.appendingPathComponent("mcp.json").path, "--strict-mcp-config",
                 "--allowedTools", "mcp__whisperer__list_meetings", "--no-session-persistence",
                 "--output-format", "text", prompt]
            },
            stdin: "", files: ["mcp.json": snippet], timeout: 180)
        print("LIVE MCP claude (token \(tokenRequired)): exit=\(result.exitCode) \(result.stdout.prefix(300))")
        XCTAssertTrue(result.stdout.contains("WHISPERER_OK"), "stdout: \(result.stdout)\nstderr: \(result.stderr.suffix(500))")
    }

    func testLiveClaudeCodeConnectsWithoutToken() async throws { try liveEnabled(); try await runClaude(tokenRequired: false) }
    func testLiveClaudeCodeConnectsWithToken() async throws { try liveEnabled(); try await runClaude(tokenRequired: true) }

    /// Codex gets the server through `-c` overrides with the same keys the Codex snippet writes
    /// (`url`, `http_headers`), so the user's real config.toml is never touched.
    private func runCodex(tokenRequired: Bool) async throws {
        guard let codex = CLIDiscovery.locate(.codex) else { throw XCTSkip("codex not installed") }
        let token = await setTokenRequired(tokenRequired)
        let info = MCPConnectionInfo(url: endpoint.absoluteString, token: tokenRequired ? token : nil)
        let snippet = MCPClient.codex.snippet(for: info)
        XCTAssertTrue(snippet.contains("[mcp_servers.whisperer]"))
        XCTAssertFalse(snippet.contains("\nheaders ="), "Codex has no `headers` key")
        XCTAssertTrue(snippet.contains("default_tools_approval_mode = \"approve\""))
        var overrides = ["-c", "mcp_servers.whisperer.url=\"\(endpoint.absoluteString)\"",
                         "-c", "mcp_servers.whisperer.default_tools_approval_mode=\"approve\""]
        if tokenRequired {
            XCTAssertTrue(snippet.contains("http_headers"))
            overrides += ["-c", "mcp_servers.whisperer.http_headers={ Authorization = \"Bearer \(token)\" }"]
        }
        let (result, collected) = try await CLIProcessRunner.run(
            executable: codex,
            arguments: { dir in
                ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral",
                 "--ignore-user-config", "--color", "never", "-o", dir.appendingPathComponent("out.txt").path]
                + overrides + [prompt]
            },
            stdin: "", timeout: 240,
            collect: { try? String(contentsOf: $0.appendingPathComponent("out.txt"), encoding: .utf8) })
        let answer = collected ?? result.stdout
        print("LIVE MCP codex (token \(tokenRequired)): exit=\(result.exitCode) \(answer.prefix(300))")
        XCTAssertTrue(answer.contains("WHISPERER_OK"), "answer: \(answer)\nstderr: \(result.stderr.suffix(800))")
    }

    func testLiveCodexConnectsWithoutToken() async throws { try liveEnabled(); try await runCodex(tokenRequired: false) }
    func testLiveCodexConnectsWithToken() async throws { try liveEnabled(); try await runCodex(tokenRequired: true) }
    #endif
}
