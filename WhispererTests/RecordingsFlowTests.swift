//
//  RecordingsFlowTests.swift
//  WhispererTests
//
//  What the user sees in Recordings after each kind of processing finishes, against real (in-memory)
//  stores: a dictation, a streamed dictation, an imported file (new and legacy rows) and a meeting all
//  appear exactly once with the model that produced them; paging never leaves a gap; search, filters and
//  deletion behave; and another part of the app reloading the store cannot silently change the list.
//

import CoreData
import XCTest
@testable import whisperer

@MainActor
final class RecordingsFlowTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    private var database: HistoryDatabase!
    private var history: HistoryManager!
    private var meetings: MeetingManager!
    private var model: RecordingsWorkspaceModel!

    override func setUp() async throws {
        database = HistoryDatabase(inMemory: true)
        history = HistoryManager(database: database)
        meetings = MeetingManager(database: database)
        RecordingResolver.historyOverride = history
        model = RecordingsWorkspaceModel(history: history, meetings: meetings)
        Self.keepAlive += [database, history, meetings, model]
        await history.loadTranscriptions()
        await meetings.loadMeetings()
    }

    override func tearDown() async throws { RecordingResolver.historyOverride = nil }

    // MARK: Helpers

    private func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !condition() { try? await Task.sleep(nanoseconds: 40_000_000) }
    }

    @discardableResult
    private func dictation(_ text: String, model modelName: String = "Whisperer V3", app: String? = "Cursor",
                           kind: String? = nil, at date: Date? = nil) async throws -> UUID {
        let record = TranscriptionRecord(transcription: text, audioFileURL: nil, duration: 12, language: "en", modelUsed: modelName,
                                         targetAppName: app, sourceKind: kind, sourceFileName: kind == "file" ? "talk.m4a" : nil)
        try await history.saveTranscription(record)
        if let date { history.update(id: record.id) { $0.timestamp = date } }
        return record.id
    }

    /// A meeting row written straight into the store with a chosen date.
    @discardableResult
    private func meeting(_ title: String, words: String = "hello", at date: Date, pinned: Bool = false, inProgress: Bool = false) async -> UUID {
        let id = UUID()
        let ctx = database.newBackgroundContext()
        await ctx.perform {
            let entity = MeetingEntity(context: ctx)
            entity.id = id
            entity.title = title
            entity.createdAt = date
            entity.duration = 60
            entity.language = "en"
            entity.modelUsed = "Nemotron Multilingual"
            entity.isInProgress = inProgress
            entity.isPinned = pinned
            let segment = MeetingSegment(timestamp: 0, endTimestamp: 5, text: words)
            entity.segmentsJSON = (try? JSONEncoder().encode([segment])).flatMap { String(data: $0, encoding: .utf8) }
            entity.wordCount = Int32(words.split(separator: " ").count)
            try? ctx.save()
        }
        return id
    }

    private func refresh() async {
        await history.loadTranscriptions(filter: history.currentFilter, searchQuery: history.currentSearchQuery, kind: history.currentKindScope)
        await meetings.loadMeetings()
        await waitUntil(1) { false }
    }

    // MARK: Each kind of processing shows up, once, with its model

    func testDictationFileLegacyFileAndMeetingAllAppearOnceWithTheirModel() async throws {
        let d = try await dictation("Buy milk and call the plumber about the sink please", model: "Whisperer V3")
        let f = try await dictation("A recorded interview about pricing", model: "Parakeet v3", app: nil, kind: "file")
        let legacy = try await dictation("An old import saved before sourceKind existed", app: "File Import")
        let m = await meeting("Weekly sync", words: "we agreed to ship on friday", at: Date())
        await refresh()
        await waitUntil { self.model.items.count == 4 }

        XCTAssertEqual(model.items.count, 4)
        XCTAssertEqual(Set(model.items.map(\.id)).count, 4, "no row twice")
        XCTAssertEqual(model.items.first { $0.id == .dictation(d) }?.kind, .dictation)
        XCTAssertEqual(model.items.first { $0.id == .dictation(f) }?.kind, .file)
        XCTAssertEqual(model.items.first { $0.id == .dictation(legacy) }?.kind, .file, "a pre-sourceKind import is still a file")
        XCTAssertEqual(model.items.first { $0.id == .meeting(m) }?.kind, .meeting)

        // Each opens with the model that produced it.
        let dictDoc = try XCTUnwrap(RecordingResolver.historyOverride?.record(id: d)).modelUsed
        XCTAssertEqual(dictDoc, "Whisperer V3")
        XCTAssertEqual(try XCTUnwrap(history.record(id: f)).modelUsed, "Parakeet v3")
        let loadedMeeting = await meetings.meeting(id: m)
        let meetingRecord = try XCTUnwrap(loadedMeeting)
        XCTAssertEqual(TranscriptDocument(meeting: meetingRecord).model, "Nemotron Multilingual")
        XCTAssertEqual(TranscriptDocument(transcription: try XCTUnwrap(history.record(id: f))).model, "Parakeet v3")
    }

    func testAStreamedDictationIsHiddenWhileEmptyAndListedOnceWhenFinished() async throws {
        let sessionID = await history.beginSession(audioFileURL: URL(fileURLWithPath: "/tmp/session.opus"), language: "en", modelUsed: "Whisperer V3")
        await history.loadTranscriptions()        // the window becoming key reloads the store mid-session
        await waitUntil(1) { false }
        XCTAssertTrue(model.items.isEmpty, "an empty in-flight dictation must not appear as an 'Untitled recording'")

        await history.appendChunk(sessionID: sessionID, chunkText: "first thought", totalDuration: 4)
        try await history.finalizeSession(sessionID: sessionID, finalText: "first thought and the rest of it", duration: 9)
        await waitUntil { self.model.items.count == 1 }
        XCTAssertEqual(model.items.map(\.id), [.dictation(sessionID)])
        XCTAssertEqual(model.items.first?.duration ?? 0, 9, accuracy: 0.01)
    }

    func testAMeetingShowsAsRecordingThenAsFinished() async throws {
        let id = await meetings.beginSession(title: "Live call", language: "en", modelUsed: "Nemotron Multilingual")
        await waitUntil { self.model.items.contains { $0.id == .meeting(id) } }
        XCTAssertEqual(model.items.first?.isInProgress, true)

        await meetings.appendSegment(meetingID: id, segment: MeetingSegment(timestamp: 0, endTimestamp: 4, text: "hello team"), duration: 4)
        await meetings.finalizeSession(meetingID: id, duration: 30, audioFileURL: nil)
        await waitUntil { self.model.items.first?.isInProgress == false }
        XCTAssertEqual(model.items.filter { $0.id == .meeting(id) }.count, 1)
        XCTAssertEqual(model.items.first?.isInProgress, false)
        XCTAssertEqual(model.items.first?.duration ?? 0, 30, accuracy: 0.01)
    }

    // MARK: Paging

    func testPagingNeverLeavesAGapAndEndsWithEveryRowExactlyOnce() async throws {
        let now = Date()
        for i in 0..<120 { try await dictation("dictation number \(i) with some words", at: now.addingTimeInterval(-Double(i) * 3600)) }
        // meetings every 7 hours: some are older than the 50th dictation, which is the newest page's end
        for i in 0..<14 { await meeting("Meeting \(i)", at: now.addingTimeInterval(-Double(i) * 7 * 3600 - 1800)) }
        await refresh()
        await waitUntil { !self.model.items.isEmpty }

        func assertNoGap(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
            let dates = model.items.map(\.date)
            XCTAssertEqual(dates, dates.sorted(by: >), "\(context): newest first", file: file, line: line)
            // Every dictation between the newest and the oldest row on screen is present: no holes.
            let shownDictations = model.items.filter { $0.kind == .dictation }
            if let oldest = shownDictations.map(\.date).min() {
                let expected = (0..<120).filter { now.addingTimeInterval(-Double($0) * 3600) >= oldest }.count
                XCTAssertEqual(shownDictations.count, expected, "\(context): a dictation is missing from the middle", file: file, line: line)
            }
            if let oldest = model.items.map(\.date).min() {
                let meetingsOnScreen = model.items.filter { $0.kind == .meeting }.count
                let expectedMeetings = (0..<14).filter { now.addingTimeInterval(-Double($0) * 7 * 3600 - 1800) >= oldest }.count
                XCTAssertEqual(meetingsOnScreen, expectedMeetings, "\(context): a meeting is missing from the middle", file: file, line: line)
            }
        }

        assertNoGap("first page")
        XCTAssertLessThan(model.items.count, 134, "older rows wait for their page")
        for round in 1...12 {
            guard let last = model.items.last else { break }
            model.loadMoreIfNeeded(after: last)
            await waitUntil(2) { false }
            assertNoGap("after page \(round)")
        }
        XCTAssertEqual(model.items.count, 134)
        XCTAssertEqual(Set(model.items.map(\.id)).count, 134)
    }

    // MARK: Filters and search

    func testFilesFilterFindsOldFilesBeyondTheFirstPageOfDictations() async throws {
        let now = Date()
        for i in 0..<90 { try await dictation("plain dictation \(i)", at: now.addingTimeInterval(-Double(i) * 60)) }
        for i in 0..<3 { try await dictation("imported talk \(i)", app: nil, kind: "file", at: now.addingTimeInterval(-Double(200 + i) * 3600)) }
        try await dictation("legacy import row", app: "File Import", at: now.addingTimeInterval(-300 * 3600))
        await refresh()

        model.kindFilter = .files
        await waitUntil { self.model.items.count == 4 }
        XCTAssertEqual(model.items.count, 4)
        XCTAssertTrue(model.items.allSatisfy { $0.kind == .file })

        model.kindFilter = .dictation
        await waitUntil { self.model.items.allSatisfy { $0.kind == .dictation } && self.model.items.count >= 30 }
        XCTAssertTrue(model.items.allSatisfy { $0.kind == .dictation }, "files never leak into the dictation tab")
    }

    func testSearchCoversDictationsAndMeetingTranscriptsAndSurvivesTheWindowReloadingTheStore() async throws {
        let now = Date()
        try await dictation("remember the quarterly budget review", at: now)
        try await dictation("something unrelated entirely", at: now.addingTimeInterval(-60))
        await meeting("Planning", words: "the quarterly budget is approved", at: now.addingTimeInterval(-120))
        await meeting("Standup", words: "nothing to see", at: now.addingTimeInterval(-180))
        await refresh()
        await waitUntil { self.model.items.count == 4 }

        model.searchText = "quarterly budget"
        await waitUntil { self.model.items.count == 2 }
        XCTAssertEqual(Set(model.items.map(\.kind)), [.dictation, .meeting])

        // The history window reloads the store with no filter every time it becomes key.
        await history.loadTranscriptions()
        await waitUntil { self.history.currentSearchQuery == "quarterly budget" }
        await waitUntil(2) { self.model.items.count == 2 }
        XCTAssertEqual(model.items.count, 2, "the list must keep showing what the search box says")

        model.searchText = ""
        await waitUntil { self.model.items.count == 4 }
        XCTAssertEqual(model.items.count, 4)
    }

    func testPinnedFilterListsPinnedDictationsAndMeetingsTogether() async throws {
        let now = Date()
        let pinnedDictation = try await dictation("pinned thought", at: now)
        try await dictation("normal thought", at: now.addingTimeInterval(-60))
        history.setPinned(id: pinnedDictation, true)
        let pinnedMeeting = await meeting("Pinned call", at: now.addingTimeInterval(-120), pinned: true)
        await meeting("Other call", at: now.addingTimeInterval(-180))
        await refresh()
        await waitUntil { self.model.items.count == 4 }

        model.markFilter = .pinned
        await waitUntil { self.model.items.count == 2 }
        XCTAssertEqual(Set(model.items.map(\.id)), [.dictation(pinnedDictation), .meeting(pinnedMeeting)])
    }

    // MARK: Selection

    func testSelectionStaysOnAFilteredOutRecordingAndMovesToANeighbourOnDelete() async throws {
        let now = Date()
        let a = try await dictation("alpha recording", at: now)
        let b = try await dictation("bravo recording", at: now.addingTimeInterval(-60))
        let c = try await dictation("charlie recording", at: now.addingTimeInterval(-120))
        await refresh()
        await waitUntil { self.model.items.count == 3 }

        model.selectedID = .dictation(b)
        model.searchText = "alpha"
        await waitUntil { self.model.items.count == 1 }
        XCTAssertEqual(model.selectedID, .dictation(b), "searching must not blank or change the open recording")

        model.searchText = ""
        await waitUntil { self.model.items.count == 3 }
        await model.delete(.dictation(b))
        XCTAssertEqual(model.selectedID, .dictation(c), "delete moves to the next older recording")
        await waitUntil { self.model.items.count == 2 }
        XCTAssertEqual(model.items.map(\.id), [.dictation(a), .dictation(c)])
    }

    func testOpeningARecordingThatTheFilterHidesClearsTheFilter() async throws {
        let m = await meeting("Call", at: Date())
        try await dictation("a dictation", at: Date().addingTimeInterval(-60))
        await refresh()
        model.kindFilter = .dictation
        await waitUntil { self.model.items.allSatisfy { $0.kind == .dictation } }
        model.open(.meeting(m))
        XCTAssertEqual(model.kindFilter, .all)
        XCTAssertEqual(model.selectedID, .meeting(m))
    }
}

// MARK: - New recording and import round trip

@MainActor
final class RecordingsNewRecordingTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    func testMeetingAndDictationBlockersExplainWhyAndClearWhenIdle() {
        let session = MeetingSession()
        Self.keepAlive.append(session)
        XCTAssertNil(RecordingStarter.meetingBlocker(session: session))
        session.isRecording = true
        XCTAssertEqual(RecordingStarter.meetingBlocker(session: session), "A meeting is already being recorded.")
        XCTAssertEqual(RecordingStarter.dictationBlocker(session: session), "A meeting is being recorded.")
        session.isRecording = false
    }

    func testDefaultMeetingTitleIsTheOldNoteTitle() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(RecordingStarter.defaultMeetingTitle(now: date).hasPrefix("Note "))
    }

    func testImportRoundTripOpensTheNewRecordingAndLeavesTheImportView() async throws {
        let database = HistoryDatabase(inMemory: true)
        let history = HistoryManager(database: database)
        let meetings = MeetingManager(database: database)
        let model = RecordingsWorkspaceModel(history: history, meetings: meetings)
        Self.keepAlive += [database, history, meetings, model]
        let record = TranscriptionRecord(transcription: "An imported talk about pricing", audioFileURL: nil, duration: 60, language: "en",
                                         modelUsed: "Whisperer V3", targetAppName: "File Import", sourceKind: "file", sourceFileName: "talk.m4a")
        model.isImporting = true
        model.selectFirstIfNeeded()
        XCTAssertNil(model.selectedID, "nothing is auto-selected behind the import flow")

        try await history.saveTranscription(record)
        model.open(.dictation(record.id))      // what RecordingImportView does when the import is saved
        XCTAssertFalse(model.isImporting)
        XCTAssertEqual(model.selectedID, .dictation(record.id))
        let end = Date().addingTimeInterval(3)
        while Date() < end, !model.items.contains(where: { $0.id == .dictation(record.id) }) { try? await Task.sleep(nanoseconds: 40_000_000) }
        XCTAssertEqual(model.items.filter { $0.id == .dictation(record.id) }.count, 1, "exactly one row for the imported file")
        XCTAssertEqual(model.items.first?.kind, .file)
    }
}
