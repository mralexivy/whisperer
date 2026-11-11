//
//  MeetingAnswerCitationTests.swift
//  WhispererTests
//
//  Ask AI answers cite moments as [95s] so they become clickable sources; the markers themselves
//  must not reach the text the user reads.
//

import XCTest
@testable import whisperer

final class MeetingAnswerCitationTests: XCTestCase {

    func testRunsOfMarkersLeaveTheText() {
        let raw = "Content Intelligence has a separate $500,000 budget allocation. [70s] [100s] [130s] [150s] [1131s]\n"
            + "  Action: Uria should review the architecture. [100s] [1310s]"
        XCTAssertEqual(MeetingAIService.stripCitations(raw),
                       "Content Intelligence has a separate $500,000 budget allocation.\n"
                       + "  Action: Uria should review the architecture.")
    }

    func testMarkerBeforePunctuationKeepsThePunctuationTight() {
        XCTAssertEqual(MeetingAIService.stripCitations("The budget was closed [70s]. Next item [90s], then lunch."),
                       "The budget was closed. Next item, then lunch.")
    }

    func testHebrewAnswer() {
        XCTAssertEqual(MeetingAIService.stripCitations("התקציב נסגר [70s] [100s]."), "התקציב נסגר.")
    }

    func testOtherBracketsStay() {
        XCTAssertEqual(MeetingAIService.stripCitations("Option [A] and [10 min] stay."), "Option [A] and [10 min] stay.")
    }
}

final class MeetingAskHistoryTests: XCTestCase {
    func testFollowUpCarriesTheConversation() {
        let q = MeetingAIService.withHistory("more detailed", [("Give me interview feedback", "- Background: …")])
        XCTAssertTrue(q.contains("Give me interview feedback"))
        XCTAssertTrue(q.contains("- Background: …"))
        XCTAssertTrue(q.hasSuffix("more detailed"))
    }

    func testFirstQuestionIsSentAsIs() {
        XCTAssertEqual(MeetingAIService.withHistory("What was decided?", []), "What was decided?")
    }
}
