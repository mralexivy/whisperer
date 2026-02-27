//
//  ShortcutRecorderView.swift
//  Whisperer
//
//  UI for recording and configuring keyboard shortcuts
//

import SwiftUI
import Carbon.HIToolbox

struct ShortcutRecorderView: View {
    static let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969) // #5B6CF7

    @ObservedObject var appState = AppState.shared
    @State private var isRecording = false
    @State private var tempConfig: ShortcutConfig?
    @State private var localMonitor: Any?
    @State private var lastModifiers: NSEvent.ModifierFlags = []
    @State private var showConflictAlert = false
    @State private var conflictMessage = ""

    var currentConfig: ShortcutConfig {
        appState.keyListener?.shortcutConfig ?? .defaultFnOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Current shortcut display with inline edit
            HStack(spacing: 12) {
                // Shortcut key display
                shortcutKeyView

                Spacer()

                // Action buttons
                if isRecording {
                    Button(action: { stopRecording(save: false) }) {
                        Text("Cancel")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)

                    Button(action: { stopRecording(save: true) }) {
                        Text("Save")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(tempConfig != nil ? ShortcutRecorderView.blueAccent : Color.gray)
                            .cornerRadius(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(tempConfig == nil)
                } else {
                    Button(action: { startRecording() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                            Text("Change")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(ShortcutRecorderView.blueAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(ShortcutRecorderView.blueAccent.opacity(0.15))
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Recording mode selector
            VStack(alignment: .leading, spacing: 6) {
                Text("Trigger Mode")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    modeButton(
                        title: "Hold to record",
                        icon: "hand.tap.fill",
                        isSelected: currentConfig.recordingMode == .holdToRecord,
                        action: {
                            var config = currentConfig
                            config.recordingMode = .holdToRecord
                            appState.keyListener?.shortcutConfig = config
                        }
                    )

                    modeButton(
                        title: "Toggle",
                        icon: "arrow.triangle.2.circlepath",
                        isSelected: currentConfig.recordingMode == .toggle,
                        action: {
                            var config = currentConfig
                            config.recordingMode = .toggle
                            appState.keyListener?.shortcutConfig = config
                        }
                    )
                }
            }
        }
        .alert("Shortcut Conflict Detected", isPresented: $showConflictAlert) {
            Button("OK", role: .cancel) { }
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts")!)
            }
        } message: {
            Text(conflictMessage)
        }
    }

    // MARK: - Shortcut Key View

    private var shortcutKeyView: some View {
        HStack(spacing: 6) {
            if isRecording {
                // Recording state
                Image(systemName: "record.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.orange)
                    .symbolEffect(.pulse)

                Text(tempConfig?.displayString ?? "Press keys...")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.orange)
            } else {
                // Display current shortcut as keyboard keys
                ForEach(shortcutParts, id: \.self) { part in
                    keyCapView(part)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isRecording ? Color.orange.opacity(0.15) : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isRecording ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
    }

    private var shortcutParts: [String] {
        let config = currentConfig
        var parts: [String] = []

        let mods = config.modifiers
        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option) { parts.append("⌥") }
        if mods.contains(.shift) { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }
        if config.useFnKey { parts.append("Fn") }

        if config.keyCode != 0 {
            parts.append(keyCodeToDisplayString(config.keyCode))
        }

        return parts.isEmpty ? ["None"] : parts
    }

    private func keyCapView(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .frame(minWidth: key.count > 2 ? 32 : 24, minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.08))
                    .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
    }

    private func keyCodeToDisplayString(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 17: return "T"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 53: return "⎋"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "Key\(keyCode)"
        }
    }

    // MARK: - Mode Button

    private func modeButton(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Self.blueAccent : Color.white.opacity(0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recording Logic

    private func startRecording() {
        isRecording = true
        tempConfig = nil
        lastModifiers = []

        // Set up local event monitor for shortcut recording (in-app only, no global monitoring)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            self.handleKeyEvent(event)
            // ALWAYS consume the event to prevent it from propagating to text fields
            return nil
        }

        // Then resign first responder with a tiny delay to ensure monitors are active
        DispatchQueue.main.async {
            // Aggressively clear all first responders and end editing
            for window in NSApp.windows {
                // End editing in all text fields
                window.endEditing(for: nil)
                // Remove first responder
                window.makeFirstResponder(nil)
            }
        }
    }

    private func stopRecording(save: Bool) {
        // Remove monitor FIRST to prevent further events
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }

        // Small delay before clearing state to prevent button clicks from re-triggering
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
            isRecording = false

            if save, let config = tempConfig {
                appState.keyListener?.shortcutConfig = config
            }

            tempConfig = nil
            lastModifiers = []
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags
        let keyCode = event.keyCode

        // Update last known modifiers on flagsChanged events
        if event.type == .flagsChanged {
            lastModifiers = modifiers
        }

        if keyCode == UInt16(kVK_Escape) {
            stopRecording(save: false)
            return
        }

        if keyCode == UInt16(kVK_Return) {
            stopRecording(save: true)
            return
        }

        var config = ShortcutConfig(
            keyCode: 0,
            modifierFlags: 0,
            useFnKey: false,
            recordingMode: currentConfig.recordingMode
        )

        // Use last known modifiers for key down events (they're more reliable)
        let activeModifiers = event.type == .keyDown ? lastModifiers : modifiers

        let isFnPressed = activeModifiers.contains(.function)
        config.useFnKey = isFnPressed

        let relevantMods: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        config.modifiers = activeModifiers.intersection(relevantMods)

        if event.type == .keyDown {
            config.keyCode = keyCode

            // Detect if modifiers were held but the key event arrived without them (system intercepted)
            let lastRelevantMods = lastModifiers.intersection(relevantMods)
            if !lastRelevantMods.isEmpty && config.modifierFlags == 0 && keyCode != UInt16(kVK_Escape) && keyCode != UInt16(kVK_Return) {
                // A modifier was held, but it's not in the current event - likely intercepted by system
                let modNames = getModifierNames(lastRelevantMods)
                let keyName = keyCodeToDisplayString(keyCode)

                conflictMessage = "The shortcut \(modNames)+\(keyName) appears to be bound to another application or system service.\n\nTo use this shortcut:\n1. Go to System Settings > Keyboard > Keyboard Shortcuts\n2. Find and disable the conflicting shortcut\n3. Try recording again"
                showConflictAlert = true
            }
        }

        if config.useFnKey || config.modifierFlags != 0 || config.keyCode != 0 {
            tempConfig = config
        }
    }

    private func getModifierNames(_ modifiers: NSEvent.ModifierFlags) -> String {
        var names: [String] = []
        if modifiers.contains(.control) { names.append("⌃") }
        if modifiers.contains(.option) { names.append("⌥") }
        if modifiers.contains(.shift) { names.append("⇧") }
        if modifiers.contains(.command) { names.append("⌘") }
        return names.joined(separator: "")
    }
}
