//
//  TranscriptionRow.swift
//  Whisperer
//
//  Clean row component for transcription list
//

import SwiftUI

struct TranscriptionRow: View {
    let transcription: TranscriptionRecord
    let isSelected: Bool
    let colorScheme: ColorScheme
    let onSelect: () -> Void

    @State private var isHovered = false
    @State private var showCopiedFeedback = false
    @AppStorage("timeFormat") private var timeFormat: String = "12h"

    // MARK: - Accent bar color

    private var accentBarColor: Color {
        if isSelected { return WhispererColors.accent }
        if transcription.isFlagged { return .red }
        if transcription.isPinned { return .orange }
        return .clear
    }

    private var showAccentBar: Bool {
        isSelected || transcription.isPinned || transcription.isFlagged
    }

    // MARK: - Body

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                // Left accent bar — full height, clipped to card radius
                Rectangle()
                    .fill(accentBarColor)
                    .frame(width: 3.5)
                    .opacity(showAccentBar ? 1 : 0)

                // Main content
                VStack(alignment: .leading, spacing: 8) {
                    // Top line: Time · Duration ... status icons + action buttons
                    HStack(spacing: 0) {
                        // Time and duration
                        HStack(spacing: 8) {
                            Text(timeString)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(isSelected ? WhispererColors.accent : WhispererColors.primaryText(colorScheme))

                            Text(durationString)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(WhispererColors.elevatedBackground(colorScheme))
                                )
                        }

                        Spacer(minLength: 8)

                        // Status icons (always visible)
                        HStack(spacing: 6) {
                            if transcription.editedTranscription != nil {
                                Image(systemName: "pencil")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.orange)
                            }

                            if transcription.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.orange)
                            }

                            if transcription.isFlagged {
                                Image(systemName: "flag.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.red)
                            }
                        }

                        // Action buttons (on hover/selected)
                        actionButtons
                    }

                    // Text preview
                    Text(transcription.displayText)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)

                    // Bottom metadata: wpm · words · Language
                    HStack(spacing: 10) {
                        metadataPill(icon: "speedometer", text: "\(transcription.wordsPerMinute) wpm", color: .orange)
                        metadataPill(icon: "text.word.spacing", text: "\(transcription.wordCount) words", color: WhispererColors.accentBlue)
                        metadataPill(icon: "globe", text: languageDisplay, color: .purple)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .padding(.trailing, 14)
                .padding(.vertical, 14)
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(LinearGradient(
                                colors: [
                                    WhispererColors.accent.opacity(colorScheme == .dark ? 0.08 : 0.05),
                                    WhispererColors.accent.opacity(colorScheme == .dark ? 0.02 : 0.01)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                            : (isHovered
                                ? AnyShapeStyle(LinearGradient(
                                    colors: [
                                        WhispererColors.cardBackground(colorScheme),
                                        WhispererColors.elevatedBackground(colorScheme).opacity(0.3)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ))
                                : AnyShapeStyle(WhispererColors.cardBackground(colorScheme)))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected
                            ? WhispererColors.accent.opacity(0.3)
                            : (isHovered
                                ? WhispererColors.border(colorScheme).opacity(colorScheme == .dark ? 2.5 : 1.2)
                                : WhispererColors.border(colorScheme)),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .shadow(
                color: isSelected
                    ? WhispererColors.accent.opacity(colorScheme == .dark ? 0.06 : 0.08)
                    : (isHovered
                        ? Color.black.opacity(colorScheme == .dark ? 0.12 : 0.06)
                        : Color.black.opacity(colorScheme == .dark ? 0.06 : 0.03)),
                radius: isSelected ? 8 : (isHovered ? 6 : 3),
                y: isSelected ? 3 : (isHovered ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .scaleEffect(isHovered && !isSelected ? 1.006 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .overlay(alignment: .top) {
            copiedFeedback
                .offset(y: -8)
                .opacity(showCopiedFeedback ? 1 : 0)
                .scaleEffect(showCopiedFeedback ? 1 : 0.8)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 2) {
            RowActionButton(icon: "doc.on.doc", tooltip: "Copy", colorScheme: colorScheme) {
                copyToClipboard()
            }

            RowActionButton(
                icon: transcription.isFlagged ? "flag.fill" : "flag",
                tooltip: transcription.isFlagged ? "Unflag" : "Flag",
                isActive: transcription.isFlagged,
                activeColor: .red,
                colorScheme: colorScheme
            ) {
                toggleFlag()
            }

            RowActionButton(
                icon: transcription.isPinned ? "pin.fill" : "pin",
                tooltip: transcription.isPinned ? "Unpin" : "Pin",
                isActive: transcription.isPinned,
                activeColor: .orange,
                colorScheme: colorScheme
            ) {
                togglePin()
            }

            Menu {
                Button(action: onSelect) {
                    Label("View Details", systemImage: "eye")
                }
                Button(action: shareTranscription) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive, action: deleteTranscription) {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(WhispererColors.elevatedBackground(colorScheme))
                    )
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("More")
        }
        .opacity(isHovered || isSelected ? 1 : 0)
    }

    // MARK: - Copied Feedback

    private var copiedFeedback: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
            Text("Copied")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(WhispererColors.accent)
                .shadow(color: WhispererColors.accent.opacity(0.3), radius: 6, y: 2)
        )
    }

    // MARK: - Metadata Pill

    private func metadataPill(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(color.opacity(colorScheme == .dark ? 0.12 : 0.08))
        )
    }

    // MARK: - Helpers

    private var timeString: String {
        let formatter = DateFormatter()
        if timeFormat == "24h" {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "h:mm a"
        }
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

    // MARK: - Actions

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcription.displayText, forType: .string)

        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            showCopiedFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.2)) {
                showCopiedFeedback = false
            }
        }
    }

    private func toggleFlag() {
        Task {
            try? await HistoryManager.shared.toggleFlag(transcription)
        }
    }

    private func togglePin() {
        Task {
            try? await HistoryManager.shared.togglePin(transcription)
        }
    }

    private func shareTranscription() {
        let picker = NSSharingServicePicker(items: [transcription.displayText])
        if let window = NSApp.keyWindow {
            picker.show(relativeTo: .zero, of: window.contentView!, preferredEdge: .minY)
        }
    }

    private func deleteTranscription() {
        Task {
            try? await HistoryManager.shared.deleteTranscription(transcription)
        }
    }
}

// MARK: - Row Action Button

struct RowActionButton: View {
    let icon: String
    var tooltip: String = ""
    var isActive: Bool = false
    var activeColor: Color = WhispererColors.accent
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(
                    isActive
                        ? activeColor
                        : (isHovered ? WhispererColors.primaryText(colorScheme) : WhispererColors.secondaryText(colorScheme))
                )
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isHovered ? WhispererColors.elevatedBackground(colorScheme) : Color.clear)
                )
                .overlay(
                    Circle()
                        .stroke(isHovered ? WhispererColors.border(colorScheme) : Color.clear, lineWidth: 0.5)
                )
                .scaleEffect(isHovered ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help(tooltip)
    }
}
