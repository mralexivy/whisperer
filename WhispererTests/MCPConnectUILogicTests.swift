//
//  MCPConnectUILogicTests.swift
//  WhispererTests
//
//  The MCP Connect page's pure decisions: is a client already configured (and current),
//  which apps are on this Mac, how the picker orders them, and the guide copy.
//

import XCTest
@testable import whisperer

final class MCPConnectUILogicTests: XCTestCase {

    private let info = MCPConnectionInfo(url: "http://localhost:8080/mcp", token: nil)
    private let tokenInfo = MCPConnectionInfo(url: "http://localhost:8080/mcp", token: "tok-123")

    // MARK: - configState: JSON

    func testJSONWithoutFileOrEntryIsNotConfigured() {
        XCTAssertEqual(MCPClient.cursor.configState(info: info, fileContents: nil), .notConfigured)
        XCTAssertEqual(MCPClient.cursor.configState(info: info, fileContents: "  \n"), .notConfigured)
        XCTAssertEqual(MCPClient.cursor.configState(info: info, fileContents: #"{"mcpServers":{"other":{"url":"x"}}}"#),
                       .notConfigured)
        XCTAssertEqual(MCPClient.cursor.configState(info: info, fileContents: "{ not json"), .notConfigured,
                       "unparseable files are never an error")
    }

    func testJSONSnippetWeWriteIsConfigured() {
        for client in [MCPClient.claudeCode, .claudeDesktop, .cursor, .vscode, .windsurf] {
            let text = client.snippet(for: tokenInfo)
            XCTAssertEqual(client.configState(info: tokenInfo, fileContents: text), .configured, "\(client)")
            XCTAssertTrue(client.isConfigured(info: tokenInfo, fileContents: text))
        }
    }

    func testJSONMergedIntoRealFileIsConfigured() throws {
        let existing = Data(#"{"numStartups": 3, "mcpServers": {"github": {"type": "http", "url": "https://x"}}}"#.utf8)
        let merged = try MCPConfigMerge.mergeJSON(existing: existing, rootKey: "mcpServers",
                                                  entry: MCPClient.claudeCode.jsonEntry(for: info)!)
        XCTAssertEqual(MCPClient.claudeCode.configState(info: info, fileContents: String(decoding: merged, as: UTF8.self)),
                       .configured)
    }

    func testJSONWithOtherPortOrMissingTokenIsOutdated() {
        let old = MCPClient.cursor.snippet(for: MCPConnectionInfo(url: "http://localhost:9090/mcp", token: nil))
        XCTAssertEqual(MCPClient.cursor.configState(info: info, fileContents: old), .outdated)
        let noToken = MCPClient.cursor.snippet(for: info)
        XCTAssertEqual(MCPClient.cursor.configState(info: tokenInfo, fileContents: noToken), .outdated,
                       "token now required but the entry lacks it")
        let oldToken = MCPClient.cursor.snippet(for: MCPConnectionInfo(url: info.url, token: "stale"))
        XCTAssertEqual(MCPClient.cursor.configState(info: tokenInfo, fileContents: oldToken), .outdated)
    }

    func testVSCodeUsesServersRootKey() {
        let wrongRoot = MCPClient.cursor.snippet(for: info)   // mcpServers, not servers
        XCTAssertEqual(MCPClient.vscode.configState(info: info, fileContents: wrongRoot), .notConfigured)
    }

    // MARK: - configState: TOML

    func testCodexTOMLStates() {
        let other = "[mcp_servers.github]\nurl = \"https://x\"\n"
        XCTAssertEqual(MCPClient.codex.configState(info: info, fileContents: other), .notConfigured)

        let merged = MCPConfigMerge.mergeCodexTOML(existing: other, block: MCPClient.codexTOMLBlock(for: tokenInfo))
        XCTAssertEqual(MCPClient.codex.configState(info: tokenInfo, fileContents: merged), .configured)
        XCTAssertEqual(MCPClient.codex.configState(info: MCPConnectionInfo(url: "http://localhost:9999/mcp", token: nil),
                                                   fileContents: merged), .outdated)
    }

    func testCodexTOMLDottedDefinitionCounts() {
        let dotted = "model = \"o4\"\nmcp_servers.whisperer.url = \"http://localhost:8080/mcp\"\n"
        XCTAssertEqual(MCPClient.codex.configState(info: info, fileContents: dotted), .configured)
        // A whisperer key inside another server's table is not ours.
        let elsewhere = "[mcp_servers.github]\nwhisperer = \"http://localhost:8080/mcp\"\n"
        XCTAssertEqual(MCPClient.codex.configState(info: info, fileContents: elsewhere), .notConfigured)
    }

    func testTextClientsAreNeverConfigured() {
        XCTAssertEqual(MCPClient.chatgpt.configState(info: info, fileContents: info.url), .notConfigured)
        XCTAssertEqual(MCPClient.other.configState(info: info, fileContents: "anything"), .notConfigured)
    }

    // MARK: - Detection

    private func probe(existing: Set<String>, cli: Set<MCPClient> = [], files: [String: String] = [:]) -> MCPDetectionProbe {
        MCPDetectionProbe(home: URL(fileURLWithPath: "/Users/test"),
                          fileExists: { existing.contains($0) },
                          cliInstalled: { cli.contains($0) },
                          readFile: { files[$0.path] })
    }

    func testDetectsAppBundlesAndCLIs() {
        let p = probe(existing: ["/Applications/Cursor.app",
                                 "/Users/test/Applications/Windsurf.app",
                                 "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                                 "/Applications/ChatGPT.app"],
                      cli: [.claudeCode])
        XCTAssertTrue(MCPClientDetector.isInstalled(.cursor, probe: p))
        XCTAssertTrue(MCPClientDetector.isInstalled(.windsurf, probe: p), "~/Applications counts")
        XCTAssertTrue(MCPClientDetector.isInstalled(.codex, probe: p), "Codex bundled in ChatGPT.app counts")
        XCTAssertTrue(MCPClientDetector.isInstalled(.chatgpt, probe: p))
        XCTAssertTrue(MCPClientDetector.isInstalled(.claudeCode, probe: p))
        XCTAssertFalse(MCPClientDetector.isInstalled(.vscode, probe: p))
        XCTAssertFalse(MCPClientDetector.isInstalled(.claudeDesktop, probe: p))
        XCTAssertFalse(MCPClientDetector.isInstalled(.other, probe: p), "Other is never 'installed'")
    }

    func testCLIFallbackPathsWithoutDiscovery() {
        let p = probe(existing: ["/opt/homebrew/bin/codex", "/Users/test/.local/bin/claude"])
        XCTAssertTrue(MCPClientDetector.isInstalled(.codex, probe: p))
        XCTAssertTrue(MCPClientDetector.isInstalled(.claudeCode, probe: p))
    }

    func testPresenceReadsConfigFilesUnderProbeHome() {
        let cursorPath = "/Users/test/.cursor/mcp.json"
        let p = probe(existing: [], files: [cursorPath: MCPClient.cursor.snippet(for: info)])
        let presence = MCPClientDetector.presence(info: info, probe: p)
        XCTAssertEqual(presence[.cursor], MCPClientPresence(installed: false, config: .configured))
        XCTAssertEqual(presence[.codex], MCPClientPresence(installed: false, config: .notConfigured))
        XCTAssertEqual(presence.count, MCPClient.allCases.count)
    }

    // MARK: - Ordering

    func testInstalledAppsComeFirstConnectedLeading() {
        let presence: [MCPClient: MCPClientPresence] = [
            .claudeDesktop: .init(installed: true, config: .notConfigured),
            .vscode: .init(installed: true, config: .outdated),
            .cursor: .init(installed: false, config: .configured),   // configured though app not found
            .codex: .init(installed: true, config: .notConfigured),
            .other: .init(installed: true, config: .configured),      // never featured
        ]
        let (onThisMac, more) = MCPClientDetector.arrange(presence: presence)
        XCTAssertEqual(onThisMac, [.cursor, .vscode, .claudeDesktop, .codex],
                       "connected, then needs-update, then installed — catalog order within each")
        XCTAssertEqual(more, [.claudeCode, .windsurf, .antigravity, .chatgpt, .other], "Other client is last")
        XCTAssertEqual(Set(onThisMac + more), Set(MCPClient.allCases), "nothing is lost")
    }

    func testNothingDetectedPutsEverythingInMore() {
        let (onThisMac, more) = MCPClientDetector.arrange(presence: [:])
        XCTAssertTrue(onThisMac.isEmpty)
        XCTAssertEqual(more.last, .other)
        XCTAssertEqual(more.count, MCPClient.allCases.count)
    }

    // MARK: - Guide

    func testStepsAddTurnOnWhenServerIsOff() {
        let off = MCPConnectGuide.steps(for: .codex, autoInstall: true, serverOn: false)
        let on = MCPConnectGuide.steps(for: .codex, autoInstall: true, serverOn: true)
        XCTAssertEqual(off.count, on.count + 1)
        XCTAssertEqual(off.first?.title, "Whisperer turns on")
        XCTAssertTrue(off.first?.automatic ?? false)
        XCTAssertEqual(on.count, 3)
        XCTAssertTrue(on[0].automatic, "auto-install writes the file itself")
        XCTAssertTrue(on[0].detail.contains("~/.codex/config.toml"))
        XCTAssertEqual(on[1].title, "Restart Codex")
    }

    func testCopyModeStepsAreNotAutomatic() {
        let steps = MCPConnectGuide.steps(for: .cursor, autoInstall: false, serverOn: true)
        XCTAssertFalse(steps.contains(where: \.automatic))
        XCTAssertEqual(steps.first?.title, "Paste the setup")
    }

    func testPrimaryTitles() {
        XCTAssertEqual(MCPConnectGuide.primaryTitle(for: .codex, autoInstall: true, serverOn: true, config: .notConfigured),
                       "Connect to Codex")
        XCTAssertEqual(MCPConnectGuide.primaryTitle(for: .codex, autoInstall: true, serverOn: true, config: .outdated),
                       "Update Codex")
        XCTAssertEqual(MCPConnectGuide.primaryTitle(for: .cursor, autoInstall: true, serverOn: false, config: .notConfigured),
                       "Turn on & connect to Cursor")
        XCTAssertEqual(MCPConnectGuide.primaryTitle(for: .cursor, autoInstall: false, serverOn: true, config: .notConfigured),
                       "Copy setup")
        XCTAssertEqual(MCPConnectGuide.primaryTitle(for: .chatgpt, autoInstall: false, serverOn: true, config: .notConfigured),
                       "Copy connector URL")
    }

    func testFixSuggestions() {
        let ok = MCPConnectionTestResult(success: true, steps: [], message: "Connected — 7 tools available")
        XCTAssertNil(MCPConnectGuide.fix(for: ok, port: 8080))
        let unauthorized = MCPConnectionTestResult(success: false, steps: [], message: "Unauthorized — the access token was rejected")
        XCTAssertTrue(MCPConnectGuide.fix(for: unauthorized, port: 8080)!.contains("Connect it again"))
        let down = MCPConnectionTestResult(success: false, steps: [], message: "Server not reachable: refused")
        XCTAssertTrue(MCPConnectGuide.fix(for: down, port: 8123)!.contains("8123"))
    }
}
