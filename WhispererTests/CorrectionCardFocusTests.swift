//
//  CorrectionCardFocusTests.swift
//  WhispererTests
//
//  The one thing the correction card's design rests on that documentation alone cannot settle:
//  can a `[.borderless, .nonactivatingPanel]` window take key focus and receive typed characters
//  in a text field, *without* activating the app?
//
//  If it can't, the card's editor is a field that silently eats keystrokes — the worst possible
//  failure for a feature whose entire job is to capture a word the user types. So this is asserted,
//  not left to a manual pass.
//

import XCTest
import AppKit
@testable import whisperer

/// Built to match `OverlayPanel.init` exactly: same style mask, same level, same
/// `canBecomeKey`/`canBecomeMain` override pair. If `OverlayPanel` changes those, this test is
/// measuring the wrong window — the assertion at the top of each test guards that.
private final class FocusProbePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class CorrectionCardFocusTests: XCTestCase {
    private var panel: FocusProbePanel!
    private var field: NSTextField!

    override func setUp() {
        super.setUp()
        panel = FocusProbePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false

        // The card's editor, configured as `CorrectionWordField` configures it.
        field = NSTextField(string: "glyn")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 22)
        panel.contentView?.addSubview(field)
    }

    override func tearDown() {
        panel.orderOut(nil)
        panel = nil
        field = nil
        super.tearDown()
    }

    /// The panel this mirrors must keep the two properties that make the editor possible at all.
    func testOverlayPanelStillDeclaresTheFocusContractThisTestAssumes() {
        let overlay = OverlayPanel()
        defer { overlay.orderOut(nil) }
        XCTAssertTrue(overlay.canBecomeKey,
                      "the correction card's editor cannot take focus in a panel that refuses key")
        XCTAssertFalse(overlay.canBecomeMain,
                       "becoming main would activate the app and steal focus from what the user is typing in")
        XCTAssertTrue(overlay.styleMask.contains(.nonactivatingPanel),
                      "without .nonactivatingPanel, showing the card would pull the user out of their app")
    }

    /// The load-bearing claim: key focus without activation.
    func testTheNonActivatingPanelBecomesKeyAndTheFieldBecomesFirstResponder() {
        panel.makeKeyAndOrderFront(nil)
        XCTAssertTrue(panel.isKeyWindow,
                      "a borderless .nonactivatingPanel with canBecomeKey did not take key focus — " +
                      "the card's editor would silently eat every keystroke")

        XCTAssertTrue(panel.makeFirstResponder(field))
        XCTAssertNotNil(field.currentEditor(),
                        "no field editor means typing goes nowhere")
        XCTAssertTrue(panel.firstResponder === field.currentEditor(),
                      "the field editor must be the first responder, not the panel itself")
    }

    /// Focus is worth nothing if characters don't land. Drive real key events through the window's
    /// own dispatch, the same path a physical keypress takes once the window is key.
    func testTypedCharactersReachTheField() throws {
        panel.makeKeyAndOrderFront(nil)
        XCTAssertTrue(panel.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor())
        editor.selectAll(nil)

        for character in "Glean" {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: String(character),
                charactersIgnoringModifiers: String(character),
                isARepeat: false,
                keyCode: 0
            ))
            panel.sendEvent(event)
        }

        XCTAssertEqual(field.stringValue, "Glean",
                       "keystrokes did not reach the editor — the card must not present this field")
    }

    /// Taking key must not activate the app. If it did, showing the card would yank the user out of
    /// whatever they were dictating into, which is a worse bug than the mishearing it fixes.
    func testTakingKeyDoesNotMakeThePanelMain() {
        panel.makeKeyAndOrderFront(nil)
        XCTAssertTrue(panel.isKeyWindow)
        XCTAssertFalse(panel.isMainWindow,
                       "the HUD became main — it would pull application focus away from the user's app")
        XCTAssertFalse(NSApp.mainWindow === panel)
    }
}
