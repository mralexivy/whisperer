//
//  MeetingTimedParagraphsTests.swift
//  WhispererTests
//
//  The timed-word path of a live meeting: settled Apple words with audio times in, paragraphs out.
//

import XCTest
@testable import whisperer

@MainActor
final class MeetingTimedParagraphsTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private func session() -> MeetingSession {
        let session = MeetingSession()
        Self.keepAlive.append(session)
        session.meetingID = UUID()
        session.isRecording = true
        return session
    }

    /// `count` words at 0.4 s each from `start`, deliberately unpunctuated.
    private func speech(from start: Double, count: Int) -> [TimedWord] {
        (0..<count).map { TimedWord(text: "word\($0)", start: start + Double($0) * 0.4, end: start + Double($0) * 0.4 + 0.35) }
    }

    func testLongPauseStartsANewParagraphAndSpeechWithoutOneDoesNot() {
        let s = session()
        defer { MeetingPendingStore.clear(meetingID: s.meetingID!) }
        // 40 words in one breath: no card yet.
        s.onAttributedWords(speech(from: 0, count: 40), speakerIndex: 0)
        XCTAssertEqual(s.segments.count, 0)
        // A 6 s pause, then more: the first paragraph is committed, the second is open.
        s.onAttributedWords(speech(from: 22, count: 30), speakerIndex: 0)
        XCTAssertEqual(s.segments.count, 1)
        XCTAssertEqual(s.segments[0].text.split(separator: " ").count, 40)
        XCTAssertEqual(s.currentSegmentText.split(separator: " ").count, 30)
    }

    func testOneSpeakerTwoMinutesIsFewParagraphsNotCardPerGap() {
        let s = session()
        defer { MeetingPendingStore.clear(meetingID: s.meetingID!) }
        var clock = 0.0
        for _ in 0..<8 {                       // eight 20-word sentences, 1 s between them
            s.onAttributedWords(speech(from: clock, count: 20), speakerIndex: 0)
            clock += 20 * 0.4 + 1.0
        }
        XCTAssertLessThanOrEqual(s.segments.count, 1, "1 s pauses are not paragraph breaks")
    }

    func testSpeakerChangeClosesTheTurn() {
        let s = session()
        defer { MeetingPendingStore.clear(meetingID: s.meetingID!) }
        s.onAttributedWords(speech(from: 0, count: 30), speakerIndex: 0)
        s.onAttributedWords(speech(from: 12.5, count: 10), speakerIndex: 1)
        XCTAssertEqual(s.segments.count, 1)
        XCTAssertEqual(s.segments[0].speakerIndex, 0)
        XCTAssertEqual(s.currentSpeakerIndex, 1)
    }
}
