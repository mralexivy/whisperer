//
//  RecordingSharedAITests.swift
//  WhispererTests
//
//  The meeting AI tools working on dictations and imports: polish through the shared controller, Undo,
//  late results that must not overwrite newer text, citations on untimed text, and durable chat.
//

import XCTest
@testable import whisperer

@MainActor
final class RecordingSharedAITests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    private func store() -> (HistoryManager, TranscriptPolishController) {
        let manager = HistoryManager(database: HistoryDatabase(inMemory: true))
        RecordingResolver.historyOverride = manager
        let defaults = UserDefaults(suiteName: "RecordingSharedAITests-\(UUID().uuidString)")!
        let connected = ConnectedAIStore(defaults: defaults, keychain: KeychainStore(service: "com.ivy.whisperer.tests.\(UUID().uuidString)"))
        let controller = TranscriptPolishController(store: connected, defaults: defaults)
        controller.persist = { id, segments in await RecordingResolver.persistSegments(id, segments) }
        Self.keepAlive += [manager, controller, connected]
        return (manager, controller)
    }

    private func loadDoc(_ id: UUID) async throws -> TranscriptDocument {
        let found = await RecordingResolver.document(for: .dictation(id))
        return try XCTUnwrap(found)
    }

    override func tearDown() { RecordingResolver.historyOverride = nil }

    private func save(_ text: String, in manager: HistoryManager, kind: String? = nil) async throws -> UUID {
        let record = TranscriptionRecord(transcription: text, audioFileURL: nil, duration: 30, language: "en", modelUsed: "m",
                                         targetAppName: "Cursor", sourceKind: kind)
        try await manager.saveTranscription(record)
        return record.id
    }

    private func fakeProvider(_ replies: [String]) -> FakeMeetingProvider {
        let fake = FakeMeetingProvider(id: .claudeCode)
        fake.completeHandler = { input in
            let items = input.split(separator: "\n").compactMap { line -> String? in
                guard let id = line.split(separator: "|").first.map({ $0.trimmingCharacters(in: .whitespaces) }), let n = Int(id), n < replies.count else { return nil }
                return #"{"id":\#(n),"text":"\#(replies[n])"}"#
            }
            return #"{"segments":[\#(items.joined(separator: ","))]}"#
        }
        return fake
    }

    private var twoBlocks: String { "um so we we decided to use postgres for the events table.\n\nuh bob will write the migration this week" }

    func testPolishWorksOnADictationKeepsTheOriginalAndUndoes() async throws {
        let (manager, controller) = store()
        let id = try await save(twoBlocks, in: manager)
        let doc = try await loadDoc(id)
        XCTAssertEqual(doc.paragraphs.count, 2)

        let provider = fakeProvider(["So we decided to use Postgres for the events table.", "Bob will write the migration this week."])
        await controller.start(meetingID: id, segments: doc.segments, languageName: "English", provider: provider)?.value

        let polished = try await loadDoc(id)
        XCTAssertEqual(polished.paragraphs.map(\.text), ["So we decided to use Postgres for the events table.", "Bob will write the migration this week."])
        XCTAssertEqual(polished.originalParagraphs?.map(\.text), doc.paragraphs.map(\.text))
        XCTAssertEqual(try XCTUnwrap(manager.record(id: id)).transcription, twoBlocks, "the original is never rewritten")
        // the segments the polish bar reads now report something to undo
        XCTAssertTrue(polished.segments.contains { $0.isPolished })

        await controller.undo(meetingID: id, segments: polished.segments)
        let undone = try await loadDoc(id)
        XCTAssertEqual(undone.paragraphs.map(\.text), doc.paragraphs.map(\.text))
        XCTAssertNil(undone.originalParagraphs)
    }

    func testALateResultNeverOverwritesNewerText() async throws {
        let (manager, controller) = store()
        let id = try await save(twoBlocks, in: manager)
        let doc = try await loadDoc(id)
        let provider = fakeProvider(["Polished one.", "Polished two."])

        // The text changes (a re-transcription) after the polish was started on the old text.
        let task = controller.start(meetingID: id, segments: doc.segments, languageName: nil, provider: provider)
        try await manager.retranscribe(try XCTUnwrap(manager.record(id: id)), newText: "Something entirely different now.", language: "en", modelUsed: "m")
        await task?.value

        let current = try await loadDoc(id)
        XCTAssertEqual(current.fullText, "Something entirely different now.")
        XCTAssertNil(current.originalParagraphs, "the stale polish was not written")
    }

    func testPolishAppliesToAnImportedFileToo() async throws {
        let (manager, controller) = store()
        let id = try await save(twoBlocks, in: manager, kind: "file")
        let doc = try await loadDoc(id)
        XCTAssertEqual(doc.kind, .file)
        await controller.start(meetingID: id, segments: doc.segments, languageName: nil,
                               provider: fakeProvider(["So we decided to use Postgres for the events table.", "Bob will write the migration this week."]))?.value
        let polished = try await loadDoc(id)
        XCTAssertEqual(polished.paragraphs.first?.text, "So we decided to use Postgres for the events table.")
        XCTAssertEqual(polished.kind, .file)
    }

    func testTitleAndSummaryRouteToTheHistoryStoreWithoutMeetingSections() async throws {
        let (manager, _) = store()
        let id = try await save("A short thought about naming things.", in: manager)
        var summary = MeetingAISummary.empty
        summary.overview = "A thought about naming."
        summary.decisions = [DecisionItem(label: "D", text: "invented")]
        await RecordingResolver.persistSummary(id, summary)
        await RecordingResolver.setTitle(id, title: "Naming things", userEdited: false)
        let doc = try await loadDoc(id)
        XCTAssertEqual(doc.summary?.overview, "A thought about naming.")
        XCTAssertEqual(doc.summary?.decisions.count, 0, "a dictation has no decisions to invent")
        XCTAssertEqual(doc.title, "Naming things")
        let info = await RecordingResolver.titleInfo(id)
        XCTAssertEqual(info?.title, "Naming things")
    }

    func testCitationsRoundTripOnUntimedText() async throws {
        let (manager, _) = store()
        let long = (0..<30).map { "This is sentence number \($0) of the recording." }.joined(separator: " ")
        let id = try await save(long, in: manager)
        let doc = try await loadDoc(id)
        XCTAssertFalse(doc.hasTiming)
        XCTAssertGreaterThan(doc.paragraphs.count, 2)
        // The model is shown [Ns] keys; it cites the second paragraph by its key.
        let key = Int(doc.citationKeys[1])
        let chunks = await MeetingAIService.shared.parseCitations(from: "It says so. [\(key)s]", segments: doc.segments)
        let chunk = try XCTUnwrap(chunks.first)
        XCTAssertEqual(doc.paragraph(forCitationKey: chunk.startTimestamp)?.id, doc.paragraphs[1].id)
        XCTAssertNil(doc.paragraph(forCitationKey: chunk.startTimestamp)?.start, "no time is invented for it")
    }

    func testChatForADictationIsDurableAndScopedToTheRecording() async throws {
        let a = UUID(), b = UUID()
        await MeetingChatStore.shared.append(MeetingChatMessage(role: "user", text: "What did I say?"), meetingID: a)
        let forA = await MeetingChatStore.shared.load(meetingID: a)
        let forB = await MeetingChatStore.shared.load(meetingID: b)
        XCTAssertEqual(forA.map(\.text), ["What did I say?"])
        XCTAssertTrue(forB.isEmpty)
        await MeetingChatStore.shared.clear(meetingID: a)
    }
}
