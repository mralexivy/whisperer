//
//  TranscriptionRow.swift
//  Whisperer
//
//  Premium row component for transcription list
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
                // Left accent bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentBarColor)
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .opacity(showAccentBar ? 1 : 0)

                // Main content
                VStack(alignment: .leading, spacing: 10) {
                    // Text preview — the hero element
                    Text(transcription.displayText)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)

                    // Metadata + actions row
                    HStack(spacing: 0) {
                        metadataRow

                        Spacer(minLength: 12)

                        actionButtons
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .padding(.vertical, 14)
            }
            .background(rowBackground)
            .overlay(rowBorder)
            .shadow(
                color: isSelected
                    ? WhispererColors.accent.opacity(0.12)
                    : (isHovered ? Color.black.opacity(colorScheme == .dark ? 0.2 : 0.06) : .clear),
                radius: isSelected ? 8 : 4,
                x: 0,
                y: isSelected ? 2 : 1
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
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

    // MARK: - Row background

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                isSelected
                    ? WhispererColors.cardBackground(colorScheme)
                    : (isHovered ? WhispererColors.cardBackground(colorScheme).opacity(0.6) : Color.clear)
            )
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(
                isSelected
                    ? WhispererColors.accent.opacity(0.5)
                    : (isHovered ? WhispererColors.border(colorScheme) : Color.clear),
                lineWidth: isSelected ? 1.5 : 1
            )
    }

    // MARK: - Inline Metadata

    private var metadataRow: some View {
        HStack(spacing: 6) {
            // Time
            Text(timeString)
                .foregroundColor(isSelected ? WhispererColors.accent : WhispererColors.secondaryText(colorScheme))
                .fontWeight(isSelected ? .semibold : .medium)

            metaDot

            // Duration
            Text(durationString)

            metaDot

            // WPM
            HStack(spacing: 3) {
                Image(systemName: "speedometer")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(WhispererColors.accent.opacity(0.7))
                Text("\(transcription.wordsPerMinute) WPM")
            }

            metaDot

            // Word count
            HStack(spacing: 3) {
                Image(systemName: "text.word.spacing")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(WhispererColors.accent.opacity(0.7))
                Text("\(transcription.wordCount)")
            }

            // Edited indicator
            if transcription.editedTranscription != nil {
                metaDot
                HStack(spacing: 3) {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.purple.opacity(0.7))
                    Text("Edited")
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(WhispererColors.secondaryText(colorScheme))
        .lineLimit(1)
    }

    private var metaDot: some View {
        Text("·")
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.4))
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
