//
//  RecordingsSearchTests.swift
//  WhispererTests
//
//  Search and chronology of the Recordings list: what a search finds (words, titles, file names, notes, other
//  scripts, characters JSON escapes), what it must not find (JSON field names), the passage shown for a hit,
//  newest-first order with ties and pinned rows, and the total shown in the header.
//

import CoreData
import XCTest
@testable import whisperer

final class RecordingSnippetTests: XCTestCase {
    func testJSONSpellingsIncludeTheEscapedForm() {
        XCTAssertEqual(RecordingSnippet.jsonSpellings(of: "budget"), ["budget"])
        XCTAssertEqual(RecordingSnippet.jsonSpellings(of: "TCP/IP"), ["TCP/IP", "TCP\\/IP"])
        XCTAssertEqual(RecordingSnippet.jsonSpellings(of: "say \"hi\""), ["say \"hi\"", "say \\\"hi\\\""])
    }

    func testContainsIgnoresCaseAndDiacritics() {
        XCTAssertTrue(RecordingSnippet.contains("A Café meeting", "cafe"))
        XCTAssertTrue(RecordingSnippet.contains("QUARTERLY budget", "quarterly BUDGET"))
        XCTAssertFalse(RecordingSnippet.contains("anything", ""))
    }

    func testAroundKeepsTheMatchAndMarksWhatWasCut() {
        let text = String(repeating: "lorem ipsum ", count: 20) + "the quarterly budget is approved" + String(repeating: " dolor sit", count: 20)
        let snippet = RecordingSnippet.around("quarterly budget", in: text)
        XCTAssertTrue(snippet.contains("quarterly budget"))
        XCTAssertTrue(snippet.hasPrefix("…") && snippet.hasSuffix("…"))
        XCTAssertLessThan(snippet.count, 130)
        XCTAssertEqual(RecordingSnippet.around("short", in: "a short one"), "a short one")
    }

    func testHighlightMarksEveryMatch() {
        let marked = RecordingSnippet.highlighted("Budget and more budget", query: "budget")
        XCTAssertEqual(marked.runs.filter { $0.backgroundColor != nil }.count, 2)
        XCTAssertEqual(RecordingSnippet.highlighted("nothing", query: nil).runs.filter { $0.backgroundColor != nil }.count, 0)
    }
}

final class RecordingListChronologyTests: XCTestCase {
    private func record(_ text: String, at date: Date, pinned: Bool = false, id: UUID = UUID()) -> TranscriptionRecord {
        var record = TranscriptionRecord(id: id, transcription: text, audioFileURL: nil, duration: 5, language: "en", modelUsed: "m", targetAppName: "Cursor")
        record.timestamp = date
        record.isPinned = pinned
        return record
    }

    func testOrderIsStrictlyNewestFirstAndPinnedRowsDoNotJump() {
        let now = Date()
        let rows = [record("oldest pinned", at: now.addingTimeInterval(-300), pinned: true),
                    record("newest", at: now), record("middle", at: now.addingTimeInterval(-100))]
        let out = RecordingListBuilder.build(.init(transcriptions: rows, meetings: [], historyHasMore: false, meetingsHaveMore: false))
        XCTAssertEqual(out.items.map(\.title), ["newest", "middle", "oldest pinned"])
        XCTAssertTrue(out.items.last?.isPinned == true)
    }

    func testEqualDatesKeepOneOrderWhateverTheInputOrder() {
        let date = Date()
        let a = record("alpha one two three four five six seven eight nine", at: date, id: UUID())
        let b = record("bravo one two three four five six seven eight nine", at: date, id: UUID())
        let forward = RecordingListBuilder.build(.init(transcriptions: [a, b], meetings: [], historyHasMore: false, meetingsHaveMore: false))
        let backward = RecordingListBuilder.build(.init(transcriptions: [b, a], meetings: [], historyHasMore: false, meetingsHaveMore: false))
        XCTAssertEqual(forward.items.map(\.id), backward.items.map(\.id))
    }

}

@MainActor
final class RecordingsSearchFlowTests: XCTestCase {
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

    private func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !condition() { try? await Task.sleep(nanoseconds: 40_000_000) }
    }

    @discardableResult
    private func dictation(_ text: String, app: String? = "Cursor", kind: String? = nil, file: String? = nil, at date: Date = Date()) async throws -> UUID {
        let record = TranscriptionRecord(transcription: text, audioFileURL: nil, duration: 5, language: "en", modelUsed: "m",
                                         targetAppName: app, sourceKind: kind, sourceFileName: file)
        try await history.saveTranscription(record)
        history.update(id: record.id) { $0.timestamp = date }
        return record.id
    }

    @discardableResult
    private func meeting(_ title: String, texts: [String], notes: [String] = [], at date: Date = Date()) async -> UUID {
        let id = UUID()
        let ctx = database.newBackgroundContext()
        await ctx.perform {
            let entity = MeetingEntity(context: ctx)
            entity.id = id
            entity.title = title
            entity.createdAt = date
            entity.duration = 60
            entity.language = "en"
            entity.modelUsed = "m"
            entity.isInProgress = false
            let segments = texts.enumerated().map { MeetingSegment(timestamp: Double($0.offset) * 5, endTimestamp: Double($0.offset) * 5 + 4, text: $0.element) }
            entity.segmentsJSON = (try? JSONEncoder().encode(segments)).flatMap { String(data: $0, encoding: .utf8) }
            if !notes.isEmpty {
                entity.notesJSON = (try? JSONEncoder().encode(notes.map { MeetingNote(kind: .note, timestamp: -1, text: $0) })).flatMap { String(data: $0, encoding: .utf8) }
            }
            entity.wordCount = Int32(texts.joined(separator: " ").split(separator: " ").count)
            try? ctx.save()
        }
        return id
    }

    private func reload() async {
        await history.loadTranscriptions(filter: history.currentFilter, searchQuery: history.currentSearchQuery, kind: history.currentKindScope)
        await meetings.loadMeetings()
        await waitUntil(1) { false }
    }

    private func search(_ text: String) async {
        model.searchText = text
        await waitUntil(3) { false }
        await waitUntil(5) { !self.model.items.isEmpty || text.isEmpty }
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    // MARK: Meetings

    func testSearchingAFieldNameOfTheStoredJSONFindsNothing() async throws {
        await meeting("Standup", texts: ["we shipped the release", "ok"])
        await reload()
        for word in ["speaker", "speakerName", "timestamp", "endTimestamp", "tags", "text"] {
            await search(word)
            XCTAssertTrue(model.items.isEmpty, "\"\(word)\" is a JSON key, not something anyone said")
        }
        await search("shipped")
        XCTAssertEqual(model.items.count, 1)
    }

    func testCharactersJSONEscapesStillMatch() async throws {
        await meeting("Networking", texts: ["we talked about TCP/IP and \"zero trust\" today"])
        await reload()
        await search("TCP/IP")
        XCTAssertEqual(model.items.count, 1, "a slash is stored as \\/")
        await search("\"zero trust\"")
        XCTAssertEqual(model.items.count, 1)
    }

    func testDiacriticsAndOtherScriptsMatch() async throws {
        await meeting("Planning", texts: ["שלום לכולם ברוכים הבאים"])
        try await dictation("A Café planning session about résumé screening")
        await reload()
        await search("שלום")
        XCTAssertEqual(model.items.map(\.kind), [.meeting])
        await search("cafe")
        XCTAssertEqual(model.items.map(\.kind), [.dictation])
        await search("RESUME")
        XCTAssertEqual(model.items.count, 1)
    }

    func testMeetingNotesAreSearchedAndTheHitShowsThePassage() async throws {
        await meeting("Roadmap", texts: ["hello everyone"], notes: ["remember the compliance deadline in March"])
        await reload()
        await search("compliance deadline")
        XCTAssertEqual(model.items.count, 1)
        XCTAssertTrue(model.items.first?.preview.contains("compliance deadline") == true, "the row shows what matched: \(model.items.first?.preview ?? "")")
    }

    // MARK: Dictations and files

    func testTitleFileNameAndAppAreSearchable() async throws {
        let titled = try await dictation("some words nobody will search for", app: "Slack")
        history.setTitle(id: titled, "Quarterly budget")
        try await dictation("an interview transcript", app: nil, kind: "file", file: "pricing-call.m4a")
        try await dictation("note to self", app: "Cursor")
        await reload()
        await search("quarterly budget")
        XCTAssertEqual(model.items.map(\.id), [.dictation(titled)])
        await search("pricing-call")
        XCTAssertEqual(model.items.first?.kind, .file)
        await search("cursor")
        XCTAssertEqual(model.items.count, 1)
    }

    func testWhitespaceOnlyOrPaddedQueriesBehave() async throws {
        try await dictation("remember the milk")
        try await dictation("buy bread")
        await reload()
        await search("   ")
        XCTAssertEqual(model.items.count, 2, "a blank search is no search")
        await search("  milk  ")
        XCTAssertEqual(model.items.count, 1)
    }

    func testTypingFastEndsWithThePlainResultsOfTheLastQuery() async throws {
        await meeting("Alpha review", texts: ["alpha one"], at: Date())
        await meeting("Beta review", texts: ["beta two"], at: Date().addingTimeInterval(-60))
        try await dictation("alpha dictation", at: Date().addingTimeInterval(-120))
        try await dictation("gamma dictation", at: Date().addingTimeInterval(-180))
        await reload()
        for query in ["a", "al", "alp", "alph", "alpha"] { model.searchText = query }
        await waitUntil(5) { false }
        await waitUntil { self.model.items.count == 2 }
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(Set(model.items.map(\.kind)), [.meeting, .dictation])
        XCTAssertEqual(model.items.count, 2)
        XCTAssertTrue(model.items.allSatisfy { $0.title.lowercased().contains("alpha") || $0.preview.lowercased().contains("alpha") })
    }

    // MARK: Order and totals

    func testRowsWithTheSameTimestampPageWithoutLossOrRepeat() async throws {
        let stamp = Date()
        for i in 0..<130 { try await dictation("same moment \(i)", at: stamp) }
        await reload()
        var guardRail = 0
        while history.hasMorePages, guardRail < 10 { guardRail += 1; await history.loadNextPage() }
        XCTAssertEqual(history.transcriptions.count, 130)
        XCTAssertEqual(Set(history.transcriptions.map(\.id)).count, 130, "no row twice across page boundaries")
    }

    func testHeaderTotalIsTheLibraryNotTheLoadedPages() async throws {
        let now = Date()
        for i in 0..<120 { try await dictation("dictation number \(i)", at: now.addingTimeInterval(-Double(i) * 60)) }
        for i in 0..<5 { try await dictation("import \(i)", app: nil, kind: "file", file: "f\(i).m4a", at: now.addingTimeInterval(-Double(i) * 60 - 30)) }
        for i in 0..<3 { await meeting("Meeting \(i)", texts: ["words"], at: now.addingTimeInterval(-Double(i) * 3600)) }
        await reload()
        await waitUntil { self.model.totalCount == 128 }
        XCTAssertEqual(model.totalCount, 128, "only the first page is loaded, the count is the library")

        model.kindFilter = .files
        await waitUntil { self.model.totalCount == 5 }
        XCTAssertEqual(model.totalCount, 5)
        model.kindFilter = .meetings
        await waitUntil { self.model.totalCount == 3 }
        XCTAssertEqual(model.totalCount, 3)
        model.kindFilter = .all
        await search("number 7")
        XCTAssertEqual(model.totalCount, model.items.count)
    }
}
