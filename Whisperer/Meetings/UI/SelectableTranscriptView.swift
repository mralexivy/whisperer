//
//  SelectableTranscriptView.swift
//  Whisperer
//
//  One NSTextView holds every completed segment, so a drag selects across
//  segment boundaries natively. Card backgrounds and the timestamp gutter are
//  drawn by SwiftUI from the layout metrics reported here.
//

import SwiftUI
import AppKit

// MARK: - Shared layout constants

enum TranscriptLayout {
    static let outerMargin:  CGFloat = 8    // card edge → column edge
    static let timestampCol: CGFloat = 58   // reserved gutter width
    static let cardVPad:     CGFloat = 14   // card padding above/below body text
    static let innerHPad:    CGFloat = 16   // body text padding inside the card
    static let cardRadius:   CGFloat = 12

    static let speakerToCardGap: CGFloat = 8    // speaker name baseline box → card top
    static let cardToSpeakerGap: CGFloat = 22   // card bottom → next speaker name
    static let groupedCardGap:   CGFloat = 8    // card bottom → next card of the SAME speaker

    /// Text sits `innerHPad` inside a card that is itself `outerMargin` inside the view.
    static var textInset: NSSize { NSSize(width: outerMargin + innerHPad, height: 16) }

    /// Paragraph spacing after the speaker line, so the card top clears the name by `speakerToCardGap`.
    static var speakerParagraphSpacing: CGFloat { cardVPad + speakerToCardGap }

    /// Paragraph spacing before a speaker line, so the name clears the previous card.
    static var interSegmentSpacing: CGFloat { cardVPad + cardToSpeakerGap }

    /// Paragraph spacing before a body paragraph that has no speaker line of its own —
    /// covers both cards' vertical padding plus the gap between them.
    static var groupedSegmentSpacing: CGFloat { cardVPad * 2 + groupedCardGap }
}

// MARK: - Per-segment layout metrics reported to SwiftUI

struct SegmentMetrics: Equatable, Identifiable {
    let id: UUID
    let speakerY: CGFloat       // top of the speaker-name line, in NSTextView coords
    let speakerHeight: CGFloat
    let cardTop: CGFloat        // top edge of the card behind the body text
    let cardHeight: CGFloat

    var cardBottom: CGFloat { cardTop + cardHeight }
}

// MARK: - NSViewRepresentable wrapper

struct SelectableTranscriptView: NSViewRepresentable {
    let segments: [MeetingSegment]
    let searchQuery: String
    let isRTL: Bool
    @Binding var contentHeight: CGFloat
    @Binding var segmentMetrics: [SegmentMetrics]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let layoutManager = NSLayoutManager()
        let storage = NSTextStorage()
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.focusRingType = NSFocusRingType.none
        textView.textContainerInset = TranscriptLayout.textInset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = NSView.AutoresizingMask.width
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.selectedTextAttributes = [
            NSAttributedString.Key.backgroundColor: NSColor(red: 0.357, green: 0.424, blue: 0.969, alpha: 0.35)
        ]
        // Metrics must be recomputed whenever the column width changes, otherwise the
        // SwiftUI card and timestamp overlays keep stale Y positions from the old wrap.
        textView.postsFrameChangedNotifications = true

        let coordinator = context.coordinator
        coordinator.textView = textView
        coordinator.layoutManager = layoutManager
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.frameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        let coordinator = context.coordinator

        // Refresh the publish closure so it always writes to the current bindings.
        let heightBinding = $contentHeight
        let metricsBinding = $segmentMetrics
        coordinator.publish = { metrics, height in
            DispatchQueue.main.async {
                if abs(heightBinding.wrappedValue - height) > 0.5 {
                    heightBinding.wrappedValue = height
                }
                if metrics != metricsBinding.wrappedValue {
                    metricsBinding.wrappedValue = metrics
                }
            }
        }

        // Rebuilding the text storage clears an in-progress selection, so only do it when
        // the content genuinely changed. Playhead ticks and metric write-backs must not
        // reach this path or selection becomes impossible during playback.
        let signature = Self.contentSignature(segments: segments, query: searchQuery, isRTL: isRTL)
        if signature != coordinator.signature {
            coordinator.signature = signature

            let built = buildAttributedString()
            coordinator.speakerRanges = built.speakerRanges
            coordinator.bodyRanges = built.bodyRanges
            coordinator.segmentIDs = segments.map(\.id)

            let previousSelection = textView.selectedRange()
            textView.textStorage?.setAttributedString(built.string)
            let length = textView.textStorage?.length ?? 0
            if previousSelection.length > 0,
               previousSelection.location + previousSelection.length <= length {
                textView.setSelectedRange(previousSelection)
            }
        }

        coordinator.recomputeMetrics()
    }

    static func dismantleNSView(_ textView: NSTextView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: - Attributed string builder

    private struct BuiltText {
        let string: NSAttributedString
        let speakerRanges: [NSRange]
        let bodyRanges: [NSRange]
    }

    private func buildAttributedString() -> BuiltText {
        let result = NSMutableAttributedString()
        var speakerRanges: [NSRange] = []
        var bodyRanges: [NSRange] = []

        let bodyFont = NSFont.systemFont(ofSize: 14, weight: .regular)
        let speakerFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let direction: NSWritingDirection = isRTL ? .rightToLeft : .leftToRight
        let alignment: NSTextAlignment = isRTL ? .right : .left

        for (index, segment) in segments.enumerated() {
            // A run of consecutive segments from one speaker is a single turn: only the
            // first card carries the name, the rest stack tightly underneath it.
            let previous = index > 0 ? segments[index - 1] : nil
            let startsTurn = previous.map {
                $0.speakerIndex != segment.speakerIndex || $0.speakerName != segment.speakerName
            } ?? true

            if startsTurn {
                // Speaker name — its own paragraph so it sits above the card.
                let speakerStart = result.length
                let speakerStyle = NSMutableParagraphStyle()
                speakerStyle.paragraphSpacingBefore = index == 0 ? 0 : TranscriptLayout.interSegmentSpacing
                speakerStyle.paragraphSpacing = TranscriptLayout.speakerParagraphSpacing
                speakerStyle.baseWritingDirection = direction
                speakerStyle.alignment = alignment
                result.append(NSAttributedString(string: segment.speakerName + "\n", attributes: [
                    .font: speakerFont,
                    .foregroundColor: speakerNSColor(for: segment.speakerIndex),
                    .paragraphStyle: speakerStyle
                ]))
                speakerRanges.append(NSRange(location: speakerStart, length: result.length - speakerStart))
            } else {
                // Kept parallel with `segments` — NSNotFound means "no speaker line".
                speakerRanges.append(NSRange(location: NSNotFound, length: 0))
            }

            // Body text — the region the card is drawn behind.
            let bodyStart = result.length
            let bodyStyle = NSMutableParagraphStyle()
            bodyStyle.lineSpacing = 5
            bodyStyle.paragraphSpacing = 0
            // Without a speaker line above it the body paragraph has to open the gap itself.
            bodyStyle.paragraphSpacingBefore = startsTurn ? 0 : TranscriptLayout.groupedSegmentSpacing
            bodyStyle.baseWritingDirection = direction
            bodyStyle.alignment = alignment
            let bodyText = segment.text + (index < segments.count - 1 ? "\n" : "")
            result.append(NSAttributedString(string: bodyText, attributes: [
                .font: bodyFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.88),
                .paragraphStyle: bodyStyle
            ]))
            bodyRanges.append(NSRange(location: bodyStart, length: result.length - bodyStart))
        }

        if !searchQuery.isEmpty {
            let plain = result.string
            var cursor = plain.startIndex
            while cursor < plain.endIndex,
                  let match = plain.range(of: searchQuery, options: .caseInsensitive, range: cursor..<plain.endIndex) {
                result.addAttribute(
                    .backgroundColor,
                    value: NSColor(red: 0.357, green: 0.424, blue: 0.969, alpha: 0.35),
                    range: NSRange(match, in: plain)
                )
                cursor = match.upperBound
            }
        }

        return BuiltText(string: result, speakerRanges: speakerRanges, bodyRanges: bodyRanges)
    }

    private func speakerNSColor(for index: Int) -> NSColor {
        let palette = ["5B6CF7", "F59E0B", "10B981", "EC4899", "8B5CF6", "06B6D4", "EF4444", "84CC16"]
        let hex = palette[abs(index) % palette.count]
        guard let value = UInt64(hex, radix: 16) else { return .white }
        return NSColor(
            red:   CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8)  & 0xFF) / 255,
            blue:  CGFloat( value        & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func contentSignature(segments: [MeetingSegment], query: String, isRTL: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(query)
        hasher.combine(isRTL)
        hasher.combine(segments.count)
        for segment in segments {
            hasher.combine(segment.id)
            hasher.combine(segment.text)
            hasher.combine(segment.speakerName)
            hasher.combine(segment.speakerIndex)
        }
        return hasher.finalize()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        weak var textView: NSTextView?
        var layoutManager: NSLayoutManager?
        var speakerRanges: [NSRange] = []
        var bodyRanges: [NSRange] = []
        var segmentIDs: [UUID] = []
        var signature: Int = 0
        var publish: (([SegmentMetrics], CGFloat) -> Void)?

        private var lastWidth: CGFloat = 0

        @objc func frameDidChange(_ notification: Notification) {
            guard let width = textView?.bounds.width, abs(width - lastWidth) > 0.5 else { return }
            lastWidth = width
            recomputeMetrics()
        }

        func recomputeMetrics() {
            guard let textView,
                  let layoutManager,
                  let container = textView.textContainer,
                  textView.bounds.width > 1 else { return }

            layoutManager.ensureLayout(for: container)
            lastWidth = textView.bounds.width

            let insetY = textView.textContainerInset.height
            let totalHeight = max(layoutManager.usedRect(for: container).height + insetY * 2, 40)

            var metrics: [SegmentMetrics] = []
            for (index, id) in segmentIDs.enumerated() {
                guard index < speakerRanges.count, index < bodyRanges.count,
                      let body = lineBounds(layoutManager, bodyRanges[index]) else { continue }

                let speakerRange = speakerRanges[index]
                let speaker = speakerRange.location == NSNotFound
                    ? nil
                    : lineBounds(layoutManager, speakerRange)
                let cardTop = insetY + body.minY - TranscriptLayout.cardVPad

                // Continuation cards have no speaker line, so the accessory row and the
                // hover region anchor to the card's own top edge instead.
                metrics.append(SegmentMetrics(
                    id: id,
                    speakerY: speaker.map { insetY + $0.minY } ?? cardTop - 1,
                    speakerHeight: speaker.map { $0.maxY - $0.minY } ?? 0,
                    cardTop: cardTop,
                    cardHeight: (body.maxY - body.minY) + TranscriptLayout.cardVPad * 2
                ))
            }
            publish?(metrics, totalHeight)
        }

        /// Union of the used (glyph-tight) rects for every line fragment in `charRange`.
        private func lineBounds(_ layoutManager: NSLayoutManager, _ charRange: NSRange) -> (minY: CGFloat, maxY: CGFloat)? {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return nil }
            var minY = CGFloat.greatestFiniteMagnitude
            var maxY: CGFloat = 0
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, used, _, _, _ in
                minY = min(minY, used.minY)
                maxY = max(maxY, used.maxY)
            }
            guard maxY > minY else { return nil }
            return (minY, maxY)
        }
    }
}
