//
//  RecordingReaderView.swift
//  Whisperer
//
//  The one paragraph reader for every recording. Speaker labels appear only when the paragraphs carry
//  speakers, times only when they carry times. The playhead paragraph is accented while audio plays or
//  after a seek, a cited or searched paragraph scrolls into view and flashes, and the row under the
//  pointer offers copy. Lazy: only visible paragraphs exist, so a two-hour recording stays light.
//

import Combine
import SwiftUI
import AppKit

// MARK: - In-transcript search

/// Search inside the open recording. Distinct from the list's global search.
@MainActor
final class RecordingSearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var matchIDs: [String] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var scrollToken = 0

    private var paragraphs: [TranscriptParagraph] = []

    var currentID: String? { matchIDs.indices.contains(currentIndex) ? matchIDs[currentIndex] : nil }
    var isActive: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    func setParagraphs(_ paragraphs: [TranscriptParagraph]) {
        self.paragraphs = paragraphs
        recompute(keepPosition: true)
    }

    func queryChanged() { recompute(keepPosition: false) }

    func next() { step(1) }
    func previous() { step(-1) }

    func clear() { query = ""; matchIDs = []; currentIndex = 0 }

    private func step(_ delta: Int) {
        guard !matchIDs.isEmpty else { return }
        currentIndex = (currentIndex + delta + matchIDs.count) % matchIDs.count
        scrollToken += 1
    }

    private func recompute(keepPosition: Bool) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { matchIDs = []; currentIndex = 0; return }
        matchIDs = paragraphs.filter { $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(\.id)
        if !keepPosition || currentIndex >= matchIDs.count { currentIndex = 0 }
        if !keepPosition { scrollToken += 1 }
    }
}

// MARK: - Reader

struct RecordingReaderView: View {
    /// How paragraphs are drawn. Chosen from what the recording has, not from a mode switch: speakers get
    /// avatar rows, an import gets numbered cards, a dictation is plain text.
    enum Style { case speakers, labelled, plain }

    let paragraphs: [TranscriptParagraph]
    let language: TranscriptionLanguage?
    let style: Style
    @ObservedObject var playback: RecordingPlaybackController
    @ObservedObject var search: RecordingSearchModel

    private static let columnWidth: CGFloat = 860

    static func style(for document: TranscriptDocument) -> Style {
        if document.hasSpeakers { return .speakers }
        return document.kind == .file ? .labelled : .plain
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: style == .plain ? 6 : 10) {
                    ForEach(Array(paragraphs.enumerated()), id: \.element.id) { index, paragraph in
                        RecordingParagraphRow(
                            paragraph: paragraph, number: index + 1, style: style, language: language, playback: playback,
                            isPlayhead: playback.playheadParagraphID == paragraph.id,
                            isMatch: search.isActive && search.matchIDs.contains(paragraph.id),
                            isCurrentMatch: search.currentID == paragraph.id,
                            query: search.isActive ? search.query.trimmingCharacters(in: .whitespaces) : "")
                            .id(paragraph.id)
                    }
                }
                .frame(maxWidth: Self.columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The rows carry 16 pt of their own padding, so text lines up with the header at 28.
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
            .onChange(of: playback.revealed) { _, reveal in
                guard let reveal else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(reveal.paragraphID, anchor: .center) }
            }
            .onChange(of: search.scrollToken) { _, _ in
                guard let id = search.currentID else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

private struct RecordingParagraphRow: View {
    let paragraph: TranscriptParagraph
    let number: Int
    let style: RecordingReaderView.Style
    let language: TranscriptionLanguage?
    @ObservedObject var playback: RecordingPlaybackController
    let isPlayhead: Bool
    let isMatch: Bool
    let isCurrentMatch: Bool
    let query: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var copied = false
    @State private var flashing = false

    private var isRTL: Bool { MeetingTranscriptText.isRightToLeft(text: paragraph.text, fallback: language) }
    private var tint: Color { speakerColor(for: paragraph.speakerIndex ?? 0) }
    private var accent: Color { WhispererColors.accent }
    private var active: Bool { isPlayhead || flashing || isCurrentMatch }
    private var showsCard: Bool { style == .labelled || active || hovering || isMatch }

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, style == .plain ? 12 : 16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(stroke, lineWidth: 1))
            .overlay(alignment: .topTrailing) { copyButton.padding(10).opacity(hovering || copied ? 1 : 0) }
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { hovering = inside } }
            .onChange(of: playback.revealed) { _, reveal in
                guard reveal?.paragraphID == paragraph.id else { return }
                withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) { flashing = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { flashing = false }
                }
            }
            .accessibilityElement(children: .combine)
    }

    // MARK: Layouts

    @ViewBuilder private var content: some View {
        switch style {
        case .speakers: speakerLayout
        case .labelled: labelledLayout
        case .plain: text
        }
    }

    private var speakerLayout: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(initials)
                .font(.system(size: 10, weight: .bold)).foregroundColor(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(0.16)))
                .overlay(Circle().stroke(tint.opacity(0.35), lineWidth: 1))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(paragraph.speakerName ?? "").font(.system(size: 14, weight: .semibold)).foregroundColor(tint)
                    Spacer()
                    timeLabel
                }
                text
            }
        }
    }

    private var labelledLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("PARAGRAPH \(String(format: "%02d", number))")
                    .font(.system(size: 10.5, weight: .semibold)).tracking(0.9)
                    .foregroundColor(Color.white.opacity(0.4))
                timeLabel
                Spacer()
            }
            text
        }
    }

    @ViewBuilder private var timeLabel: some View {
        if let start = paragraph.start {
            Button { playback.seek(toParagraph: paragraph) } label: {
                Text(FileTranscriptClock.format(start))
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundColor(hovering || isPlayhead ? accent : Color.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!playback.isAvailable)
            .help(playback.isAvailable ? "Play from here" : "Audio not available")
            .accessibilityLabel("Play from \(FileTranscriptClock.format(start))")
        }
    }

    @ViewBuilder private var text: some View {
        if isRTL {
            ReaderRTLText(text: paragraph.text, size: 17)
        } else {
            Text(highlighted)
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(Color.white.opacity(0.9))
                .lineSpacing(9)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var initials: String {
        let parts = (paragraph.speakerName ?? "").split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "·" : String(letters).uppercased()
    }

    // MARK: Surfaces

    private var fill: Color {
        if flashing { return accent.opacity(0.20) }
        if isCurrentMatch { return Color.yellow.opacity(0.12) }
        if isPlayhead { return accent.opacity(0.10) }
        if style == .labelled { return Color.white.opacity(hovering ? 0.045 : 0.025) }
        if isMatch { return Color.yellow.opacity(0.05) }
        return Color.white.opacity(hovering ? 0.035 : 0)
    }

    private var stroke: Color {
        if flashing || isPlayhead { return accent.opacity(0.45) }
        if isCurrentMatch { return Color.yellow.opacity(0.35) }
        if style == .labelled { return Color.white.opacity(0.08) }
        return showsCard ? Color.white.opacity(0.08) : .clear
    }

    private var highlighted: AttributedString {
        var attributed = AttributedString(paragraph.text)
        guard !query.isEmpty else { return attributed }
        var searchStart = paragraph.text.startIndex
        while let range = paragraph.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                               range: searchStart..<paragraph.text.endIndex),
              let target = Range(range, in: attributed) {
            attributed[target].backgroundColor = Color.yellow.opacity(isCurrentMatch ? 0.55 : 0.35)
            attributed[target].foregroundColor = .black
            searchStart = range.upperBound
        }
        return attributed
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paragraph.text, forType: .string)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(copied ? Color(hex: "22C55E") : Color.white.opacity(0.6))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color(hex: "1C1C3A")))
                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Copy paragraph")
        .accessibilityLabel("Copy paragraph")
    }
}

/// Right-to-left paragraph: SwiftUI `Text` cannot set a paragraph's base writing direction, so this is an
/// AppKit text field (CLAUDE.md, "RTL text in SwiftUI"). Selectable; wraps to the proposed width.
private struct ReaderRTLText: NSViewRepresentable {
    let text: String
    var size: CGFloat = 15

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
        style.lineSpacing = 9
        style.baseWritingDirection = .rightToLeft
        style.alignment = .right
        field.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
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
