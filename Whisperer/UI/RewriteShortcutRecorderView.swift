//
//  RewriteShortcutRecorderView.swift
//  Whisperer
//
//  UI for recording and configuring the rewrite mode shortcut
//

#if !APP_STORE

import SwiftUI
import Carbon.HIToolbox

struct RewriteShortcutRecorderView: View {
    private static let accent = Color(red: 0.545, green: 0.361, blue: 0.965) // #8B5CF6

    @ObservedObject var appState = AppState.shared
    @State private var isRecording = false
    @State private var tempConfig: RewriteShortcutConfig?
    @State private var localMonitor: Any?
    @State private var lastModifiers: NSEvent.ModifierFlags = []
    @State private var showConflictAlert = false
    @State private var conflictMessage = ""

    private var currentConfig: RewriteShortcutConfig {
        appState.keyListener?.rewriteShortcutConfig ?? .defaultConfig
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Current shortcut display with inline edit
            HStack(spacing: 12) {
                shortcutKeyView
                Spacer()

                if isRecording {
                    Button(action: { stopRecording(save: false) }) {
                        Text("Cancel")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerOnHover()
                    .foregroundColor(.secondary)

                    Button(action: { stopRecording(save: true) }) {
                        Text("Save")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(tempConfig != nil ? Self.accent : Color.gray)
                            .cornerRadius(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerOnHover()
                    .disabled(tempConfig == nil)
                } else {
                    Button(action: { startRecording() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                            Text("Change")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(Self.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Self.accent.opacity(0.15))
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerOnHover()
                }
            }

            Text("Hold shortcut + speak to rewrite selected text")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
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
                Image(systemName: "record.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.orange)
                    .symbolEffect(.pulse)

                Text(tempConfig?.displayString ?? "Press modifier + key...")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.orange)
            } else {
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
        guard config.isEnabled else { return ["Not Set"] }

        var parts: [String] = []
        let mods = config.modifiers
        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option) { parts.append("⌥") }
        if mods.contains(.shift) { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }

        if config.keyCode != 0 {
            parts.append(keyCodeToDisplayString(config.keyCode))
        }

        return parts.isEmpty ? ["Not Set"] : parts
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

    // MARK: - Recording Logic

    private func startRecording() {
        isRecording = true
        tempConfig = nil
        lastModifiers = []

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            self.handleKeyEvent(event)
            return nil
        }

        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.endEditing(for: nil)
                window.makeFirstResponder(nil)
            }
        }
    }

    private func stopRecording(save: Bool) {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
            isRecording = false

            if save, let config = tempConfig {
                var finalConfig = config
                finalConfig.isEnabled = true
                appState.keyListener?.rewriteShortcutConfig = finalConfig
            }

            tempConfig = nil
            lastModifiers = []
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags
        let keyCode = event.keyCode

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

        // Build config — requires at least one modifier + a key
        let relevantMods: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let activeModifiers = event.type == .keyDown ? lastModifiers : modifiers
        let activeMods = activeModifiers.intersection(relevantMods)

        if event.type == .keyDown {
            // Check for system-intercepted shortcut
            let lastRelevantMods = lastModifiers.intersection(relevantMods)
            if !lastRelevantMods.isEmpty && activeMods.isEmpty && keyCode != UInt16(kVK_Escape) && keyCode != UInt16(kVK_Return) {
                let modNames = getModifierNames(lastRelevantMods)
                let keyName = keyCodeToDisplayString(keyCode)
                conflictMessage = "The shortcut \(modNames)+\(keyName) appears to be bound to another application or system service.\n\nTo use this shortcut:\n1. Go to System Settings > Keyboard > Keyboard Shortcuts\n2. Find and disable the conflicting shortcut\n3. Try recording again"
                showConflictAlert = true
                return
            }

            // Require at least one modifier for rewrite shortcut
            guard !activeMods.isEmpty else { return }

            // Check conflict with dictation shortcut
            let dictConfig = appState.keyListener?.shortcutConfig ?? .defaultFnOnly
            if keyCode == dictConfig.keyCode && activeMods.rawValue == dictConfig.modifiers.rawValue {
                conflictMessage = "This shortcut is already used for dictation. Please choose a different combination."
                showConflictAlert = true
                return
            }

            let config = RewriteShortcutConfig(
                keyCode: keyCode,
                modifierFlags: activeMods.rawValue,
                isEnabled: true
            )
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

#endif
