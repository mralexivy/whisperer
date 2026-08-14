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

    /// True when a sample of transcript text is predominantly RTL script.
    ///
    /// Content wins over the configured language everywhere this is used: `meeting.language`
    /// is the shortlist entry the session started with, not what was actually spoken.
    ///
    /// Lives here because three views had already grown their own copy of it and this change
    /// would have added a fourth.
    static func isRightToLeft(sample: String) -> Bool {
        var rtl = 0, letters = 0
        for scalar in sample.prefix(50).unicodeScalars {
            let v = scalar.value
            if scalar.properties.isAlphabetic { letters += 1 }
            if (v >= 0x0590 && v <= 0x05FF) || (v >= 0x0600 && v <= 0x06FF) ||
               (v >= 0x0700 && v <= 0x074F) || (v >= 0xFB50 && v <= 0xFDFF) ||
               (v >= 0xFE70 && v <= 0xFEFF) { rtl += 1 }
        }
        return letters > 0 && Double(rtl) / Double(letters) > 0.3
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
