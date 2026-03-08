//
//  TextSelectionService.swift
//  Whisperer
//
//  Reads selected text from the focused app using read-only Accessibility APIs
//

import AppKit

@MainActor
class TextSelectionService {

    /// Reads the currently selected text from the frontmost app's focused element.
    /// Uses only read-only AX calls (CopyAttributeValue) — never writes.
    /// Returns nil if no selection, AX not granted, or the target app doesn't support it.
    func getSelectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.1)

        // Get focused element
        var focusedRef: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusResult == .success, let focused = focusedRef else {
            return tryFrontmostAppFallback()
        }

        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)

        // Try direct selected text attribute
        if let text = readSelectedText(from: element), !text.isEmpty {
            return text
        }

        // Fallback: selected text range + full value
        if let text = readSelectedTextViaRange(from: element), !text.isEmpty {
            return text
        }

        return nil
    }

    // MARK: - Private

    private func readSelectedText(from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &valueRef)
        guard result == .success, let value = valueRef as? String else { return nil }
        return value
    }

    private func readSelectedTextViaRange(from element: AXUIElement) -> String? {
        // Get selected text range
        var rangeRef: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard rangeResult == .success, let rangeValue = rangeRef else { return nil }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.length > 0 else { return nil }

        // Get full text value
        var textRef: CFTypeRef?
        let textResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &textRef)
        guard textResult == .success, let fullText = textRef as? String else { return nil }

        // Extract substring
        let nsString = fullText as NSString
        guard range.location >= 0, range.location + range.length <= nsString.length else { return nil }
        return nsString.substring(with: NSRange(location: range.location, length: range.length))
    }

    private func tryFrontmostAppFallback() -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.1)

        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard result == .success, let focused = focusedRef else { return nil }

        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)

        if let text = readSelectedText(from: element), !text.isEmpty {
            return text
        }

        return readSelectedTextViaRange(from: element)
    }
}
