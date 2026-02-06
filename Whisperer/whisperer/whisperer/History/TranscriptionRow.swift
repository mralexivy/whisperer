//
//  TranscriptionRow.swift
//  Whisperer
//
//  Row component for transcription list - Matching Whisperer design
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

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 16) {
                // Time column
                VStack(spacing: 4) {
                    Text(timeString)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(isSelected ? WhispererColors.accent : WhispererColors.secondaryText(colorScheme))

                    // Duration badge
                    Text(durationString)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(isSelected ? WhispererColors.accent : WhispererColors.secondaryText(colorScheme).opacity(0.6))
                        )
                }
                .frame(width: 56)

                // Content
                VStack(alignment: .leading, spacing: 10) {
                    // Text preview
                    Text(transcription.displayText)
                        .font(.system(size: 14))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(3)

                    // Metadata row
                    HStack(spacing: 10) {
                        // WPM
                        MetaBadge(
                            icon: "speedometer",
                            text: "\(transcription.wordsPerMinute) WPM",
                            colorScheme: colorScheme
                        )

                        // Word count
                        MetaBadge(
                            icon: "text.word.spacing",
                            text: "\(transcription.wordCount) words",
                            colorScheme: colorScheme
                        )

                        // Status indicators
                        HStack(spacing: 4) {
                            if transcription.isPinned {
                                StatusDot(icon: "pin.fill", color: .orange)
                            }
                            if transcription.isFlagged {
                                StatusDot(icon: "flag.fill", color: .red)
                            }
                            if transcription.editedTranscription != nil {
                                StatusDot(icon: "pencil", color: .purple)
                            }
                        }

                        Spacer()
                    }
                }

                // Action buttons (on hover/select)
                if isHovered || isSelected {
                    actionButtons
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? WhispererColors.cardBackground(colorScheme) : (isHovered ? WhispererColors.cardBackground(colorScheme).opacity(0.7) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected ? WhispererColors.accent.opacity(0.5) : (isHovered ? WhispererColors.border(colorScheme) : Color.clear),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .overlay(
            copiedFeedback
                .opacity(showCopiedFeedback ? 1 : 0)
        )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 2) {
            RowActionButton(icon: "doc.on.doc", colorScheme: colorScheme) {
                copyToClipboard()
            }

            RowActionButton(
                icon: transcription.isFlagged ? "flag.fill" : "flag",
                isActive: transcription.isFlagged,
                activeColor: .red,
                colorScheme: colorScheme
            ) {
                toggleFlag()
            }

            RowActionButton(
                icon: transcription.isPinned ? "pin.fill" : "pin",
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
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(WhispererColors.elevatedBackground(colorScheme))
                    )
            }
            .menuStyle(.borderlessButton)
            .frame(width: 26)
        }
    }

    private var copiedFeedback: some View {
        Text("Copied!")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(WhispererColors.accent)
            )
    }

    // MARK: - Helpers

    private var timeString: String {
        let formatter = DateFormatter()
        // Use time format from settings
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

        withAnimation(.spring(response: 0.3)) {
            showCopiedFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut) {
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

// MARK: - Supporting Views

struct MetaBadge: View {
    let icon: String
    let text: String
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(WhispererColors.accent)

            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(WhispererColors.accent.opacity(0.1))
        )
    }
}

struct StatusDot: View {
    let icon: String
    let color: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .frame(width: 20, height: 20)
            .background(
                Circle()
                    .fill(color.opacity(0.15))
            )
    }
}

struct RowActionButton: View {
    let icon: String
    var isActive: Bool = false
    var activeColor: Color = WhispererColors.accent
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isActive ? activeColor : (isHovered ? WhispererColors.primaryText(colorScheme) : WhispererColors.secondaryText(colorScheme)))
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(isHovered ? WhispererColors.elevatedBackground(colorScheme) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
