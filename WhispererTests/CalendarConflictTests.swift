//
//  CalendarConflictTests.swift
//  WhispererTests
//
//  Two invites at the same time: the one the user accepted is the meeting — it is what the
//  "Meeting now" card shows, what reminds, and what names a detected call. The other is not shown.
//

import XCTest
@testable import whisperer

final class CalendarConflictTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func meeting(_ id: String, start: Double, minutes: Double, _ response: MeetingRSVP) -> ScheduledMeeting {
        ScheduledMeeting(id: id, calendarID: "c", source: .google, title: id,
                         startAt: t0.addingTimeInterval(start * 60),
                         endAt: t0.addingTimeInterval((start + minutes) * 60),
                         joinURL: nil, provider: nil, hasConflictingLinks: false,
                         hasOtherParticipants: true, response: response, kind: .online)
    }

    func testAcceptedBeatsAnEarlierUnansweredInvite() {
        let invite = meeting("DevOpsDays", start: 0, minutes: 60, .pending)
        let accepted = meeting("Weekly", start: 15, minutes: 30, .accepted)
        XCTAssertEqual([invite, accepted].preferredFirst?.id, "Weekly")
        XCTAssertEqual([invite, accepted].outranking(invite)?.id, "Weekly")
        XCTAssertNil([invite, accepted].outranking(accepted))
    }

    func testTentativeBeatsUnanswered() {
        let a = meeting("A", start: 0, minutes: 30, .unknown)
        let b = meeting("B", start: 0, minutes: 30, .tentative)
        XCTAssertEqual([a, b].preferredFirst?.id, "B")
    }

    func testEqualAnswersKeepStartOrder() {
        let a = meeting("A", start: 0, minutes: 30, .accepted)
        let b = meeting("B", start: 10, minutes: 30, .accepted)
        XCTAssertEqual([a, b].preferredFirst?.id, "A")
        XCTAssertNil([a, b].outranking(b), "two accepted meetings both stay")
    }

    func testMeetingsThatDoNotOverlapAreNotConflicts() {
        let a = meeting("A", start: 0, minutes: 30, .pending)
        let b = meeting("B", start: 30, minutes: 30, .accepted)
        XCTAssertNil([a, b].outranking(a), "back to back is not a conflict")
        XCTAssertEqual([a, b].preferredFirst?.id, "A")
    }
}
