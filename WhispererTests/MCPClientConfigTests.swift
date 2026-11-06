//
//  MCPClientConfigTests.swift
//  WhispererTests
//
//  Per-client MCP config snippets and the pure merge functions. Never touches the real
//  home directory.
//

import XCTest
@testable import whisperer

final class MCPClientConfigTests: XCTestCase {

    private let open = MCPConnectionInfo(url: "http://localhost:8080/mcp", token: nil)
    private let locked = MCPConnectionInfo(url: "http://localhost:8080/mcp", token: "tok123")

    private func json(_ s: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    private func entry(_ client: MCPClient, _ info: MCPConnectionInfo) throws -> [String: Any] {
        let root = try json(client.snippet(for: info))
        let key = try XCTUnwrap(client.jsonRootKey)
        let servers = try XCTUnwrap(root[key] as? [String: Any])
        return try XCTUnwrap(servers["whisperer"] as? [String: Any])
    }

    // MARK: - Connection info

    func testDerivedURLs() {
        XCTAssertEqual(open.sseURL, "http://localhost:8080/sse")
        XCTAssertEqual(open.healthURL, "http://localhost:8080/health")
        XCTAssertNil(open.authorizationHeader)
        XCTAssertEqual(locked.authorizationHeader, "Bearer tok123")
        XCTAssertEqual(locked.urlWithTokenQuery, "http://localhost:8080/mcp?token=tok123")
        let tunnel = MCPConnectionInfo(url: "https://x.trycloudflare.com/mcp/", token: "")
        XCTAssertNil(tunnel.token, "an empty token means no token")
        XCTAssertEqual(tunnel.sseURL, "https://x.trycloudflare.com/sse")
    }

    // MARK: - Snippets

    func testEveryClientHasASnippet() {
        for client in MCPClient.allCases {
            XCTAssertFalse(client.snippet(for: open).isEmpty, "\(client)")
            XCTAssertFalse(client.snippet(for: locked).isEmpty, "\(client)")
            XCTAssertFalse(client.snippet(for: open).contains("Bearer"), "\(client) leaks a header when no token is required")
            if client != .chatgpt {
                XCTAssertTrue(client.snippet(for: locked).contains("Bearer tok123"), "\(client) misses the token")
            }
        }
    }

    func testJSONSnippetsParse() throws {
        for client in MCPClient.allCases where client.snippetFormat == .json {
            _ = try entry(client, open)
            _ = try entry(client, locked)
        }
    }

    func testClaudeCodeUsesTypeHTTP() throws {
        let e = try entry(.claudeCode, locked)
        XCTAssertEqual(e["type"] as? String, "http")
        XCTAssertEqual(e["url"] as? String, "http://localhost:8080/mcp")
        XCTAssertEqual((e["headers"] as? [String: String])?["Authorization"], "Bearer tok123")
        XCTAssertNil(try entry(.claudeCode, open)["headers"])
        XCTAssertFalse(MCPClient.claudeCode.snippet(for: locked).contains("streamable-http"))
    }

    func testClaudeCodeCLICommand() {
        XCTAssertEqual(MCPClient.claudeCode.cliCommand(for: open),
                       "claude mcp add --transport http --scope user whisperer http://localhost:8080/mcp")
        XCTAssertEqual(MCPClient.claudeCode.cliCommand(for: locked),
                       "claude mcp add --transport http --scope user whisperer http://localhost:8080/mcp --header 'Authorization: Bearer tok123'")
    }

    func testCodexUsesHTTPHeadersNeverHeaders() {
        let withToken = MCPClient.codex.snippet(for: locked)
        XCTAssertEqual(withToken, """
        [mcp_servers.whisperer]
        url = "http://localhost:8080/mcp"
        http_headers = { Authorization = "Bearer tok123" }
        default_tools_approval_mode = "approve"
        """)
        XCTAssertFalse(withToken.contains("\nheaders ="))
        XCTAssertFalse(withToken.hasPrefix("headers"))
        XCTAssertEqual(MCPClient.codex.snippet(for: open), """
        [mcp_servers.whisperer]
        url = "http://localhost:8080/mcp"
        default_tools_approval_mode = "approve"
        """)
        XCTAssertNil(MCPClient.codex.cliCommand(for: open), "codex mcp add cannot set the approval mode")
        XCTAssertNil(MCPClient.codex.cliCommand(for: locked), "with a token the TOML is the reliable path")
    }

    func testCodexTOMLEscapesStrings() {
        let weird = MCPConnectionInfo(url: "http://localhost:8080/mcp?a=\"b\"\\", token: "t\"k")
        let block = MCPClient.codexTOMLBlock(for: weird)
        XCTAssertTrue(block.contains(#"url = "http://localhost:8080/mcp?a=\"b\"\\""#), block)
        XCTAssertTrue(block.contains(#"Authorization = "Bearer t\"k""#), block)
    }

    func testVSCodeUsesServersRoot() throws {
        let root = try json(MCPClient.vscode.snippet(for: locked))
        XCTAssertNotNil(root["servers"])
        XCTAssertNil(root["mcpServers"])
        let e = try entry(.vscode, locked)
        XCTAssertEqual(e["type"] as? String, "http")
        let cli = try XCTUnwrap(MCPClient.vscode.cliCommand(for: open))
        XCTAssertTrue(cli.hasPrefix("code --add-mcp '{\"name\":\"whisperer\",\"type\":\"http\""), cli)
    }

    func testWindsurfAndAntigravityUseServerUrl() throws {
        for client in [MCPClient.windsurf, .antigravity] {
            let e = try entry(client, locked)
            XCTAssertEqual(e["serverUrl"] as? String, "http://localhost:8080/mcp", "\(client)")
            XCTAssertNil(e["url"], "\(client)")
            XCTAssertEqual((e["headers"] as? [String: String])?["Authorization"], "Bearer tok123")
        }
    }

    func testCursorUsesURL() throws {
        let e = try entry(.cursor, open)
        XCTAssertEqual(e["url"] as? String, "http://localhost:8080/mcp")
        XCTAssertNil(e["type"])
    }

    func testClaudeDesktopBridgesThroughMCPRemote() throws {
        let e = try entry(.claudeDesktop, open)
        XCTAssertEqual(e["command"] as? String, "npx")
        XCTAssertEqual(e["args"] as? [String], ["-y", "mcp-remote@latest", "http://localhost:8080/mcp"])
        let locked = try entry(.claudeDesktop, self.locked)
        XCTAssertEqual(locked["args"] as? [String],
                       ["-y", "mcp-remote@latest", "http://localhost:8080/mcp", "--header", "Authorization: Bearer tok123"])
        let lan = try entry(.claudeDesktop, MCPConnectionInfo(url: "http://mac.local:8080/mcp", token: "t"))
        XCTAssertTrue((lan["args"] as? [String] ?? []).contains("--allow-http"), "mcp-remote refuses plain http off-loopback")
    }

    func testGenericSnippetListsBothTransportsAndCurl() {
        let s = MCPClient.other.snippet(for: locked)
        XCTAssertTrue(s.contains("http://localhost:8080/mcp"))
        XCTAssertTrue(s.contains("http://localhost:8080/sse"))
        XCTAssertTrue(s.contains("Authorization: Bearer tok123"))
        XCTAssertTrue(s.contains("?token=tok123"))
        XCTAssertTrue(s.contains("curl -s"))
        XCTAssertTrue(s.contains("tools/list"))
        XCTAssertFalse(MCPClient.other.snippet(for: open).contains("Authorization"))
    }

    func testChatGPTSnippetIsTheURL() {
        XCTAssertEqual(MCPClient.chatgpt.snippet(for: open), "http://localhost:8080/mcp")
        XCTAssertFalse(MCPClient.chatgpt.canAutoInstall)
    }

    func testConfigPathsAreUnderHome() {
        let home = URL(fileURLWithPath: "/Users/test")
        XCTAssertEqual(MCPClient.claudeCode.configPath(home: home)?.path, "/Users/test/.claude.json")
        XCTAssertEqual(MCPClient.codex.configPath(home: home)?.path, "/Users/test/.codex/config.toml")
        XCTAssertEqual(MCPClient.cursor.configPath(home: home)?.path, "/Users/test/.cursor/mcp.json")
        XCTAssertEqual(MCPClient.vscode.configPath(home: home)?.path,
                       "/Users/test/Library/Application Support/Code/User/mcp.json")
        XCTAssertEqual(MCPClient.windsurf.configPath(home: home)?.path,
                       "/Users/test/.codeium/windsurf/mcp_config.json")
        XCTAssertNil(MCPClient.antigravity.configPath(home: home))
        XCTAssertEqual(MCPClient.codex.configPathDisplay, "~/.codex/config.toml")
    }

    // MARK: - mergeCodexTOML

    private let userCodexConfig = """
    model = "gpt-5.5"

    [mcp_servers.node_repl]
    command = "node"
    args = [
      "repl.js",
    ]

    [mcp_servers.node_repl.env]
    NODE_ENV = "dev"

    [mcp_servers.whisperer]
    url = "http://localhost:8080/mcp"
    headers = { Authorization = "Bearer old" }

    [mcp_servers.whisperer.env]
    FOO = "bar"

    [projects."/Users/me/code"]
    trust_level = "trusted"
    """

    func testMergeCodexReplacesStaleBlockAndKeepsOthers() {
        let block = MCPClient.codexTOMLBlock(for: locked)
        let merged = MCPConfigMerge.mergeCodexTOML(existing: userCodexConfig, block: block)

        XCTAssertTrue(merged.contains("[mcp_servers.node_repl]\ncommand = \"node\"\nargs = [\n  \"repl.js\",\n]"))
        XCTAssertTrue(merged.contains("[mcp_servers.node_repl.env]\nNODE_ENV = \"dev\""))
        XCTAssertTrue(merged.contains("[projects.\"/Users/me/code\"]\ntrust_level = \"trusted\""))
        XCTAssertTrue(merged.hasPrefix("model = \"gpt-5.5\""))

        XCTAssertFalse(merged.contains("headers = { Authorization = \"Bearer old\" }"), "stale invalid key must go")
        XCTAssertFalse(merged.contains("[mcp_servers.whisperer.env]"))
        XCTAssertFalse(merged.contains("FOO = \"bar\""))
        XCTAssertEqual(merged.components(separatedBy: "[mcp_servers.whisperer]").count, 2, "exactly one whisperer table")
        XCTAssertTrue(merged.hasSuffix(block + "\n"))
    }

    func testMergeCodexIsIdempotent() {
        let block = MCPClient.codexTOMLBlock(for: locked)
        let once = MCPConfigMerge.mergeCodexTOML(existing: userCodexConfig, block: block)
        let twice = MCPConfigMerge.mergeCodexTOML(existing: once, block: block)
        XCTAssertEqual(once, twice)
    }

    func testMergeCodexRemovesDuplicatesAndDottedForms() {
        let messy = """
        mcp_servers.whisperer.url = "http://old/mcp"

        [mcp_servers.whisperer]
        url = "a"

        [mcp_servers]
        whisperer = { url = "b" }
        other = { url = "keep" }

        [ mcp_servers . "whisperer" ]  # quoted duplicate
        url = "c"
        """
        let merged = MCPConfigMerge.mergeCodexTOML(existing: messy, block: MCPClient.codexTOMLBlock(for: open))
        XCTAssertFalse(merged.contains("http://old/mcp"))
        XCTAssertFalse(merged.contains("url = \"a\""))
        XCTAssertFalse(merged.contains("url = \"b\""))
        XCTAssertFalse(merged.contains("url = \"c\""))
        XCTAssertTrue(merged.contains("other = { url = \"keep\" }"))
        XCTAssertTrue(merged.contains("[mcp_servers]"))
    }

    func testMergeCodexIntoEmptyFile() {
        let block = MCPClient.codexTOMLBlock(for: open)
        XCTAssertEqual(MCPConfigMerge.mergeCodexTOML(existing: "", block: block), block + "\n")
    }

    func testMergeCodexLeavesSimilarlyNamedServers() {
        let toml = "[mcp_servers.whisperer_old]\nurl = \"x\"\n\n[mcp_servers.whisperer-2.env]\nA = \"1\"\n"
        let merged = MCPConfigMerge.mergeCodexTOML(existing: toml, block: MCPClient.codexTOMLBlock(for: open))
        XCTAssertTrue(merged.contains("[mcp_servers.whisperer_old]\nurl = \"x\""))
        XCTAssertTrue(merged.contains("[mcp_servers.whisperer-2.env]\nA = \"1\""))
    }

    // MARK: - mergeJSON

    func testMergeJSONPreservesOtherServersAndKeys() throws {
        let existing = Data("""
        {"theme":"dark","mcpServers":{"other":{"url":"http://x/mcp"},"whisperer":{"type":"streamable-http","url":"old"}}}
        """.utf8)
        let entry = try XCTUnwrap(MCPClient.claudeCode.jsonEntry(for: open))
        let merged = try MCPConfigMerge.mergeJSON(existing: existing, rootKey: "mcpServers", entry: entry)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        XCTAssertEqual(root["theme"] as? String, "dark")
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["other"] as? [String: Any])?["url"] as? String, "http://x/mcp")
        let w = try XCTUnwrap(servers["whisperer"] as? [String: Any])
        XCTAssertEqual(w["type"] as? String, "http")
        XCTAssertEqual(w["url"] as? String, "http://localhost:8080/mcp")
        XCTAssertFalse(String(decoding: merged, as: UTF8.self).contains("\\/"), "slashes must not be escaped")
    }

    func testMergeJSONCreatesFileContents() throws {
        let entry = try XCTUnwrap(MCPClient.vscode.jsonEntry(for: open))
        for existing in [nil, Data(), Data("  \n".utf8)] as [Data?] {
            let merged = try MCPConfigMerge.mergeJSON(existing: existing, rootKey: "servers", entry: entry)
            let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
            XCTAssertNotNil((root["servers"] as? [String: Any])?["whisperer"])
        }
    }

    func testMergeJSONRejectsMalformedInput() throws {
        let entry = try XCTUnwrap(MCPClient.cursor.jsonEntry(for: open))
        let bad: [String] = [
            "{ \"mcpServers\": { ",                         // truncated
            "// comment\n{\"mcpServers\":{}}",               // JSONC
            "[1,2,3]",                                       // not an object
            "{\"mcpServers\": [\"not\", \"a\", \"map\"]}",   // wrong root type
        ]
        for text in bad {
            XCTAssertThrowsError(try MCPConfigMerge.mergeJSON(existing: Data(text.utf8),
                                                              rootKey: "mcpServers", entry: entry), text)
        }
    }

    func testPrettyJSONEscapes() {
        let v = MCPJSONValue.object([("a\"b", .string("line\nbreak\\"))])
        let parsed = try? JSONSerialization.jsonObject(with: Data(v.pretty().utf8)) as? [String: String]
        XCTAssertEqual(parsed?["a\"b"], "line\nbreak\\")
        XCTAssertEqual(MCPShell.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(MCPShell.quote("http://localhost:8080/mcp"), "http://localhost:8080/mcp")
    }
}
