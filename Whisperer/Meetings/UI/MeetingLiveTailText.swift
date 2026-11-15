//
//  MeetingLiveTailText.swift
//  Whisperer
//
//  The words of a meeting still being spoken — the open paragraph plus what Apple dictation is
//  hearing now.
//
//  Drawn exactly like a committed card: the same text view, the same font and spacing, no animation.
//
//  It used to pour the words one at a time on a timer, each in its own animated view (a dictation-HUD
//  effect). On a meeting that meant every poured word re-published the word list and SwiftUI re-evaluated
//  one view per word of the paragraph, ten to thirty times a second for as long as the meeting ran —
//  a constant drain on a Mac that was otherwise only listening — and when the paragraph was committed
//  into a card the text changed renderer and visibly jumped. A meeting is read, not watched arriving:
//  a single text view updated when the text changes costs one layout per update (≈3 a second) and
//  has nothing to jump to when the paragraph closes (2026-11-15).
//

import SwiftUI

struct MeetingLiveTailText: View {
    let text: String
    let isRTL: Bool
    var fontSize: CGFloat = 14

    var body: some View {
        let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isRTL {
            MeetingSegmentTextView(text: shown, highlightQuery: "", isRTL: true, fontSize: fontSize)
        } else {
            Text(shown)
                .font(.system(size: fontSize, weight: .regular))
                .foregroundColor(.white.opacity(0.88))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
