//
//  ShortcutConfig.swift
//  Whisperer
//
//  Configuration for customizable keyboard shortcuts
//

import Cocoa

enum RecordingMode: String, Codable, CaseIterable {
    case holdToRecord    // Hold shortcut to record, release to stop (default)
    case toggle          // Press to start, press again to stop

    var displayName: String {
        switch self {
        case .holdToRecord:
            return "Hold to record"
        case .toggle:
            return "Press to start/stop"
        }
    }
}

struct ShortcutConfig: Codable, Equatable {
    var keyCode: UInt16              // The physical key (or 0 for modifier-only)
    var modifierFlags: UInt          // Raw modifier flags value
    var useFnKey: Bool               // Special flag for Fn-only mode (default)
    var recordingMode: RecordingMode

    // Default: Fn key only, hold to record
    static let defaultFnOnly = ShortcutConfig(
        keyCode: 0,
        modifierFlags: 0,
        useFnKey: true,
        recordingMode: .holdToRecord
    )

    // MARK: - Modifier Helpers

    var modifiers: NSEvent.ModifierFlags {
        get { NSEvent.ModifierFlags(rawValue: modifierFlags) }
        set { modifierFlags = newValue.rawValue }
    }

    var hasModifiers: Bool {
        return modifierFlags != 0 || useFnKey
    }

    var hasKeyCode: Bool {
        return keyCode != 0
    }

    // MARK: - Display

    var displayString: String {
        if useFnKey && keyCode == 0 && modifierFlags == 0 {
            return "Fn"
        }

        var parts: [String] = []

        // Add modifiers
        let mods = modifiers
        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option) { parts.append("⌥") }
        if mods.contains(.shift) { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }
        if useFnKey { parts.append("Fn") }

        // Add key
        if keyCode != 0 {
            parts.append(keyCodeToString(keyCode))
        }

        return parts.isEmpty ? "None" : parts.joined(separator: " + ")
    }

    // MARK: - Matching

    func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isFnPressed: Bool) -> Bool {
        // For Fn-only mode
        if useFnKey && self.keyCode == 0 && modifierFlags == 0 {
            return isFnPressed
        }

        // Check key code
        if self.keyCode != 0 && self.keyCode != keyCode {
            return false
        }

        // Check Fn if required
        if useFnKey && !isFnPressed {
            return false
        }

        // Check modifiers (mask to only relevant modifiers)
        let relevantMods: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let requiredMods = self.modifiers.intersection(relevantMods)
        let actualMods = modifiers.intersection(relevantMods)

        return requiredMods == actualMods
    }

    // MARK: - Persistence

    static func load() -> ShortcutConfig {
        guard let data = UserDefaults.standard.data(forKey: "shortcutConfig"),
              let config = try? JSONDecoder().decode(ShortcutConfig.self, from: data) else {
            return .defaultFnOnly
        }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "shortcutConfig")
        }
    }
}

// MARK: - Key Code to String

private func keyCodeToString(_ keyCode: UInt16) -> String {
    // Common key codes to readable strings
    switch keyCode {
    case 0: return "A"
    case 1: return "S"
    case 2: return "D"
    case 3: return "F"
    case 4: return "H"
    case 5: return "G"
    case 6: return "Z"
    case 7: return "X"
    case 8: return "C"
    case 9: return "V"
    case 11: return "B"
    case 12: return "Q"
    case 13: return "W"
    case 14: return "E"
    case 15: return "R"
    case 16: return "Y"
    case 17: return "T"
    case 18: return "1"
    case 19: return "2"
    case 20: return "3"
    case 21: return "4"
    case 22: return "6"
    case 23: return "5"
    case 24: return "="
    case 25: return "9"
    case 26: return "7"
    case 27: return "-"
    case 28: return "8"
    case 29: return "0"
    case 30: return "]"
    case 31: return "O"
    case 32: return "U"
    case 33: return "["
    case 34: return "I"
    case 35: return "P"
    case 36: return "↩"  // Return
    case 37: return "L"
    case 38: return "J"
    case 39: return "'"
    case 40: return "K"
    case 41: return ";"
    case 42: return "\\"
    case 43: return ","
    case 44: return "/"
    case 45: return "N"
    case 46: return "M"
    case 47: return "."
    case 48: return "⇥"  // Tab
    case 49: return "Space"
    case 50: return "`"
    case 51: return "⌫"  // Delete
    case 53: return "⎋"  // Escape
    case 96: return "F5"
    case 97: return "F6"
    case 98: return "F7"
    case 99: return "F3"
    case 100: return "F8"
    case 101: return "F9"
    case 103: return "F11"
    case 109: return "F10"
    case 111: return "F12"
    case 118: return "F4"
    case 120: return "F2"
    case 122: return "F1"
    case 123: return "←"
    case 124: return "→"
    case 125: return "↓"
    case 126: return "↑"
    default: return "Key\(keyCode)"
    }
}
