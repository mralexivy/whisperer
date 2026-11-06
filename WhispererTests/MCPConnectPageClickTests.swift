//
//  MCPConnectPageClickTests.swift
//  WhispererTests
//
//  Click-level tests of the MCP Connect page: the real page is hosted in a real window and
//  controls are clicked with synthesized mouse events sent through `NSWindow.sendEvent`, so
//  SwiftUI's hit-testing, buttons and toggles run exactly as for a user. Every side effect
//  (config writes, pasteboard, Finder, server test, server on/off) is injected, so these
//  tests never touch the user's real ~/.codex, ~/.claude.json, ~/.cursor or clipboard.
//

import AppKit
import SwiftUI
import XCTest
@testable import whisperer

/// Records what the page asked for.
@MainActor
final class MCPFakeActions {
    var installs: [MCPClient] = []
    var copies: [String] = []
    var reveals: [MCPClient] = []
    var tests = 0
    var enabledCalls: [Bool] = []
    var installResult: (MCPClient) -> MCPInstallResult = { .installed(path: "/tmp/fake/\($0.rawValue).json") }
    var autoInstall: (MCPClient) -> Bool = { $0.canAutoInstall }
    var testResult = MCPConnectionTestResult(success: true, steps: ["Health check passed"],
                                             message: "Connected — 7 tools available")
    /// Read when the page is built.
    var presence: [MCPClient: MCPClientPresence] = [:]

    var actions: MCPConnectActions {
        let presence = self.presence
        return MCPConnectActions(
            install: { [unowned self] client, _ in installs.append(client); return installResult(client) },
            canAutoInstall: { [unowned self] in autoInstall($0) },
            copy: { [unowned self] in copies.append($0) },
            reveal: { [unowned self] in reveals.append($0) },
            test: { [unowned self] _ in tests += 1; return testResult },
            detect: { _ in presence },
            isServerEnabled: { true },
            setServerEnabled: { [unowned self] in enabledCalls.append($0) },
            isServerRunning: { true })
    }
}

@MainActor
final class MCPConnectPageClickTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private var window: NSWindow!
    private var fake: MCPFakeActions!
    private var scope = ""

    // AppState values a test may change; restored in tearDown.
    private var savedRequireToken = false
    private var savedLAN = false
    private var savedCustomURL = ""

    // Synchronous on purpose: an async setUp holds the main actor while it pumps the run loop,
    // so the page's main-actor work (detection landing) could not run until the test did.
    override func setUpWithError() throws {
        try super.setUpWithError()
        let app = AppState.shared
        savedRequireToken = app.mcpRequireToken
        savedLAN = app.mcpLANEnabled
        savedCustomURL = app.mcpCustomURL
        app.mcpLANEnabled = false
        app.mcpCustomURL = ""

        fake = MCPFakeActions()
        fake.presence = [
            .codex: MCPClientPresence(installed: true, config: .notConfigured),
            .claudeCode: MCPClientPresence(installed: true, config: .configured),
        ]
        scope = "mcp-click-\(UUID().uuidString)"
        let hosting = NSHostingView(rootView: MCPConnectPageView(colorScheme: .dark,
                                                                 actions: fake.actions,
                                                                 testScope: scope))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 1000, height: 2000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        window.setFrame(CGRect(x: 40, y: 40, width: 1000, height: 2000), display: true)
        self.window = window
        Self.keepAlive += [fake, hosting, window]
        // Detection runs detached, then lands on the main actor.
        for _ in 0..<60 where frame("mcp.moreApps") == nil { pump(0.05) }
        pump(0.3)
    }

    override func tearDownWithError() throws {
        window.orderOut(nil)
        let app = AppState.shared
        app.mcpRequireToken = savedRequireToken
        app.mcpLANEnabled = savedLAN
        app.mcpCustomURL = savedCustomURL
        try super.tearDownWithError()
    }

    // MARK: - Clicking

    private func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    private func frame(_ id: String) -> CGRect? {
        UITestFrames.frames[UITestFrames.key(scope: scope, id: id)]
    }

    private func click(_ id: String, xFraction: CGFloat = 0.5,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        pump(0.4)
        guard let frame = frame(id) else {
            let mine = UITestFrames.frames.keys.filter { $0.hasPrefix(scope) }.sorted()
            XCTFail("no frame for \(id); have \(mine)", file: file, line: line)
            return
        }
        let height = window.contentView?.bounds.height ?? 0
        let point = NSPoint(x: frame.minX + frame.width * xFraction, y: height - frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            pump(0.05)
        }
        pump(0.6)
    }

    // MARK: - Tests

    func testDetectedAppsAreTaggedAndPanelIsClosedInitially() {
        XCTAssertNotNil(frame("mcp.tile.codex"), "detected app is on the page")
        XCTAssertNotNil(frame("mcp.moreApps"), "undetected apps sit behind More apps")
        XCTAssertNil(frame("mcp.tile.cursor"), "More apps starts collapsed")
        XCTAssertNil(frame("mcp.panel.codex"))
    }

    func testClickingTileExpandsItsPanel() throws {
        try click("mcp.tile.codex")
        XCTAssertNotNil(frame("mcp.panel.codex"), "picking an app opens its inline panel")
        XCTAssertNotNil(frame("mcp.primary.codex"))
    }

    func testPrimaryButtonInstallsThenShowsSuccessAndRunsTest() throws {
        try click("mcp.tile.codex")
        try click("mcp.primary.codex")
        XCTAssertEqual(fake.installs, [.codex], "primary button writes the config through the injected installer")
        pump(0.6)
        XCTAssertNotNil(frame("mcp.success.codex"), "success state is shown")
        XCTAssertEqual(fake.tests, 1, "the connection test runs automatically after connecting")
        XCTAssertNotNil(frame("mcp.testOK.codex"), "test result is shown inline")
        XCTAssertTrue(fake.enabledCalls.isEmpty, "server already on — not toggled")
    }

    func testFailedInstallShowsErrorInline() throws {
        fake.installResult = { _ in .failed("Could not write config.toml: denied") }
        try click("mcp.tile.codex")
        try click("mcp.primary.codex")
        XCTAssertNotNil(frame("mcp.error.codex"))
        XCTAssertNil(frame("mcp.success.codex"))
        XCTAssertEqual(fake.tests, 0, "no test after a failed install")
    }

    func testCopySetupPathCopiesSnippet() throws {
        // A client this build cannot write: the primary button is "Copy setup".
        fake.autoInstall = { _ in false }
        let f = fake!
        f.installResult = { [unowned f] client in
            f.copies.append(client.snippet(for: AppState.shared.mcpConnectionInfo))
            return .copied(hint: client.instructions)
        }
        try click("mcp.tile.codex")
        try click("mcp.primary.codex")
        XCTAssertEqual(fake.copies, [MCPClient.codex.snippet(for: AppState.shared.mcpConnectionInfo)])
        XCTAssertNotNil(frame("mcp.success.codex"))
    }

    func testShowConfigRevealsSnippetAndCopyButtonCopiesIt() throws {
        try click("mcp.tile.codex")
        XCTAssertNil(frame("mcp.snippetText.codex"))
        try click("mcp.showConfig.codex")
        XCTAssertNotNil(frame("mcp.snippetText.codex"), "Show config reveals the snippet")
        try click("mcp.copy.snippet.codex")
        XCTAssertEqual(fake.copies.last, MCPClient.codex.snippet(for: AppState.shared.mcpConnectionInfo))
        try click("mcp.reveal.codex")
        XCTAssertEqual(fake.reveals, [.codex], "Reveal goes through the injected action, not Finder")
    }

    func testMoreAppsExpands() throws {
        try click("mcp.moreApps")
        XCTAssertNotNil(frame("mcp.tile.cursor"))
        XCTAssertNotNil(frame("mcp.tile.other"))
    }

    func testAdvancedExpandsAndRequireTokenToggleFlipsAppState() throws {
        AppState.shared.mcpRequireToken = false
        XCTAssertNil(frame("mcp.requireToken"))
        try click("mcp.advanced")
        XCTAssertNotNil(frame("mcp.requireToken"), "Advanced reveals the access settings")
        XCTAssertNotNil(frame("mcp.copy.streamable"))

        try click("mcp.requireToken")
        XCTAssertTrue(AppState.shared.mcpRequireToken, "clicking the switch requires a token")
        XCTAssertNotNil(frame("mcp.token.copy"), "token row appears")
        try click("mcp.requireToken")
        XCTAssertFalse(AppState.shared.mcpRequireToken)
    }

    func testEndpointCopyUsesInjectedPasteboard() throws {
        try click("mcp.advanced")
        try click("mcp.copy.streamable")
        XCTAssertEqual(fake.copies, [AppState.shared.mcpConnectionInfo.url])
    }
}
