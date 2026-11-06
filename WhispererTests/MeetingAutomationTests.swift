//
//  MeetingAutomationTests.swift
//  WhispererTests
//
//  Calendar reminders and confidence-gated call detection. No Calendar access, no microphone:
//  the calendar provider is a fake, detections are built by hand, and nothing records.
//

import XCTest
@testable import whisperer

// MARK: - Confidence policy

final class MeetingCallPolicyTests: XCTestCase {

    private func signals(_ source: MeetingCallSignals.Source, _ provider: ConferenceProvider?,
                         capture: Bool = true, device: Bool = false, sustained: Double = 10) -> MeetingCallSignals {
        MeetingCallSignals(source: source, provider: provider, processCaptureConfirmed: capture,
                           virtualDeviceActive: device, sustainedSeconds: sustained)
    }

    func testAnAppMerelyRunningNeverPrompts() {
        XCTAssertEqual(MeetingCallPolicy.confidence(signals(.nativeApp, .zoom, capture: false)), .possible)
    }

    func testValidatedNativeCallsConfirmAfterStableEvidence() {
        XCTAssertEqual(MeetingCallPolicy.confidence(signals(.nativeApp, .zoom, sustained: 1)), .likely,
                       "under 3 s is not yet stable")
        XCTAssertEqual(MeetingCallPolicy.confidence(signals(.nativeApp, .zoom, sustained: 3)), .confirmed)
        XCTAssertEqual(MeetingCallPolicy.confidence(signals(.nativeApp, .teams, capture: false, device: true, sustained: 0)),
                       .confirmed, "the in-call audio device exists only during a call")
    }

    func testUnvalidatedNativeAppsArePromptOnly() {
        XCTAssertEqual(MeetingCallPolicy.confidence(signals(.nativeApp, .slack)), .likely)
        XCTAssertEqual(MeetingCallPolicy.confidence(signals(.nativeApp, nil)), .likely, "FaceTime and unknown apps")
    }

    /// Chrome holding the microphone for dictation or voice search must never auto-record.
    func testUnverifiedBrowserMicIsNeverConfirmed() {
        XCTAssertEqual(MeetingCallPolicy.confidence(signals(.browserUnverified, nil, sustained: 3600)), .likely)
    }

    func testVerifiedMeetingTabConfirms() {
        XCTAssertEqual(MeetingCallPolicy.confidence(signals(.browserVerifiedTab, .googleMeet, sustained: 5)), .confirmed)
        XCTAssertEqual(MeetingCallPolicy.confidence(signals(.browserVerifiedTab, .googleMeet, capture: false)), .possible)
    }
}

// MARK: - Coordinator

@MainActor
final class MeetingSessionCoordinatorTests: XCTestCase {

    private let coordinator = MeetingSessionCoordinator.shared
    private var savedAuto = false
    private var savedExcluded: Set<String> = []

    override func setUp() async throws {
        savedAuto = coordinator.autoRecordEnabled
        savedExcluded = coordinator.excludedBundleIDs
    }

    override func tearDown() async throws {
        coordinator.detectionCardClosed()
        coordinator.autoRecordEnabled = savedAuto
        coordinator.excludedBundleIDs = savedExcluded
    }

    private func detection(_ source: MeetingCallSignals.Source = .nativeApp, provider: ConferenceProvider? = .zoom,
                           bundleID: String = "test.not.running.zoom") -> MeetingDetector.DetectedMeetingApp {
        MeetingDetector.DetectedMeetingApp(
            name: "Zoom", iconSystemName: "video.fill", iconColor: .blue, bundleID: bundleID,
            signals: MeetingCallSignals(source: source, provider: provider, processCaptureConfirmed: true,
                                        virtualDeviceActive: false, sustainedSeconds: 10))
    }

    func testNoCountdownWithoutOptIn() {
        coordinator.autoRecordEnabled = false
        XCTAssertTrue(coordinator.shouldPresentDetection(detection()))
        XCTAssertNil(coordinator.countdownSecondsLeft, "default is a one-click prompt, never a countdown")
    }

    func testCountdownOnlyForConfirmedCalls() {
        coordinator.autoRecordEnabled = true
        XCTAssertTrue(coordinator.shouldPresentDetection(detection(.browserUnverified, provider: nil)))
        XCTAssertNil(coordinator.countdownSecondsLeft, "an unidentified browser call is prompt-only")

        XCTAssertTrue(coordinator.shouldPresentDetection(detection()))
        XCTAssertEqual(coordinator.countdownSecondsLeft, coordinator.countdownSeconds)
    }

    /// The fake app is not running, so the first re-check finds no live call.
    func testLosingEvidenceDuringTheCountdownDearmsIt() async throws {
        coordinator.autoRecordEnabled = true
        XCTAssertTrue(coordinator.shouldPresentDetection(detection()))
        XCTAssertNotNil(coordinator.countdownSecondsLeft)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertNil(coordinator.countdownSecondsLeft, "no evidence, no automatic start")
        XCTAssertFalse(AppState.shared.isMeetingMode, "and nothing was recorded")
    }

    func testExcludedAppsAreNotPrompted() {
        coordinator.excludedBundleIDs = ["test.excluded"]
        XCTAssertFalse(coordinator.shouldPresentDetection(detection(bundleID: "test.excluded")))
    }

    func testDefaultTitlesNeverInventAName() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(MeetingSessionCoordinator.defaultTitle(appName: "Teams", at: date).hasPrefix("Unscheduled Teams meeting · "))
        XCTAssertTrue(MeetingSessionCoordinator.defaultTitle(appName: "Meeting in Chrome", at: date)
            .hasPrefix("Unscheduled call in Chrome · "))
        XCTAssertTrue(MeetingAIService.isAutoGeneratedTitle("Unscheduled Teams meeting · 11:24"),
                      "a generated name may be refined by the AI")
        XCTAssertFalse(MeetingAIService.isAutoGeneratedTitle("Design review"),
                       "a calendar title is the user's and is never renamed")
    }
}

// MARK: - Calendar store

/// A signed-in Google account with two calendars, "work" and "home". Events are held by
/// reference so a test can change them between refreshes.
private final class FakeCalendarProvider: @unchecked Sendable {
    static let account = CalendarAccount(provider: .google, email: "dana@example.com")
    var events: [CalendarEventSnapshot] = []
}

private struct FakeGoogleSource: RemoteCalendarSource {
    let account: CalendarAccount
    let backing: FakeCalendarProvider
    func calendars() async throws -> [CalendarSummary] {
        [CalendarSummary(id: account.namespaced("work"), title: "Work", sourceTitle: "Google", color: [1, 0, 0]),
         CalendarSummary(id: account.namespaced("home"), title: "Home", sourceTitle: "Google", color: [0, 1, 0])]
    }
    func events(from start: Date, to end: Date, calendarIDs: [String]) async throws -> [CalendarEventSnapshot] {
        backing.events.filter { e in calendarIDs.contains { account.namespaced($0) == e.calendarID } }
    }
}

@MainActor
final class CalendarMeetingsStoreTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []
    private var saved: [String: Any] = [:]
    private let keys = [CalendarMeetingsStore.Keys.accounts, CalendarMeetingsStore.Keys.enabledCalendars,
                        CalendarMeetingsStore.Keys.reminderLead, CalendarMeetingsStore.Keys.decisions]

    override func setUp() async throws {
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() async throws {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func meetingEvent(id: String = "UID-1", calendar: String = "work", startsIn: TimeInterval) -> CalendarEventSnapshot {
        let start = Date().addingTimeInterval(startsIn)
        return CalendarEventSnapshot(eventIdentifier: id, externalIdentifier: id,
                                     calendarID: FakeCalendarProvider.account.namespaced(calendar),
                                     title: "Standup", startAt: start, endAt: start.addingTimeInterval(1800),
                                     isAllDay: false, isCanceled: false, url: URL(string: "https://zoom.us/j/1"),
                                     location: nil, notes: nil, attendeeCount: 4, currentUserRSVP: .accepted,
                                     isSoloEvent: false)
    }

    /// A store with the fake Google account signed in (same UserDefaults across "restarts").
    private func connectedStore(_ provider: FakeCalendarProvider) async -> CalendarMeetingsStore {
        if let data = try? JSONEncoder().encode([FakeCalendarProvider.account]) {
            UserDefaults.standard.set(data, forKey: CalendarMeetingsStore.Keys.accounts)
        }
        let store = CalendarMeetingsStore()
        Self.keepAlive.append(store)
        store.makeRemoteSource = { FakeGoogleSource(account: $0, backing: provider) }
        await store.refresh(reason: "test")
        return store
    }

    func testReminderIsDueTwoMinutesBeforeByDefault() async throws {
        let provider = FakeCalendarProvider()
        provider.events = [meetingEvent(startsIn: 3600)]
        let store = await connectedStore(provider)
        let meeting = try XCTUnwrap(store.upcoming.first)
        let due = try XCTUnwrap(store.reminderDate(for: meeting))
        XCTAssertEqual(meeting.startAt.timeIntervalSince(due), 120, accuracy: 0.5)
        store.reminderLeadMinutes = nil
        XCTAssertNil(store.reminderDate(for: meeting), "reminders off")
    }

    func testOneReminderPerOccurrenceAcrossRestarts() async throws {
        let provider = FakeCalendarProvider()
        provider.events = [meetingEvent(startsIn: 60)]            // inside the 2-minute lead: due now
        let store = await connectedStore(provider)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.activeReminder?.title, "Standup", "the reminder fired")
        store.dismissReminder()

        let restarted = await connectedStore(provider)              // same UserDefaults
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(restarted.activeReminder, "a dismissed occurrence never reminds again")
        let meeting = try XCTUnwrap(restarted.upcoming.first)
        XCTAssertNil(restarted.reminderDate(for: meeting))
    }

    func testSnoozeNeverRunsPastTheMeeting() async throws {
        let provider = FakeCalendarProvider()
        provider.events = [meetingEvent(startsIn: 30)]
        let store = await connectedStore(provider)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(store.activeReminder)
        store.snoozeReminder()
        let meeting = try XCTUnwrap(store.upcoming.first)
        let again = try XCTUnwrap(store.reminderDate(for: meeting))
        XCTAssertLessThan(again, meeting.endAt)
        XCTAssertGreaterThan(again.timeIntervalSinceNow, 4 * 60)
    }

    func testDisabledCalendarsNeverRemind() async {
        let provider = FakeCalendarProvider()
        provider.events = [meetingEvent(id: "A", calendar: "work", startsIn: 3600),
                           meetingEvent(id: "B", calendar: "home", startsIn: 7200)]
        let store = await connectedStore(provider)
        XCTAssertEqual(store.upcoming.count, 2)
        store.setCalendar(FakeCalendarProvider.account.namespaced("home"), enabled: false)
        await store.refresh(reason: "test")
        XCTAssertEqual(store.upcoming.map(\.calendarID), [FakeCalendarProvider.account.namespaced("work")])
    }

    func testCancelledEventRemovesItsReminder() async throws {
        let provider = FakeCalendarProvider()
        provider.events = [meetingEvent(startsIn: 30)]
        let store = await connectedStore(provider)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(store.activeReminder)
        provider.events[0].isCanceled = true
        await store.refresh(reason: "calendar changed")
        XCTAssertNil(store.activeReminder, "a cancelled meeting's reminder goes away")
        XCTAssertTrue(store.upcoming.isEmpty)
    }

    func testDetectedCallsAreNamedFromAMatchingEventOnly() async {
        let provider = FakeCalendarProvider()
        provider.events = [meetingEvent(startsIn: -300)]           // started five minutes ago, Zoom
        let store = await connectedStore(provider)
        XCTAssertEqual(store.meeting(matching: .zoom)?.title, "Standup")
        XCTAssertNil(store.meeting(matching: .teams), "a Teams call is not this Zoom meeting")
    }

    func testSigningOutClearsCachedEvents() async throws {
        let provider = FakeCalendarProvider()
        provider.events = [meetingEvent(startsIn: 3600)]
        let store = await connectedStore(provider)
        XCTAssertFalse(store.upcoming.isEmpty)
        store.removeAccount(FakeCalendarProvider.account)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(store.upcoming.isEmpty)
        XCTAssertFalse(store.hasAnySource)
    }
}
