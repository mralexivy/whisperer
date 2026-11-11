//
//  SpeakerSourceAttribution.swift
//  Whisperer
//
//  Names meeting speakers from the calendar invite without learning anyone's voice.
//
//  The identity signal is where a voice comes from. The call's audio is captured on its own
//  (`MeetingCallAudioController`'s process tap), so for every moment of the meeting it is known
//  whether the call was talking. A diarized speaker whose speech mostly happens while the call is
//  silent is the person at this Mac's microphone — the user. One whose speech mostly happens while
//  the call is talking is someone on the call. Then:
//  - the user takes their own name (the invite's self entry, else this Mac's account name);
//  - in a 1:1 (the user plus one other non-declined attendee) the call's voice is that attendee;
//  - in a group nothing remote is named — invite names stay one-click suggestions — until the
//    meeting app's active-speaker indicator can be matched.
//
//  Pure: segment spans and per-buffer levels in, names out.
//

import Foundation

nonisolated enum SpeakerSource: Equatable, Sendable {
    /// Speaking into this Mac's microphone.
    case local
    /// Heard through the call.
    case remote
}

nonisolated enum SpeakerSourceAttribution {
    static let sampleRate = 16_000.0
    /// Call RMS above which the call counts as talking in a buffer. The tap's silence is digital
    /// zero, so the line can sit low: a call played quietly (whole meetings peaking at 0.12 on
    /// 2026-11-10) speaks around 0.005–0.02, under the 0.008 this used to be. Same line as the
    /// mixer's own `callTalkingRMS`.
    static let callActiveRMS: Float = SystemAudioMixer.callTalkingRMS
    /// A speaker needs this much speech before it is classified.
    static let minSpeechSeconds = 4.0
    /// Below this much call activity in the whole meeting the tap has not shown it can hear the
    /// call (capture denied, call on another app, nobody else spoke yet). Every voice would then
    /// look local, so nothing is classified.
    static let minCallActiveSeconds = 10.0
    static let localMaxCallShare = 0.25
    static let remoteMinCallShare = 0.6
    /// Microphone RMS above which a buffer has someone speaking at this Mac (when the call is
    /// quiet). Room noise sits around 0.001–0.003; a headset raised for the recording is well above.
    static let micSpeechRMS: Float = 0.004

    /// Per speaker: seconds the call was talking during their turns, and seconds the microphone
    /// was talking while the call was quiet. Only moments someone speaks count — a 30 s card is
    /// mostly pauses, and dividing by its whole length kept a voice from the call under the 0.6
    /// line, so nobody was ever named (2026-11-09).
    struct Evidence: Equatable, Sendable {
        var callSeconds = 0.0
        var micSeconds = 0.0
        var activeSeconds: Double { callSeconds + micSeconds }
        var callShare: Double { activeSeconds > 0 ? callSeconds / activeSeconds : 0 }
    }

    struct Span: Equatable, Sendable {
        let speakerIndex: Int
        let start: Double
        let end: Double
    }

    /// Classifies each speaker with enough speech. At most one speaker is `.local`: if two voices
    /// look local (the diarizer split the user, or someone sits beside them) only the one with the
    /// most speech is kept, so a guest in the room is never given the user's name.
    static func classify(_ spans: [Span], activity: [SystemAudioMixer.SourceFrame]) -> [Int: SpeakerSource] {
        classify(evidence(spans, activity: activity), callActiveSeconds: callActiveSeconds(activity))
    }

    static func classify(_ evidence: [Int: Evidence], callActiveSeconds: Double) -> [Int: SpeakerSource] {
        guard callActiveSeconds >= minCallActiveSeconds else { return [:] }
        var result: [Int: SpeakerSource] = [:]
        var bestLocal: (index: Int, seconds: Double)?
        for (index, e) in evidence where e.activeSeconds >= minSpeechSeconds {
            if e.callShare >= remoteMinCallShare {
                result[index] = .remote
            } else if e.callShare <= localMaxCallShare, e.activeSeconds > (bestLocal?.seconds ?? 0) {
                bestLocal = (index, e.activeSeconds)
            }
        }
        if let bestLocal { result[bestLocal.index] = .local }
        return result
    }

    static func callActiveSeconds(_ activity: [SystemAudioMixer.SourceFrame]) -> Double {
        activity.reduce(0) { $0 + ($1.callRMS >= callActiveRMS ? Double($1.count) / sampleRate : 0) }
    }

    /// Call and microphone speech inside each speaker's spans, from the per-buffer levels.
    static func evidence(_ spans: [Span], activity: [SystemAudioMixer.SourceFrame]) -> [Int: Evidence] {
        let sorted = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var out: [Int: Evidence] = [:]
        var cursor = 0
        for frame in activity {
            let start = Double(frame.start) / sampleRate
            let end = Double(frame.start + frame.count) / sampleRate
            let call = frame.callRMS >= callActiveRMS
            let mic = !call && frame.micRMS >= micSpeechRMS
            guard call || mic else { continue }
            while cursor < sorted.count, sorted[cursor].end <= start { cursor += 1 }
            var i = cursor
            while i < sorted.count, sorted[i].start < end {
                let span = sorted[i]
                let seconds = min(end, span.end) - max(start, span.start)
                if seconds > 0 {
                    if call { out[span.speakerIndex, default: Evidence()].callSeconds += seconds }
                    else { out[span.speakerIndex, default: Evidence()].micSeconds += seconds }
                }
                i += 1
            }
        }
        return out
    }

    /// Names for the classified speakers. The user is named in every meeting — the voice at this
    /// Mac's microphone is theirs, invite or not; the call's voice only in a 1:1 from the invite.
    static func names(for sources: [Int: SpeakerSource], participants: [MeetingParticipant],
                      ownName: String) -> [Int: String] {
        let others = participants.expectedOthers
        var names: [Int: String] = [:]
        for (index, source) in sources {
            switch source {
            case .local:
                names[index] = ownName
            case .remote:
                if others.count == 1 { names[index] = others[0].displayName }
            }
        }
        return names
    }

    /// The user's name: the invite's own entry when the calendar names it (Outlook does, Google
    /// never does), else this Mac's account name, else "Me".
    static func ownName(participants: [MeetingParticipant], macAccountName: String = NSFullUserName()) -> String {
        if let me = participants.first(where: \.isSelf), me.displayName != "Me" { return me.displayName }
        let account = macAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        return account.isEmpty ? "Me" : account
    }
}
