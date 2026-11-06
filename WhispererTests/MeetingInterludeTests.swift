//
//  MeetingInterludeTests.swift
//  WhispererTests
//
//  Dictating on top of a meeting: the shortcut pauses the meeting, dictates, and resumes it —
//  never silently dropped. Driven through AppState with the null backend, so no model loads and
//  nothing is typed (an empty decode types nothing).
//

import XCTest
@testable import whisperer

@MainActor
final class MeetingInterludeTests: XCTestCase {

    /// `@MainActor` classes must outlive the test host's synchronous teardown (see CLAUDE.md).
    private static var keepAlive: [AnyObject] = []

    private var savedState: RecordingState = .idle
    private var savedBridge: TranscriptionBackend?

    override func setUp() async throws {
        let app = AppState.shared
        savedState = app.state
        savedBridge = app.whisperBridge
    }

    override func tearDown() async throws {
        let app = AppState.shared
        app.cancelMeetingInterlude(reason: "test teardown")
        app._setActiveMeetingSessionForTesting(nil)
        app.whisperBridge = savedBridge
        app.state = savedState
        ForegroundGate.shared.clearAll(reason: "test teardown")
    }

    private func liveMeeting() -> MeetingSession {
        let session = MeetingSession()
        Self.keepAlive.append(session)
        let app = AppState.shared
        app._setActiveMeetingSessionForTesting(session)
        app.state = .recording(startTime: Date())
        return session
    }

    // MARK: - Live meeting

    func testShortcutDuringAMeetingPausesItAndDictates() async throws {
        let app = AppState.shared
        let session = liveMeeting()
        app.whisperBridge = NullTranscriptionBackend()

        app.startRecording()

        XCTAssertEqual(app.meetingInterlude, .listening, "the press must start a dictation, not be dropped")
        XCTAssertTrue(session.isPausedForDictation, "the meeting surfaces show it paused")
        XCTAssertTrue(ForegroundGate.shared.isRaised, "background work yields to the dictation")
        XCTAssertTrue(app.state.isRecording, "the meeting itself is still recording underneath")

        app.stopRecording()
        XCTAssertEqual(app.meetingInterlude, .finishing, "release finishes the dictation")
        XCTAssertFalse(session.isPausedForDictation, "and resumes the meeting at once")

        // The finish runs async; with the null backend there is nothing to type.
        let deadline = Date().addingTimeInterval(5)
        while app.meetingInterlude != nil, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNil(app.meetingInterlude)
        XCTAssertFalse(ForegroundGate.shared.isRaised, "the gate comes down after the dictation")
        XCTAssertTrue(app.state.isRecording, "the meeting never stopped")
        XCTAssertNotNil(app.activeMeetingSession)
    }

    /// Fn + another key arrives as a cancel. It used to be able to tear the meeting down; now it
    /// cancels only the dictation.
    func testCancelDropsOnlyTheDictation() {
        let app = AppState.shared
        let session = liveMeeting()
        app.whisperBridge = NullTranscriptionBackend()

        app.startRecording()
        XCTAssertEqual(app.meetingInterlude, .listening)
        app.cancelRecording()

        XCTAssertNil(app.meetingInterlude)
        XCTAssertFalse(session.isPausedForDictation)
        XCTAssertFalse(ForegroundGate.shared.isRaised)
        XCTAssertTrue(app.state.isRecording, "the meeting keeps recording")
        XCTAssertTrue(app.activeMeetingSession === session)
    }

    func testNoModelSaysSoInsteadOfDoingNothing() {
        let app = AppState.shared
        _ = liveMeeting()
        app.whisperBridge = nil
        app.showModelLoadingToast = false

        app.startRecording()

        XCTAssertNil(app.meetingInterlude)
        XCTAssertTrue(app.showModelLoadingToast, "the HUD explains why nothing is recording")
        app.showModelLoadingToast = false
    }

    func testSecondPressWhileDictatingDoesNotStartAnother() {
        let app = AppState.shared
        _ = liveMeeting()
        app.whisperBridge = NullTranscriptionBackend()
        app.startRecording()
        app.startRecording()
        XCTAssertEqual(app.meetingInterlude, .listening)
    }

    // MARK: - Meeting stopping

    /// Pressed while the meeting saves its last seconds: remembered, shown, and started when the
    /// meeting lets go — not swallowed.
    func testPressWhileMeetingStopsIsRememberedAndReleaseForgetsIt() {
        let app = AppState.shared
        _ = liveMeeting()
        app.state = .stopping

        app.startRecording()
        XCTAssertEqual(app.meetingInterlude, .waitingForMeetingStop, "the HUD says it will start")

        app.stopRecording()
        XCTAssertNil(app.meetingInterlude, "released before the meeting finished: nothing to dictate")
    }

    // MARK: - Meeting start during a dictation

    func testMeetingStartWaitsForADictationToFinish() async {
        let app = AppState.shared
        app._setActiveMeetingSessionForTesting(nil)
        app.state = .recording(startTime: Date())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.state = .idle }
        let started = Date()
        let ok = await app.waitForDictationToFinish(timeout: 5)
        XCTAssertTrue(ok)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.25, "the meeting waited for the dictation")
    }

    func testMeetingStartGivesUpOnAStuckDictation() async {
        let app = AppState.shared
        app._setActiveMeetingSessionForTesting(nil)
        app.state = .recording(startTime: Date())
        let ok = await app.waitForDictationToFinish(timeout: 0.3)
        XCTAssertFalse(ok)
    }

    // MARK: - Backlog

    func testBacklogHoldsInOrderOnlyWhileHolding() {
        let backlog = MeetingSampleBacklog()
        XCTAssertFalse(backlog.holdIfHolding([1, 2]), "not holding: the caller feeds live")
        backlog.startHolding()
        XCTAssertTrue(backlog.holdIfHolding([1, 2]))
        XCTAssertTrue(backlog.holdIfHolding([3]))
        XCTAssertEqual(backlog.release(), [1, 2, 3], "every sample, in order — the file got the same")
        XCTAssertFalse(backlog.isHolding)
        XCTAssertFalse(backlog.holdIfHolding([4]))
        XCTAssertEqual(backlog.release(), [])
    }
}
