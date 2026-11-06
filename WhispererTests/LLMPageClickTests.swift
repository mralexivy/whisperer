//
//  LLMPageClickTests.swift
//  WhispererTests
//
//  Click-level tests of the LLM settings page: the real page is hosted in a real window and
//  controls are clicked with synthesized mouse-down / mouse-up events through
//  `NSWindow.sendEvent`, so SwiftUI's own hit-testing, buttons, switches and the inline
//  panels run exactly as for a user. Targets come from `uiTestFrame(_:)` (debug builds only).
//

import AppKit
import SwiftUI
import XCTest
@testable import whisperer

@MainActor
final class LLMPageClickTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private var window: NSWindow!
    private var store: ConnectedAIStore!

    // Synchronous on purpose: an async setUp holds the main actor while it spins the run
    // loop, so the page's own main-actor work (the readiness refresh) can't land until the
    // test body runs — and then overwrites the state the test injected.
    override func setUpWithError() throws {
        try super.setUpWithError()
        store = ConnectedAIStore(
            defaults: UserDefaults(suiteName: "LLMPageClick-\(UUID().uuidString)")!,
            keychain: KeychainStore(service: "com.ivy.whisperer.tests.\(UUID().uuidString)"))
        let hosting = NSHostingView(rootView: LLMPageView(colorScheme: .dark, store: store))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 1000, height: 2200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        // Ordering front constrains a window to the screen; restore the full height so every
        // control is inside the window and hittable.
        window.setFrame(CGRect(x: 40, y: 40, width: 1000, height: 2200), display: true)
        self.window = window
        Self.keepAlive += [store, hosting, window]
        // The page refreshes every provider on appear (the CLI checks run real processes).
        // Wait for all of them, or a late result overwrites the state a test injects.
        let deadline = Date().addingTimeInterval(20)
        pump(0.5)
        while Date() < deadline,
              !store.checking.isEmpty || store.readiness.count < store.availableProviders.count {
            pump(0.1)
        }
        pump(0.3)
    }

    override func tearDownWithError() throws {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.orderOut(nil)
        try super.tearDownWithError()
    }

    // MARK: - Clicking

    /// Spins the main run loop so SwiftUI commits updates. `Task.sleep` alone suspends without
    /// servicing the run loop, and the page would never re-render.
    private func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    private func frame(_ id: String) -> CGRect? {
        UITestFrames.frames[UITestFrames.key(scope: LLMPageView.testScope(for: store), id: id)]
    }

    /// Clicks a tagged control at a fraction of its frame (rows are clicked near the top so
    /// an open panel underneath isn't hit instead).
    private func click(_ id: String, in target: NSWindow? = nil, x: CGFloat = 0.5, y: CGFloat = 0.5,
                       topInset: CGFloat? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let win = target ?? window!
        pump(0.4)
        guard let f = frame(id) else {
            let scope = LLMPageView.testScope(for: store)
            XCTFail("no frame for \(id); have \(UITestFrames.frames.keys.filter { $0.hasPrefix(scope) }.sorted())",
                    file: file, line: line)
            return
        }
        let height = win.contentView?.bounds.height ?? 0
        let py = topInset.map { f.minY + $0 } ?? (f.minY + f.height * y)
        let point = NSPoint(x: f.minX + f.width * x, y: height - py)
        // Move in first (SwiftUI arms a button's press on hover tracking), then a real-length press.
        for (type, hold) in [(NSEvent.EventType.mouseMoved, 0.15), (.leftMouseDown, 0.2), (.leftMouseUp, 0.05)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            win.sendEvent(event)
            pump(hold)
        }
        pump(0.6)
    }

    private func clickRow(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try click(id, x: 0.3, topInset: 30, file: file, line: line)
    }

    // MARK: - Tests

    func testClickingKeepLocalSwitchTogglesIt() throws {
        XCTAssertFalse(store.keepLocalOnly)
        try click("llm.keepLocal")
        XCTAssertTrue(store.keepLocalOnly, "clicking the switch turns local-only on")
        try click("llm.keepLocal")
        XCTAssertFalse(store.keepLocalOnly)
    }

    func testClickingReadyProviderShowsInlineConsentThenAllowRoutesMeetings() throws {
        store._setReadinessForTesting(.ready(detail: "test"), for: .anthropicKey)
        try clickRow("llm.row.anthropicKey")
        XCTAssertNil(store.activeProviderID, "nothing routes before consent")
        XCTAssertNotNil(frame("llm.consent.allow"), "the consent panel unfolds in the row")

        try click("llm.consent.allow")
        XCTAssertTrue(store.hasConsent(.anthropicKey))
        XCTAssertEqual(store.activeProviderID, .anthropicKey)

        try clickRow("llm.row.local")
        XCTAssertNil(store.activeProviderID, "clicking On this Mac goes back to local")
    }

    func testClickingNotNowInConsentSendsNothing() throws {
        store._setReadinessForTesting(.ready(detail: "test"), for: .geminiKey)
        try clickRow("llm.row.geminiKey")
        try click("llm.consent.cancel")
        XCTAssertFalse(store.hasConsent(.geminiKey))
        XCTAssertNil(store.activeProviderID)
    }

    func testClickingNotSignedInCLIShowsCopyableSignInStep() throws {
        store._setReadinessForTesting(.notSignedIn(hint: "claude auth login"), for: .claudeCode)
        try clickRow("llm.row.claudeCode")
        XCTAssertNotNil(frame("llm.setup.copy.claudeCode"), "sign-in step unfolds with the command")
        XCTAssertNotNil(frame("llm.setup.check.claudeCode"))
        XCTAssertNil(store.activeProviderID, "a provider that isn't signed in can't be used")
    }

    func testClickingRowWithoutKeyShowsKeyFieldAndModelSheet() throws {
        store._setReadinessForTesting(.needsKey, for: .openAIKey)
        try clickRow("llm.row.openAIKey")
        XCTAssertNotNil(frame("llm.key.field.openAIKey"))
        XCTAssertNotNil(frame("llm.key.save.openAIKey"))
        try click("llm.key.model.openAIKey")
        pump(0.6)
        XCTAssertNotNil(window.attachedSheet, "Choose model… opens the key and model sheet")
    }

    func testClickingRowInUseOpensManageAndStopSending() throws {
        store._setReadinessForTesting(.ready(detail: "test"), for: .anthropicKey)
        store.grantConsent(.anthropicKey)
        try clickRow("llm.row.anthropicKey")
        XCTAssertEqual(store.activeProviderID, .anthropicKey, "an allowed provider is used without a second prompt")

        try clickRow("llm.row.anthropicKey")
        XCTAssertNotNil(frame("llm.manage.revoke.anthropicKey"), "clicking the row in use opens its manage panel")
        try click("llm.manage.revoke.anthropicKey")
        XCTAssertFalse(store.hasConsent(.anthropicKey))
        XCTAssertNil(store.activeProviderID)
    }

    // The dictation-polish switch is not clicked here: turning `llmEnabled` on loads a
    // multi-gigabyte model into the test host. Its frame is still checked to be present.
    #if !APP_STORE
    func testDictationPolishSwitchIsOnThePage() {
        pump(0.3)
        XCTAssertNotNil(frame("llm.dictation.toggle"))
    }
    #endif
}
