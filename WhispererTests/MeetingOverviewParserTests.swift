//
//  MeetingOverviewParserTests.swift
//  WhispererTests
//
//  Unit tests for MeetingOverviewParser — the line-based parser for
//  LLM-generated meeting overviews.
//

import XCTest
@testable import whisperer

final class MeetingOverviewParserTests: XCTestCase {

    // MARK: - Basic parsing

    func testParsesMinimalOutput() {
        let raw = """
        OVERVIEW: The team reviewed the sprint backlog.
        NEXT: none
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.overview, "The team reviewed the sprint backlog.")
        XCTAssertTrue(result?.keyTopics.isEmpty ?? false)
        XCTAssertNil(result?.nextMeeting)
    }

    func testParsesFullOutput() {
        let raw = """
        OVERVIEW: The speaker demonstrated transcription issues and tested the system.
        TOPIC: Transcription experience | 9
        TOPIC: Voice capture quality | 28
        DECISION: Fix UX | Improve the transcription experience before release | 45
        OPEN: Why does the voice not change? | 28
        NEXT: Friday — continue testing
        ACTION: Review transcription code | Alex Ivy | 2026-08-15
        """
        guard let result = MeetingOverviewParser.parse(raw) else {
            XCTFail("parse returned nil"); return
        }
        XCTAssertFalse(result.overview.isEmpty)
        XCTAssertEqual(result.keyTopics.count, 2)
        XCTAssertEqual(result.keyTopics[0].text, "Transcription experience")
        XCTAssertEqual(result.keyTopics[0].timestampSeconds, 9)
        XCTAssertEqual(result.decisions.count, 1)
        XCTAssertEqual(result.decisions[0].label, "Fix UX")
        XCTAssertEqual(result.openQuestions.count, 1)
        XCTAssertEqual(result.nextMeeting, "Friday — continue testing")
        XCTAssertEqual(result.actionItems.count, 1)
        XCTAssertEqual(result.actionItems[0].ownerName, "Alex Ivy")
        XCTAssertEqual(result.actionItems[0].dueLabel, "2026-08-15")
    }

    func testNextMeetingNone() {
        let raw = """
        OVERVIEW: Short stand-up with no follow-up scheduled.
        NEXT: none
        """
        XCTAssertNil(MeetingOverviewParser.parse(raw)?.nextMeeting)
    }

    func testNextMeetingNoneVariant() {
        let raw = """
        OVERVIEW: Quick sync call.
        NEXT: None
        """
        XCTAssertNil(MeetingOverviewParser.parse(raw)?.nextMeeting)
    }

    func testNextMeetingPresent() {
        let raw = """
        OVERVIEW: Budget review meeting.
        NEXT: Next Tuesday 10am — review Q3 budget
        """
        XCTAssertEqual(MeetingOverviewParser.parse(raw)?.nextMeeting, "Next Tuesday 10am — review Q3 budget")
    }

    // MARK: - Robustness

    func testIgnoresUnknownPrefixes() {
        let raw = """
        OVERVIEW: The meeting covered design updates.
        NOTE: This is not a known prefix.
        TOPIC: Design system | 15
        NEXT: none
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertEqual(result?.keyTopics.count, 1)
    }

    func testHandlesEmptyLines() {
        let raw = """

        OVERVIEW: The meeting covered design updates.

        TOPIC: Design system | 15

        NEXT: none

        """
        XCTAssertNotNil(MeetingOverviewParser.parse(raw))
    }

    func testReturnsNilWhenNoOverview() {
        let raw = """
        TOPIC: Design system | 15
        NEXT: none
        """
        XCTAssertNil(MeetingOverviewParser.parse(raw), "overview is required — no OVERVIEW: line → nil")
    }

    func testActionWithNoDue() {
        let raw = """
        OVERVIEW: Planning meeting.
        NEXT: none
        ACTION: Send report | Bob Smith | none
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertEqual(result?.actionItems.count, 1)
        XCTAssertNil(result?.actionItems.first?.dueLabel)
        XCTAssertEqual(result?.actionItems.first?.ownerName, "Bob Smith")
    }

    func testTopicWithNoTimestamp() {
        let raw = """
        OVERVIEW: Kickoff.
        TOPIC: Project scope | invalid
        NEXT: none
        """
        // Falls back to 0 seconds when timestamp can't be parsed
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertEqual(result?.keyTopics.first?.timestampSeconds, 0)
    }

    // MARK: - Partial output (LLM truncation)

    func testHandlesTruncatedOutput_overviewOnly() {
        let raw = """
        OVERVIEW: The speaker tested the transcription system for two minutes.
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result, "A lone OVERVIEW line should produce a valid summary")
        XCTAssertFalse(result!.overview.isEmpty)
        XCTAssertTrue(result!.keyTopics.isEmpty)
    }

    func testHandlesTruncatedOutput_overviewAndTopics() {
        // Simulates timeout after topics but before decisions
        let raw = """
        OVERVIEW: Budget meeting with three agenda items.
        TOPIC: Q3 budget | 10
        TOPIC: Headcount | 45
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.keyTopics.count, 2)
        XCTAssertTrue(result?.decisions.isEmpty ?? false)
    }

    // MARK: - Multi-language

    func testParsesHebrewOverview() {
        let raw = """
        OVERVIEW: הצוות דן בתקציב הרבעון הרביעי ובלוח הזמנים לשחרור.
        TOPIC: תקציב | 0
        NEXT: none
        """
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.overview.isEmpty)
    }

    func testParsesRussianOverview() {
        let raw = """
        OVERVIEW: Команда обсудила дорожную карту продукта на следующий квартал.
        NEXT: нет
        """
        // "нет" is not "none" — will be kept as nextMeeting value (that's fine, language-agnostic)
        let result = MeetingOverviewParser.parse(raw)
        XCTAssertNotNil(result)
    }
}
