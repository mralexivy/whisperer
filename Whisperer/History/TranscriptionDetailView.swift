//
//  TranscriptionDetailView.swift
//  Whisperer
//
//  Detail panel for viewing and editing transcriptions - Matching Whisperer design
//

import SwiftUI
import AVFoundation
import AppKit

struct TranscriptionDetailView: View {
    @Environment(\.colorScheme) var colorScheme
    let transcription: TranscriptionRecord
    let onClose: () -> Void

    @State private var editedText: String
    @State private var notes: String
    @State private var isEditing = false
    @State private var isRetranscribing = false
    @State private var showingOriginal = false
    @State private var showRevertConfirmation = false
    @State private var showRetranscribePanel = false
    @State private var retranscribeLanguage: TranscriptionLanguage

    init(transcription: TranscriptionRecord, onClose: @escaping () -> Void) {
        self.transcription = transcription
        self.onClose = onClose
        _editedText = State(initialValue: transcription.displayText)
        _notes = State(initialValue: transcription.notes ?? "")
        _retranscribeLanguage = State(initialValue: TranscriptionLanguage(rawValue: transcription.language) ?? .auto)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Audio player
                    if let audioURL = transcription.audioURL {
                        audioSection(url: audioURL)
                    }

                    // Transcription
                    transcriptionSection

                    // Details grid
                    detailsSection

                    // Notes
                    notesSection
                }
                .padding(24)
            }
        }
        .background(
            LinearGradient(
                colors: [
                    WhispererColors.accent.opacity(colorScheme == .dark ? 0.04 : 0.02),
                    WhispererColors.background(colorScheme)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(maxHeight: .infinity)
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(dayLabel)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [WhispererColors.accent, WhispererColors.accentDark],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .textCase(.uppercase)
                        .tracking(0.5)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(dateString)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                        Text("at \(timeString)")
                            .font(.system(size: 13))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    DetailHeaderButton(icon: "square.and.arrow.up", colorScheme: colorScheme, action: shareTranscription)
                        .help("Share")

                    DetailHeaderButton(icon: "xmark", colorScheme: colorScheme, action: onClose)
                        .help("Close")
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 72)

            // Gradient separator
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            WhispererColors.accent.opacity(0.2),
                            WhispererColors.border(colorScheme),
                            WhispererColors.border(colorScheme).opacity(0.3)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
        .background(WhispererColors.background(colorScheme))
    }

    // MARK: - Audio Section

    private func audioSection(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionLabel("Audio Recording", icon: "waveform", color: .red)

                Spacer()

                if FileManager.default.fileExists(atPath: url.path) {
                    RevealInFinderButton(url: url, colorScheme: colorScheme)
                        .help("Show in Finder")
                }
            }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)

            AudioPlayerView(audioURL: url, duration: transcription.duration)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(WhispererColors.cardBackground(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.06 : 0.03),
            radius: 4, y: 1
        )
    }

    // MARK: - Transcription Section

    /// The text currently shown in the transcription card
    private var activeTranscriptionText: String {
        if transcription.hasAIEnhancement && showingOriginal {
            return transcription.transcription
        }
        return editedText
    }

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack {
                sectionLabel("Transcription", icon: "text.alignleft", color: WhispererColors.accentBlue)

                Spacer()

                if isEditing {
                    Button(action: {
                        saveChanges()
                        withAnimation(.spring(response: 0.3)) {
                            isEditing = false
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Save")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(WhispererColors.accentGradient))
                        .shadow(color: WhispererColors.accentBlue.opacity(0.25), radius: 4, y: 1)
                    }
                    .buttonStyle(.plain).pointerOnHover()
                } else {
                    transcriptionHeaderMenu
                }
            }

            // Retranscribe panel (inline, shown when user clicks Re-transcribe)
            if showRetranscribePanel {
                retranscribePanel
            }

            // Text content
            if isEditing {
                TextEditor(text: $editedText)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .frame(minHeight: 140)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        WhispererColors.accent.opacity(colorScheme == .dark ? 0.06 : 0.08),
                                        WhispererColors.cardBackground(colorScheme)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(WhispererColors.accent.opacity(0.4), lineWidth: 1.5)
                    )
            } else {
                let borderColor = transcription.hasAIEnhancement && !showingOriginal
                    ? Color.purple.opacity(colorScheme == .dark ? 0.15 : 0.12)
                    : WhispererColors.border(colorScheme)

                VStack(alignment: .leading, spacing: 0) {
                    HighlightedText(text: activeTranscriptionText, corrections: showingOriginal ? [] : transcription.corrections)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .foregroundColor(WhispererColors.primaryText(colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)

                    // Bottom bar: mode badge + menu (AI enhanced) or retranscribe
                    transcriptionCardFooter
                }
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(WhispererColors.cardBackground(colorScheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(borderColor, lineWidth: 1)
                    )
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.04 : 0.025),
                        radius: 3, y: 1
                    )
            }
        }
    }

    // MARK: - Transcription Header Menu

    private var transcriptionHeaderMenu: some View {
        Menu {
            Button(action: {
                withAnimation(.spring(response: 0.3)) { isEditing = true }
            }) {
                Label("Edit", systemImage: "pencil")
            }

            if transcription.hasAIEnhancement {
                Divider()

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) { showingOriginal.toggle() }
                }) {
                    Label(
                        showingOriginal ? "View AI Enhanced" : "View Original",
                        systemImage: showingOriginal ? "wand.and.stars" : "doc.text"
                    )
                }

                Button(role: .destructive, action: {
                    withAnimation(.easeInOut(duration: 0.15)) { showRevertConfirmation = true }
                }) {
                    Label("Revert to Original", systemImage: "arrow.uturn.backward")
                }
            }

            if transcription.audioURL != nil {
                Divider()

                Button(action: {
                    withAnimation(.spring(response: 0.35)) { showRetranscribePanel = true }
                }) {
                    Label("Re-transcribe", systemImage: "arrow.clockwise")
                }
                .disabled(isRetranscribing || showRetranscribePanel)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isRetranscribing ? "progress.indicator" : "ellipsis.circle")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(WhispererColors.secondaryText(colorScheme))
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.6))
            )
            .overlay(
                Circle()
                    .stroke(WhispererColors.border(colorScheme), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .frame(width: 32)
    }

    // MARK: - Transcription Card Footer

    @ViewBuilder
    private var transcriptionCardFooter: some View {
        if transcription.hasAIEnhancement {
            HStack(spacing: 8) {
                // AI enhanced + mode badge
                let badgeColor: Color = showingOriginal ? WhispererColors.accentBlue : .purple
                let badgeIcon = showingOriginal ? "doc.text" : "wand.and.stars"
                let badgeText: String = {
                    if showingOriginal { return "Original" }
                    if let modeName = transcription.aiModeName {
                        return "AI Enhanced \u{00B7} \(modeName)"
                    }
                    return "AI Enhanced"
                }()

                HStack(spacing: 4) {
                    Image(systemName: badgeIcon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(badgeColor)
                    Text(badgeText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(badgeColor)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(badgeColor.opacity(colorScheme == .dark ? 0.12 : 0.08)))

                // Revert confirmation inline
                if showRevertConfirmation {
                    HStack(spacing: 4) {
                        Button(action: revertAIEnhancement) {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                Text("Revert")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.red))
                        }
                        .buttonStyle(.plain).pointerOnHover()

                        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showRevertConfirmation = false } }) {
                            Text("Cancel")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(WhispererColors.elevatedBackground(colorScheme)))
                        }
                        .buttonStyle(.plain).pointerOnHover()
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Retranscribe Panel

    private var retranscribePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Language label + picker
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.blue.opacity(colorScheme == .dark ? 0.15 : 0.12))
                        .frame(width: 24, height: 24)
                        .shadow(color: Color.blue.opacity(0.06), radius: 2, y: 1)

                    Image(systemName: "globe")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.blue)
                }

                Text("Language")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))

                Spacer()

                Picker("", selection: $retranscribeLanguage) {
                    ForEach(TranscriptionLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .tint(WhispererColors.accentBlue)
            }

            // Action buttons
            HStack {
                Button(action: retranscribe) {
                    HStack(spacing: 6) {
                        if isRetranscribing {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(isRetranscribing ? "Re-transcribing..." : "Re-transcribe")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(WhispererColors.accentGradient))
                    .shadow(color: WhispererColors.accentBlue.opacity(0.25), radius: 4, y: 1)
                }
                .buttonStyle(.plain).pointerOnHover()
                .disabled(isRetranscribing)

                Spacer()

                Button(action: {
                    withAnimation(.spring(response: 0.35)) { showRetranscribePanel = false }
                }) {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                }
                .buttonStyle(.plain).pointerOnHover()
                .disabled(isRetranscribing)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(WhispererColors.elevatedBackground(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(WhispererColors.accent.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: WhispererColors.accent.opacity(0.06), radius: 3, y: 1)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Details Section

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Details", icon: "info.circle", color: .red)

            // 2-column grid of stat cards
            let columns = [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ]

            LazyVGrid(columns: columns, spacing: 12) {
                DetailStatCard(icon: "clock", label: "DURATION", value: durationString, color: WhispererColors.accent, colorScheme: colorScheme)
                DetailStatCard(icon: "text.word.spacing", label: "WORDS", value: "\(transcription.wordCount)", color: .blue, colorScheme: colorScheme)
                DetailStatCard(icon: "speedometer", label: "WPM", value: "\(transcription.wordsPerMinute)", color: .red, colorScheme: colorScheme)
                DetailStatCard(icon: "globe", label: "LANGUAGE", value: languageDisplay, color: .orange, colorScheme: colorScheme)
                DetailStatCard(icon: "cpu", label: "MODEL", value: modelDisplay, color: .cyan, colorScheme: colorScheme)
            }
        }
    }

    // MARK: - Notes Section

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Notes", icon: "note.text", color: .orange)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $notes)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .frame(minHeight: 100)
                    .onChange(of: notes) { _ in
                        saveNotes()
                    }

                if notes.isEmpty {
                    Text("Add notes about this transcription...")
                        .font(.system(size: 14))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.6))
                        .padding(18)
                        .allowsHitTesting(false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(WhispererColors.cardBackground(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.04 : 0.025),
                radius: 3, y: 1
            )
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String, icon: String, color: Color = WhispererColors.accent) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.opacity(colorScheme == .dark ? 0.15 : 0.12))
                    .frame(width: 24, height: 24)
                    .shadow(color: color.opacity(0.06), radius: 2, y: 1)

                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(color)
            }

            Text(text.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                .tracking(0.8)
        }
    }

    private var dayLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(transcription.timestamp) {
            return "Today"
        } else if calendar.isDateInYesterday(transcription.timestamp) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: transcription.timestamp)
        }
    }

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        return formatter.string(from: transcription.timestamp)
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: transcription.timestamp)
    }

    private var durationString: String {
        let minutes = Int(transcription.duration) / 60
        let seconds = Int(transcription.duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var languageDisplay: String {
        let code = transcription.language
        if code == "en" { return "English" }
        if code == "auto" { return "Auto" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private var modelDisplay: String {
        let model = transcription.modelUsed
        // Legacy records stored Whisper filenames — map to display names
        if model.contains("large-v3-turbo-q5") { return "Large V3 Turbo Q5" }
        else if model.contains("large-v3-turbo") { return "Large V3 Turbo" }
        else if model.contains("large-v3-q5") { return "Large V3 Q5" }
        else if model.contains("large-v3") { return "Large V3" }
        else if model.contains("distil-large") { return "Distil Large V3" }
        else if model.contains("distil-small") { return "Distil Small" }
        else if model.contains("medium") { return "Medium" }
        else if model.contains("small") { return "Small" }
        else if model.contains("base") { return "Base" }
        else if model.contains("tiny") { return "Tiny" }
        // New records already store display names (e.g., "Parakeet v3 (Multilingual)", "Apple Speech")
        return model
    }

    // MARK: - Actions

    private func saveChanges() {
        guard editedText != transcription.displayText else { return }
        Task {
            try? await HistoryManager.shared.editTranscription(transcription, newText: editedText)
        }
    }

    private func saveNotes() {
        Task {
            try? await HistoryManager.shared.updateNotes(transcription, notes: notes.isEmpty ? nil : notes)
        }
    }

    private func retranscribe() {
        guard let audioURL = transcription.audioURL else { return }
        guard let bridge = AppState.shared.fileTranscriptionBridge else {
            Logger.warning("Cannot re-transcribe: model not loaded", subsystem: .transcription)
            return
        }
        guard AppState.shared.state == .idle else {
            Logger.warning("Cannot re-transcribe: recording in progress", subsystem: .transcription)
            return
        }

        isRetranscribing = true
        let language = retranscribeLanguage

        Task.detached(priority: .userInitiated) { [weak bridge] in
            guard let bridge = bridge else {
                await MainActor.run { isRetranscribing = false }
                return
            }

            do {
                // Load audio samples from saved WAV file (already 16kHz mono Float32)
                let audioFile = try AVAudioFile(forReading: audioURL)
                let frameCount = AVAudioFrameCount(audioFile.length)
                guard frameCount > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
                    Logger.error("Failed to create audio buffer for re-transcription", subsystem: .transcription)
                    await MainActor.run { isRetranscribing = false }
                    return
                }
                try audioFile.read(into: buffer)

                guard let channelData = buffer.floatChannelData else {
                    Logger.error("No channel data in audio buffer", subsystem: .transcription)
                    await MainActor.run { isRetranscribing = false }
                    return
                }
                let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))

                let promptWords = await AppState.shared.promptWordsString
                let modelName = await AppState.shared.activeModelDisplayName
                let rawText = bridge.transcribe(samples: samples, initialPrompt: promptWords, language: language)

                // Resolve language for history: detected language when auto, otherwise user selection
                let recordedLanguage: String
                if language == .auto, let detected = bridge.lastDetectedLanguage {
                    recordedLanguage = detected
                } else {
                    recordedLanguage = language.rawValue
                }

                // Apply dictionary corrections
                let finalText = DictionaryManager.shared.correctText(rawText)

                guard !finalText.isEmpty else {
                    Logger.warning("Re-transcription produced empty result", subsystem: .transcription)
                    await MainActor.run { isRetranscribing = false }
                    return
                }

                Logger.info("Re-transcription complete (\(modelName), lang=\(recordedLanguage)): '\(finalText.prefix(80))'", subsystem: .transcription)

                await MainActor.run {
                    editedText = finalText
                    isRetranscribing = false
                    showingOriginal = false
                    withAnimation(.spring(response: 0.35)) { showRetranscribePanel = false }
                }

                // Save to history with updated language and model
                try? await HistoryManager.shared.retranscribe(transcription, newText: finalText, language: recordedLanguage, modelUsed: modelName)

            } catch {
                Logger.error("Re-transcription failed: \(error.localizedDescription)", subsystem: .transcription)
                await MainActor.run { isRetranscribing = false }
            }
        }
    }

    private func revertAIEnhancement() {
        Task {
            try? await HistoryManager.shared.revertAIEnhancement(transcription)
            showRevertConfirmation = false
            editedText = transcription.transcription
        }
    }

    private func shareTranscription() {
        let picker = NSSharingServicePicker(items: [transcription.displayText])
        if let window = NSApp.keyWindow {
            picker.show(relativeTo: .zero, of: window.contentView!, preferredEdge: .minY)
        }
    }
}

// MARK: - Detail Header Button

struct DetailHeaderButton: View {
    let icon: String
    var iconColor: Color? = nil
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isHovered = false

    private var foreground: Color {
        if let iconColor { return iconColor }
        return isHovered ? WhispererColors.primaryText(colorScheme) : WhispererColors.secondaryText(colorScheme)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: icon == "xmark" ? 11 : 13, weight: icon == "xmark" ? .bold : .medium))
                .foregroundColor(foreground)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(isHovered ? WhispererColors.elevatedBackground(colorScheme) : WhispererColors.elevatedBackground(colorScheme).opacity(0.6))
                )
                .overlay(
                    Circle()
                        .stroke(isHovered ? WhispererColors.border(colorScheme) : Color.clear, lineWidth: 0.5)
                )
                .shadow(
                    color: isHovered ? Color.black.opacity(colorScheme == .dark ? 0.08 : 0.06) : Color.clear,
                    radius: 3, y: 1
                )
                .scaleEffect(isHovered ? 1.06 : 1.0)
        }
        .buttonStyle(.plain).pointerOnHover()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Retranscribe Button

struct RetranscribeButton: View {
    let isRetranscribing: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRetranscribing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.65)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isHovered ? WhispererColors.primaryText(colorScheme) : WhispererColors.secondaryText(colorScheme))
                }
            }
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(isHovered ? WhispererColors.elevatedBackground(colorScheme) : WhispererColors.elevatedBackground(colorScheme).opacity(0.6))
            )
            .overlay(
                Circle()
                    .stroke(isHovered ? WhispererColors.border(colorScheme) : Color.clear, lineWidth: 0.5)
            )
            .shadow(
                color: isHovered ? Color.black.opacity(colorScheme == .dark ? 0.08 : 0.06) : Color.clear,
                radius: 3, y: 1
            )
            .scaleEffect(isHovered ? 1.06 : 1.0)
        }
        .buttonStyle(.plain).pointerOnHover()
        .disabled(isRetranscribing)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Detail Stat Card

struct DetailStatCard: View {
    let icon: String
    let label: String
    let value: String
    let color: Color
    let colorScheme: ColorScheme

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Icon in gradient circle
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(colorScheme == .dark ? 0.12 : 0.12),
                                color.opacity(colorScheme == .dark ? 0.05 : 0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)

                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(color)
            }
            .padding(.bottom, 14)

            // Label
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.7))
                .tracking(1.0)
                .padding(.bottom, 4)

            // Value
            Text(value)
                .font(.system(size: 20, weight: .light, design: .rounded))
                .foregroundColor(WhispererColors.primaryText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [
                            color.opacity(colorScheme == .dark ? 0.08 : 0.04),
                            WhispererColors.cardBackground(colorScheme)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(
                    color: colorScheme == .dark
                        ? Color.black.opacity(0.25)
                        : color.opacity(0.08),
                    radius: isHovered ? 10 : 4,
                    y: isHovered ? 4 : 1
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    isHovered
                        ? color.opacity(colorScheme == .dark ? 0.2 : 0.25)
                        : color.opacity(colorScheme == .dark ? 0.08 : 0.1),
                    lineWidth: 1
                )
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Reveal in Finder Button

struct RevealInFinderButton: View {
    let url: URL
    let colorScheme: ColorScheme

    @State private var isHovered = false

    var body: some View {
        Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(
                    isHovered ? .cyan : WhispererColors.secondaryText(colorScheme)
                )
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isHovered ? WhispererColors.elevatedBackground(colorScheme) : WhispererColors.elevatedBackground(colorScheme).opacity(0.6))
                )
                .overlay(
                    Circle()
                        .stroke(isHovered ? WhispererColors.border(colorScheme) : Color.clear, lineWidth: 0.5)
                )
                .shadow(
                    color: isHovered ? Color.black.opacity(colorScheme == .dark ? 0.08 : 0.06) : Color.clear,
                    radius: 3, y: 1
                )
                .scaleEffect(isHovered ? 1.06 : 1.0)
        }
        .buttonStyle(.plain).pointerOnHover()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}
