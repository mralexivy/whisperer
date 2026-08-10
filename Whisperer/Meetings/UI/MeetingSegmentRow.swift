//
//  MeetingSegmentRow.swift
//  Whisperer
//
//  Single transcript segment with inline speaker editing and tag chips.
//

import SwiftUI
import AppKit

// Speaker color palette — 8 colors cycling by speakerIndex
private let speakerColors: [Color] = [
    Color(hex: "5B6CF7"),
    Color(hex: "F59E0B"),
    Color(hex: "10B981"),
    Color(hex: "EC4899"),
    Color(hex: "8B5CF6"),
    Color(hex: "06B6D4"),
    Color(hex: "EF4444"),
    Color(hex: "84CC16"),
]

func speakerColor(for index: Int) -> Color {
    speakerColors[abs(index) % speakerColors.count]
}

// MARK: - Row

struct MeetingSegmentRow: View {
    let segment: MeetingSegment
    let isActive: Bool          // playback cursor inside this segment's range
    let searchQuery: String
    var isRTL: Bool = false
    var isLive: Bool = false    // hides speaker header during recording
    var onSpeakerRenamed: ((String) -> Void)?
    var onTagToggled: ((SegmentTag) -> Void)?

    @State private var isHovered = false
    @State private var isEditingSpeaker = false
    @State private var speakerDraft = ""
    @FocusState private var speakerFocused: Bool

    private var color: Color { speakerColor(for: segment.speakerIndex) }

    private var timestampColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: isRTL ? .leading : .trailing, spacing: 2) {
                Text(formatTimestamp(segment.timestamp))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(isActive ? color : .white.opacity(0.3))
                Text(formatTimestamp(segment.endTimestamp))
                    .font(.system(size: 10, weight: .regular).monospacedDigit())
                    .foregroundColor(isActive ? color.opacity(0.5) : .white.opacity(0.15))
            }
            .frame(width: 48, alignment: isRTL ? .leading : .trailing)
            .padding(.top, 2)

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 2)
                .padding(.top, 4)
                .padding(isRTL ? .trailing : .leading, 46)
        }
        .frame(width: 58)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if !isRTL { timestampColumn }

            // Content
            VStack(alignment: isRTL ? .trailing : .leading, spacing: 6) {
                // Speaker row — hidden during live recording
                if !isLive { HStack(spacing: 8) {
                    if isRTL { Spacer() }

                    if isHovered && !isEditingSpeaker && isRTL {
                        hoverActions
                    }

                    // Tag chips (reversed order for RTL so they sit left of name)
                    if isRTL {
                        ForEach(segment.tags, id: \.self) { tag in
                            segmentTagChip(tag)
                        }
                    }

                    if isEditingSpeaker {
                        TextField("Speaker name", text: $speakerDraft)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(color)
                            .textFieldStyle(.plain)
                            .focused($speakerFocused)
                            .onSubmit { commitSpeakerEdit() }
                            .onExitCommand { isEditingSpeaker = false }
                    } else {
                        Text(segment.speakerName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(color)
                            .onTapGesture {
                                speakerDraft = segment.speakerName
                                isEditingSpeaker = true
                                speakerFocused = true
                            }
                    }

                    speakerAvatar

                    if !isRTL {
                        // Tag chips
                        ForEach(segment.tags, id: \.self) { tag in
                            segmentTagChip(tag)
                        }

                        Spacer()

                        // Hover actions
                        if isHovered && !isEditingSpeaker {
                            hoverActions
                        }
                    }
                } }

                // Text — NSTextField for RTL to get proper paragraph base writing direction
                if isRTL {
                    MeetingSegmentTextView(text: segment.text, highlightQuery: searchQuery, isRTL: true)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(highlightedText(segment.text, query: searchQuery))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.white.opacity(0.85))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, isRTL ? 12 : 12)
            .padding(.trailing, 12)
            .padding(.vertical, 10)

            if isRTL { timestampColumn }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.white.opacity(0.04) : Color.clear)
        )
        .overlay(alignment: isRTL ? .trailing : .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 3)
                    .padding(isRTL ? .trailing : .leading, 56)
                    .frame(maxHeight: .infinity)
            }
        }
        .onHover { isHovered = $0 }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
    }

    // MARK: - Sub-views

    private var speakerAvatar: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.2))
                .overlay(
                    Circle().stroke(isActive ? color : Color.clear, lineWidth: 2)
                )
                .frame(width: 26, height: 26)
            Text(String(segment.speakerName.prefix(1)))
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(color)
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 6) {
            hoverButton("doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(segment.text, forType: .string)
            }
            Menu {
                ForEach(SegmentTag.allCases, id: \.self) { tag in
                    Button {
                        onTagToggled?(tag)
                    } label: {
                        Label(tag.rawValue, systemImage: segment.tags.contains(tag) ? "checkmark" : "tag")
                    }
                }
            } label: {
                Image(systemName: "tag")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 24, height: 22)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
    }

    private func hoverButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 24, height: 22)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private func segmentTagChip(_ tag: SegmentTag) -> some View {
        Text(tag.rawValue)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.3)
            .foregroundColor(Color(hex: tag.color))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(hex: tag.color).opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Helpers

    private func commitSpeakerEdit() {
        let name = speakerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingSpeaker = false
        guard !name.isEmpty, name != segment.speakerName else { return }
        onSpeakerRenamed?(name)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func highlightedText(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty,
              let range = attributed.range(of: query, options: .caseInsensitive) else {
            return attributed
        }
        attributed[range].backgroundColor = Color(hex: "5B6CF7").opacity(0.3)
        return attributed
    }
}

// MARK: - RTL-aware segment text (NSTextField for proper paragraph base writing direction)

struct MeetingSegmentTextView: NSViewRepresentable {
    let text: String
    let highlightQuery: String
    let isRTL: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.isBordered = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.cell?.truncatesLastVisibleLine = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let c = context.coordinator
        guard text != c.lastText || highlightQuery != c.lastQuery || isRTL != c.lastIsRTL else { return }
        c.lastText = text
        c.lastQuery = highlightQuery
        c.lastIsRTL = isRTL

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
        style.alignment = isRTL ? .right : .left

        let font = NSFont.systemFont(ofSize: 14, weight: .regular)
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .paragraphStyle: style
        ]

        let attributed = NSMutableAttributedString(string: text, attributes: baseAttrs)

        if !highlightQuery.isEmpty,
           let range = text.range(of: highlightQuery, options: .caseInsensitive) {
            let nsRange = NSRange(range, in: text)
            attributed.addAttribute(.backgroundColor,
                                    value: NSColor(red: 0.357, green: 0.424, blue: 0.969, alpha: 0.3),
                                    range: nsRange)
        }

        field.attributedStringValue = attributed
    }

    final class Coordinator {
        var lastText: String = ""
        var lastQuery: String = ""
        var lastIsRTL: Bool = false
    }
}
