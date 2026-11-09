//
//  MeetingLiveTailTextTests.swift
//  WhispererTests
//
//  The meeting live text must read like dictation: words only ever arrive at the end, and when
//  the open paragraph is committed into a card the words still on screen stay where they are.
//

import XCTest
@testable import whisperer

@MainActor
final class MeetingLiveTailTextTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    /// Immediate (unpaced) right-to-left updater, so the sliding logic is checked without timers.
    private func immediate() -> SmoothTextUpdater {
        let u = SmoothTextUpdater()
        u.pacesRTL = false
        Self.keepAlive.append(u)
        return u
    }

    private func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    func testCommittedFrontLeavesWithoutRetypingTheRest() {
        let u = immediate()
        u.setSlidingTarget("שלום לכולם היום נדבר על התקציב", rtl: true)
        XCTAssertEqual(u.displayedText, "שלום לכולם היום נדבר על התקציב")
        // "שלום לכולם" became a card; the rest stays and one new word arrives.
        let firstID = u.firstWordID
        u.setSlidingTarget("היום נדבר על התקציב של", rtl: true)
        XCTAssertEqual(u.displayedText, "היום נדבר על התקציב", "the drop is drawn on its own first")
        XCTAssertEqual(u.firstWordID, firstID + 2, "the words that stayed keep their identity")
        pump(0.05)
        XCTAssertEqual(u.displayedText, "היום נדבר על התקציב של")
    }

    /// A reset never reuses identities, so a word view from the old text is never handed a new word.
    func testResetIssuesFreshIdentities() {
        let u = immediate()
        u.setSlidingTarget("one two three four five", rtl: true)
        let before = u.firstWordID + u.words.count
        u.setSlidingTarget("alpha beta", rtl: true)
        XCTAssertGreaterThanOrEqual(u.firstWordID, before)
    }

    func testGrowingTextOnlyAppends() {
        let u = immediate()
        u.setSlidingTarget("we will talk about", rtl: true)
        u.setSlidingTarget("we will talk about the budget", rtl: true)
        XCTAssertEqual(u.displayedText, "we will talk about the budget")
    }

    /// Apple revising a word it already showed must not drag the text backwards.
    func testRevisionOfAShownWordDoesNotJumpBack() {
        let u = immediate()
        u.setSlidingTarget("we will talk about the budget", rtl: true)
        u.setSlidingTarget("we will talk about the budgets today", rtl: true)
        XCTAssertTrue(u.displayedText.hasPrefix("we will talk about the budget"))
        XCTAssertTrue(u.displayedText.hasSuffix("today"))
    }

    /// Text that no longer lines up and got shorter: start over instead of duplicating a card.
    func testUnrelatedShorterTextStartsOver() {
        let u = immediate()
        u.setSlidingTarget("one two three four five", rtl: true)
        u.setSlidingTarget("alpha beta", rtl: true)
        XCTAssertEqual(u.displayedText, "alpha beta")
    }

    /// In the meeting, Hebrew is poured word by word rather than a whole batch at once.
    func testMeetingUpdaterPoursHebrewWordByWord() {
        let u = SmoothTextUpdater.forMeetingLiveText()
        Self.keepAlive.append(u)
        u.setSlidingTarget("אחד שתיים שלוש ארבע חמש שש", rtl: true)
        let first = u.displayedText.split(separator: " ").count
        XCTAssertLessThan(first, 6, "the whole batch landed at once")
        pump(2.0)
        XCTAssertEqual(u.displayedText.split(separator: " ").count, 6)
    }
}
