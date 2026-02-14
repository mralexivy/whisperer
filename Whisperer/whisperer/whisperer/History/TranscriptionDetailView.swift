//
//  TranscriptionDetailView.swift
//  Whisperer
//
//  Detail panel for viewing and editing transcriptions - Matching Whisperer design
//

import SwiftUI

struct TranscriptionDetailView: View {
    @Environment(\.colorScheme) var colorScheme
    let transcription: TranscriptionRecord
    let onClose: () -> Void

    @State private var editedText: String
    @State private var notes: String
    @State private var isEditing = false

    init(transcription: TranscriptionRecord, onClose: @escaping () -> Void) {
        self.transcription = transcription
        self.onClose = onClose
        _editedText = State(initialValue: transcription.displayText)
        _notes = State(initialValue: transcription.notes ?? "")
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
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(dayLabel)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(WhispererColors.accent)
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
        .padding(.vertical, 16)
        .background(WhispererColors.background(colorScheme))
    }

    // MARK: - Audio Section

    private func audioSection(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Audio Recording", icon: "waveform")
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
    }

    // MARK: - Transcription Section

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel("Transcription", icon: "text.alignleft")

                Spacer()

                Button(action: {
                    if isEditing {
                        saveChanges()
                    }
                    withAnimation(.spring(response: 0.3)) {
                        isEditing.toggle()
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: isEditing ? "checkmark" : "pencil")
                            .font(.system(size: 10, weight: .semibold))
                        Text(isEditing ? "Save" : "Edit")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(isEditing ? .white : WhispererColors.primaryText(colorScheme))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(isEditing ? WhispererColors.accent : WhispererColors.elevatedBackground(colorScheme))
                    )
                }
                .buttonStyle(.plain)
            }

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
                                        WhispererColors.accent.opacity(colorScheme == .dark ? 0.12 : 0.08),
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
                // Show highlighted text with dictionary corrections
                HighlightedText(text: editedText, corrections: transcription.corrections)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundColor(WhispererColors.primaryText(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(WhispererColors.cardBackground(colorScheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - Details Section

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Details", icon: "info.circle")

            // 2-column grid of stat cards
            let columns = [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ]

            LazyVGrid(columns: columns, spacing: 12) {
                DetailStatCard(icon: "clock", label: "DURATION", value: durationString, color: WhispererColors.accent, colorScheme: colorScheme)
                DetailStatCard(icon: "text.word.spacing", label: "WORDS", value: "\(transcription.wordCount)", color: .blue, colorScheme: colorScheme)
                DetailStatCard(icon: "speedometer", label: "WPM", value: "\(transcription.wordsPerMinute)", color: .purple, colorScheme: colorScheme)
                DetailStatCard(icon: "globe", label: "LANGUAGE", value: languageDisplay, color: .orange, colorScheme: colorScheme)
                DetailStatCard(icon: "cpu", label: "MODEL", value: modelDisplay, color: .cyan, colorScheme: colorScheme)
            }
        }
    }

    // MARK: - Notes Section

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Notes", icon: "note.text")

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
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(WhispererColors.accent.opacity(colorScheme == .dark ? 0.15 : 0.1))
                    .frame(width: 24, height: 24)

                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(WhispererColors.accent)
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
        if model.contains("large-v3-turbo") { return "Large V3 Turbo" }
        else if model.contains("large-v3") { return "Large V3" }
        else if model.contains("medium") { return "Medium" }
        else if model.contains("small") { return "Small" }
        else if model.contains("base") { return "Base" }
        else if model.contains("tiny") { return "Tiny" }
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
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: icon == "xmark" ? 11 : 13, weight: icon == "xmark" ? .bold : .medium))
                .foregroundColor(isHovered ? WhispererColors.primaryText(colorScheme) : WhispererColors.secondaryText(colorScheme))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(isHovered ? WhispererColors.elevatedBackground(colorScheme) : WhispererColors.elevatedBackground(colorScheme).opacity(0.6))
                )
                .overlay(
                    Circle()
                        .stroke(isHovered ? WhispererColors.border(colorScheme) : Color.clear, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
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
                                color.opacity(colorScheme == .dark ? 0.2 : 0.12),
                                color.opacity(colorScheme == .dark ? 0.1 : 0.06)
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
                .font(.system(size: 20, weight: .bold, design: .rounded))
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
                        ? color.opacity(colorScheme == .dark ? 0.35 : 0.25)
                        : color.opacity(colorScheme == .dark ? 0.15 : 0.1),
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
