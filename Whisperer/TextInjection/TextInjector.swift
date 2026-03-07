//
//  TextInjector.swift
//  Whisperer
//
//  Text entry for dictation via CGEvent unicode or clipboard paste.
//  Primary: posts keyboard events with unicode string (no clipboard disruption).
//  Fallback: clipboard + simulated Cmd+V for long text or CGEvent failure.
//

import Cocoa
import ApplicationServices

class TextInjector {

    // The PID of the app that was frontmost when recording started.
    // Must be captured BEFORE recording begins (before overlay steals focus).
    private var targetAppPID: pid_t?

    // CGEvent keyboardSetUnicodeString has a practical limit on UTF-16 units per event.
    // Beyond this, fall back to clipboard paste.
    private static let cgEventUnicodeLimit = 200

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

        guard AppState.shared.autoPasteEnabled && Self.hasAccessibilityPermission() else {
            Logger.info("Auto-paste disabled or accessibility not granted, copying to clipboard", subsystem: .textInjection)
            copyToClipboard(text)
            return
        }

        // Wait for target app activation
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Primary: CGEvent unicode insertion (no clipboard disruption).
        // Splits long text into chunks to stay within per-event UTF-16 limit.
        if enterViaCGEventUnicode(text) {
            return
        }
        Logger.warning("CGEvent unicode failed, falling back to clipboard paste", subsystem: .textInjection)

        // Fallback: clipboard + Cmd+V paste (CGEvent failure)
        try await enterViaClipboardPaste(text)
    }

    // MARK: - CGEvent Unicode Insertion

    /// Inserts text by posting CGEvent keyboard events with unicode string data.
    /// Splits long text into chunks of cgEventUnicodeLimit UTF-16 units each.
    /// No clipboard involvement — instant, zero side effects.
    private func enterViaCGEventUnicode(_ text: String) -> Bool {
        let utf16Array = Array(text.utf16)
        guard !utf16Array.isEmpty else { return false }

        // Split into chunks and post each as a separate key event
        let chunks = stride(from: 0, to: utf16Array.count, by: Self.cgEventUnicodeLimit).map {
            Array(utf16Array[$0..<min($0 + Self.cgEventUnicodeLimit, utf16Array.count)])
        }

        for (i, chunk) in chunks.enumerated() {
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                Logger.error("Failed to create CGEvent for unicode insertion (chunk \(i))", subsystem: .textInjection)
                return false
            }

            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)

            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            usleep(1000) // 1ms between keyDown/keyUp
            keyUp.post(tap: .cgAnnotatedSessionEventTap)

            // Small delay between chunks to let the target app process each event
            if i < chunks.count - 1 {
                usleep(2000) // 2ms between chunks
            }
        }

        Logger.debug("Text entered via CGEvent unicode (\(utf16Array.count) UTF-16 units, \(chunks.count) chunk(s))", subsystem: .textInjection)
        return true
    }

    // MARK: - Clipboard + Paste

    private func enterViaClipboardPaste(_ text: String) async throws {
        // Activation delay already applied in insertText

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
