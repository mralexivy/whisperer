//
//  MeetingNotesService.swift
//  Whisperer
//
//  The one way to change a meeting's notes from outside the notes pane — the MCP note tools,
//  and the pane itself after a meeting has ended.
//
//  While a meeting is recording, its `MeetingSession` owns the notes in memory and persists
//  the whole array, so a write that went straight to Core Data would be overwritten by the
//  session's next save. Writes for the live meeting therefore go through the session; every
//  other meeting is changed with an atomic read-modify-write in `MeetingManager`.
//

import Foundation

@MainActor
enum MeetingNotesService {

    enum Failure: Error, Equatable, LocalizedError {
        case meetingNotFound
        case noteNotFound
        case notEditable

        var errorDescription: String? {
            switch self {
            case .meetingNotFound: return "Meeting not found."
            case .noteNotFound:    return "Note not found."
            case .notEditable:     return "That note was written by the user; AI apps can add notes but only change their own."
            }
        }
    }

    /// Hook for tests: the session that is recording right now, if any.
    static var liveSession: () -> MeetingSession? = { AppState.shared.activeMeetingSession }

    private static func live(for meetingID: UUID) -> MeetingSession? {
        guard let session = liveSession(), session.isRecording, session.meetingID == meetingID else { return nil }
        return session
    }

    /// Applies `transform` and returns the new list. `transform` may throw to refuse the change.
    static func mutate(meetingID: UUID,
                       _ transform: @escaping @Sendable ([MeetingNote]) throws -> [MeetingNote]) async throws -> [MeetingNote] {
        if let session = live(for: meetingID) {
            let updated = try transform(session.notes)
            session.replaceNotes(updated)
            announce(meetingID, updated)
            return updated
        }
        let refusal = RefusalBox()
        let result = await MeetingManager.shared.mutateNotes(meetingID: meetingID) { current in
            do { return try transform(current) } catch { refusal.error = error; return current }
        }
        if let error = refusal.error { throw error }
        guard let result else { throw Failure.meetingNotFound }
        announce(meetingID, result)
        return result
    }

    static func notes(meetingID: UUID) async -> [MeetingNote]? {
        if let session = live(for: meetingID) { return session.notes }
        return await MeetingManager.shared.meeting(id: meetingID)?.notes
    }

    @discardableResult
    static func add(_ note: MeetingNote, to meetingID: UUID) async throws -> [MeetingNote] {
        try await mutate(meetingID: meetingID) { $0 + [note] }
    }

    /// Changes a note's text. AI apps (`asAuthor` non-nil) may only change notes they wrote.
    @discardableResult
    static func update(noteID: UUID, text: String, kind: NoteKind? = nil, in meetingID: UUID,
                       asAuthor: String?) async throws -> [MeetingNote] {
        try await mutate(meetingID: meetingID) { try applyUpdate($0, noteID: noteID, text: text, kind: kind, asAuthor: asAuthor) }
    }

    @discardableResult
    static func delete(noteID: UUID, in meetingID: UUID, asAuthor: String?) async throws -> [MeetingNote] {
        try await mutate(meetingID: meetingID) { try applyDelete($0, noteID: noteID, asAuthor: asAuthor) }
    }

    // MARK: Rules (pure, tested)

    /// AI apps (`asAuthor` non-nil) may change only notes an AI app wrote; the user may change any.
    nonisolated static func applyUpdate(_ notes: [MeetingNote], noteID: UUID, text: String, kind: NoteKind?,
                                        asAuthor: String?) throws -> [MeetingNote] {
        guard let i = notes.firstIndex(where: { $0.id == noteID }) else { throw Failure.noteNotFound }
        if asAuthor != nil && !notes[i].isByAI { throw Failure.notEditable }
        var copy = notes
        copy[i].text = text
        if let kind { copy[i].kind = kind }
        return copy
    }

    nonisolated static func applyDelete(_ notes: [MeetingNote], noteID: UUID, asAuthor: String?) throws -> [MeetingNote] {
        guard let note = notes.first(where: { $0.id == noteID }) else { throw Failure.noteNotFound }
        if asAuthor != nil && !note.isByAI { throw Failure.notEditable }
        return notes.filter { $0.id != noteID }
    }

    private static func announce(_ meetingID: UUID, _ notes: [MeetingNote]) {
        NotificationCenter.default.post(name: .meetingNotesDidChange, object: meetingID, userInfo: ["notes": notes])
    }

    /// `@unchecked Sendable`: written at most once inside the Core Data `perform` block and read
    /// only after `mutateNotes` returns, so the two accesses are sequenced, never concurrent.
    nonisolated private final class RefusalBox: @unchecked Sendable { var error: Error? }
}
