//
//  CalendarAccountsTests.swift
//  WhispererTests
//
//  Direct Google / Microsoft calendar connections: response mapping, OAuth helpers, and how
//  signed-in accounts merge with macOS calendars. No network — remote sources are fakes.
//

import XCTest
@testable import whisperer

final class CalendarAccountMappingTests: XCTestCase {

    private let google = CalendarAccount(provider: .google, email: "dana@example.com")
    private let microsoft = CalendarAccount(provider: .microsoft, email: "dana@contoso.com")

    func testGoogleEventMapsConferenceLinkRSVPAndUID() throws {
        let item: [String: Any] = [
            "id": "evt1_20261106T090000Z", "iCalUID": "abc@google.com", "status": "confirmed",
            "summary": "Planning", "start": ["dateTime": "2026-11-06T09:00:00Z"], "end": ["dateTime": "2026-11-06T09:30:00Z"],
            "conferenceData": ["entryPoints": [["entryPointType": "phone", "uri": "tel:+1"],
                                               ["entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij"]]],
            "attendees": [["email": "dana@example.com", "self": true, "responseStatus": "accepted"],
                          ["email": "avi@example.com", "responseStatus": "needsAction"]],
        ]
        let s = try XCTUnwrap(GoogleCalendarSource.snapshot(item, calendarID: google.namespaced("primary")))
        XCTAssertEqual(s.url?.host, "meet.google.com")
        XCTAssertEqual(s.currentUserRSVP, .accepted)
        XCTAssertEqual(s.externalIdentifier, "abc@google.com", "the cross-source dedupe key")
        XCTAssertFalse(s.isSoloEvent)
        XCTAssertEqual(MeetingEventClassifier.meeting(from: s)?.provider, .googleMeet)
    }

    func testGoogleBlocksAndDeclinesNeverRemind() throws {
        let focus: [String: Any] = ["id": "f", "summary": "Focus", "eventType": "focusTime",
                                    "start": ["dateTime": "2026-11-06T09:00:00Z"], "end": ["dateTime": "2026-11-06T10:00:00Z"]]
        XCTAssertNil(GoogleCalendarSource.snapshot(focus, calendarID: "c").flatMap { MeetingEventClassifier.meeting(from: $0) })
        let declined: [String: Any] = ["id": "d", "summary": "Sync", "hangoutLink": "https://meet.google.com/x-y-z",
                                       "start": ["dateTime": "2026-11-06T09:00:00Z"], "end": ["dateTime": "2026-11-06T10:00:00Z"],
                                       "attendees": [["self": true, "responseStatus": "declined"], ["email": "a@b.c"]]]
        XCTAssertNil(GoogleCalendarSource.snapshot(declined, calendarID: "c").flatMap { MeetingEventClassifier.meeting(from: $0) })
        let allDay: [String: Any] = ["id": "a", "summary": "Offsite", "start": ["date": "2026-11-06"], "end": ["date": "2026-11-07"]]
        XCTAssertEqual(GoogleCalendarSource.snapshot(allDay, calendarID: "c")?.isAllDay, true)
    }

    func testMicrosoftEventMapsTeamsLinkAndUTC() throws {
        let item: [String: Any] = [
            "id": "AAMk", "iCalUId": "040000008200", "subject": "Weekly", "isCancelled": false, "isAllDay": false,
            "start": ["dateTime": "2026-11-06T14:00:00.0000000", "timeZone": "UTC"],
            "end": ["dateTime": "2026-11-06T14:30:00.0000000", "timeZone": "UTC"],
            "onlineMeeting": ["joinUrl": "https://teams.microsoft.com/l/meetup-join/19%3a..."],
            "responseStatus": ["response": "tentativelyAccepted"],
            "attendees": [["emailAddress": ["address": "a@contoso.com"]]],
        ]
        let s = try XCTUnwrap(MicrosoftCalendarSource.snapshot(item, calendarID: microsoft.namespaced("cal")))
        XCTAssertEqual(s.startAt, CalendarDates.rfc3339.date(from: "2026-11-06T14:00:00Z"))
        XCTAssertEqual(s.currentUserRSVP, .tentative)
        XCTAssertEqual(MeetingEventClassifier.meeting(from: s)?.provider, .teams)
    }

    func testNamespacedCalendarIDsRoundTrip() {
        let ns = google.namespaced("team@group.calendar.google.com")
        XCTAssertEqual(google.localCalendarID(ns), "team@group.calendar.google.com")
        XCTAssertNil(microsoft.localCalendarID(ns), "another account's calendar is not ours")
    }

    func testOAuthHelpers() {
        // {"email":"dana@example.com"} as a JWT payload.
        let payload = CalendarOAuthClient.base64URL(Data(#"{"email":"dana@example.com"}"#.utf8))
        XCTAssertEqual(CalendarOAuthClient.emailClaim(in: "h.\(payload).s"), "dana@example.com")
        let verifier = CalendarOAuthClient.randomURLSafe(64)
        XCTAssertGreaterThanOrEqual(verifier.count, 43, "PKCE verifiers are 43–128 characters")
        XCTAssertFalse(verifier.contains("=") || verifier.contains("+") || verifier.contains("/"))
        let redirect = CalendarAccountProvider.google.redirect(clientID: "123-abc.apps.googleusercontent.com")
        XCTAssertEqual(redirect.uri, "com.googleusercontent.apps.123-abc:/oauth2redirect")
    }
}

// MARK: - Merging with the store

private struct FakeRemote: RemoteCalendarSource {
    let account: CalendarAccount
    var result: Result<[CalendarEventSnapshot], CalendarAccountError>
    func calendars() async throws -> [CalendarSummary] {
        [CalendarSummary(id: account.namespaced("primary"), title: "Primary", sourceTitle: account.email, color: [0, 0, 1])]
    }
    func events(from start: Date, to end: Date, calendarIDs: [String]) async throws -> [CalendarEventSnapshot] {
        try result.get()
    }
}

@MainActor
final class CalendarAccountStoreTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []
    private var saved: [String: Any] = [:]
    private let keys = [CalendarMeetingsStore.Keys.enabledCalendars,
                        CalendarMeetingsStore.Keys.reminderLead, CalendarMeetingsStore.Keys.decisions,
                        CalendarMeetingsStore.Keys.accounts]
    private let account = CalendarAccount(provider: .google, email: "dana@example.com")

    override func setUp() async throws {
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key); UserDefaults.standard.removeObject(forKey: key) }
    }
    override func tearDown() async throws {
        for key in keys {
            if let v = saved[key] { UserDefaults.standard.set(v, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func event(uid: String, calendar: String, startsIn: TimeInterval) -> CalendarEventSnapshot {
        let start = Date().addingTimeInterval(startsIn)
        return CalendarEventSnapshot(eventIdentifier: uid + calendar, externalIdentifier: uid, calendarID: calendar,
                                     title: "Review", startAt: start, endAt: start.addingTimeInterval(1800),
                                     isAllDay: false, isCanceled: false, url: URL(string: "https://meet.google.com/a-b-c"),
                                     location: nil, notes: nil, attendeeCount: 3, currentUserRSVP: .accepted, isSoloEvent: false)
    }

    private func store(accounts: [CalendarAccount]? = nil,
                       remote: @escaping (CalendarAccount) -> Result<[CalendarEventSnapshot], CalendarAccountError>) async -> CalendarMeetingsStore {
        if let data = try? JSONEncoder().encode(accounts ?? [account]) {
            UserDefaults.standard.set(data, forKey: CalendarMeetingsStore.Keys.accounts)
        }
        let s = CalendarMeetingsStore()
        Self.keepAlive.append(s)
        s.makeRemoteSource = { FakeRemote(account: $0, result: remote($0)) }
        await s.refresh(reason: "test")
        return s
    }

    func testSignedInAccountIsTheSource() async {
        let s = await store { _ in .success([self.event(uid: "u1", calendar: self.account.namespaced("primary"), startsIn: 3600)]) }
        XCTAssertTrue(s.hasAnySource)
        XCTAssertEqual(s.upcoming.count, 1)
        XCTAssertEqual(s.calendars.map(\.title), ["Primary"])
    }

    /// An invite on both a Google and an Outlook calendar shows its meeting once.
    func testTheSameEventFromTwoAccountsAppearsOnce() async {
        let outlook = CalendarAccount(provider: .microsoft, email: "dana@contoso.com")
        let s = await store(accounts: [account, outlook]) { acct in
            .success([self.event(uid: "shared-uid", calendar: acct.namespaced("primary"), startsIn: 3600)])
        }
        XCTAssertEqual(s.upcoming.count, 1)
        XCTAssertEqual(s.calendars.count, 2, "both accounts' calendars are listed")
    }

    func testNoAccountMeansNoCalendarAndNoMacOSFallback() async {
        let s = await store(accounts: []) { _ in .success([]) }
        XCTAssertFalse(s.hasAnySource)
        XCTAssertTrue(s.upcoming.isEmpty)
        XCTAssertTrue(s.calendars.isEmpty)
    }

    func testRevokedAccountIsFlaggedNotCrashed() async {
        let s = await store { _ in .failure(.needsReconnect) }
        XCTAssertTrue(s.accountsNeedingReconnect.contains(account.id))
        XCTAssertTrue(s.upcoming.isEmpty)
    }

    func testRemovingTheAccountClearsItsEvents() async {
        let s = await store { _ in .success([self.event(uid: "u1", calendar: self.account.namespaced("primary"), startsIn: 3600)]) }
        XCTAssertFalse(s.upcoming.isEmpty)
        s.removeAccount(account)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(s.accounts.isEmpty)
        XCTAssertTrue(s.upcoming.isEmpty)
    }
}
