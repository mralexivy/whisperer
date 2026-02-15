//
//  TextInjector.swift
//  Whisperer
//
//  Cross-app text injection using Accessibility API + clipboard fallback
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

        print("Attempting to insert text: \(text)")

        // Try Accessibility API first
        if Self.hasAccessibilityPermission() {
            if try await insertViaAccessibility(text) {
                print("Text inserted via Accessibility API")
                return
            } else {
                print("Accessibility insertion failed, falling back to clipboard")
            }
        } else {
            print("No accessibility permission, using clipboard method")
        }

        // Fallback to clipboard + paste
        try await insertViaClipboard(text)
        print("Text inserted via clipboard")
    }

    // MARK: - Accessibility API Method

    private func insertViaAccessibility(_ text: String) async throws -> Bool {
        let pid = self.targetAppPID
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Try using the captured target app PID first
                let appElement: AXUIElement
                if let pid = pid {
                    appElement = AXUIElementCreateApplication(pid)
                } else {
                    // Fall back to system-wide focused app query
                    let systemWide = AXUIElementCreateSystemWide()
                    var focusedApp: AnyObject?
                    let appResult = AXUIElementCopyAttributeValue(
                        systemWide,
                        kAXFocusedApplicationAttribute as CFString,
                        &focusedApp
                    )
                    guard appResult == .success, let app = focusedApp else {
                        print("Failed to get focused application")
                        continuation.resume(returning: false)
                        return
                    }
                    appElement = app as! AXUIElement
                }

                // Activate the target app to ensure it has focus
                if let pid = pid {
                    let app = NSRunningApplication(processIdentifier: pid)
                    app?.activate()
                    // Brief wait for activation
                    Thread.sleep(forTimeInterval: 0.05)
                }

                var focusedElement: AnyObject?
                let elementResult = AXUIElementCopyAttributeValue(
                    appElement,
                    kAXFocusedUIElementAttribute as CFString,
                    &focusedElement
                )

                guard elementResult == .success, let element = focusedElement as! AXUIElement? else {
                    print("Failed to get focused UI element")
                    continuation.resume(returning: false)
                    return
                }

                // Try inserting at selection first (appends at cursor position)
                let setSelectedText = AXUIElementSetAttributeValue(
                    element,
                    kAXSelectedTextAttribute as CFString,
                    text as CFString
                )

                if setSelectedText == .success {
                    continuation.resume(returning: true)
                    return
                }

                // Fall back to setting the entire value
                let setValue = AXUIElementSetAttributeValue(
                    element,
                    kAXValueAttribute as CFString,
                    text as CFString
                )

                continuation.resume(returning: setValue == .success)
            }
        }
    }

    // MARK: - Clipboard Method

    private func insertViaClipboard(_ text: String) async throws {
        // Re-activate the target app before pasting
        if let pid = targetAppPID,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms for activation
        }

        let pasteboard = NSPasteboard.general

        // Save current clipboard content (just the string, if any)
        let previousString = pasteboard.string(forType: .string)

        // Set new content
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Wait a moment for clipboard to update
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Simulate Cmd+V
        try await simulatePaste()

        // Wait for paste to complete
        try await Task.sleep(nanoseconds: 150_000_000) // 150ms

        // Restore previous clipboard content
        if let previousString = previousString {
            pasteboard.clearContents()
            pasteboard.setString(previousString, forType: .string)
        }
    }

    private func simulatePaste() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGEventSource(stateID: .hidSystemState) else {
                    continuation.resume(throwing: InjectionError.eventSourceFailed)
                    return
                }

                // Create Cmd+V events
                // V key code is 0x09
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
                    continuation.resume(throwing: InjectionError.eventCreationFailed)
                    return
                }

                // Set command flag
                keyDown.flags = .maskCommand
                keyUp.flags = .maskCommand

                // Post events
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)

                continuation.resume()
            }
        }
    }
}

enum InjectionError: Error, LocalizedError {
    case emptyText
    case noAccessibilityPermission
    case focusedElementNotFound
    case eventSourceFailed
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Cannot insert empty text"
        case .noAccessibilityPermission:
            return "Accessibility permission required"
        case .focusedElementNotFound:
            return "No focused text field found"
        case .eventSourceFailed:
            return "Failed to create event source"
        case .eventCreationFailed:
            return "Failed to create keyboard event"
        }
    }
}
