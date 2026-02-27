//
//  TextInjector.swift
//  Whisperer
//
//  Assistive text entry for dictation.
//  Enters transcribed text into the focused app via clipboard + paste,
//  similar to Apple's built-in dictation.
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

    // MARK: - Permission Check

    static func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)

        if accessEnabled {
            Logger.info("Accessibility permission granted", subsystem: .textInjection)
        } else {
            Logger.info("Accessibility permission not granted — user will be prompted", subsystem: .textInjection)
        }
    }

    static func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    // MARK: - Text Entry

    func insertText(_ text: String) async throws {
        guard !text.isEmpty else {
            throw InjectionError.emptyText
        }

        // Activate the target app
        if let pid = targetAppPID,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }

        guard Self.hasAccessibilityPermission() else {
            Logger.info("Accessibility not granted, copying to clipboard for manual paste", subsystem: .textInjection)
            copyToClipboard(text)
            return
        }

        // Enter dictated text via clipboard + paste (same mechanism as Apple's dictation)
        try await enterViaClipboardPaste(text)
    }

    // MARK: - Clipboard + Paste

    private func enterViaClipboardPaste(_ text: String) async throws {
        // Target app already activated — wait briefly for focus
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms for activation

        let pasteboard = NSPasteboard.general

        // Save current clipboard content
        let previousString = pasteboard.string(forType: .string)

        // Set transcribed text
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

        Logger.debug("Dictated text entered via clipboard paste", subsystem: .textInjection)
    }

    private func simulatePaste() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Logger.error("Failed to create event source for paste", subsystem: .textInjection)
            return
        }

        // Create Cmd+V key events (V key code = 0x09)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            Logger.error("Failed to create paste key events", subsystem: .textInjection)
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

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
            return "Cannot enter empty text"
        }
    }
}
