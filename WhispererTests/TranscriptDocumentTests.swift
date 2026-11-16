//
//  TranscriptDocumentTests.swift
//  WhispererTests
//
//  The shared recording model: identity, adapters over both stores, citation keys, and that the new
//  persisted fields survive in the history store.
//

import XCTest
@testable import whisperer

@MainActor
final class TranscriptDocumentTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    private func words(_ count: Int) -> String {
        (0..<count).map { "word\($0)" }.joined(separator: " ")
    }

    private func sentences(_ count: Int) -> String {
        (0..<count).map { "This is sentence number \($0) of the recording." }.joined(separator: " ")
    }

    private func record(text: String, edited: String? = nil, ai: String? = nil, mode: String? = nil,
                        app: String? = "Cursor", kind: String? = nil, paragraphs: [StoredParagraph]? = nil) -> TranscriptionRecord {
        TranscriptionRecord(
            transcription: text, audioFileURL: nil, duration: 60, language: "en", modelUsed: "m",
            targetAppName: app, aiEnhancedText: ai, aiModeName: mode, sourceKind: kind,
            sourceFileName: kind == "file" ? "interview.m4a" : nil,
            paragraphsJSON: paragraphs.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) })
            .withEdited(edited)
    }

    // MARK: Identity

    func testIdentityIsNamespacedByStoreAndStableAcrossBuilds() {
        let r = record(text: sentences(30))
        let a = TranscriptDocument(transcription: r), b = TranscriptDocument(transcription: r)
        XCTAssertEqual(a.id, RecordingID.dictation(r.id))
        XCTAssertEqual(a.paragraphs.map(\.id), b.paragraphs.map(\.id))
        XCTAssertNotEqual(RecordingID.dictation(r.id), RecordingID.meeting(r.id))
        XCTAssertEqual(a.revision, b.revision)
    }

    func testKindIsCentralisedAndLegacyFileImportIsRecognised() {
        XCTAssertEqual(TranscriptDocument(transcription: record(text: "hi there", app: "Cursor")).kind, .dictation)
        XCTAssertEqual(TranscriptDocument(transcription: record(text: "hi there", app: "File Import")).kind, .file)
        XCTAssertEqual(TranscriptDocument(transcription: record(text: "hi there", app: nil, kind: "file")).kind, .file)
    }

    // MARK: Dictation / file adapters

    func testFlatDictationGetsReadableParagraphsWithoutInventedTimesOrSpeakers() {
        let doc = TranscriptDocument(transcription: record(text: sentences(40)))
        XCTAssertGreaterThan(doc.paragraphs.count, 1)
        XCTAssertFalse(doc.hasTiming)
        XCTAssertFalse(doc.hasSpeakers)
        XCTAssertEqual(doc.paragraphs.map(\.text).joined(separator: " ").filter { !$0.isWhitespace },
                       sentences(40).filter { !$0.isWhitespace })
    }

    func testStoredImportParagraphsKeepTheirTimes() {
        let stored = [StoredParagraph(text: "First paragraph here.", start: 0, end: 5),
                      StoredParagraph(text: "Second paragraph here.", start: 31, end: 40)]
        let doc = TranscriptDocument(transcription: record(text: "First paragraph here. Second paragraph here.", kind: "file", paragraphs: stored))
        XCTAssertEqual(doc.kind, .file)
        XCTAssertEqual(doc.paragraphs.map(\.start), [0, 31])
        XCTAssertTrue(doc.hasTiming)
        XCTAssertEqual(doc.title, "interview")
    }

    func testEditedTextDropsStaleTimesInsteadOfKeepingWrongOnes() {
        let stored = [StoredParagraph(text: "First paragraph here.", start: 0, end: 5)]
        let doc = TranscriptDocument(transcription: record(text: "First paragraph here.", edited: "Something else entirely.", kind: "file", paragraphs: stored))
        XCTAssertFalse(doc.hasTiming)
        XCTAssertEqual(doc.fullText, "Something else entirely.")
    }

    func testPolishedVersionAlignsWithOriginalAndKeepsTheOriginal() {
        let stored = [StoredParagraph(text: "um first one", start: 0, end: 5), StoredParagraph(text: "um second one", start: 40, end: 50)]
        let doc = TranscriptDocument(transcription: record(
            text: "um first one um second one", ai: "First one.\n\nSecond one.", mode: HistoryManager.aiPolishModeName, kind: "file", paragraphs: stored))
        XCTAssertEqual(doc.paragraphs.map(\.text), ["First one.", "Second one."])
        XCTAssertEqual(doc.paragraphs.map(\.start), [0, 40])
        XCTAssertEqual(doc.originalParagraphs?.map(\.text), ["um first one", "um second one"])
        XCTAssertEqual(doc.enhancementName, HistoryManager.aiPolishModeName)
    }

    func testPolishMadeAfterAnEditIsTheOneShown() {
        let doc = TranscriptDocument(transcription: record(
            text: "raw", edited: "edited text", ai: "Polished text.", mode: HistoryManager.aiPolishModeName))
        XCTAssertEqual(doc.fullText, "Polished text.")
        XCTAssertEqual(doc.originalParagraphs?.first?.text, "edited text")
    }

    func testLegacyEditBeatsFastPolishAsBefore() {
        let doc = TranscriptDocument(transcription: record(text: "raw", edited: "my edit", ai: "enhanced", mode: "Fast Polish"))
        XCTAssertEqual(doc.fullText, "my edit")
    }

    func testStoredNotesSurviveEvenThoughDictationHasNoNotesTab() {
        var r = record(text: "hello world")
        r = r.withNotes("keep me")
        XCTAssertEqual(TranscriptDocument(transcription: r).legacyNotes, "keep me")
    }

    // MARK: Meeting adapter

    func testMeetingKeepsSegmentIdsTimesSpeakersAndPolishOriginals() {
        let a = MeetingSegment(timestamp: 0, endTimestamp: 10, text: "Polished one.", speakerName: "Alex", speakerIndex: 0, rawText: "um one")
        let b = MeetingSegment(timestamp: 12, endTimestamp: 20, text: "Second.", speakerName: "Maya", speakerIndex: 1)
        var meeting = MeetingRecord(id: UUID(), title: "Sync", language: "en", modelUsed: "m")
        meeting.segments = [a, b]
        let doc = TranscriptDocument(meeting: meeting)
        XCTAssertEqual(doc.id, .meeting(meeting.id))
        XCTAssertEqual(doc.kind, .meeting)
        XCTAssertEqual(doc.paragraphs.map(\.sourceSegmentID), [a.id, b.id])
        XCTAssertEqual(doc.paragraphs.map(\.start), [0, 12])
        XCTAssertEqual(doc.speakerNames, ["Alex", "Maya"])
        XCTAssertEqual(doc.originalParagraphs?.first?.text, "um one")
        XCTAssertEqual(doc.originalParagraphs?[1].text, "Second.")
        XCTAssertEqual(doc.segments.map(\.id), [a.id, b.id])
    }

    // MARK: Citations

    func testUntimedCitationKeysAreOrdinalAtSixtySecondSpacingAndResolveBack() {
        let doc = TranscriptDocument(transcription: record(text: sentences(40)))
        XCTAssertEqual(doc.citationKeys.prefix(3), [0, 60, 120])
        XCTAssertEqual(doc.paragraph(forCitationKey: 118)?.id, doc.paragraphs[2].id)
        XCTAssertEqual(doc.segments.count, doc.paragraphs.count)
    }

    func testTimedCitationKeysAreRealStartTimes() {
        let stored = [StoredParagraph(text: "A one.", start: 5, end: 9), StoredParagraph(text: "B two.", start: 70, end: 80)]
        let doc = TranscriptDocument(transcription: record(text: "A one. B two.", kind: "file", paragraphs: stored))
        XCTAssertEqual(doc.citationKeys, [5, 70])
        XCTAssertEqual(doc.paragraph(forCitationKey: 68)?.start, 70)
    }

    // MARK: Persistence

    func testNewFieldsSurviveInTheHistoryStore() async throws {
        let manager = HistoryManager(database: HistoryDatabase(inMemory: true))
        Self.keepAlive.append(manager)
        let r = record(text: "Hello there. This is a file.", kind: "file",
                       paragraphs: [StoredParagraph(text: "Hello there. This is a file.", start: 0, end: 4)])
        try await manager.saveTranscription(r)
        let saved = try XCTUnwrap(manager.record(id: r.id))
        XCTAssertEqual(saved.sourceKind, "file")
        XCTAssertEqual(saved.sourceFileName, "interview.m4a")
        XCTAssertNotNil(saved.paragraphsJSON)

        manager.setTitle(id: r.id, "My title")
        manager.setAISummary(id: r.id, MeetingAISummary(overview: "About a file.", keyTopics: [], decisions: [], openQuestions: [], nextMeeting: nil, actionItems: [], generatedAt: Date()))
        manager.setPolished(id: r.id, text: "Hello there.\n\nThis is a file.")
        manager.setPinned(id: r.id, true)

        let doc = TranscriptDocument(transcription: try XCTUnwrap(manager.record(id: r.id)))
        XCTAssertEqual(doc.title, "My title")
        XCTAssertEqual(doc.summary?.overview, "About a file.")
        XCTAssertTrue(doc.isPinned)
        XCTAssertEqual(doc.paragraphs.count, 2)
        // the recognizer's text is untouched
        XCTAssertEqual(try XCTUnwrap(manager.record(id: r.id)).transcription, "Hello there. This is a file.")

        manager.setPolished(id: r.id, text: nil)   // Undo
        XCTAssertEqual(TranscriptDocument(transcription: try XCTUnwrap(manager.record(id: r.id))).paragraphs.count, 1)
        XCTAssertTrue(manager.searchIDs("a file").contains(r.id))
    }

    func testDictationSummaryIsStrippedOfMeetingOnlySections() {
        var summary = MeetingAISummary.empty
        summary.overview = "A thought."
        summary.decisions = [DecisionItem(label: "D1", text: "Invented")]
        summary.actionItems = [MeetingActionItem(text: "Invented task", ownerName: "Bob")]
        summary.nextMeeting = "Tuesday"
        let stored = RecordingResolver.summaryForStorage(summary, kind: .dictation)
        XCTAssertEqual(stored.overview, "A thought.")
        XCTAssertTrue(stored.decisions.isEmpty && stored.actionItems.isEmpty && stored.openQuestions.isEmpty)
        XCTAssertNil(stored.nextMeeting)
        XCTAssertEqual(RecordingResolver.summaryForStorage(summary, kind: .file).decisions.count, 1)
    }
}

private extension TranscriptionRecord {
    func withEdited(_ edited: String?) -> TranscriptionRecord {
        guard let edited else { return self }
        var copy = self
        copy.editedTranscription = edited
        return copy
    }
    func withNotes(_ notes: String) -> TranscriptionRecord {
        var copy = self
        copy.notes = notes
        return copy
    }
}
