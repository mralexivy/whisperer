//
//  MeetingSilencePolicy.swift
//  Whisperer
//
//  Pure, stateless thresholds and a pure state machine for silent-meeting handling.
//  No actor isolation: safe in synchronous XCTest methods.
//
//  Two different situations, which the app used to treat as one:
//
//  1. **Started by mistake** — nothing has been transcribed and no note written since Start.
//     The user is asked, given a visible 30 s countdown, and the empty meeting is discarded if
//     nobody answers. The card used to vanish for good the first time the VAD heard anything —
//     a cough, a key click — so it was gone before anyone could read it.
//  2. **Went quiet mid-meeting** — there is real content, then a long silence (a break, everyone
//     on mute). That meeting is never discarded. The user is offered Pause / Keep going / Stop.
//

import Foundation

/// What the silent-meeting card shows.
enum MeetingQuietPrompt: Equatable {
    case none
    /// Nothing captured since Start. `micSilent` when the input has produced no sound at all —
    /// the likelier cause is the microphone, not the room.
    case startedByMistake(secondsLeft: Int, micSilent: Bool)
    /// Real content, then `minutes` of quiet. Never auto-discarded.
    case wentQuiet(minutes: Int)
}

/// Tracks one meeting's silence on the session clock (`MeetingSession.elapsedSeconds`, which
/// stops while capture is paused). Pure value type: `MeetingSilenceWatcher` drives it.
nonisolated struct MeetingQuietTracker: Equatable {
    /// Silence before an empty meeting is questioned.
    static let mistakePromptAfter: Double = 15
    /// Countdown shown before an empty meeting is discarded. Restarts on any sound.
    static let discardCountdown: Double = 30
    /// Quiet before a meeting with content is asked about.
    static let quietPromptAfter: Double = 300
    /// "Keep going" on the quiet prompt asks again after this.
    static let quietSnooze: Double = 600

    private(set) var lastVoiceAt: Double = 0
    private(set) var lastContentAt: Double?
    private(set) var hasAudioSignal = false
    private(set) var keptByUser = false
    /// Set while the started-by-mistake card is showing.
    private(set) var discardDeadline: Double?
    private(set) var quietSnoozedUntil: Double?
    private(set) var prompt: MeetingQuietPrompt = .none
    /// Latched true when an empty meeting's countdown runs out. The owner stops and discards.
    private(set) var autoDiscardDue = false
    private var lastElapsed: Double = 0

    init() {}

    var hasContent: Bool { lastContentAt != nil }
    /// Anything voiced, or any content. What the stop-time discard rule calls "speech".
    var speechDetected: Bool { lastContentAt != nil || lastVoiceAt > 0 }

    /// Voice activity (VAD or the RMS fallback). Restarts a running countdown rather than
    /// hiding the card: a single noise must not make it vanish.
    mutating func noteVoice(at t: Double) {
        lastVoiceAt = max(lastVoiceAt, t)
        if let deadline = discardDeadline {
            discardDeadline = max(deadline, t + Self.discardCountdown)
        }
    }

    /// Transcribed words or a note. Ends the started-by-mistake question for good.
    mutating func noteContent(at t: Double) {
        lastContentAt = max(lastContentAt ?? t, t)
        lastVoiceAt = max(lastVoiceAt, t)
        discardDeadline = nil
        autoDiscardDue = false
        if case .startedByMistake = prompt { prompt = .none }
        if case .wentQuiet = prompt { prompt = .none }
    }

    /// The input produced non-silent samples at least once.
    mutating func noteAudioSignal() { hasAudioSignal = true }

    /// "Keep recording" on the started-by-mistake card.
    mutating func keep() {
        keptByUser = true
        discardDeadline = nil
        autoDiscardDue = false
        prompt = .none
    }

    /// "Keep going" on the quiet card: ask again after `quietSnooze`.
    mutating func snoozeQuiet(at t: Double) {
        quietSnoozedUntil = t + Self.quietSnooze
        prompt = .none
    }

    /// Recomputes `prompt` and `autoDiscardDue` at session time `t`.
    ///
    /// `capturePaused` (user pause, mute, a dictation on top): nothing is being listened to, so
    /// silence is not evidence of anything. The card hides and the clocks restart from here.
    mutating func update(elapsed t: Double, capturePaused: Bool) {
        defer { lastElapsed = t }
        if capturePaused {
            prompt = .none
            lastVoiceAt = max(lastVoiceAt, t)
            discardDeadline = nil
            if let content = lastContentAt { lastContentAt = max(content, t) }
            return
        }

        guard let content = lastContentAt else {
            if keptByUser { prompt = .none; return }
            if discardDeadline == nil, t - lastVoiceAt >= Self.mistakePromptAfter {
                discardDeadline = t + Self.discardCountdown
            }
            guard let deadline = discardDeadline else { prompt = .none; return }
            let left = Int((deadline - t).rounded(.up))
            if left <= 0 { autoDiscardDue = true }
            prompt = .startedByMistake(secondsLeft: max(0, left), micSilent: !hasAudioSignal)
            return
        }

        if let snooze = quietSnoozedUntil, t < snooze { prompt = .none; return }
        let quiet = t - max(content, lastVoiceAt)
        prompt = quiet >= Self.quietPromptAfter ? .wentQuiet(minutes: Int(quiet / 60)) : .none
    }
}

/// Pure, nonisolated logic — all callers supply the inputs; nothing is stored here.
nonisolated enum MeetingSilencePolicy {

    /// A meeting shorter than this, with no speech and no transcript, is discarded silently.
    static let discardUnder: Double = 10.0

    // MARK: - Discard decision

    /// True only when **all** discard conditions hold — any content or confirmed speech
    /// flips this to false.
    ///
    /// - Parameters:
    ///   - elapsed: Wall-clock seconds the recording ran.
    ///   - hasTranscript: At least one non-empty word was transcribed.
    ///   - hasNotes: The user typed at least one note during the session.
    ///   - speechDetected: VAD (or RMS fallback) confirmed voiced audio.
    ///   - requested: the started-by-mistake card ran out or the user pressed Discard. Lifts the
    ///     length and voice conditions — noise is not a meeting — but never the content ones: a
    ///     word that arrived with the tail still keeps the meeting.
    static func shouldDiscard(elapsed: Double,
                              hasTranscript: Bool,
                              hasNotes: Bool,
                              speechDetected: Bool,
                              requested: Bool = false) -> Bool {
        guard !hasTranscript else { return false }
        guard !hasNotes else { return false }
        if requested { return true }
        guard elapsed < discardUnder else { return false }
        guard !speechDetected else { return false }
        return true
    }
}
