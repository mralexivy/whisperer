//
//  MCPMeetingToolsTests.swift
//  WhispererTests
//
//  The meeting MCP tools built for long meetings and agent collaboration: transcript paging
//  by budget / time / speaker, search across transcript and notes, the note write rules
//  (AI apps change only their own notes), and notes reaching Ask AI.
//

import MCP
import XCTest
@testable import whisperer

final class MCPMeetingToolsTests: XCTestCase {

    private func seg(_ t: Double, _ speaker: String, _ text: String) -> MeetingSegment {
        MeetingSegment(timestamp: t, endTimestamp: t + 5, text: text, speakerName: speaker)
    }

    private lazy var long: [MeetingSegment] = (0..<2_000).map { i in
        seg(Double(i * 6), i % 2 == 0 ? "Dana" : "Bob", "Line \(i) about the roadmap, the budget and the hiring plan for next quarter.")
    }

    // MARK: Paging

    func testPageRespectsBudgetAndCursor() {
        let first = MCPMeetingTools.page(long, cursor: 0, from: nil, to: nil, speaker: nil, maxChars: 2_000)
        XCTAssertLessThanOrEqual(first.lines.joined(separator: "\n").count, 2_000)
        XCTAssertEqual(first.lines.first, "[0:00] Dana: Line 0 about the roadmap, the budget and the hiring plan for next quarter.")
        let next = try! XCTUnwrap(first.nextCursor)
        let second = MCPMeetingTools.page(long, cursor: next, from: nil, to: nil, speaker: nil, maxChars: 2_000)
        XCTAssertTrue(second.lines.first?.contains("Line \(next) ") == true, "the next page starts where the last ended")
    }

    func testPagingCoversEverythingExactlyOnce() {
        var cursor: Int? = 0
        var seen = 0
        var pages = 0
        while let c = cursor {
            let p = MCPMeetingTools.page(long, cursor: c, from: nil, to: nil, speaker: nil, maxChars: 12_000)
            seen += p.lines.count
            cursor = p.nextCursor
            pages += 1
        }
        XCTAssertEqual(seen, long.count)
        XCTAssertGreaterThan(pages, 5, "a long meeting comes in pages, not one dump")
    }

    func testTimeWindowAndSpeakerFilters() {
        let window = MCPMeetingTools.page(long, cursor: 0, from: 600, to: 660, speaker: nil, maxChars: 60_000)
        XCTAssertEqual(window.lines.count, 10)
        XCTAssertNil(window.nextCursor, "a window ends at to_seconds")
        XCTAssertTrue(window.lines.first?.hasPrefix("[10:00]") == true)
        let bob = MCPMeetingTools.page(long, cursor: 0, from: 0, to: 120, speaker: "bob", maxChars: 60_000)
        XCTAssertTrue(bob.lines.allSatisfy { $0.contains("] Bob: ") })
    }

    func testClockFormatsHours() {
        XCTAssertEqual(MCPMeetingTools.clock(75), "1:15")
        XCTAssertEqual(MCPMeetingTools.clock(3_725), "1:02:05")
    }

    func testTranscriptInfoInsteadOfDump() {
        let info = MCPMeetingTools.transcriptInfo(long)
        XCTAssertEqual(info["segments"] as? Int, 2_000)
        XCTAssertEqual(info["speakers"] as? [String], ["Dana", "Bob"])
        XCTAssertNotNil(info["hint"])
    }

    // MARK: Search

    private func meeting(_ segments: [MeetingSegment], notes: [MeetingNote] = []) -> MCPMeetingTools.Loaded {
        .init(id: UUID(), title: "Planning", createdAt: Date(), duration: 600, wordCount: 100, language: "en",
              isInProgress: false, segments: segments, summary: nil, notes: notes)
    }

    func testSearchRanksPhraseAndIncludesNotes() {
        let m = meeting([seg(10, "Dana", "We talked about the budget."),
                         seg(20, "Bob", "The hiring budget is frozen until March."),
                         seg(30, "Dana", "Lunch?")],
                        notes: [MeetingNote(kind: .note, timestamp: -1, text: "Hiring budget needs CFO sign-off", author: "Claude")])
        let terms = MCPMeetingTools.terms("hiring budget")
        let hits = MCPMeetingTools.search(in: m, terms: terms, phrase: terms.joined(separator: " "))
            .sorted { $0.score > $1.score }
        XCTAssertEqual(hits.count, 3, "two transcript lines and the note")
        XCTAssertTrue(hits.first?.isNote == true || hits.first?.seconds == 20)
        XCTAssertTrue(hits.contains { $0.isNote && $0.speaker == "Claude" })
        XCTAssertFalse(hits.contains { $0.snippet == "Lunch?" })
    }

    func testSearchIsDiacriticAndCaseInsensitive() {
        let m = meeting([seg(0, "A", "Café opening in MÜNCHEN")])
        let t = MCPMeetingTools.terms("cafe munchen")
        XCTAssertEqual(MCPMeetingTools.search(in: m, terms: t, phrase: t.joined(separator: " ")).count, 1)
    }

    func testSnippetCentersOnMatch() {
        let text = String(repeating: "filler ", count: 80) + "the decisive budget number" + String(repeating: " filler", count: 80)
        let s = MCPMeetingTools.snippet(text, around: ["budget"])
        XCTAssertTrue(s.contains("budget"))
        XCTAssertTrue(s.hasPrefix("…") && s.hasSuffix("…"))
        XCTAssertLessThan(s.count, 260)
    }

    // MARK: Notes

    func testAIAppsCanOnlyChangeTheirOwnNotes() throws {
        let mine = MeetingNote(kind: .decision, timestamp: 30, text: "Ship Friday")
        let theirs = MeetingNote(kind: .note, timestamp: -1, text: "Risk: QA", author: "Codex")
        let notes = [mine, theirs]

        XCTAssertThrowsError(try MeetingNotesService.applyUpdate(notes, noteID: mine.id, text: "x", kind: nil, asAuthor: "mcp")) {
            XCTAssertEqual($0 as? MeetingNotesService.Failure, .notEditable)
        }
        XCTAssertThrowsError(try MeetingNotesService.applyDelete(notes, noteID: mine.id, asAuthor: "mcp"))
        let updated = try MeetingNotesService.applyUpdate(notes, noteID: theirs.id, text: "Risk: QA slips", kind: .risk, asAuthor: "mcp")
        XCTAssertEqual(updated[1].text, "Risk: QA slips")
        XCTAssertEqual(updated[1].kind, .risk)
        XCTAssertEqual(try MeetingNotesService.applyDelete(notes, noteID: theirs.id, asAuthor: "mcp").count, 1)
        // The user may change anything.
        XCTAssertEqual(try MeetingNotesService.applyUpdate(notes, noteID: mine.id, text: "Ship Monday", kind: nil, asAuthor: nil)[0].text,
                       "Ship Monday")
        XCTAssertThrowsError(try MeetingNotesService.applyDelete(notes, noteID: UUID(), asAuthor: nil)) {
            XCTAssertEqual($0 as? MeetingNotesService.Failure, .noteNotFound)
        }
    }

    func testOldNotesStillDecode() throws {
        let legacy = #"[{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","kind":"IDEA","timestamp":12,"text":"old"}]"#
        let notes = try JSONDecoder().decode([MeetingNote].self, from: Data(legacy.utf8))
        XCTAssertEqual(notes.first?.text, "old")
        XCTAssertNil(notes.first?.author)
        XCTAssertFalse(notes.first!.isByAI)
    }

    func testNoteJSONAndAuthorCleanup() {
        let n = MeetingNote(kind: .risk, timestamp: -1, text: "t", author: "Claude")
        let json = MCPMeetingTools.noteJSON(n)
        XCTAssertEqual(json["kind"] as? String, "risk")
        XCTAssertEqual(json["seconds"] as? Int, -1)
        XCTAssertEqual(json["at"] as? String, "whole meeting")
        XCTAssertEqual(MCPMeetingTools.cleanAuthor("  "), "AI assistant")
        XCTAssertEqual(MCPMeetingTools.cleanAuthor(String(repeating: "x", count: 80)), "AI assistant")
        XCTAssertEqual(MCPMeetingTools.cleanAuthor(" Codex "), "Codex")
    }

    func testNotesReachAskAI() {
        let block = MeetingAIService.notesBlock([
            MeetingNote(kind: .decision, timestamp: 95, text: "Postgres it is"),
            MeetingNote(kind: .note, timestamp: -1, text: "Follow up with finance", author: "Claude"),
            MeetingNote(kind: .idea, timestamp: 10, text: "   "),
        ])
        XCTAssertEqual(block, """
        NOTES (written during or after the meeting by the user and their AI apps; treat them as context, not as transcript):
        [95s] User — DECISION: Postgres it is
        [whole meeting] Claude — NOTE: Follow up with finance
        """)
        XCTAssertNil(MeetingAIService.notesBlock([]))
    }

    func testAuthorMapsToProviderIcon() {
        XCTAssertEqual(AIProviderID.fromAuthor("Claude Code"), .claudeCode)
        XCTAssertEqual(AIProviderID.fromAuthor("codex-mcp-client"), .codex)
        XCTAssertEqual(AIProviderID.fromAuthor("ChatGPT"), .chatGPT)
        XCTAssertNil(AIProviderID.fromAuthor("Cursor"))
    }

    // MARK: Tool surface

    func testToolsAndAnnotations() async throws {
        let names = await MainActor.run { MCPMeetingTools.toolDefinitions.map(\.name) }
        for n in ["list_meetings", "get_meeting", "get_meeting_transcript", "search_meetings", "list_meeting_notes"] {
            XCTAssertTrue(names.contains(n), n)
        }
        if MCPNoteWrites.enabled {
            XCTAssertTrue(names.contains("add_meeting_note"))
        }
        XCTAssertEqual(MCPMeetingTools.writeToolNames, ["add_meeting_note", "update_meeting_note", "delete_meeting_note"])
    }

    func testToolErrorsAreClear() async throws {
        let missing = try await MCPMeetingTools.handle(name: "get_meeting_transcript", arguments: ["id": .string("nope")])
        XCTAssertEqual(missing?.isError, true)
        let unknown = try await MCPMeetingTools.handle(name: "add_meeting_note",
                                                       arguments: ["meeting_id": .string(UUID().uuidString), "text": .string("hi")])
        XCTAssertEqual(unknown?.isError, true, "adding to a meeting that doesn't exist fails, it does not create one")
    }
}
