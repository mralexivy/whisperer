//
//  AIModesView.swift
//  Whisperer
//
//  Workspace view for managing AI mode presets with function-based assignment
//

import SwiftUI

struct AIModesView: View {
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var modeManager = AIModeManager.shared
    @State private var selectedModeId: UUID?
    @State private var editedPrompt: String = ""
    @State private var editedTemperature: Float = 0.3
    @State private var editedTopP: Float = 0.9
    @State private var editedName: String = ""
    @State private var editedTargetLanguage: String = ""
    @State private var hasChanges = false
    @State private var showAddModeSheet = false

    private var selectedMode: AIMode? {
        modeManager.modes.first { $0.id == selectedModeId }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                header

                // Function Assignments Card
                functionAssignmentsCard

                // Modes Section
                modesSection

                // Mode Editor (when mode selected)
                if selectedMode != nil {
                    modeEditorCard
                }
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WhispererColors.background(colorScheme))
        .onAppear {
            if selectedModeId == nil {
                selectedModeId = modeManager.postProcessModeId
            }
            loadModeValues()
        }
        .onChange(of: selectedModeId) { _ in
            loadModeValues()
        }
    }

    // MARK: - Header

    private var header: some View {
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
                Text("Assign modes to functions and customize prompts")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.white.opacity(0.4))
            }

            Spacer()
        }
    }

    // MARK: - Function Assignments Card

    private var functionAssignmentsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 26, height: 26)
                    Image(systemName: "arrow.triangle.swap")
                        .foregroundColor(.blue)
                        .font(.system(size: 12, weight: .medium))
                }
                Text("FUNCTION ASSIGNMENTS")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundColor(.white.opacity(0.5))
            }

            // Post-Process function row
            FunctionAssignmentRow(
                icon: "waveform.and.mic",
                iconColor: .green,
                label: "Post-Process",
                description: "Applied to transcribed speech",
                selectedModeId: Binding(
                    get: { modeManager.postProcessModeId },
                    set: { modeManager.setPostProcessMode($0) }
                ),
                modes: modeManager.modes,
                colorScheme: colorScheme
            )

            #if !APP_STORE
            // Rewrite function row
            FunctionAssignmentRow(
                icon: "pencil.line",
                iconColor: .orange,
                label: "Rewrite",
                description: "Applied to selected text with voice command",
                selectedModeId: Binding(
                    get: { modeManager.rewriteModeId },
                    set: { modeManager.setRewriteMode($0) }
                ),
                modes: modeManager.modes,
                colorScheme: colorScheme
            )
            #endif
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(WhispererColors.cardBackground(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            LinearGradient(
                                colors: [WhispererColors.accentBlue.opacity(0.2), Color(hex: "8B5CF6").opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
        )
    }

    // MARK: - Modes Section

    private var modesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MODES")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundColor(.white.opacity(0.5))

            // Horizontal scrolling mode chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(modeManager.modes.sorted { $0.sortOrder < $1.sortOrder }) { mode in
                        ModeChip(
                            mode: mode,
                            isSelected: selectedModeId == mode.id,
                            isPostProcess: modeManager.postProcessModeId == mode.id,
                            isRewrite: modeManager.rewriteModeId == mode.id,
                            colorScheme: colorScheme
                        ) {
                            selectedModeId = mode.id
                        }
                    }

                    // Add button
                    Button(action: addNewMode) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Add")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(WhispererColors.accentBlue)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .strokeBorder(WhispererColors.accentBlue.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Mode Editor Card

    private var modeEditorCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Mode header
            if let mode = selectedMode {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(hex: mode.color).opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: mode.icon)
                            .foregroundColor(Color(hex: mode.color))
                            .font(.system(size: 18, weight: .medium))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        if mode.isBuiltIn {
                            Text(mode.name)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        } else {
                            TextField("Mode name", text: $editedName)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .textFieldStyle(.plain)
                                .onChange(of: editedName) { _ in hasChanges = true }
                        }

                        HStack(spacing: 8) {
                            if mode.isBuiltIn {
                                Text("Built-in mode")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.white.opacity(0.4))
                            }

                            if modeManager.postProcessModeId == mode.id {
                                functionBadge("Post-Process", color: .green)
                            }
                            if modeManager.rewriteModeId == mode.id {
                                functionBadge("Rewrite", color: .orange)
                            }
                        }
                    }

                    Spacer()

                    // Actions menu
                    Menu {
                        Button(action: { duplicateMode(mode) }) {
                            Label("Duplicate", systemImage: "doc.on.doc")
                        }
                        if mode.isBuiltIn {
                            Button(action: { resetMode(mode) }) {
                                Label("Reset to Default", systemImage: "arrow.counterclockwise")
                            }
                        }
                        if !mode.isBuiltIn {
                            Divider()
                            Button(role: .destructive, action: { deleteMode(mode) }) {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .menuStyle(.borderlessButton)
                }
            }

            // Prompt editor
            VStack(alignment: .leading, spacing: 8) {
                Text("PROMPT")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.0)
                    .foregroundColor(.white.opacity(0.4))

                Text("Use {transcript} where the input text should go")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.35))

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $editedPrompt)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                        .scrollContentBackground(.hidden)
                        .padding(14)
                        .frame(minHeight: 180)
                        .onChange(of: editedPrompt) { _ in hasChanges = true }

                    if editedPrompt.isEmpty {
                        Text("Enter your prompt... use {transcript} for the input text")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white.opacity(0.2))
                            .padding(.top, 22)
                            .padding(.leading, 18)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(WhispererColors.elevatedBackground(colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                        )
                )
            }

            // Target Language (for Translate mode)
            if selectedMode?.name == "Translate" || selectedMode?.targetLanguage != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TARGET LANGUAGE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.0)
                        .foregroundColor(.white.opacity(0.4))

                    TextField("English", text: $editedTargetLanguage)
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
                                .stroke(Color.white.opacity(0.06), lineWidth: 1)
                        )
                        .onChange(of: editedTargetLanguage) { _ in hasChanges = true }
                }
            }

            // Parameters row
            HStack(spacing: 24) {
                ParameterSlider(
                    label: "Temperature",
                    value: $editedTemperature,
                    range: 0...1,
                    colorScheme: colorScheme
                )
                .onChange(of: editedTemperature) { _ in hasChanges = true }

                ParameterSlider(
                    label: "Top P",
                    value: $editedTopP,
                    range: 0...1,
                    colorScheme: colorScheme
                )
                .onChange(of: editedTopP) { _ in hasChanges = true }
            }

            // Save button
            Button(action: saveMode) {
                Text("Save Changes")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [WhispererColors.accentBlue, Color(hex: "8B5CF6")],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .opacity(hasChanges ? 1 : 0.5)
            .disabled(!hasChanges)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(WhispererColors.cardBackground(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    // MARK: - Helper Views

    private func functionBadge(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - Actions

    private func loadModeValues() {
        guard let mode = selectedMode else { return }
        editedPrompt = mode.prompt
        editedTemperature = mode.temperature
        editedTopP = mode.topP
        editedName = mode.name
        editedTargetLanguage = mode.targetLanguage ?? ""
        hasChanges = false
    }

    private func saveMode() {
        guard var mode = selectedMode else { return }
        mode.prompt = editedPrompt
        mode.temperature = editedTemperature
        mode.topP = editedTopP
        if !mode.isBuiltIn {
            mode.name = editedName
        }
        mode.targetLanguage = editedTargetLanguage.isEmpty ? nil : editedTargetLanguage
        modeManager.updateMode(mode)
        hasChanges = false
    }

    private func addNewMode() {
        // sortOrder is assigned by AIModeManager.addMode() — pass 0 as placeholder
        let newMode = AIMode(
            id: UUID(),
            name: "New Mode",
            icon: "sparkle",
            color: "A855F7",
            prompt: "Process this text:\n{transcript}",
            temperature: 0.3,
            topP: 0.9,
            isBuiltIn: false,
            sortOrder: 0
        )
        modeManager.addMode(newMode)
        selectedModeId = newMode.id
    }

    private func duplicateMode(_ mode: AIMode) {
        if let newMode = modeManager.duplicateMode(mode.id) {
            selectedModeId = newMode.id
        }
    }

    private func resetMode(_ mode: AIMode) {
        modeManager.resetToDefault(mode.id)
        loadModeValues()
    }

    private func deleteMode(_ mode: AIMode) {
        guard !mode.isBuiltIn else { return }
        let nextId = modeManager.modes.first { $0.id != mode.id }?.id
        modeManager.deleteMode(mode.id)
        selectedModeId = nextId
    }
}

// MARK: - Function Assignment Row

private struct FunctionAssignmentRow: View {
    let icon: String
    let iconColor: Color
    let label: String
    let description: String
    @Binding var selectedModeId: UUID
    let modes: [AIMode]
    let colorScheme: ColorScheme

    private var selectedMode: AIMode? {
        modes.first { $0.id == selectedModeId }
    }

    var body: some View {
        HStack(spacing: 14) {
            // Icon container
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .font(.system(size: 14, weight: .medium))
            }

            // Label + description
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(description)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.4))
            }

            Spacer()

            // Dropdown picker
            Menu {
                ForEach(modes.sorted { $0.sortOrder < $1.sortOrder }) { mode in
                    Button {
                        selectedModeId = mode.id
                    } label: {
                        HStack {
                            Image(systemName: mode.icon)
                            Text(mode.name)
                            if mode.id == selectedModeId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if let mode = selectedMode {
                        Image(systemName: mode.icon)
                            .foregroundColor(Color(hex: mode.color))
                            .font(.system(size: 11, weight: .medium))
                        Text(mode.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(WhispererColors.elevatedBackground(colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
            }
            .menuStyle(.borderlessButton)
        }
    }
}

// MARK: - Mode Chip

private struct ModeChip: View {
    let mode: AIMode
    let isSelected: Bool
    let isPostProcess: Bool
    let isRewrite: Bool
    let colorScheme: ColorScheme
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: mode.icon)
                    .foregroundColor(Color(hex: mode.color))
                    .font(.system(size: 11, weight: .medium))
                Text(mode.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.7))

                // Function indicators
                if isPostProcess || isRewrite {
                    HStack(spacing: 3) {
                        if isPostProcess {
                            Circle().fill(Color.green).frame(width: 5, height: 5)
                        }
                        if isRewrite {
                            Circle().fill(Color.orange).frame(width: 5, height: 5)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? Color(hex: mode.color).opacity(0.2) : WhispererColors.cardBackground(colorScheme))
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isSelected ? Color(hex: mode.color).opacity(0.5) : Color.white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
            .shadow(color: isSelected ? Color(hex: mode.color).opacity(0.25) : .clear, radius: 8, y: 2)
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Parameter Slider

private struct ParameterSlider: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            Slider(value: $value, in: range, step: 0.05)
                .tint(WhispererColors.accentBlue)
                .frame(width: 100)

            Text(String(format: "%.2f", value))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 40)
        }
    }
}
