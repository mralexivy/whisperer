//
//  RecordingResolver.swift
//  Whisperer
//
//  Routes work on "a recording" to whichever store holds it. The AI services (Ask AI, overview,
//  polish) were written against meetings and address them by UUID; UUIDs are unique across the two
//  stores, so a lookup by id is enough to send a dictation's or an import's result to the history
//  store instead of the meeting store. Meetings behave exactly as before.
//

import Foundation

@MainActor
enum RecordingResolver {

    /// The history store the resolver works on. Tests substitute an in-memory one.
    static var historyOverride: HistoryManager?
    private static var history: HistoryManager { historyOverride ?? HistoryManager.shared }

    // MARK: Reading

    static func document(for id: RecordingID) async -> TranscriptDocument? {
        switch id.store {
        case .meeting:
            guard let record = await MeetingManager.shared.meeting(id: id.uuid) else { return nil }
            return TranscriptDocument(meeting: record)
        case .transcription:
            guard let record = history.record(id: id.uuid) else { return nil }
            return TranscriptDocument(transcription: record)
        }
    }

    /// The transcript as segments, whichever store the recording is in.
    static func segments(for uuid: UUID) async -> [MeetingSegment]? {
        if let record = history.record(id: uuid) {
            return TranscriptDocument(transcription: record).segments
        }
        return await MeetingManager.shared.meeting(id: uuid)?.segments
    }

    static func isInTranscriptionStore(_ uuid: UUID) -> Bool {
        history.record(id: uuid) != nil
    }

    // MARK: Writing

    /// A short dictation has no decisions, owners or deadlines to find. The model is told so in the
    /// prompt, but a small model still invents them; this keeps the stored result honest.
    static func summaryForStorage(_ summary: MeetingAISummary, kind: RecordingKind) -> MeetingAISummary {
        guard kind == .dictation else { return summary }
        var trimmed = summary
        trimmed.decisions = []
        trimmed.openQuestions = []
        trimmed.actionItems = []
        trimmed.nextMeeting = nil
        return trimmed
    }

    static func persistSummary(_ uuid: UUID, _ summary: MeetingAISummary) async {
        if let record = history.record(id: uuid) {
            let stored = summaryForStorage(summary, kind: TranscriptDocument.kind(of: record))
            history.setAISummary(id: uuid, stored)
        } else {
            await MeetingManager.shared.updateAISummary(meetingID: uuid, summary: summary)
        }
    }

    /// Meetings keep polished text on their segments. Everything else keeps it as one enhanced version
    /// next to the original, so the original is never touched and Undo is "clear the enhanced version".
    static func persistSegments(_ uuid: UUID, _ segments: [MeetingSegment]) async {
        guard history.record(id: uuid) != nil else {
            await MeetingManager.shared.updateSegments(meetingID: uuid, segments: segments)
            return
        }
        if segments.contains(where: { $0.isPolished }) {
            // A late result is for the text it was started on. If the recording changed since (an edit, a
            // re-transcription, another polish), it is dropped rather than written over newer content.
            guard let record = history.record(id: uuid), resultMatchesCurrentText(segments, record: record) else {
                Logger.info("AI polish result dropped: the recording changed while it ran (\(uuid))", subsystem: .transcription)
                return
            }
            history.setPolished(id: uuid, text: segments.map(\.text).joined(separator: "\n\n"))
        } else {
            history.setPolished(id: uuid, text: nil)
        }
    }

    static func titleInfo(_ uuid: UUID) async -> (title: String, userSet: Bool)? {
        if let record = history.record(id: uuid) {
            return (record.title ?? "", record.title != nil)
        }
        guard let record = await MeetingManager.shared.meeting(id: uuid) else { return nil }
        return (record.title, record.titleIsUserSet)
    }

    static func setTitle(_ uuid: UUID, title: String, userEdited: Bool) async {
        if history.record(id: uuid) != nil {
            // A dictation's title is either the user's or the AI's; once present it is kept, so the AI
            // only names recordings that have no title yet.
            history.setTitle(id: uuid, title)
        } else {
            await MeetingManager.shared.updateTitle(meetingID: uuid, title: title, userEdited: userEdited)
        }
    }
}

extension RecordingResolver {
    /// True when every segment of a polish result was made from text the recording still has — either the
    /// version shown now or the original behind it.
    static func resultMatchesCurrentText(_ segments: [MeetingSegment], record: TranscriptionRecord) -> Bool {
        let document = TranscriptDocument(transcription: record)
        func matches(_ paragraphs: [TranscriptParagraph]) -> Bool {
            paragraphs.count == segments.count
                && zip(paragraphs, segments).allSatisfy { $0.text == ($1.rawText ?? $1.text) }
        }
        return matches(document.paragraphs) || (document.originalParagraphs.map(matches) ?? false)
    }
}
