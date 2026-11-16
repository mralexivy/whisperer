//
//  FileTranscriptReaderView.swift
//  Whisperer
//
//  The finished file transcription as something to read: paragraphs in a comfortable column, an
//  approximate time beside each, and a copy button on the one under the pointer. Lazy, so a
//  two-hour recording scrolls as smoothly as a one-minute one. Any script: each paragraph picks its
//  own direction from its letters.
//

import SwiftUI
import AppKit

struct FileTranscriptReaderView: View {
    let paragraphs: [FileTranscriptParagraph]
    let language: TranscriptionLanguage
    let colorScheme: ColorScheme

    /// Wide enough to feel like a page, narrow enough that a line is easy to follow (~75 characters).
    private static let columnWidth: CGFloat = 720

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(paragraphs) { paragraph in
                FileTranscriptParagraphRow(paragraph: paragraph, language: language, colorScheme: colorScheme)
            }
        }
        .frame(maxWidth: Self.columnWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct FileTranscriptParagraphRow: View {
    let paragraph: FileTranscriptParagraph
    let language: TranscriptionLanguage
    let colorScheme: ColorScheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var copied = false

    private var isRTL: Bool { MeetingTranscriptText.isRightToLeft(text: paragraph.text, fallback: language) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            timestamp
                .frame(width: 48, alignment: .trailing)

            text
                .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)

            copyButton
                .opacity(hovering || copied ? 1 : 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.035 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { hovering = inside }
        }
    }

    @ViewBuilder private var timestamp: some View {
        if let start = paragraph.start {
            Text(FileTranscriptClock.format(start))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundColor(hovering ? WhispererColors.accent : WhispererColors.tertiaryText(colorScheme))
        }
    }

    @ViewBuilder private var text: some View {
        if isRTL {
            ReaderParagraphText(text: paragraph.text)
        } else {
            Text(paragraph.text)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(Color.white.opacity(0.88))
                .lineSpacing(6)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var copyButton: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(copied ? Color(hex: "22C55E") : WhispererColors.secondaryText(colorScheme))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help("Copy paragraph")
        .uiTestFrame("fileTranscript.paragraph.copy.\(paragraph.id)")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paragraph.text, forType: .string)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { copied = false }
        }
    }

}

/// Right-to-left paragraph. SwiftUI `Text` cannot set a paragraph's base writing direction, so this
/// is an AppKit text field (see CLAUDE.md, "RTL text in SwiftUI"). Selectable, wraps to the width
/// SwiftUI proposes.
private struct ReaderParagraphText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isEditable = false
        field.isSelectable = true
        field.drawsBackground = false
        field.isBordered = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        style.baseWritingDirection = .rightToLeft
        style.alignment = .right
        field.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88),
            .paragraphStyle: style,
        ])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        field.preferredMaxLayoutWidth = width
        let size = field.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }
}

nonisolated enum FileTranscriptClock {
    /// `m:ss`, or `h:mm:ss` from an hour up.
    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
