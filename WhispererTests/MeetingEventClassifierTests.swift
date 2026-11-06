//
//  MeetingEventClassifierTests.swift
//  WhispererTests
//
//  Which calendar events are meetings worth a recording reminder, and which links may be
//  offered as Join. Pure — plain snapshots, no Calendar access.
//

import XCTest
@testable import whisperer

final class MeetingEventClassifierTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(title: String = "Design review", minutes: Double = 30, allDay: Bool = false,
                       canceled: Bool = false, url: String? = nil, location: String? = nil,
                       notes: String? = nil, attendees: Int? = 3, solo: Bool = false,
                       rsvp: MeetingRSVP = .accepted, externalID: String? = "UID-1") -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            eventIdentifier: "EK-1", externalIdentifier: externalID, calendarID: "cal",
            title: title, startAt: start, endAt: start.addingTimeInterval(minutes * 60),
            isAllDay: allDay, isCanceled: canceled, url: url.flatMap(URL.init(string:)),
            location: location, notes: notes, attendeeCount: attendees,
            currentUserRSVP: rsvp, isSoloEvent: solo)
    }

    // MARK: - Rule 1: never remind

    func testDeclinedCanceledAllDayAndOverlongAreExcluded() {
        XCTAssertNil(MeetingEventClassifier.meeting(from: event(rsvp: .declined)))
        XCTAssertNil(MeetingEventClassifier.meeting(from: event(canceled: true)))
        XCTAssertNil(MeetingEventClassifier.meeting(from: event(allDay: true)))
        XCTAssertNil(MeetingEventClassifier.meeting(from: event(minutes: 8 * 60)), "an all-day-ish block is not a meeting")
        XCTAssertNil(MeetingEventClassifier.meeting(from: event(minutes: 0)))
    }

    // MARK: - Rule 2: a conference link qualifies, 1:1 included

    func testConferenceLinkQualifiesEvenOneToOne() throws {
        let m = try XCTUnwrap(MeetingEventClassifier.meeting(from:
            event(notes: "Join: https://us02web.zoom.us/j/123456789?pwd=abc", attendees: 2)))
        XCTAssertEqual(m.provider, .zoom)
        XCTAssertEqual(m.kind, .online)
        XCTAssertEqual(m.joinURL?.host, "us02web.zoom.us")
    }

    func testStructuredURLIsPreferredOverNotes() throws {
        let m = try XCTUnwrap(MeetingEventClassifier.meeting(from:
            event(url: "https://meet.google.com/abc-defg-hij",
                  notes: "Fallback dial-in https://meet.google.com/abc-defg-hij?hs=1")))
        XCTAssertEqual(m.provider, .googleMeet)
        XCTAssertFalse(m.hasConflictingLinks, "the same meeting linked twice is one link")
    }

    // MARK: - Rule 3: attendees without a link → record, no join

    func testAttendeesWithoutLinkQualifyForRecordOnly() throws {
        let m = try XCTUnwrap(MeetingEventClassifier.meeting(from: event(location: "Room 4B", attendees: 4)))
        XCTAssertNil(m.joinURL)
        XCTAssertEqual(m.kind, .inPerson)
    }

    // MARK: - Rule 4: solo, unlinked blocks only on request

    func testSoloUnlinkedBlockIsExcludedUnlessOptedIn() {
        let block = event(title: "Focus time", attendees: nil, solo: true)
        XCTAssertNil(MeetingEventClassifier.meeting(from: block))
        XCTAssertNotNil(MeetingEventClassifier.meeting(from: block, includeUnlinkedSolo: true))
    }

    // MARK: - Links

    func testOnlyAllowlistedHttpsLinksAreJoinable() {
        XCTAssertNil(MeetingEventClassifier.validated(URL(string: "http://zoom.us/j/1")!), "https only")
        XCTAssertNil(MeetingEventClassifier.validated(URL(string: "https://evilzoom.us/j/1")!), "label-boundary match")
        XCTAssertNil(MeetingEventClassifier.validated(URL(string: "https://example.com/?u=https://zoom.us/j/1")!),
                     "a redirector carrying a meeting URL is not a meeting URL")
        XCTAssertEqual(MeetingEventClassifier.validated(URL(string: "https://teams.microsoft.com/l/meetup-join/x")!)?.provider, .teams)
    }

    func testConflictingLinksAreNeverAutoJoined() throws {
        let m = try XCTUnwrap(MeetingEventClassifier.meeting(from:
            event(notes: "https://zoom.us/j/111 or https://meet.google.com/aaa-bbbb-ccc")))
        XCTAssertTrue(m.hasConflictingLinks)
        XCTAssertNil(m.joinURL, "two different meetings: the user picks, nothing opens on its own")
    }

    // MARK: - Identity

    func testOccurrenceIdentitySurvivesResyncAndSeparatesRecurrences() {
        var a = event(externalID: "UID-42")
        var b = a
        b.eventIdentifier = "EK-CHANGED-AFTER-SYNC"
        XCTAssertEqual(MeetingEventClassifier.occurrenceID(for: a), MeetingEventClassifier.occurrenceID(for: b))
        a.startAt = start.addingTimeInterval(7 * 86_400)   // next week's occurrence
        XCTAssertNotEqual(MeetingEventClassifier.occurrenceID(for: a), MeetingEventClassifier.occurrenceID(for: b))
    }

    func testBlankTitleIsNamedHonestly() {
        XCTAssertEqual(MeetingEventClassifier.meeting(from: event(title: "  ", url: "https://zoom.us/j/1"))?.title,
                       "Untitled meeting")
    }
}
