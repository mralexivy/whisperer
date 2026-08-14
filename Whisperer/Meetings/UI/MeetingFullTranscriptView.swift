//
//  MeetingFullTranscriptView.swift
//  Whisperer
//
//  The transcript as continuous prose — no speaker cards, no timestamp gutter.
//

import SwiftUI
import AppKit

/// Plain-prose rendering of a finished transcript, for reading it straight through or
/// selecting the lot.
///
/// A separate view from `MeetingTranscriptView` rather than a mode inside it: that view's
/// single `NSTextView` carries speaker ranges, `segmentMetrics` for the SwiftUI card and
/// gutter overlays, rename popovers, tag menus, chapter buckets and playhead sync — every
/// one of which is exactly what this mode exists to remove.
///
/// `NSTextView` and not SwiftUI `Text` for the two reasons that recur throughout this app:
/// selection across the whole document, and `baseWritingDirection`, which SwiftUI `Text`
/// cannot set (see the RTL notes in ARCHITECTURE.md).
struct MeetingFullTranscriptView: NSViewRepresentable {
    let text: String
    let isRTL: Bool

    private static let font = NSFont.systemFont(ofSize: 15, weight: .regular)
    private static let lineSpacing: CGFloat = 6
    private static let paragraphSpacing: CGFloat = 14
    private static let horizontalInset: CGFloat = 24
    private static let verticalInset: CGFloat = 20

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// Rebuilding the storage drops an in-progress selection, so the text is only
        /// re-rendered when it actually changed — the same rule `SelectableTranscriptView`
        /// follows. Without it, a playhead tick during playback makes selection impossible.
        var signature: String?
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.focusRingType = .none
        textView.textContainerInset = NSSize(width: Self.horizontalInset, height: Self.verticalInset)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(red: 0.357, green: 0.424, blue: 0.969, alpha: 0.35)
        ]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
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
    }

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
