//
//  StrandedGateWatchdogTests.swift
//  WhispererTests
//
//  The "app was killed, not functional" half of the 2026-09-14 incident.
//
//  Two process-wide gates go up when a meeting starts:
//    • `ModelWorkQueue.meetingActive` — parks every background model job on `meetingWaiters`.
//    • `MeetingJobQueue.isSuspended`  — blocks `startNext()`, so no summary, title or
//      fine-tuning job can ever start.
//
//  The capture-failure path never reached the code that lowers them. The log shows both raised
//  at 11:05:57 with no matching resume in the remaining 92 minutes: one audio fault bricked the
//  entire background pipeline for the life of the process. Both flags must now be treated as
//  recoverable state with a watchdog, not as invariants that some single code path owes us.
//
//  Run with: xcodebuild test -only-testing:WhispererTests/StrandedGateWatchdogTests
//

import XCTest
@testable import whisperer

final class StrandedGateWatchdogTests: XCTestCase {

    // MARK: - ModelWorkQueue

    func testStrandedModelGateIsLowered() async {
        let queue = ModelWorkQueue.shared
        await queue.setMeetingActive(true)
        let raised = await queue.isMeetingGateRaised
        XCTAssertTrue(raised, "precondition: the gate is up")

        await queue.clearStrandedMeetingGate(reason: "unit test")

        let stillRaised = await queue.isMeetingGateRaised
        XCTAssertFalse(stillRaised, "a stranded meeting gate must be survivable, not fatal")
    }

    func testClearingAnAlreadyLoweredModelGateIsHarmless() async {
        let queue = ModelWorkQueue.shared
        await queue.setMeetingActive(false)
        await queue.clearStrandedMeetingGate(reason: "unit test")
        let raised = await queue.isMeetingGateRaised
        XCTAssertFalse(raised)
    }

    func testTheModelGateWatchdogIsIdempotent() async {
        let queue = ModelWorkQueue.shared
        await queue.setMeetingActive(true)
        for _ in 0..<3 {
            await queue.clearStrandedMeetingGate(reason: "unit test")
        }
        let raised = await queue.isMeetingGateRaised
        XCTAssertFalse(raised)
    }

    // MARK: - MeetingJobQueue

    @MainActor
    func testStrandedJobQueueSuspensionIsLifted() {
        let queue = MeetingJobQueue.shared
        queue.suspendForRecording()
        XCTAssertTrue(queue.isSuspended, "precondition: the queue is suspended")

        queue.clearStrandedSuspension(reason: "unit test")

        XCTAssertFalse(queue.isSuspended,
                       "a stranded suspension means no meeting is ever summarized again")
    }

    @MainActor
    func testClearingAnUnsuspendedJobQueueIsHarmless() {
        let queue = MeetingJobQueue.shared
        queue.resumeAfterRecording()
        XCTAssertFalse(queue.isSuspended)

        queue.clearStrandedSuspension(reason: "unit test")
        XCTAssertFalse(queue.isSuspended)
    }

    @MainActor
    func testTheJobQueueWatchdogIsIdempotent() {
        let queue = MeetingJobQueue.shared
        queue.suspendForRecording()
        for _ in 0..<3 {
            queue.clearStrandedSuspension(reason: "unit test")
        }
        XCTAssertFalse(queue.isSuspended)
    }

    // MARK: - Both together

    /// The exact end state the incident left behind: both gates up, no meeting running. One
    /// call has to clear both, because they are raised together and the user never sees either.
    @MainActor
    func testBothGatesRecoverFromTheIncidentState() async {
        await ModelWorkQueue.shared.setMeetingActive(true)
        MeetingJobQueue.shared.suspendForRecording()

        await ModelWorkQueue.shared.clearStrandedMeetingGate(reason: "capture failure")
        MeetingJobQueue.shared.clearStrandedSuspension(reason: "capture failure")

        let gateRaised = await ModelWorkQueue.shared.isMeetingGateRaised
        XCTAssertFalse(gateRaised)
        XCTAssertFalse(MeetingJobQueue.shared.isSuspended)
    }

    // MARK: - Cleanup

    override func tearDown() async throws {
        // These are process-wide singletons; leaving a gate up would poison every later suite.
        await ModelWorkQueue.shared.setMeetingActive(false)
        await MainActor.run { MeetingJobQueue.shared.resumeAfterRecording() }
        try await super.tearDown()
    }
}
