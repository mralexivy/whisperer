//
//  MeetingTranscriptText.swift
//  Whisperer
//
//  Renders a segment array as text: plain prose, or speaker-labelled lines.
//

import Foundation

/// The two textual renderings of a meeting transcript.
///
/// One type rather than a helper on each view, because both renderings are produced twice —
/// once for the screen and once for the clipboard — and a screen/clipboard mismatch is the
/// exact bug this is meant to avoid. Pure, UI-free, and therefore testable.
///
/// Neither function consults `rawText`. The Polished/Original toggle is applied by the caller
/// (`MeetingDetailView.applyOriginalToggle`) before segments arrive here, so `text` is always
/// already the string the user chose to see.
enum MeetingTranscriptText {

    /// A gap longer than this between one segment's end and the next one's start reads as a
    /// break in the thought, not a breath. Segment spans sit on the audio clock, so this is
    /// real silence in the recording.
    private static let paragraphGap: Double = 2.5

    /// Continuous prose — no speaker names, no timestamps, nothing but the words.
    ///
    /// Paragraphs break on a speaker change or a `paragraphGap` silence. Without them a long
    /// meeting is one unreadable block; with a break per segment it is a list of fragments,
    /// since a segment boundary is a property of the ASR backend's chunking rather than of
    /// the speech (whisper.cpp emits one per voiced VAD span, Nemotron one for the session).
    static func plainProse(from segments: [MeetingSegment]) -> String {
        var paragraphs: [String] = []
        var current: [String] = []
        // Tracked separately from `segments`' own indices: a blank segment is dropped, but the
        // break its neighbours imply must survive it, so comparison is against the last segment
        // that actually contributed text.
        var previous: MeetingSegment?

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if let prev = previous, breaksParagraph(from: prev, to: segment) {
                paragraphs.append(current.joined(separator: " "))
                current = []
            }
            current.append(text)
            previous = segment
        }

        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n\n")
    }

    /// One line per segment, `[m:ss] Speaker: text` — the shape the clipboard has always used
    /// for the speaker-grouped view.
    static func labelled(from segments: [MeetingSegment]) -> String {
        segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "[\(timestamp(segment.timestamp))] \(segment.speakerName): \(text)"
        }
        .joined(separator: "\n")
    }

    // MARK: - Writing direction

    /// The base writing direction for a whole meeting — the only correct scope for this
    /// question, because base direction is a property of the paragraph, and these views lay
    /// out one document.
    ///
    /// Sampled across the **whole** transcript, not its opening. Every earlier copy of this
    /// rule read the first three segments and, inside them, the first fifty scalars — so the
    /// direction of a forty-minute meeting was decided by roughly its first sentence. On
    /// 2026-08-23 a Hebrew meeting whose first three cards were mis-decoded English rendered
    /// entirely left-to-right, punctuation on the wrong side of every Hebrew card. Those
    /// opening windows are also the *least* trustworthy part of a transcript: they are decoded
    /// before the language router has settled. Majority over the document has neither problem.
    ///
    /// - Parameters:
    ///   - segments: the transcript, in order. Sampled with a stride, so cost does not grow
    ///     with meeting length — this is read from a SwiftUI computed property.
    ///   - liveTail: uncommitted live text, used only when the segments are still empty. On the
    ///     Nemotron backend that is the whole recording, since it emits one chunk at `finish()`.
    ///   - fallback: the meeting's language, consulted only when there is not enough text to
    ///     judge. Without it a `he`-configured meeting flashes LTR until its first words land.
    static func isRightToLeft(
        segments: [MeetingSegment],
        liveTail: String = "",
        fallback: TranscriptionLanguage? = nil
    ) -> Bool {
        var tally = ScriptTally()
        if !segments.isEmpty {
            let step = max(1, segments.count / directionSampleSegments)
            for index in Swift.stride(from: 0, to: segments.count, by: step) {
                tally.count(segments[index].text, limit: directionSampleLetters)
                if tally.letters >= directionSampleLetters { break }
            }
        }
        if tally.letters < directionMinimumLetters {
            tally.count(liveTail, limit: directionSampleLetters)
        }
        if let verdict = tally.isRightToLeft { return verdict }
        if let fallback, fallback != .auto { return fallback.isRTL }
        return false
    }

    /// Letters to look at in total. Enough to be representative, small enough that a view can
    /// recompute it on every render.
    private static let directionSampleLetters = 2_000
    /// Segments to spread that budget over, so the sample is not all from one speaker's turn.
    private static let directionSampleSegments = 40
    /// Below this there is no majority worth trusting; fall back to the language.
    private static let directionMinimumLetters = 8

    /// Running RTL-vs-total letter count. A majority decides, so a Hebrew meeting keeps its
    /// direction through quoted English and Latin technical terms.
    private struct ScriptTally {
        private(set) var letters = 0
        private var rtl = 0

        var isRightToLeft: Bool? {
            guard letters >= MeetingTranscriptText.directionMinimumLetters else { return nil }
            return Double(rtl) / Double(letters) > 0.3
        }

        mutating func count(_ text: String, limit: Int) {
            for scalar in text.unicodeScalars {
                guard letters < limit else { return }
                guard scalar.properties.isAlphabetic else { continue }
                letters += 1
                let v = scalar.value
                if (v >= 0x0590 && v <= 0x05FF) || (v >= 0x0600 && v <= 0x06FF) ||
                   (v >= 0x0700 && v <= 0x074F) || (v >= 0xFB50 && v <= 0xFDFF) ||
                   (v >= 0xFE70 && v <= 0xFEFF) { rtl += 1 }
            }
        }
    }

    // MARK: - Internals

    private static func breaksParagraph(from previous: MeetingSegment, to next: MeetingSegment) -> Bool {
        if previous.speakerIndex != next.speakerIndex { return true }
        // Spans can overlap or arrive out of order; a negative gap is not a pause.
        return next.timestamp - previous.endTimestamp > paragraphGap
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
