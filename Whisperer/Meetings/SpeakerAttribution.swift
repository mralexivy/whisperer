//
//  SpeakerAttribution.swift
//  Whisperer
//
//  Decides which speaker, if any, a finalized diarizer timeline puts in a window.
//

import Foundation

/// Pure, UI-free attribution rule shared by `MeetingSpeakerCoordinator` and its tests.
///
/// Extracted for the same reason `MeetingTranscriptText` was: the rule is arithmetic over a
/// timeline, the failure it prevents is subtle, and it is unreachable for a test while it sits
/// private inside an actor behind `#if canImport(FluidAudio)`.
enum SpeakerAttribution {

    struct Turn: Equatable {
        let start: TimeInterval
        let end: TimeInterval
        let speaker: Int

        init(start: TimeInterval, end: TimeInterval, speaker: Int) {
            self.start = start
            self.end = end
            self.speaker = speaker
        }
    }

    /// A speaker must hold at least this much audio in the window before it can be named.
    static let minSeconds: TimeInterval = 0.30
    /// …and at least this share of it.
    static let minShare: Double = 0.5

    /// The speaker holding the window, or `nil` when the timeline has no real opinion.
    ///
    /// Overlapping speech resolves to whoever dominates rather than whoever started first, but
    /// "dominates" is not the same as "won". Sortformer runs its speaker slots independently
    /// and finalizes a turn only when that slot's activity *falls*, so a slot talking
    /// continuously finalizes nothing at all: through an unbroken turn the finalized timeline
    /// holds almost nothing but the other slots' short blips. A blip that covers 0.4s of a 1.1s
    /// window has won it by default, and naming a speaker on that is what renamed the talker
    /// every second of a monologue — each rename closing a transcript card.
    ///
    /// `nil` is therefore a real answer, and the caller's job is to carry the current speaker
    /// rather than to guess a new one.
    static func dominantSpeaker(in turns: [Turn], from start: TimeInterval, to end: TimeInterval) -> Int? {
        var totals: [Int: TimeInterval] = [:]
        for turn in turns {
            let overlap = min(turn.end, end) - max(turn.start, start)
            if overlap > 0 { totals[turn.speaker, default: 0] += overlap }
        }
        guard let best = totals.max(by: { $0.value < $1.value }) else { return nil }

        let span = max(end - start, 0)
        guard best.value >= minSeconds else { return nil }
        guard span <= 0 || best.value >= span * minShare else { return nil }
        return best.key
    }

    /// Merged voiced intervals inside the span that **one speaker** accounts for.
    ///
    /// Placing a speaker's words is a question about that speaker's audio, and only their own
    /// turns are evidence about it. Another slot's turn is evidence that *somebody* made a
    /// sound, which is a different question — and during a monologue it is the only kind of
    /// evidence there is, because the talker's own turn does not finalize until it ends.
    /// Clipping a one-second partial onto a foreign 0.4s blip shrinks the span to the blip and
    /// invents a gap on either side of it; enough of those in a row and every card is two words
    /// long. Filtering leaves the monologue with no runs at all, so the caller keeps the raw
    /// span, while a genuine pause — where the talker's own turn closed and therefore finalized
    /// — still produces the run that exposes it.
    static func voicedRuns(in turns: [Turn], by speaker: Int, from start: TimeInterval, to end: TimeInterval)
        -> [(start: TimeInterval, end: TimeInterval)]
    {
        voicedRuns(in: turns.filter { $0.speaker == speaker }, from: start, to: end)
    }

    /// Merged voiced intervals inside the span, in order, regardless of who made them.
    ///
    /// Overlapping turns collapse into one interval — this answers *where there is sound*, not
    /// who made it. No threshold is applied: the gaps are reported as they are and
    /// `MeetingSession.silenceSplitGap` decides which of them is long enough to break a card.
    static func voicedRuns(in turns: [Turn], from start: TimeInterval, to end: TimeInterval)
        -> [(start: TimeInterval, end: TimeInterval)]
    {
        var clipped: [(start: TimeInterval, end: TimeInterval)] = []
        for turn in turns {
            let lo = max(turn.start, start)
            let hi = min(turn.end, end)
            if hi > lo { clipped.append((start: lo, end: hi)) }
        }
        guard !clipped.isEmpty else { return [] }
        clipped.sort { $0.start < $1.start }

        var merged: [(start: TimeInterval, end: TimeInterval)] = [clipped[0]]
        for interval in clipped.dropFirst() {
            if interval.start <= merged[merged.count - 1].end {
                merged[merged.count - 1].end = max(merged[merged.count - 1].end, interval.end)
            } else {
                merged.append(interval)
            }
        }
        return merged
    }
}
