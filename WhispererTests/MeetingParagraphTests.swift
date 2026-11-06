//
//  MeetingParagraphTests.swift
//  WhispererTests
//
//  Live meeting paragraphs: cards close at the speaker's pauses, stay a sensible size, and a
//  long card never shatters into several in one update. Driven through MeetingSession with
//  synthetic attributed text (the default engine's path); no models.
//

import XCTest
@testable import whisperer

@MainActor
final class MeetingParagraphTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private func liveSession() -> MeetingSession {
        let session = MeetingSession()
        Self.keepAlive.append(session)
        session.meetingID = UUID()
        session.isRecording = true
        return session
    }

    /// Speaks `words` as consecutive 1-second items of three words, with no pauses.
    private func speak(_ session: MeetingSession, words: Int, from start: Double, speaker: Int = 0,
                       script: String = "word") -> Double {
        var t = start
        var left = words
        while left > 0 {
            let n = min(3, left)
            let text = (0..<n).map { "\(script)\($0 + t.hashValue % 7)" }.joined(separator: " ")
            session.onAttributedText(text: text, speakerIndex: speaker, startTimestamp: t, endTimestamp: t + 1)
            t += 1
            left -= n
        }
        return t
    }

    func testAPauseClosesTheParagraphEvenWithoutAPeriod() {
        let s = liveSession()
        let end = speak(s, words: 18, from: 0)          // 6 s, 18 words, no terminator
        XCTAssertTrue(s.segments.isEmpty)
        _ = speak(s, words: 3, from: end + 2)            // 2 s pause, then speech
        XCTAssertEqual(s.segments.count, 1, "the pause is the paragraph boundary")
        XCTAssertEqual(s.segments.first?.text.split(separator: " ").count, 18)
        XCTAssertFalse(s.currentSegmentText.isEmpty, "the words after the pause open the next card")
    }

    func testAShortFragmentIsNotItsOwnCard() {
        let s = liveSession()
        let end = speak(s, words: 6, from: 0)            // 2 s, 6 words
        _ = speak(s, words: 3, from: end + 2)
        XCTAssertTrue(s.segments.isEmpty, "a six-word fragment belongs to the paragraph around it")
    }

    /// The reported bug: one big paragraph, then several cards appearing at once.
    func testALongMonologueNeverShattersIntoSeveralCardsAtOnce() {
        let s = liveSession()
        var t = 0.0
        var maxAddedAtOnce = 0
        // 2.7 s items: the coordinator releases speech in uneven batches (diarizer bursts, the
        // 3 s drain deadline), so an item routinely carries a card past the 30 s cap.
        for _ in 0..<30 {
            let before = s.segments.count
            s.onAttributedText(text: "and then we talked about it", speakerIndex: 0, startTimestamp: t, endTimestamp: t + 2.7)
            maxAddedAtOnce = max(maxAddedAtOnce, s.segments.count - before)
            t += 2.7
        }
        XCTAssertGreaterThanOrEqual(s.segments.count, 2, "an 80 s monologue is several paragraphs")
        XCTAssertEqual(maxAddedAtOnce, 1, "cards appear one at a time, never a burst")
        for card in s.segments {
            XCTAssertLessThanOrEqual(card.endTimestamp - card.timestamp, 30.5, "no card runs past the cap")
        }
    }

    func testHebrewMeetingStaysRightToLeftThroughAFewEnglishWords() {
        let s = liveSession()
        var t = 0.0
        for _ in 0..<8 {
            s.onAttributedText(text: "שלום לכולם אנחנו מתחילים", speakerIndex: 0, startTimestamp: t, endTimestamp: t + 1)
            t += 1
        }
        t += 2
        s.onAttributedText(text: "okay", speakerIndex: 0, startTimestamp: t, endTimestamp: t + 1)
        XCTAssertEqual(s.liveIsRTL, true)
        // A few English cards do not flip a Hebrew meeting.
        for _ in 0..<2 {
            t += 2
            for _ in 0..<6 {
                s.onAttributedText(text: "the quarterly numbers look good", speakerIndex: 0, startTimestamp: t, endTimestamp: t + 1)
                t += 1
            }
        }
        XCTAssertEqual(s.liveIsRTL, true, "direction holds within the hysteresis band")
    }

    func testDirectionHysteresis() {
        XCTAssertNil(MeetingTranscriptText.stickyRightToLeft(current: nil, text: "hi"))
        XCTAssertEqual(MeetingTranscriptText.stickyRightToLeft(current: nil, text: String(repeating: "שלום ", count: 10)), true)
        let mixed = String(repeating: "שלום ", count: 3) + String(repeating: "hello ", count: 4)   // ~30% RTL
        XCTAssertEqual(MeetingTranscriptText.stickyRightToLeft(current: true, text: mixed), true)
        XCTAssertEqual(MeetingTranscriptText.stickyRightToLeft(current: false, text: mixed), false)
    }
}
