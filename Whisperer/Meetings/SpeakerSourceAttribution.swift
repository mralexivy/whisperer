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
    /// Call RMS above which the call counts as talking in a buffer. Speech on the tap sits around
    /// 0.02–0.2; the tap's silence is digital zero.
    static let callActiveRMS: Float = 0.008
    /// A speaker needs this much speech before it is classified.
    static let minSpeechSeconds = 4.0
    /// Below this much call activity in the whole meeting the tap has not shown it can hear the
    /// call (capture denied, call on another app, nobody else spoke yet). Every voice would then
    /// look local, so nothing is classified.
    static let minCallActiveSeconds = 10.0
    static let localMaxCallShare = 0.25
    static let remoteMinCallShare = 0.6

    struct Span: Equatable, Sendable {
        let speakerIndex: Int
        let start: Double
        let end: Double
    }

    /// Classifies each speaker with enough speech. At most one speaker is `.local`: if two voices
    /// look local (the diarizer split the user, or someone sits beside them) only the one with the
    /// most speech is kept, so a guest in the room is never given the user's name.
    static func classify(_ spans: [Span], activity: [SystemAudioMixer.SourceFrame]) -> [Int: SpeakerSource] {
        let active = callActiveIntervals(activity)
        guard active.reduce(0, { $0 + ($1.end - $1.start) }) >= minCallActiveSeconds else { return [:] }

        var speech: [Int: Double] = [:]
        var overlap: [Int: Double] = [:]
        for span in spans where span.end > span.start {
            speech[span.speakerIndex, default: 0] += span.end - span.start
            overlap[span.speakerIndex, default: 0] += overlapSeconds(span.start, span.end, active)
        }
        var result: [Int: SpeakerSource] = [:]
        var bestLocal: (index: Int, seconds: Double)?
        for (index, seconds) in speech where seconds >= minSpeechSeconds {
            let share = (overlap[index] ?? 0) / seconds
            if share >= remoteMinCallShare {
                result[index] = .remote
            } else if share <= localMaxCallShare, seconds > (bestLocal?.seconds ?? 0) {
                bestLocal = (index, seconds)
            }
        }
        if let bestLocal { result[bestLocal.index] = .local }
        return result
    }

    /// Names for the classified speakers. Empty without an invite: an ad-hoc call has no one to
    /// name the call's voices after, and naming only the user would stand out as a half-answer.
    static func names(for sources: [Int: SpeakerSource], participants: [MeetingParticipant],
                      ownName: String) -> [Int: String] {
        guard !participants.isEmpty else { return [:] }
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

    // MARK: - Private

    private static func callActiveIntervals(_ frames: [SystemAudioMixer.SourceFrame]) -> [(start: Double, end: Double)] {
        var intervals: [(start: Double, end: Double)] = []
        for frame in frames where frame.callRMS >= callActiveRMS {
            let start = Double(frame.start) / sampleRate
            let end = Double(frame.start + frame.count) / sampleRate
            if let last = intervals.last, start - last.end < 0.05 {
                intervals[intervals.count - 1].end = max(last.end, end)
            } else {
                intervals.append((start, end))
            }
        }
        return intervals
    }

    private static func overlapSeconds(_ start: Double, _ end: Double,
                                       _ intervals: [(start: Double, end: Double)]) -> Double {
        var total = 0.0
        for interval in intervals where interval.end > start && interval.start < end {
            total += min(end, interval.end) - max(start, interval.start)
        }
        return total
    }
}
