//
//  MeetingLiveTailText.swift
//  Whisperer
//
//  The words of a meeting still being spoken — the open paragraph plus what Apple dictation is
//  hearing now — rendered like dictation in the HUD: words arrive one at a time, paced to the
//  speech, and nothing already on screen moves.
//

import SwiftUI

/// Shared by the meeting live window and the Workspace transcript, so both read the same.
///
/// Before, the live window re-created its pour for every committed paragraph (every word still
/// on screen was typed again — text that jumped back), showed Hebrew a whole batch at a time, and
/// Workspace printed the raw text with no pacing at all (2026-11-09). `setSlidingTarget` keeps the
/// words already shown when the paragraph's front is committed into a card, and `pacesRTL` pours
/// right-to-left text word by word too.
struct MeetingLiveTailText: View {
    let text: String
    let isRTL: Bool
    var fontSize: CGFloat = 14

    @StateObject private var updater = SmoothTextUpdater.forMeetingLiveText()

    var body: some View {
        Group {
            if isRTL {
                MeetingSegmentTextView(text: updater.displayedText, highlightQuery: "", isRTL: true)
            } else {
                DictationStreamView(words: updater.words, isStreaming: updater.isActive, scale: 1,
                                    fontSize: fontSize, fontDesign: .default, placeholder: nil)
            }
        }
        .onAppear { updater.setSlidingTarget(text, rtl: isRTL) }
        .onChange(of: text) { _, newValue in updater.setSlidingTarget(newValue, rtl: isRTL) }
        .onDisappear { updater.stop() }
    }
}

extension SmoothTextUpdater {
    static func forMeetingLiveText() -> SmoothTextUpdater {
        let updater = SmoothTextUpdater()
        updater.pacesRTL = true
        return updater
    }
}
