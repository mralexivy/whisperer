//
//  MeetingTranscriptView.swift
//  Whisperer
//
//  Transcript for both post-recording and live recording views.
//
//  Layout:
//    - Speaker label: OUTSIDE and ABOVE the card, in the speaker's accent color
//    - Card: rounded navy box behind the body text, with a speaker-colored leading edge
//    - Timestamps: OUTSIDE the card in a fixed gutter — start pinned to the card's top
//      edge, end pinned to the card's bottom edge, so the pair spans the segment
//
//  All completed segments live in one NSTextView (SelectableTranscriptView) so a drag
//  selects across segment boundaries. Cards and timestamps are SwiftUI overlays placed
//  from the Y metrics that view reports after each layout pass.
//

import SwiftUI
import AppKit

private let outerMargin  = TranscriptLayout.outerMargin
private let timestampCol = TranscriptLayout.timestampCol
private let cardVPad     = TranscriptLayout.cardVPad
private let innerHPad    = TranscriptLayout.innerHPad
private let cardRadius   = TranscriptLayout.cardRadius

struct MeetingTranscriptView: View {
    let meeting: MeetingRecord?
    @ObservedObject var session: MeetingSession
    let segments: [MeetingSegment]
    let isLoadingSegments: Bool
    let hasMoreSegments: Bool
    var onLoadMoreSegments: () -> Void
    var searchQuery: String
    var playheadSeconds: Double
    var onSpeakerRenamed: ((UUID, String) -> Void)?
    var onTagToggled: ((UUID, SegmentTag) -> Void)?

    @State private var transcriptHeight: CGFloat = 100
    @State private var segmentMetrics: [SegmentMetrics] = []
    @State private var hoveredSegmentID: UUID?
    @State private var renamingSegmentID: UUID?
    @State private var renameDraft = ""

    private var isLive: Bool {
        session.isRecording && session.meetingID == meeting?.id
    }

    private var isRTL: Bool {
        let sample = segments.prefix(3).map(\.text).joined()
        if !sample.isEmpty { return Self.detectRTL(in: String(sample.prefix(150))) }
        if let lang = TranscriptionLanguage(rawValue: meeting?.language ?? ""), lang != .auto {
            return lang.isRTL
        }
        return false
    }

    private var segmentByID: [UUID: MeetingSegment] {
        Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Segment the playhead currently sits inside, used for the active card accent.
    private var activeSegmentID: UUID? {
        guard playheadSeconds > 0 else { return nil }
        return segments.last {
            $0.timestamp <= playheadSeconds && playheadSeconds <= $0.endTimestamp + 0.5
        }?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if isLoadingSegments && segments.isEmpty {
                        ForEach(0..<5, id: \.self) { MeetingSegmentSkeleton(seed: $0) }
                            .transition(.opacity)

                    } else if segments.isEmpty && session.currentSegmentText.isEmpty && session.livePreviewText.isEmpty {
                        emptyState

                    } else if !segments.isEmpty {
                        completedSegmentsView
                    }

                    if isLive && (!session.currentSegmentText.isEmpty || !session.livePreviewText.isEmpty) {
                        liveSegmentBubble
                            .id("livePreview")
                    }

                    if hasMoreSegments {
                        Color.clear.frame(height: 1)
                            .id("transcript-more-sentinel")
                            .onAppear { onLoadMoreSegments() }
                    }
                }
                .padding(.vertical, 10)
            }
            .onChange(of: segments.count)             { _, _ in scrollToLive(proxy) }
            .onChange(of: transcriptHeight)           { _, _ in scrollToLive(proxy) }
            .onChange(of: session.livePreviewText)    { _, _ in scrollToLive(proxy) }
            .onChange(of: session.currentSegmentText) { _, _ in scrollToLive(proxy) }
        }
    }

    // MARK: - Completed segments

    private var completedSegmentsView: some View {
        // The ZStack is inset by `timestampCol` so the NSTextView, the cards and the
        // gutter all measure from the same origin.
        ZStack(alignment: .topLeading) {
            // Anchor the stack to the full content height. Without this the ZStack
            // collapses to its tallest child and .frame(height:) centres everything.
            Color.clear.frame(height: transcriptHeight)

            ForEach(segmentMetrics) { info in
                card(for: info)
            }

            SelectableTranscriptView(
                segments: segments,
                searchQuery: searchQuery,
                isRTL: isRTL,
                contentHeight: $transcriptHeight,
                segmentMetrics: $segmentMetrics
            )
            .frame(height: transcriptHeight)

            ForEach(segmentMetrics) { info in
                segmentAccessories(for: info)
            }
        }
        .frame(height: transcriptHeight, alignment: .top)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hoveredSegmentID = segmentMetrics.first {
                    point.y >= $0.speakerY - 4 && point.y <= $0.cardBottom
                }?.id
            case .ended:
                hoveredSegmentID = nil
            }
        }
        .padding(isRTL ? .leading : .trailing, timestampCol)
        .overlay(alignment: isRTL ? .topLeading : .topTrailing) { timestampGutter }
        .id("transcriptBody")
    }

    private func card(for info: SegmentMetrics) -> some View {
        let accent = speakerColor(for: segmentByID[info.id]?.speakerIndex ?? 0)
        let isActive = activeSegmentID == info.id

        return RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
            .fill(Color(hex: "14142B"))
            .overlay(alignment: isRTL ? .trailing : .leading) {
                Rectangle()
                    .fill(accent.opacity(isActive ? 0.9 : 0.32))
                    .frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .strokeBorder(
                        isActive ? accent.opacity(0.30) : Color.white.opacity(0.06),
                        lineWidth: 1
                    )
            }
            .frame(height: info.cardHeight)
            .padding(.horizontal, outerMargin)
            .offset(y: info.cardTop)
            .allowsHitTesting(false)
    }

    /// Tag chips (always) and hover actions (rename / copy / tag), on the speaker line.
    @ViewBuilder
    private func segmentAccessories(for info: SegmentMetrics) -> some View {
        if let segment = segmentByID[info.id] {
            let showActions = hoveredSegmentID == info.id || renamingSegmentID == info.id
            if showActions || !segment.tags.isEmpty {
                HStack(spacing: 6) {
                    if showActions { hoverActions(for: segment) }
                    ForEach(segment.tags, id: \.self) { tagChip($0) }
                }
                .padding(.horizontal, outerMargin + 6)
                .frame(maxWidth: .infinity, alignment: isRTL ? .leading : .trailing)
                .offset(y: info.speakerY - 3)
            }
        }
    }

    private func hoverActions(for segment: MeetingSegment) -> some View {
        HStack(spacing: 6) {
            iconButton("pencil") {
                renameDraft = segment.speakerName
                renamingSegmentID = segment.id
            }
            .popover(isPresented: Binding(
                get: { renamingSegmentID == segment.id },
                set: { if !$0 { renamingSegmentID = nil } }
            )) {
                renamePopover(for: segment)
            }

            iconButton("doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(segment.text, forType: .string)
            }

            Menu {
                ForEach(SegmentTag.allCases, id: \.self) { tag in
                    Button {
                        onTagToggled?(segment.id, tag)
                    } label: {
                        Label(tag.rawValue, systemImage: segment.tags.contains(tag) ? "checkmark" : "tag")
                    }
                }
            } label: {
                Image(systemName: "tag")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 22, height: 20)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22, height: 20)
        }
    }

    private func renamePopover(for segment: MeetingSegment) -> some View {
        HStack(spacing: 8) {
            TextField("Speaker name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .onSubmit { commitRename(for: segment) }
            Button("Save") { commitRename(for: segment) }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func commitRename(for segment: MeetingSegment) {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingSegmentID = nil
        guard !name.isEmpty, name != segment.speakerName else { return }
        onSpeakerRenamed?(segment.id, name)
    }

    private func iconButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 22, height: 20)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private func tagChip(_ tag: SegmentTag) -> some View {
        Text(tag.rawValue)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.3)
            .foregroundColor(Color(hex: tag.color))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(hex: tag.color).opacity(0.12), in: Capsule())
    }

    // MARK: - Timestamp gutter
    //
    // Start time sits on the card's top edge, end time on its bottom edge, so the
    // pair brackets the segment. Both are outside the card.

    private var timestampGutter: some View {
        ZStack(alignment: isRTL ? .topLeading : .topTrailing) {
            // Full-height anchor — otherwise the ZStack shrinks to one label and
            // .frame(height:) centres every timestamp far below its card.
            Color.clear.frame(width: timestampCol, height: transcriptHeight)

            ForEach(segmentMetrics) { info in
                if let segment = segmentByID[info.id] {
                    let isActive = activeSegmentID == info.id
                    let accent = speakerColor(for: segment.speakerIndex)

                    stampLabel(
                        formatTimestamp(segment.timestamp),
                        size: 11,
                        color: isActive ? accent : .white.opacity(0.38)
                    )
                    .offset(y: info.cardTop + 6)

                    // Below 40pt the two 14pt labels (6pt inset each) would collide.
                    if info.cardHeight >= 42 {
                        stampLabel(
                            formatTimestamp(segment.endTimestamp),
                            size: 10,
                            color: isActive ? accent.opacity(0.55) : .white.opacity(0.2)
                        )
                        .offset(y: info.cardBottom - 20)
                    }
                }
            }
        }
        .frame(width: timestampCol, height: transcriptHeight, alignment: .top)
        .allowsHitTesting(false)
    }

    private func stampLabel(_ text: String, size: CGFloat, color: Color) -> some View {
        Text(text)
            .font(.system(size: size, weight: .medium).monospacedDigit())
            .foregroundColor(color)
            .frame(width: timestampCol - 10, height: 14, alignment: isRTL ? .leading : .trailing)
    }

    // MARK: - Live bubble (same card style, no timestamps yet)

    private var liveSegmentBubble: some View {
        VStack(alignment: isRTL ? .trailing : .leading, spacing: TranscriptLayout.speakerToCardGap) {
            Text("Speaker 1")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "5B6CF7"))
                .padding(isRTL ? .trailing : .leading, outerMargin + innerHPad)
                .padding(isRTL ? .leading : .trailing, outerMargin + timestampCol + innerHPad)

            Text(combinedSegmentText)
                .font(.system(size: 14, weight: .regular))
                .lineSpacing(5)
                .multilineTextAlignment(isRTL ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)
                .padding(.horizontal, innerHPad)
                .padding(.vertical, cardVPad)
                .background {
                    RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                        .fill(Color(hex: "14142B"))
                        .overlay(alignment: isRTL ? .trailing : .leading) {
                            Rectangle()
                                .fill(Color(hex: "5B6CF7").opacity(0.32))
                                .frame(width: 3)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                        }
                }
                .padding(.leading, isRTL ? outerMargin + timestampCol : outerMargin)
                .padding(.trailing, isRTL ? outerMargin : outerMargin + timestampCol)
        }
        .padding(.top, TranscriptLayout.cardToSpeakerGap)
    }

    private var combinedSegmentText: AttributedString {
        var result = AttributedString()
        if !session.currentSegmentText.isEmpty {
            var committed = AttributedString(session.currentSegmentText)
            committed.foregroundColor = .white.opacity(0.88)
            result += committed
        }
        if !session.livePreviewText.isEmpty {
            if !result.characters.isEmpty {
                var spacer = AttributedString(" ")
                spacer.foregroundColor = .white.opacity(0.4)
                result += spacer
            }
            var live = AttributedString(session.livePreviewText)
            live.foregroundColor = .white.opacity(0.4)
            result += live
        }
        return result
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.white.opacity(0.15))
            Text("No transcript yet")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.3))
            if !session.isRecording {
                Text("Start recording to capture the conversation")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.2))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Helpers

    private func scrollToLive(_ proxy: ScrollViewProxy) {
        guard isLive else { return }
        withAnimation { proxy.scrollTo("livePreview", anchor: .bottom) }
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    private static func detectRTL(in text: String) -> Bool {
        var rtl = 0, letters = 0
        for scalar in text.prefix(50).unicodeScalars {
            let v = scalar.value
            if scalar.properties.isAlphabetic { letters += 1 }
            if (v >= 0x0590 && v <= 0x05FF) || (v >= 0x0600 && v <= 0x06FF) ||
               (v >= 0x0700 && v <= 0x074F) || (v >= 0xFB50 && v <= 0xFDFF) ||
               (v >= 0xFE70 && v <= 0xFEFF) { rtl += 1 }
        }
        return letters > 0 && Double(rtl) / Double(letters) > 0.3
    }
}

// MARK: - Blinking caret

struct BlinkingCaret: View {
    @State private var visible = true
    var body: some View {
        Rectangle()
            .fill(Color(hex: "5B6CF7"))
            .frame(width: 2, height: 16)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}
