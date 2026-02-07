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
        .background(WhispererColors.background(colorScheme))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dayLabel)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(WhispererColors.accent)
                    .textCase(.uppercase)

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
                // Share
                Button(action: shareTranscription) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(WhispererColors.elevatedBackground(colorScheme))
                        )
                }
                .buttonStyle(.plain)
                .help("Share")

                // Close
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(WhispererColors.elevatedBackground(colorScheme))
                        )
                }
                .buttonStyle(.plain)
                .help("Close")
            }
        }
        .padding(20)
        .background(WhispererColors.cardBackground(colorScheme))
        .overlay(
            Rectangle()
                .fill(WhispererColors.border(colorScheme))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Audio Section

    private func audioSection(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Audio Recording", icon: "waveform")

            AudioPlayerView(audioURL: url, duration: transcription.duration)
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(WhispererColors.cardBackground(colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                )
        }
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
                            .fill(WhispererColors.cardBackground(colorScheme))
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

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 10) {
                DetailCard(icon: "clock", label: "Duration", value: durationString, colorScheme: colorScheme)
                DetailCard(icon: "text.word.spacing", label: "Words", value: "\(transcription.wordCount)", colorScheme: colorScheme)
                DetailCard(icon: "speedometer", label: "WPM", value: "\(transcription.wordsPerMinute)", colorScheme: colorScheme)
                DetailCard(icon: "globe", label: "Language", value: languageDisplay, colorScheme: colorScheme)
            }

            // Model (full width)
            HStack(spacing: 12) {
                Image(systemName: "cpu")
                    .font(.system(size: 12))
                    .foregroundColor(WhispererColors.accent)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(WhispererColors.accent.opacity(0.15))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("Model")
                        .font(.system(size: 10))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    Text(modelDisplay)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))
                }

                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(WhispererColors.cardBackground(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
            )
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
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(WhispererColors.accent)

            Text(text)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(WhispererColors.primaryText(colorScheme))
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

// MARK: - Detail Card

struct DetailCard: View {
    let icon: String
    let label: String
    let value: String
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(WhispererColors.accent)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(WhispererColors.accent.opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(WhispererColors.cardBackground(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
        )
    }
}
