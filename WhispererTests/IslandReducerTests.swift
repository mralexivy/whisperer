//
//  IslandReducerTests.swift
//  WhispererTests
//
//  Fast pure-Swift tests for IslandReducer.
//  Run with: xcodebuild test -only-testing:WhispererTests/IslandReducerTests
//
//  CLAUDE.md note: IslandReducer is a nonisolated enum with static methods,
//  so no @MainActor class is allocated/deallocated — the deinit hazard does not apply.
//

import XCTest
@testable import whisperer

final class IslandReducerTests: XCTestCase {

    private func freshModel(sessionID: UUID = UUID()) -> IslandModel {
        var m = IslandModel.initial
        let effects = IslandReducer.reduce(&m, .meetingStarted(sessionID: sessionID))
        XCTAssertTrue(effects.contains(.cancelHide))
        return m
    }

    // MARK: - Session correctness

    func testStaleSessionEventsAreDropped() {
        let realID = UUID()
        var m = freshModel(sessionID: realID)
        let staleID = UUID()

        let effects = IslandReducer.reduce(&m, .stopRequested(sessionID: staleID))
        XCTAssertTrue(effects.isEmpty, "Stale session stop must emit no effects")
        XCTAssertFalse(m.stopInFlight, "stopInFlight must not be set by stale event")
        XCTAssertEqual(m.capture, .starting, "Capture state must be unchanged")
    }

    func testNewSessionSupersedes() {
        let id1 = UUID()
        var m = freshModel(sessionID: id1)
        let rev0 = m.revision

        let id2 = UUID()
        IslandReducer.reduce(&m, .meetingStarted(sessionID: id2))
        XCTAssertEqual(m.sessionID, id2)
        XCTAssertGreaterThan(m.revision, rev0)
        XCTAssertFalse(m.stopInFlight)
    }

    // MARK: - Stop idempotency

    func testDoubleStopFiresOnce() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        IslandReducer.reduce(&m, .captureConfirmed)

        let effects1 = IslandReducer.reduce(&m, .stopRequested(sessionID: id))
        XCTAssertEqual(effects1.filter { $0 == .stopCapture }.count, 1)
        XCTAssertTrue(m.stopInFlight)

        let effects2 = IslandReducer.reduce(&m, .stopRequested(sessionID: id))
        XCTAssertTrue(effects2.isEmpty, "Second stop must produce no effects")
    }

    // MARK: - Escape never stops

    func testEscapeCollapseOnly() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        IslandReducer.reduce(&m, .captureConfirmed)
        IslandReducer.reduce(&m, .expand)
        XCTAssertEqual(m.presentation, .expanded)

        IslandReducer.reduce(&m, .escape)
        XCTAssertEqual(m.presentation, .compact,  "Escape must collapse")
        XCTAssertEqual(m.capture, .recording,      "Escape must not stop capture")
        XCTAssertFalse(m.stopInFlight)
    }

    func testEscapeWhileCompactIsNoop() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        IslandReducer.reduce(&m, .captureConfirmed)
        XCTAssertEqual(m.presentation, .compact)

        IslandReducer.reduce(&m, .escape)
        XCTAssertEqual(m.presentation, .compact)
        XCTAssertEqual(m.capture, .recording)
    }

    // MARK: - Expand/collapse do not touch capture

    func testExpandDoesNotStopCapture() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        IslandReducer.reduce(&m, .captureConfirmed)

        IslandReducer.reduce(&m, .expand)
        XCTAssertEqual(m.capture, .recording)
        XCTAssertFalse(m.stopInFlight)
    }

    func testCollapseDoesNotStopCapture() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        IslandReducer.reduce(&m, .captureConfirmed)
        IslandReducer.reduce(&m, .expand)

        let effects = IslandReducer.reduce(&m, .collapse)
        XCTAssertEqual(m.presentation, .compact)
        XCTAssertEqual(m.capture, .recording)
        XCTAssertFalse(effects.contains(.stopCapture))
    }

    // MARK: - Failure persistence

    func testFailurePersistsUntilDismissed() {
        var m = IslandModel.initial
        IslandReducer.reduce(&m, .meetingStarted(sessionID: UUID()))
        IslandReducer.reduce(&m, .captureFailed("Mic unplugged"))

        guard case .failed(let msg) = m.capture else {
            return XCTFail("Expected .failed")
        }
        XCTAssertEqual(msg, "Mic unplugged")

        // Additional events should not clear the failure.
        IslandReducer.reduce(&m, .displayChanged)
        guard case .failed = m.capture else {
            return XCTFail("Failure cleared by displayChanged")
        }

        IslandReducer.reduce(&m, .dismissFailure)
        XCTAssertEqual(m.capture, .idle)
        XCTAssertEqual(m.presentation, .hidden)
    }

    func testFailureMakesIslandVisible() {
        var m = IslandModel.initial
        XCTAssertEqual(m.presentation, .hidden)
        IslandReducer.reduce(&m, .meetingStarted(sessionID: UUID()))
        IslandReducer.reduce(&m, .captureFailed(""))
        XCTAssertNotEqual(m.presentation, .hidden, "Failed Island must not be hidden")
    }

    // MARK: - Pause / Resume

    func testPauseResumeCycle() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        IslandReducer.reduce(&m, .captureConfirmed)
        XCTAssertEqual(m.capture, .recording)

        let pauseEffects = IslandReducer.reduce(&m, .pauseResumeRequested(sessionID: id))
        XCTAssertEqual(m.capture, .paused)
        XCTAssertTrue(m.isPaused)
        XCTAssertTrue(pauseEffects.contains(.togglePause))

        let resumeEffects = IslandReducer.reduce(&m, .pauseResumeRequested(sessionID: id))
        XCTAssertEqual(m.capture, .recording)
        XCTAssertFalse(m.isPaused)
        XCTAssertTrue(resumeEffects.contains(.togglePause))
    }

    func testPauseIgnoredWhenNotRecording() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        // Still in .starting — pause must be a no-op
        let effects = IslandReducer.reduce(&m, .pauseResumeRequested(sessionID: id))
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(m.capture, .starting)
    }

    // MARK: - Mic / output mute toggles

    func testMicMuteToggles() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        XCTAssertFalse(m.isMicMuted)

        let e1 = IslandReducer.reduce(&m, .micMuteRequested(sessionID: id))
        XCTAssertTrue(m.isMicMuted)
        XCTAssertTrue(e1.contains(.toggleMicMute))

        let e2 = IslandReducer.reduce(&m, .micMuteRequested(sessionID: id))
        XCTAssertFalse(m.isMicMuted)
        XCTAssertTrue(e2.contains(.toggleMicMute))
    }

    func testOutputMuteToggles() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        let e = IslandReducer.reduce(&m, .outputMuteRequested(sessionID: id))
        XCTAssertTrue(m.isOutputMuted)
        XCTAssertTrue(e.contains(.toggleOutputMute))
    }

    // MARK: - captureEnded hides Island

    func testCaptureEndedHidesIsland() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        IslandReducer.reduce(&m, .captureConfirmed)
        IslandReducer.reduce(&m, .expand)

        let effects = IslandReducer.reduce(&m, .captureEnded)
        XCTAssertEqual(m.capture, .idle)
        XCTAssertEqual(m.presentation, .hidden)
        XCTAssertFalse(m.stopInFlight)
        XCTAssertTrue(effects.contains(.cancelHide))
    }

    // MARK: - Revision monotonicity

    func testRevisionMonotonicallyIncreases() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        let r0 = m.revision
        IslandReducer.reduce(&m, .captureConfirmed)
        let r1 = m.revision
        IslandReducer.reduce(&m, .capturePaused)
        let r2 = m.revision
        IslandReducer.reduce(&m, .captureResumed)
        let r3 = m.revision
        XCTAssertGreaterThan(r1, r0)
        XCTAssertGreaterThan(r2, r1)
        XCTAssertGreaterThan(r3, r2)
    }

    // MARK: - ViewModel projection

    func testViewModelActions_recording() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        IslandReducer.reduce(&m, .captureConfirmed)
        let vm = m.viewModel()
        XCTAssertTrue(vm.availableActions.contains(.stop))
        XCTAssertTrue(vm.availableActions.contains(.pauseResume))
        XCTAssertTrue(vm.availableActions.contains(.micMute))
        XCTAssertTrue(vm.availableActions.contains(.outputMute))
        XCTAssertTrue(vm.availableActions.contains(.openWindow))
    }

    func testViewModelStatusLabel_paused() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        IslandReducer.reduce(&m, .captureConfirmed)
        IslandReducer.reduce(&m, .capturePaused)
        let vm = m.viewModel()
        // Label must contain a non-empty paused string
        XCTAssertFalse(vm.statusLabel.isEmpty)
    }
}
