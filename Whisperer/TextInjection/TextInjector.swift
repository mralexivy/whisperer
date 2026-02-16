//
//  TextInjector.swift
//  Whisperer
//
//  Cross-app text injection using Accessibility API for assistive text input.
//  Falls back to clipboard + paste simulation when direct insertion fails.
//

import Cocoa
import ApplicationServices

class TextInjector {

    // The PID of the app that was frontmost when recording started.
    // Must be captured BEFORE recording begins (before overlay steals focus).
    private var targetAppPID: pid_t?

    /// Call this before recording starts to capture which app should receive the text
    func captureTargetApp() {
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetAppPID = frontApp.processIdentifier
        } else {
            targetAppPID = nil
        }
    }

    // MARK: - Permission Request

    static func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)

        if accessEnabled {
            print("Accessibility permission granted")
        } else {
            print("Accessibility permission not granted - user will be prompted")
        }
    }

    static func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    // MARK: - Text Insertion

    func insertText(_ text: String) async throws {
        guard !text.isEmpty else {
            throw InjectionError.emptyText
        }

        // Activate the target app once upfront
        if let pid = targetAppPID,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }

        guard Self.hasAccessibilityPermission() else {
            print("No accessibility permission, copying to clipboard only")
            copyToClipboard(text)
            return
        }

        // Try quick AX insertion inline (no background dispatch — avoids queue contention)
        if let pid = targetAppPID {
            let appElement = AXUIElementCreateApplication(pid)
            // Cap AX messaging at 100ms so a hung target app can't block us
            AXUIElementSetMessagingTimeout(appElement, 0.1)
            if let element = getFocusedElement(from: appElement) {
                AXUIElementSetMessagingTimeout(element, 0.1)
                if insertIntoElement(element, text: text) {
                    print("Text inserted via Accessibility API")
                    return
                }
            }
        }

        // Fallback: clipboard + simulated paste (app already activated above)
        print("AX insertion failed, using clipboard + paste")
        try await insertViaClipboard(text)
    }

    private func getFocusedElement(from appElement: AXUIElement) -> AXUIElement? {
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success else {
            return nil
        }

        return (focusedElement as! AXUIElement)
    }

    private func insertIntoElement(_ element: AXUIElement, text: String) -> Bool {
        // Try inserting at selection first (replaces selection / inserts at cursor)
        let setSelectedText = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )

        if setSelectedText == .success {
            return true
        }

        // Fall back to setting the entire value
        let setValue = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            text as CFString
        )

        return setValue == .success
    }

    // MARK: - Clipboard + Paste Fallback

    private func insertViaClipboard(_ text: String) async throws {
        // Target app already activated in insertText() — just wait briefly for focus
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms for activation

        let pasteboard = NSPasteboard.general

        // Save current clipboard content
        let previousString = pasteboard.string(forType: .string)

        // Set new content
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V to paste
        simulatePaste()

        // Wait for paste to complete
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Restore previous clipboard content
        if let previousString = previousString {
            pasteboard.clearContents()
            pasteboard.setString(previousString, forType: .string)
        }

        print("Text inserted via clipboard + paste")
    }

    private func simulatePaste() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            print("Failed to create event source for paste")
            return
        }

        // Create Cmd+V key events
        // V key code is 0x09
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            print("Failed to create paste key events")
            return
        }

        // Set command flag
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // Post events to insert the pasted text
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - Clipboard Only (no Accessibility)

    private func copyToClipboard(_ text: String) {
        // Re-activate the target app
        if let pid = targetAppPID,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Notify that text was copied to clipboard
        NotificationCenter.default.post(
            name: NSNotification.Name("TextCopiedToClipboard"),
            object: nil,
            userInfo: ["text": text]
        )
    }
}

enum InjectionError: Error, LocalizedError {
    case emptyText

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Cannot insert empty text"
        }
    }
}
