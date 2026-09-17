//
//  AudioFlowTimeoutTests.swift
//  WhispererTests
//
//  Covers `AppState.lowerStrandedRecordingGates(reason:)` — the belt-and-braces call that every
//  capture-failure path now ends with, and the one that would have kept the app usable on
//  2026-09-14 after the recorder surrendered.
//
//  Scope note: `handleAudioFlowTimeout()` and `forceCaptureTeardown()` themselves are not
//  exercised here. They drop the live transcriber, tear down the audio engine and call
//  `abandonMeetingMode`, which needs a real `MeetingSession` with a CoreData row and a live
//  recording window — that is integration territory, not a unit test. What *is* unit-testable is
//  their shared tail, which is the part that was missing in the incident: the gates. The reducer
//  and queue behaviour around it is covered by `StrandedGateWatchdogTests`.
//
//  Run with: xcodebuild test -only-testing:WhispererTests/AudioFlowTimeoutTests
//

import XCTest
@testable import whisperer

@MainActor
final class AudioFlowTimeoutTests: XCTestCase {

    func testLoweringGatesWithNoActiveSessionClearsBoth() async {
        let app = AppState.shared
        XCTAssertNil(app.activeMeetingSession, "precondition: no meeting is running in the host")

        await ModelWorkQueue.shared.setMeetingActive(true)
        MeetingJobQueue.shared.suspendForRecording()

        app.lowerStrandedRecordingGates(reason: "unit test")

        // The model gate is lowered from a detached `Task`, so yield until it lands.
        var gateRaised = await ModelWorkQueue.shared.isMeetingGateRaised
        for _ in 0..<50 where gateRaised {
            try? await Task.sleep(nanoseconds: 10_000_000)
            gateRaised = await ModelWorkQueue.shared.isMeetingGateRaised
        }

        XCTAssertFalse(gateRaised, "background model work must not stay parked forever")
        XCTAssertFalse(MeetingJobQueue.shared.isSuspended,
                       "meeting summaries must not stay blocked forever")
    }

    func testLoweringGatesIsSafeWhenNothingIsStranded() async {
        let app = AppState.shared
        await ModelWorkQueue.shared.setMeetingActive(false)
        MeetingJobQueue.shared.resumeAfterRecording()

        app.lowerStrandedRecordingGates(reason: "unit test")

        let gateRaised = await ModelWorkQueue.shared.isMeetingGateRaised
        XCTAssertFalse(gateRaised)
        XCTAssertFalse(MeetingJobQueue.shared.isSuspended)
    }

    override func tearDown() async throws {
        await ModelWorkQueue.shared.setMeetingActive(false)
        await MainActor.run { MeetingJobQueue.shared.resumeAfterRecording() }
        try await super.tearDown()
    }
}
