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

private final class FakeCalendarProvider: CalendarMeetingProvider, @unchecked Sendable {
    var events: [CalendarEventSnapshot] = []
    func accessStatus() -> CalendarAccess { .granted }
    func requestReadAccess() async throws -> Bool { true }
    func calendars() -> [CalendarSummary] {
        [CalendarSummary(id: "work", title: "Work", sourceTitle: "iCloud", color: [1, 0, 0]),
         CalendarSummary(id: "home", title: "Home", sourceTitle: "iCloud", color: [0, 1, 0])]
    }
    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) async -> [CalendarEventSnapshot] {
        events.filter { e in calendarIDs.map { $0.contains(e.calendarID) } ?? true }
    }
    func observeChanges() -> AsyncStream<Void> { AsyncStream { _ in } }
}

@MainActor
final class CalendarMeetingsStoreTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []
    private var saved: [String: Any] = [:]
    private let keys = [CalendarMeetingsStore.Keys.connected, CalendarMeetingsStore.Keys.enabledCalendars,
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
        return CalendarEventSnapshot(eventIdentifier: id, externalIdentifier: id, calendarID: calendar,
                                     title: "Standup", startAt: start, endAt: start.addingTimeInterval(1800),
                                     isAllDay: false, isCanceled: false, url: URL(string: "https://zoom.us/j/1"),
                                     location: nil, notes: nil, attendeeCount: 4, currentUserRSVP: .accepted,
                                     isSoloEvent: false)
    }

    private func connectedStore(_ provider: FakeCalendarProvider) async -> CalendarMeetingsStore {
        let store = CalendarMeetingsStore(provider: provider)
        Self.keepAlive.append(store)
        _ = await store.connect()
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
        store.setCalendar("home", enabled: false)
        await store.refresh(reason: "test")
        XCTAssertEqual(store.upcoming.map(\.calendarID), ["work"])
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

    func testDisconnectClearsCachedEvents() async {
        let provider = FakeCalendarProvider()
        provider.events = [meetingEvent(startsIn: 3600)]
        let store = await connectedStore(provider)
        XCTAssertFalse(store.upcoming.isEmpty)
        store.disconnect()
        XCTAssertTrue(store.upcoming.isEmpty)
        XCTAssertFalse(store.isConnected)
    }
}
