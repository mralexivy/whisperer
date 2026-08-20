//
//  MeetingRecordEqualityTests.swift
//  WhispererTests
//
//  `MeetingRecord` is the value SwiftUI diffs to decide whether a meeting view needs to be
//  re-rendered — `MeetingOverviewView` takes one as its only non-@State property. An `==`
//  that ignores a field therefore does not just misreport equality: it silently freezes
//  every view rendering that field.
//
//  The shipped bug: `==` compared only id / audioFileURL / isInProgress, so the record
//  refreshed after the LLM overview landed compared equal to the one without it. The
//  Overview tab stayed on its empty state until the tab was switched away and back, which
//  rebuilt the view from scratch.
//

import XCTest
@testable import whisperer

final class MeetingRecordEqualityTests: XCTestCase {

    private func makeRecord() -> MeetingRecord {
        MeetingRecord(id: UUID(), title: "Untitled", language: "en", modelUsed: "large-v3")
    }

    private func makeSummary(overview: String = "We picked Postgres.") -> MeetingAISummary {
        MeetingAISummary(overview: overview,
                         keyTopics: [TopicItem(text: "Storage", timestampSeconds: 30)],
                         decisions: [],
                         openQuestions: [],
                         nextMeeting: nil,
                         actionItems: [],
                         generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// The regression itself.
    func testArrivalOfAISummaryBreaksEquality() {
        let before = makeRecord()
        var after = before
        after.aiSummary = makeSummary()

        XCTAssertNotEqual(before, after,
                          "A record that gained an AI summary must not compare equal — SwiftUI skips the re-render otherwise")
    }

    /// A regenerated overview replaces an existing one; same shape, different text.
    func testRegeneratedSummaryBreaksEquality() {
        var before = makeRecord()
        before.aiSummary = makeSummary(overview: "First take.")
        var after = before
        after.aiSummary = makeSummary(overview: "Second take.")

        XCTAssertNotEqual(before, after)
    }

    func testTitleChangeBreaksEquality() {
        let before = makeRecord()
        var after = before
        after.title = "Events table database choice"

        XCTAssertNotEqual(before, after)
    }

    func testPolishedSegmentTextBreaksEquality() {
        var before = makeRecord()
        before.segments = [MeetingSegment(timestamp: 0, endTimestamp: 4, text: "we picked postgres")]
        var after = before
        after.segments[0].text = "We picked Postgres."

        XCTAssertNotEqual(before, after)
    }

    func testNoteEditBreaksEquality() {
        var before = makeRecord()
        before.notes = [MeetingNote(kind: .decision, timestamp: 12, text: "")]
        var after = before
        after.notes[0].text = "Postgres for the events table"

        XCTAssertNotEqual(before, after)
    }

    /// The other half of the contract: an unchanged record must still compare equal, or every
    /// diff pass re-renders the whole meeting surface.
    func testUnchangedRecordsCompareEqual() {
        var before = makeRecord()
        before.segments = [MeetingSegment(timestamp: 0, endTimestamp: 4, text: "we picked postgres")]
        before.aiSummary = makeSummary()
        let after = before

        XCTAssertEqual(before, after)
    }
}
