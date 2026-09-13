//
//  MeetingSilencePolicy.swift
//  Whisperer
//
//  Pure, stateless thresholds for silent-meeting detection.
//  No actor isolation: safe in synchronous XCTest methods.
//

import Foundation

/// The UI stage of the no-speech warning. `.hidden` before speech is confirmed absent,
/// `.warning` once we have modest confidence, `.confident` when we're fairly sure.
enum MeetingSilenceStage: Equatable {
    case hidden
    case warning
    case confident
}

/// Pure, nonisolated logic — all callers supply the inputs; nothing is stored here.
nonisolated enum MeetingSilencePolicy {

    // MARK: - Thresholds

    /// Seconds of silence after which the warning toast appears.
    static let warnAfter: Double = 6.0
    /// Seconds of silence after which copy hardens ("No speech detected") and Stop becomes primary.
    static let confidentAfter: Double = 12.0
    /// A meeting shorter than this, with no speech and no transcript, is discarded silently.
    static let discardUnder: Double = 10.0

    // MARK: - Stage

    /// Returns the current UI stage for the silence warning.
    static func stage(elapsed: Double, speechDetected: Bool, dismissed: Bool) -> MeetingSilenceStage {
        guard !speechDetected, !dismissed else { return .hidden }
        if elapsed >= confidentAfter { return .confident }
        if elapsed >= warnAfter { return .warning }
        return .hidden
    }

    // MARK: - Progress

    /// 0…1 linear progress across the warnAfter → confidentAfter window.
    /// Returns 0 before the warning threshold and 1 at or beyond confidentAfter.
    static func progress(elapsed: Double) -> Double {
        let range = confidentAfter - warnAfter
        guard range > 0 else { return 1 }
        return max(0, min(1, (elapsed - warnAfter) / range))
    }

    // MARK: - Discard decision

    /// True only when **all** discard conditions hold — any content or confirmed speech
    /// flips this to false.
    ///
    /// - Parameters:
    ///   - elapsed: Wall-clock seconds the recording ran.
    ///   - hasTranscript: At least one non-empty word was transcribed.
    ///   - hasNotes: The user typed at least one note during the session.
    ///   - speechDetected: VAD (or RMS fallback) confirmed voiced audio.
    static func shouldDiscard(elapsed: Double,
                               hasTranscript: Bool,
                               hasNotes: Bool,
                               speechDetected: Bool) -> Bool {
        guard elapsed < discardUnder else { return false }
        guard !hasTranscript else { return false }
        guard !hasNotes else { return false }
        guard !speechDetected else { return false }
        return true
    }
}
