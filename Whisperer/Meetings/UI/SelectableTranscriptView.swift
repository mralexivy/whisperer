//
//  SelectableTranscriptView.swift
//  Whisperer
//
//  One NSTextView holds every completed segment, so a drag selects across
//  segment boundaries natively. Card backgrounds and the timestamp gutter are
//  drawn by SwiftUI from the layout metrics reported here.
//
//  Search highlighting uses NSLayoutManager.addTemporaryAttributes — display-only,
//  no storage mutation, no relayout, selection is unaffected.  The query is NOT part
//  of contentSignature; highlight application is a post-build step driven by the
//  Coordinator's Combine subscription to TranscriptSearchModel.
//

import SwiftUI
import AppKit
import Combine

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

    /// Visual spacing between consecutive paragraphs *within* a single segment's card.
    /// Kept small so the break reads as structure, not as a card boundary.
    static let intraSegmentSpacing: CGFloat = 8
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
    /// The search model — held by reference, not observed by this struct. The Coordinator
    /// subscribes directly via Combine so highlights update without re-rendering the view.
    let search: TranscriptSearchModel
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
        coordinator.storage = storage
        coordinator.inset = TranscriptLayout.textInset

        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.frameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: textView
        )

        // Subscribe to search model so highlights stay in sync without re-rendering the view.
        coordinator.bindSearch(search)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        let coordinator = context.coordinator

        // Refresh publish closure so it always writes to current bindings.
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

        // Query is deliberately NOT part of the signature — highlights are applied as a
        // post-build step via temporary attributes, not by rebuilding storage.
        let signature = Self.contentSignature(segments: segments, isRTL: isRTL)
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

            // Feed updated text snapshot to the search model so scans stay current.
            let snapshot = textView.string
            Task { @MainActor in
                coordinator.searchModel?.ingest(text: snapshot)
            }
        }

        coordinator.recomputeMetrics()
    }

    static func dismantleNSView(_ textView: NSTextView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.searchCancellable = nil
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
            let previous = index > 0 ? segments[index - 1] : nil
            let startsTurn = previous.map {
                $0.speakerIndex != segment.speakerIndex || $0.speakerName != segment.speakerName
            } ?? true

            if startsTurn {
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
                speakerRanges.append(NSRange(location: NSNotFound, length: 0))
            }

            let bodyStart = result.length
            let isLastSegment = index == segments.count - 1
            let nonEmptyLines = segment.text.components(separatedBy: "\n").filter { !$0.isEmpty }
            if nonEmptyLines.isEmpty {
                let paraStyle = NSMutableParagraphStyle()
                paraStyle.lineSpacing = 5
                paraStyle.paragraphSpacingBefore = startsTurn ? 0 : TranscriptLayout.groupedSegmentSpacing
                paraStyle.baseWritingDirection = direction; paraStyle.alignment = alignment
                result.append(NSAttributedString(
                    string: isLastSegment ? "" : "\n",
                    attributes: [.font: bodyFont,
                                 .foregroundColor: NSColor.white.withAlphaComponent(0.88),
                                 .paragraphStyle: paraStyle]))
            } else {
                for (pIdx, para) in nonEmptyLines.enumerated() {
                    let isLastPara = pIdx == nonEmptyLines.count - 1
                    let lineText = (isLastPara && isLastSegment) ? para : para + "\n"
                    let paraStyle = NSMutableParagraphStyle()
                    paraStyle.lineSpacing = 5
                    paraStyle.paragraphSpacing = 0
                    paraStyle.paragraphSpacingBefore = pIdx == 0
                        ? (startsTurn ? 0 : TranscriptLayout.groupedSegmentSpacing)
                        : TranscriptLayout.intraSegmentSpacing
                    paraStyle.baseWritingDirection = direction; paraStyle.alignment = alignment
                    result.append(NSAttributedString(
                        string: lineText,
                        attributes: [.font: bodyFont,
                                     .foregroundColor: NSColor.white.withAlphaComponent(0.88),
                                     .paragraphStyle: paraStyle]))
                }
            }
            bodyRanges.append(NSRange(location: bodyStart, length: result.length - bodyStart))
        }

        // Highlights are NOT applied here — they are applied as temporary attributes by
        // the Coordinator after storage is set, so the query never invalidates layout.

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

    /// Segment content hash — deliberately excludes the search query so changing the query
    /// does not rebuild text storage or drop the user's selection.
    private static func contentSignature(segments: [MeetingSegment], isRTL: Bool) -> Int {
        var hasher = Hasher()
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
        var storage: NSTextStorage?
        var inset: NSSize = .zero
        var speakerRanges: [NSRange] = []
        var bodyRanges: [NSRange] = []
        var segmentIDs: [UUID] = []
        var signature: Int = 0
        var publish: (([SegmentMetrics], CGFloat) -> Void)?

        // Search
        weak var searchModel: TranscriptSearchModel?
        var searchCancellable: AnyCancellable?

        private var lastWidth: CGFloat = 0

        // MARK: Search subscription

        func bindSearch(_ model: TranscriptSearchModel) {
            searchModel = model
            // Subscribe to scanToken (new scan result) and currentIndex (navigation).
            // scanToken is only bumped by the scanner — never by report() — so this sink
            // does not feed back into the publisher and cannot form an infinite cycle.
            searchCancellable = Publishers.CombineLatest(model.$scanToken, model.$currentIndex)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _ in
                    self?.applySearchHighlights(model: model)
                }
        }

        func applySearchHighlights(model: TranscriptSearchModel) {
            guard let lm = layoutManager, let s = storage else { return }
            TranscriptSearch.applyHighlights(
                layoutManager: lm,
                storageLength: s.length,
                matches: model.matches,
                currentIndex: model.currentIndex
            )
            // Locate match Y positions after layout is up to date, then push geometry back.
            locateAndReport(model: model)
        }

        private func locateAndReport(model: TranscriptSearchModel) {
            guard let lm = layoutManager, let tv = textView else { return }
            lm.ensureLayout(for: lm.textContainers.first ?? NSTextContainer())
            let located = TranscriptSearch.locateMatches(
                model.matches,
                layoutManager: lm,
                textContainerInset: tv.textContainerInset)
            let totalHeight = max(
                (lm.usedRect(for: lm.textContainers.first ?? NSTextContainer()).height
                 + tv.textContainerInset.height * 2),
                40)
            model.report(located: located, contentHeight: totalHeight)
        }

        // MARK: Layout

        @objc func frameDidChange(_ notification: Notification) {
            guard let width = textView?.bounds.width, abs(width - lastWidth) > 0.5 else { return }
            lastWidth = width
            recomputeMetrics()
            if let m = searchModel { locateAndReport(model: m) }
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
