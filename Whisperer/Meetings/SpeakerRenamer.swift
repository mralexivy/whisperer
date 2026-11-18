//
//  SpeakerRenamer.swift
//  Whisperer
//
//  The one way a speaker gets a name from the user, from any screen: the live window, the
//  Recordings workspace (live and finished), the People pane. Each screen used to wire its
//  own copy, and the ones that forgot to store the rename looked right until the next reload.
//

import Foundation

@MainActor
enum SpeakerRenamer {

    /// Why a typed name was not applied. Nil from `problem(...)` means the name is fine.
    enum Problem: Equatable {
        case empty
        case taken(by: String)
    }

    static func problem(for name: String, speakerIndex: Int,
                        roster: [(index: Int, name: String)]) -> Problem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if let other = SpeakerNaming.conflictingName(for: trimmed, in: roster, excluding: speakerIndex) {
            return .taken(by: other)
        }
        return nil
    }

    /// Names `speakerIndex` in `meetingID` and stores it. While the meeting is being recorded the
    /// session owns the transcript, so it applies the name to what is on screen, to every card
    /// flushed from now on, and to the stored copy; the stop-time naming from the invite never
    /// overrides it. A finished meeting is rewritten in storage only.
    @discardableResult
    static func rename(meetingID: UUID, speakerIndex: Int, to name: String,
                       session: MeetingSession?) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let session, session.meetingID == meetingID {
            await session.renameSpeaker(speakerIndex: speakerIndex, newName: trimmed)
        } else {
            await MeetingManager.shared.renameSpeaker(meetingID: meetingID, speakerIndex: speakerIndex, newName: trimmed)
        }
        NotificationCenter.default.post(name: .meetingSegmentsDidPersist, object: meetingID)
        return true
    }

    /// Invite names nobody carries yet: one tap names a voice. Only offered while the voice still
    /// has its generated "Speaker N" label.
    static func suggestions(participants: [MeetingParticipant],
                            roster: [(index: Int, name: String)]) -> [String] {
        let taken = Set(roster.map { SpeakerNaming.normalized($0.name) })
        var seen = Set<String>()
        return participants.filter { $0.response != .declined }.map(\.displayName).filter {
            let key = SpeakerNaming.normalized($0)
            return !taken.contains(key) && seen.insert(key).inserted
        }
    }

    /// What a live transcript needs to name a voice in place. `afterRename` runs once the name is
    /// stored, for a screen that keeps its own copy of the transcript (the floating window's detail
    /// model, the workspace's reader).
    static func action(meetingID: UUID, session: MeetingSession,
                       participants: @escaping () -> [MeetingParticipant],
                       roster: (() -> [(index: Int, name: String)])? = nil,
                       afterRename: @escaping (_ speakerIndex: Int, _ name: String) -> Void = { _, _ in }) -> SpeakerRenameAction {
        SpeakerRenameAction(
            roster: roster ?? { session.speakerRoster },
            suggestions: { suggestions(participants: participants(), roster: roster?() ?? session.speakerRoster) },
            apply: { index, name in
                // On screen first, so the new name is there before the write returns.
                afterRename(index, name)
                Task { await rename(meetingID: meetingID, speakerIndex: index, to: name, session: session) }
            })
    }
}
