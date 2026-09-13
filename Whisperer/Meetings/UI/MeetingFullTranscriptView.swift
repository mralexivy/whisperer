//
//  MeetingFullTranscriptView.swift
//  Whisperer
//
//  The transcript as continuous prose — no speaker cards, no timestamp gutter.
//
//  Uses an explicit TextKit 1 stack (NSTextStorage / NSLayoutManager / NSTextContainer)
//  so temporary attributes work for search highlighting without mutating storage.
//

import SwiftUI
import AppKit
import Combine

/// Plain-prose rendering of a finished transcript, for reading it straight through or
/// selecting the lot.
///
/// A separate view from `MeetingTranscriptView` rather than a mode inside it: that view's
/// single `NSTextView` carries speaker ranges, `segmentMetrics` for the SwiftUI card and
/// gutter overlays, rename popovers, tag menus, chapter buckets and playhead sync — every
/// one of which is exactly what this mode exists to remove.
///
/// TextKit 1 stack rather than bare `NSTextView()` so `addTemporaryAttributes` works for
/// search highlighting without mutating the text storage or invalidating layout.
struct MeetingFullTranscriptView: NSViewRepresentable {
    let text: String
    let isRTL: Bool
    /// The shared search model — held by reference, not observed by this struct. The
    /// Coordinator subscribes via Combine so highlights update without triggering a
    /// storage rebuild or losing the user's selection.
    let search: TranscriptSearchModel

    private static let font = NSFont.systemFont(ofSize: 15, weight: .regular)
    private static let lineSpacing: CGFloat = 6
    private static let paragraphSpacing: CGFloat = 14
    private static let horizontalInset: CGFloat = 24
    private static let verticalInset: CGFloat = 20

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: -

    final class Coordinator {
        /// Rebuilding the storage drops an in-progress selection, so the text is only
        /// re-rendered when it actually changed — the same rule `SelectableTranscriptView`
        /// follows.
        var signature: String?
        weak var textView: NSTextView?
        var layoutManager: NSLayoutManager?
        var storage: NSTextStorage?
        weak var searchModel: TranscriptSearchModel?
        var searchCancellable: AnyCancellable?

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
            guard let lm = layoutManager, let s = storage, let tv = textView else { return }
            TranscriptSearch.applyHighlights(
                layoutManager: lm,
                storageLength: s.length,
                matches: model.matches,
                currentIndex: model.currentIndex)

            // Scroll to and pulse-highlight the current match using the system find indicator.
            if let idx = model.currentIndex, idx < model.matches.count {
                let range = model.matches[idx].range
                guard range.upperBound <= s.length else { return }
                tv.scrollRangeToVisible(range)
                tv.showFindIndicator(for: range)
            }

            // Report located geometry so the tick gutter has Y positions.
            locateAndReport(model: model, textView: tv, layoutManager: lm)
        }

        private func locateAndReport(
            model: TranscriptSearchModel,
            textView: NSTextView,
            layoutManager: NSLayoutManager
        ) {
            guard let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let located = TranscriptSearch.locateMatches(
                model.matches,
                layoutManager: layoutManager,
                textContainerInset: textView.textContainerInset)
            let usedHeight = layoutManager.usedRect(for: container).height
            let totalHeight = max(usedHeight + textView.textContainerInset.height * 2, 40)
            model.report(located: located, contentHeight: totalHeight)
        }
    }

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        // Explicit TextKit 1 stack — required for addTemporaryAttributes
        let layoutManager = NSLayoutManager()
        let storage = NSTextStorage()
        let container = NSTextContainer(containerSize: NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.focusRingType = .none
        textView.textContainerInset = NSSize(
            width: Self.horizontalInset, height: Self.verticalInset)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(red: 0.357, green: 0.424, blue: 0.969, alpha: 0.35)
        ]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        context.coordinator.textView = textView
        context.coordinator.layoutManager = layoutManager
        context.coordinator.storage = storage
        context.coordinator.bindSearch(search)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let signature = "\(isRTL)|\(text)"
        guard signature != context.coordinator.signature else { return }
        context.coordinator.signature = signature

        let previousSelection = textView.selectedRange()
        textView.textStorage?.setAttributedString(attributedProse())
        if previousSelection.upperBound <= (textView.string as NSString).length {
            textView.setSelectedRange(previousSelection)
        }

        // Feed updated text to the search model so scans stay current without reading
        // the view per keystroke.
        let snapshot = textView.string
        Task { @MainActor in
            context.coordinator.searchModel?.ingest(text: snapshot)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.searchCancellable = nil
    }

    // MARK: - Prose builder

    private func attributedProse() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Self.lineSpacing
        paragraph.paragraphSpacing = Self.paragraphSpacing
        paragraph.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
        paragraph.alignment = isRTL ? .right : .left

        return NSAttributedString(string: text, attributes: [
            .font: Self.font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .paragraphStyle: paragraph
        ])
    }
}
