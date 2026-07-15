//
//  TextInjector.swift
//  Whisperer
//
//  Text entry for dictation.
//  APP_STORE build: clipboard-only (no Accessibility, no CGEvent.post).
//  Non-App Store build: Clipboard+Cmd+V (primary) → CGEvent unicode fallback.
//
//  Architecture: Clipboard+Cmd+V is the universal default. Direct AX mutation
//  is NOT used as an insertion path — Chromium and other renderer-backed inputs
//  return AXSuccess but silently discard the write, causing silent failures.

import Cocoa
import ApplicationServices

// MARK: - ClipboardSnapshot

/// Full capture of NSPasteboard contents — all items, all types.
/// Plain-string-only restoration loses images, files, rich text, etc.
struct ClipboardSnapshot {
    struct StoredItem {
        let representations: [NSPasteboard.PasteboardType: Data]
    }
    private let items: [StoredItem]

    static func capture(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
        let stored = (pasteboard.pasteboardItems ?? []).map { item in
            var reps: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    reps[type] = data
                }
            }
            return StoredItem(representations: reps)
        }
        return ClipboardSnapshot(items: stored)
    }

    func restore(to pasteboard: NSPasteboard) {
        let rebuilt: [NSPasteboardItem] = items.map { stored in
            let item = NSPasteboardItem()
            for (type, data) in stored.representations {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.clearContents()
        if !rebuilt.isEmpty {
            pasteboard.writeObjects(rebuilt)
        }
    }
}

// MARK: - TextInjector

class TextInjector {

    // The PID and bundle ID of the app that was frontmost when recording started.
    // Must be captured BEFORE recording begins (before overlay shows).
    private var targetAppPID: pid_t?
    private var targetBundleID: String?

    #if !APP_STORE
    // CGEvent keyboardSetUnicodeString has a practical limit on UTF-16 units per event.
    private static let cgEventUnicodeLimit = 200

    // Per-app clipboard restore delay. Conservative default covers most apps.
    // Too short = pasting restored clipboard content instead of transcription.
    private static let defaultRestoreDelay: UInt64 = 300_000_000 // 300ms
    private static let restoreDelayByBundle: [String: UInt64] = [
        "com.google.Chrome":                   150_000_000,
        "org.mozilla.firefox":                 150_000_000,
        "com.apple.Safari":                    150_000_000,
        "com.microsoft.VSCode":                120_000_000,
        "com.todesktop.230313mzl4w4u92":       120_000_000, // Cursor
        "com.microsoft.Word":                  500_000_000,
        "com.microsoft.Excel":                 500_000_000,
        "com.apple.TextEdit":                  120_000_000,
    ]
    #endif

    /// Call this before recording starts to freeze which app receives the text.
    func captureTargetApp() {
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetAppPID = frontApp.processIdentifier
            targetBundleID = frontApp.bundleIdentifier
        } else {
            targetAppPID = nil
            targetBundleID = nil
        }
    }

    // MARK: - Permission Check

    #if !APP_STORE
    static func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }
    #endif

    // MARK: - Text Entry

    func insertText(_ text: String) async throws {
        guard !text.isEmpty else {
            throw InjectionError.emptyText
        }

        #if APP_STORE
        // App Store build: clipboard-only, no Accessibility or CGEvent.post.
        Logger.info("Clipboard mode — copying transcript to clipboard", subsystem: .textInjection)
        copyToClipboard(text)
        #else
        let axTrusted = Self.hasAccessibilityPermission()
        guard AppState.shared.autoPasteEnabled && axTrusted else {
            Logger.info("insertText: autoPaste=\(AppState.shared.autoPasteEnabled) AXTrusted=\(axTrusted) → clipboard only", subsystem: .textInjection)
            copyToClipboard(text)
            return
        }

        // Restore target app focus before insertion.
        if let pid = targetAppPID {
            try await activateApp(pid: pid)
        }

        // Tier 1: Clipboard + Cmd+V — the universal default.
        // Works with Chrome web inputs, Electron apps, Safari, AppKit, VS Code,
        // Slack, Notion, terminals, and every other destination. The target app
        // performs its own insertion (selection replacement, undo, DOM events).
        let pasted = try await enterViaClipboardPaste(text)
        if pasted {
            return
        }
        Logger.warning("Clipboard paste attempt ended without confirmed success, trying unicode", subsystem: .textInjection)

        // Tier 2: CGEvent unicode keyboard events.
        // Fallback for apps that intercept or block paste (e.g., secure fields,
        // some terminals configured to ignore Cmd+V).
        if enterViaCGEventUnicode(text) {
            return
        }
        Logger.warning("CGEvent unicode also failed — text may be lost", subsystem: .textInjection)
        #endif
    }

    // MARK: - Activation

    #if !APP_STORE
    /// Activates the target app and polls until it is frontmost, up to 200ms.
    private func activateApp(pid: pid_t) async throws {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [.activateIgnoringOtherApps])
        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms per poll
        }
        // Best effort — proceed even if PID not confirmed frontmost.
    }
    #endif

    // MARK: - Clipboard + Paste (Tier 1)

    #if !APP_STORE
    /// Copies text to the clipboard, posts Cmd+V, waits for the target to consume it,
    /// then restores the previous clipboard — all types preserved.
    ///
    /// Returns true always (paste is best-effort; we rely on it working rather than
    /// doing AX-read verification which is unreliable for renderer-backed inputs).
    @discardableResult
    private func enterViaClipboardPaste(_ text: String) async throws -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            Logger.error("Failed to write transcript to pasteboard", subsystem: .textInjection)
            return false
        }

        simulatePaste()
        let changeCountAfterWrite = pasteboard.changeCount

        // Wait for the target app to consume the paste. Delay is per-app tuned
        // because some apps (Word, slow Electron) read the clipboard asynchronously.
        let delay = Self.restoreDelayByBundle[targetBundleID ?? ""] ?? Self.defaultRestoreDelay
        try await Task.sleep(nanoseconds: delay)

        // Only restore if nobody changed the clipboard since our write.
        // If the user copied something during dictation, don't clobber it.
        if pasteboard.changeCount == changeCountAfterWrite {
            snapshot.restore(to: pasteboard)
            Logger.debug("Clipboard restored after paste", subsystem: .textInjection)
        } else {
            Logger.debug("Clipboard changed during paste window — skipping restore", subsystem: .textInjection)
        }

        Logger.debug("Dictated text entered via clipboard paste", subsystem: .textInjection)
        return true
    }

    private func simulatePaste() {
        // combinedSessionState reflects the current graphical session state,
        // which is appropriate when targeting the active session's focused app.
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            Logger.error("Failed to create event source for paste", subsystem: .textInjection)
            return
        }

        // V key code = 0x09
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
    #endif

    // MARK: - CGEvent Unicode Fallback (Tier 2)

    #if !APP_STORE
    /// Inserts text by posting CGEvent keyboard events with unicode string data.
    /// No clipboard involvement. Less reliable for long text and complex editors.
    private func enterViaCGEventUnicode(_ text: String) -> Bool {
        let utf16Array = Array(text.utf16)
        guard !utf16Array.isEmpty else { return false }

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

            if i < chunks.count - 1 {
                usleep(2000) // 2ms between chunks
            }
        }

        Logger.debug("Text entered via CGEvent unicode (\(utf16Array.count) UTF-16 units, \(chunks.count) chunk(s))", subsystem: .textInjection)
        return true
    }
    #endif

    // MARK: - Clipboard Only (APP_STORE + autoPaste disabled)

    private func copyToClipboard(_ text: String) {
        if let pid = targetAppPID,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        NotificationCenter.default.post(
            name: NSNotification.Name("TextCopiedToClipboard"),
            object: nil,
            userInfo: ["text": text]
        )
    }
}

// MARK: - InjectionError

enum InjectionError: Error, LocalizedError {
    case emptyText

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Cannot enter empty text"
        }
    }
}
