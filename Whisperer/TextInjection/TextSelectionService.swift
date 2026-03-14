//
//  TextSelectionService.swift
//  Whisperer
//
//  Reads selected text from the focused app via clipboard simulation (Cmd+C).
//

#if !APP_STORE

import AppKit

@MainActor
class TextSelectionService {

    /// Reads the currently selected text by simulating Cmd+C and reading the clipboard.
    func getSelectedText() async -> String? {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount

        // Simulate Cmd+C
        let source = CGEventSource(stateID: .hidSystemState)
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else {
            Logger.error("Rewrite: failed to create CGEvent for Cmd+C", subsystem: .textInjection)
            return nil
        }
        cmdDown.flags = .maskCommand
        cmdUp.flags = .maskCommand
        cmdDown.post(tap: .cgAnnotatedSessionEventTap)
        cmdUp.post(tap: .cgAnnotatedSessionEventTap)

        // Wait for clipboard to update
        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms

        // Check if clipboard changed
        guard pasteboard.changeCount != changeCount else {
            Logger.debug("Rewrite: clipboard didn't change after Cmd+C (no selection?)", subsystem: .textInjection)
            return nil
        }

        let selectedText = pasteboard.string(forType: .string)

        if let text = selectedText, !text.isEmpty {
            Logger.debug("Rewrite: got \(text.count) chars via clipboard", subsystem: .textInjection)
            return text
        }

        Logger.debug("Rewrite: clipboard empty after Cmd+C", subsystem: .textInjection)
        return nil
    }
}

#endif
