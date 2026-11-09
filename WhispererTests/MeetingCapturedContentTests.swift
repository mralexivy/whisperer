//
//  MeetingCapturedContentTests.swift
//  WhispererTests
//
//  A meeting that captured anything is ended through `stopRecording()` when capture fails or the
//  Mac sleeps — never abandoned, which kept the cards but skipped refine, polish and overview.
//

import XCTest
@testable import whisperer

@MainActor
final class MeetingCapturedContentTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private func session() -> MeetingSession {
        let s = MeetingSession()
        Self.keepAlive.append(s)
        return s
    }

    func testEmptyMeetingHasNothingCaptured() {
        XCTAssertFalse(session().hasCapturedContent)
    }

    func testCardsCount() {
        let s = session()
        s.segments = [MeetingSegment(timestamp: 0, endTimestamp: 5, text: "שלום לכולם", speakerName: "Alex", speakerIndex: 0)]
        XCTAssertTrue(s.hasCapturedContent)
    }

    func testOpenParagraphOrLiveTextCounts() {
        let s = session()
        s.currentSegmentText = "  "
        XCTAssertFalse(s.hasCapturedContent, "whitespace is not content")
        s.livePreviewText = "we were talking about the budget"
        XCTAssertTrue(s.hasCapturedContent)
    }
}
