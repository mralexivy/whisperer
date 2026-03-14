//
//  AIModesView.swift
//  Whisperer
//
//  Workspace view for managing AI mode presets and customizing prompts
//

import SwiftUI

struct AIModesView: View {
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var modeManager = AIModeManager.shared
    @State private var editingMode: AIMode?
    @State private var showDropdown = false

    private var builtInModes: [AIMode] {
        modeManager.modes.filter(\.isBuiltIn).sorted { $0.sortOrder < $1.sortOrder }
    }

    private var customModes: [AIMode] {
        modeManager.modes.filter { !$0.isBuiltIn }.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(hex: "8B5CF6").opacity(0.15))
                                .frame(width: 36, height: 36)
                            Image(systemName: "wand.and.sparkles")
                                .foregroundColor(Color(hex: "8B5CF6"))
                                .font(.system(size: 16, weight: .medium))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI Modes")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text("Customize prompts and parameters for post-processing and rewrite")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(.white.opacity(0.4))
                        }

                        Spacer()

                        Button(action: addNewMode) {
                            HStack(spacing: 5) {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("New Mode")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(
                                        LinearGradient(colors: [WhispererColors.accentBlue, Color(hex: "8B5CF6")], startPoint: .leading, endPoint: .trailing)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // Mode selector dropdown trigger
                    modeDropdownTrigger

                    // Mode editor card
                    if let mode = editingMode {
                        modeEditor(mode: mode)
                    }
                }
                .padding(28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WhispererColors.background(colorScheme))

            // Premium dropdown overlay
            if showDropdown {
                AIModeDropdownOverlay(
                    editingMode: $editingMode,
                    showDropdown: $showDropdown,
                    builtInModes: builtInModes,
                    customModes: customModes,
                    activeModeId: modeManager.activeModeId,
                    colorScheme: colorScheme
                )
                .padding(.leading, 28)
                .padding(.top, 120)
            }
        }
        .onAppear {
            if editingMode == nil {
                editingMode = modeManager.modes.first { $0.id == modeManager.activeModeId }
            }
        }
    }

    // MARK: - Dropdown Trigger

    private var modeDropdownTrigger: some View {
        HStack(spacing: 12) {
            Button(action: { withAnimation(.easeOut(duration: 0.15)) { showDropdown.toggle() } }) {
                HStack(spacing: 10) {
                    // Icon — gradient fill with micro-shadow
                    if let mode = editingMode {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(hex: mode.color).opacity(0.18),
                                            Color(hex: mode.color).opacity(0.08)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 32, height: 32)
                                .shadow(color: Color(hex: mode.color).opacity(0.08), radius: 3, y: 1)

                            Image(systemName: mode.icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color(hex: mode.color))
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text(mode.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)

                            Text(mode.isBuiltIn ? "Built-in" : "Custom")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }

                    Spacer()

                    // Active badge
                    if let mode = editingMode, modeManager.activeModeId == mode.id {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(WhispererColors.accentBlue)
                                .frame(width: 5, height: 5)
                            Text("ACTIVE")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .tracking(0.8)
                                .foregroundColor(WhispererColors.accentBlue)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(WhispererColors.accentBlue.opacity(0.12)))
                    }

                    // Chevron
                    Image(systemName: showDropdown ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(showDropdown ? WhispererColors.accentBlue.opacity(0.08) : WhispererColors.cardBackground(colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(showDropdown ? WhispererColors.accentBlue.opacity(0.3) : WhispererColors.border(colorScheme), lineWidth: 1)
                )
                .shadow(
                    color: showDropdown
                        ? WhispererColors.accentBlue.opacity(0.08)
                        : Color.black.opacity(0.06),
                    radius: showDropdown ? 6 : 3,
                    y: 1
                )
            }
            .buttonStyle(.plain).pointerOnHover()
            .frame(maxWidth: 320)

            // Set Active button
            if let mode = editingMode, modeManager.activeModeId != mode.id {
                Button(action: { modeManager.setActive(mode.id) }) {
                    Text("Set Active")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(colors: [WhispererColors.accentBlue, Color(hex: "8B5CF6")], startPoint: .leading, endPoint: .trailing)
                                )
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    // MARK: - Mode Editor

    private func modeEditor(mode: AIMode) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // Name field for custom modes
            if !mode.isBuiltIn {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MODE NAME")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundColor(.white.opacity(0.35))

                    TextField("Mode name", text: bindingForField(\.name))
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(WhispererColors.elevatedBackground(colorScheme))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                        )
                }
            }

            // System Prompt
            promptSection(
                title: "SYSTEM PROMPT",
                subtitle: "Applied when post-processing dictation output",
                text: bindingForField(\.systemPrompt),
                placeholder: "Enter system prompt for post-processing..."
            )

            // Rewrite Prompt
            #if !APP_STORE
            promptSection(
                title: "REWRITE PROMPT",
                subtitle: "Applied when using rewrite shortcut on selected text",
                text: bindingForField(\.rewritePrompt),
                placeholder: "Enter prompt for rewrite mode..."
            )
            #endif

            // Target Language
            if mode.name == "Translate" || mode.targetLanguage != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TARGET LANGUAGE")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundColor(.white.opacity(0.35))

                    TextField("English", text: bindingForOptionalField(\.targetLanguage))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(WhispererColors.elevatedBackground(colorScheme))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                        )
                }
            }

            // Parameters
            VStack(alignment: .leading, spacing: 10) {
                Text("PARAMETERS")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundColor(.white.opacity(0.35))

                HStack(spacing: 20) {
                    parameterField(title: "Temperature", value: bindingForField(\.temperature), range: 0...1)
                    parameterField(title: "Top P", value: bindingForField(\.topP), range: 0...1)
                }
            }

            // Action buttons
            HStack(spacing: 10) {
                Button(action: saveMode) {
                    Text("Save")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(colors: [WhispererColors.accentBlue, Color(hex: "8B5CF6")], startPoint: .leading, endPoint: .trailing)
                                )
                        )
                }
                .buttonStyle(.plain)

                if mode.isBuiltIn {
                    Button(action: {
                        modeManager.resetToDefault(mode.id)
                        editingMode = modeManager.modes.first { $0.id == mode.id }
                    }) {
                        Text("Reset to Default")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

                if !mode.isBuiltIn {
                    Button(action: {
                        if let newMode = modeManager.duplicateMode(mode.id) {
                            editingMode = newMode
                        }
                    }) {
                        Text("Duplicate")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(action: { deleteMode(mode) }) {
                        Text("Delete")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.red.opacity(0.8))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .stroke(.red.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(WhispererColors.cardBackground(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 3, y: 1)
    }

    // MARK: - Components

    private func promptSection(title: String, subtitle: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundColor(.white.opacity(0.35))
                Text(subtitle)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.white.opacity(0.25))
            }

            TextEditor(text: text)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 100, maxHeight: 180)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(WhispererColors.elevatedBackground(colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                )
                .overlay(alignment: .topLeading, content: {
                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.2))
                            .padding(.top, 18)
                            .padding(.leading, 15)
                            .allowsHitTesting(false)
                    }
                })
        }
    }

    private func parameterField(title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 8) {
                Slider(value: value, in: range, step: 0.05)
                    .tint(WhispererColors.accentBlue)

                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 36)
            }
        }
    }

    // MARK: - Bindings

    private func bindingForField<T>(_ keyPath: WritableKeyPath<AIMode, T>) -> Binding<T> {
        Binding(
            get: { editingMode?[keyPath: keyPath] ?? AIMode.defaultMode()[keyPath: keyPath] },
            set: { newValue in
                editingMode?[keyPath: keyPath] = newValue
            }
        )
    }

    private func bindingForOptionalField(_ keyPath: WritableKeyPath<AIMode, String?>) -> Binding<String> {
        Binding(
            get: { editingMode?[keyPath: keyPath] ?? "" },
            set: { newValue in
                editingMode?[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
            }
        )
    }

    // MARK: - Actions

    private func saveMode() {
        guard let mode = editingMode else { return }
        modeManager.updateMode(mode)
    }

    private func addNewMode() {
        let newMode = AIMode(
            id: UUID(),
            name: "New Mode",
            icon: "sparkle",
            color: "A855F7",
            systemPrompt: "",
            rewritePrompt: "",
            temperature: 0.3,
            topP: 0.9,
            isBuiltIn: false,
            sortOrder: (modeManager.modes.map(\.sortOrder).max() ?? 0) + 1
        )
        modeManager.addMode(newMode)
        editingMode = newMode
    }

    private func deleteMode(_ mode: AIMode) {
        guard !mode.isBuiltIn else { return }
        modeManager.deleteMode(mode.id)
        editingMode = modeManager.modes.first { $0.id == modeManager.activeModeId }
    }
}

// MARK: - Premium Dropdown Overlay

private struct AIModeDropdownOverlay: View {
    @Binding var editingMode: AIMode?
    @Binding var showDropdown: Bool
    let builtInModes: [AIMode]
    let customModes: [AIMode]
    let activeModeId: UUID
    let colorScheme: ColorScheme

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.15)) { showDropdown = false }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Backdrop
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            // Premium dropdown card
            VStack(alignment: .leading, spacing: 0) {
                // Scrollable mode list
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Built-in section
                        sectionHeader("BUILT-IN")

                        ForEach(builtInModes) { mode in
                            AIModeDropdownItem(
                                mode: mode,
                                isSelected: editingMode?.id == mode.id,
                                isActive: activeModeId == mode.id,
                                colorScheme: colorScheme
                            ) {
                                editingMode = mode
                                dismiss()
                            }
                        }

                        // Custom section
                        if !customModes.isEmpty {
                            sectionHeader("CUSTOM")

                            ForEach(customModes) { mode in
                                AIModeDropdownItem(
                                    mode: mode,
                                    isSelected: editingMode?.id == mode.id,
                                    isActive: activeModeId == mode.id,
                                    colorScheme: colorScheme
                                ) {
                                    editingMode = mode
                                    dismiss()
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 380)

                Divider()

                // Bottom bar
                HStack {
                    Text("\(builtInModes.count + customModes.count) modes")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))

                    Spacer()

                    if let active = builtInModes.first(where: { $0.id == activeModeId }) ?? customModes.first(where: { $0.id == activeModeId }) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(WhispererColors.accentBlue)
                                .frame(width: 5, height: 5)
                            Text(active.name)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(WhispererColors.accentBlue)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(WhispererColors.elevatedBackground(colorScheme).opacity(0.3))
            }
            .frame(width: 300)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(WhispererColors.cardBackground(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(WhispererColors.border(colorScheme).opacity(0.5), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 20, x: 0, y: 8)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(.white.opacity(0.3))
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

// MARK: - Mode Dropdown Item

private struct AIModeDropdownItem: View {
    let mode: AIMode
    let isSelected: Bool
    let isActive: Bool
    let colorScheme: ColorScheme
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                // Selection checkmark
                ZStack {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(WhispererColors.accentBlue)
                    }
                }
                .frame(width: 16)

                // Mode icon
                Image(systemName: mode.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: mode.color))
                    .frame(width: 18)

                // Mode name
                Text(mode.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer()

                // Active indicator
                if isActive {
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.5)
                        .foregroundColor(WhispererColors.accentBlue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(WhispererColors.accentBlue.opacity(0.12))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? WhispererColors.accentBlue.opacity(0.1) : (isHovered ? WhispererColors.elevatedBackground(colorScheme) : Color.clear))
            )
            .scaleEffect(isHovered ? 1.006 : 1.0)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain).pointerOnHover()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}
