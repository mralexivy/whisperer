//
//  TextInjector.swift
//  Whisperer
//
//  Cross-app text injection using Accessibility API + clipboard fallback
//

import Cocoa
import ApplicationServices

class TextInjector {

    // MARK: - Permission Request

    static func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
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
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Get system-wide accessibility element
                let systemWide = AXUIElementCreateSystemWide()

                // Get focused element
                var focusedApp: AnyObject?
                let appResult = AXUIElementCopyAttributeValue(
                    systemWide,
                    kAXFocusedApplicationAttribute as CFString,
                    &focusedApp
                )

                guard appResult == .success, let focusedApp = focusedApp else {
                    print("Failed to get focused application")
                    continuation.resume(returning: false)
                    return
                }

                var focusedElement: AnyObject?
                let elementResult = AXUIElementCopyAttributeValue(
                    focusedApp as! AXUIElement,
                    kAXFocusedUIElementAttribute as CFString,
                    &focusedElement
                )

                guard elementResult == .success, let element = focusedElement as! AXUIElement? else {
                    print("Failed to get focused UI element")
                    continuation.resume(returning: false)
                    return
                }

                // Try to set the value directly
                let setValue = AXUIElementSetAttributeValue(
                    element,
                    kAXValueAttribute as CFString,
                    text as CFString
                )

                if setValue == .success {
                    continuation.resume(returning: true)
                    return
                }

                // If direct value setting fails, try inserting at selection
                let setSelectedText = AXUIElementSetAttributeValue(
                    element,
                    kAXSelectedTextAttribute as CFString,
                    text as CFString
                )

                continuation.resume(returning: setSelectedText == .success)
            }
        }
    }

    // MARK: - Clipboard Method

    private func insertViaClipboard(_ text: String) async throws {
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
