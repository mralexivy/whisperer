//
//  IslandCaptureFailureTests.swift
//  WhispererTests
//
//  The Island is the only failure surface that outlives `state == .idle`. On 2026-09-14 it
//  rendered a healthy 68-minute recording over a microphone that was delivering nothing, then
//  vanished when the state collapsed. `IslandCaptureState.failed` and `IslandEvent.captureFailed`
//  already existed at the time — nothing in the app ever emitted them.
//
//  `IslandReducer` is a nonisolated enum of static methods, so the CLAUDE.md `@MainActor` deinit
//  hazard does not apply here.
//
//  Run with: xcodebuild test -only-testing:WhispererTests/IslandCaptureFailureTests
//

import XCTest
@testable import whisperer

final class IslandCaptureFailureTests: XCTestCase {

    private func recordingModel() -> IslandModel {
        var m = IslandModel.initial
        IslandReducer.reduce(&m, .meetingStarted(sessionID: UUID()))
        IslandReducer.reduce(&m, .captureConfirmed)
        XCTAssertEqual(m.capture, .recording)
        return m
    }

    // MARK: - Entering the failed state

    func testCaptureFailedReplacesTheRecordingRow() {
        var m = recordingModel()
        IslandReducer.reduce(&m, .captureFailed("Your microphone is muted."))
        XCTAssertEqual(m.capture, .failed("Your microphone is muted."))
    }

    func testFailureIsFlooredAtCompactFromHidden() {
        var m = IslandModel.initial
        m.presentation = .hidden
        IslandReducer.reduce(&m, .captureFailed("no audio"))
        XCTAssertEqual(m.presentation, .compact,
                       "a hidden Island cannot report a failure — floor it at compact")
    }

    func testFailureIsFlooredAtCompactFromPeek() {
        var m = recordingModel()
        m.presentation = .peek
        IslandReducer.reduce(&m, .captureFailed("no audio"))
        XCTAssertEqual(m.presentation, .compact,
                       "the peek nub has no room for a message — it must grow")
    }

    func testFailureDoesNotShrinkAnAlreadyExpandedIsland() {
        var m = recordingModel()
        m.presentation = .expanded
        IslandReducer.reduce(&m, .captureFailed("no audio"))
        XCTAssertEqual(m.presentation, .expanded)
    }

    func testFailureBumpsTheRevisionSoTheViewRepublishes() {
        var m = recordingModel()
        let before = m.revision
        IslandReducer.reduce(&m, .captureFailed("no audio"))
        XCTAssertGreaterThan(m.revision, before)
    }

    /// The failure row carries the diagnosis verbatim, so the specific verdict copy reaches the
    /// user rather than a generic "recording failed".
    func testTheDiagnosisSurvivesIntoTheViewModel() {
        var m = recordingModel()
        let message = InputHealthVerdict.gainZero.userMessage
        IslandReducer.reduce(&m, .captureFailed(message))
        XCTAssertEqual(m.viewModel().statusLabel, message)
        XCTAssertEqual(m.viewModel().capture, .failed(message))
    }

    // MARK: - Dismissing

    func testDismissClearsAppStateSoTheRowCannotComeStraightBack() {
        var m = recordingModel()
        IslandReducer.reduce(&m, .captureFailed("no audio"))
        let effects = IslandReducer.reduce(&m, .dismissFailure)

        XCTAssertEqual(m.capture, .idle)
        XCTAssertEqual(m.presentation, .compact)
        // Without this the coordinator re-derives `.failed` from `AppState.captureFailure` on the
        // very next sync and the row becomes immortal.
        XCTAssertTrue(effects.contains(.clearCaptureFailure))
    }

    func testDismissIsANoOpWhenNothingHasFailed() {
        var m = recordingModel()
        let before = m
        let effects = IslandReducer.reduce(&m, .dismissFailure)
        XCTAssertEqual(m, before, "dismissing a healthy recording must not stop it")
        XCTAssertTrue(effects.isEmpty)
    }

    func testDismissClearsTheRepairAffordance() {
        var m = recordingModel()
        m.captureCanRepair = true
        IslandReducer.reduce(&m, .captureFailed("muted"))
        IslandReducer.reduce(&m, .dismissFailure)
        XCTAssertFalse(m.captureCanRepair)
    }

    // MARK: - Repair

    func testRepairIsOfferedOnlyWhenTheAppCanActuallyFixIt() {
        var m = recordingModel()
        IslandReducer.reduce(&m, .captureFailed(InputHealthVerdict.muted.userMessage))
        m.captureCanRepair = true

        let effects = IslandReducer.reduce(&m, .repairCaptureRequested)
        XCTAssertTrue(effects.contains(.repairCapture))
    }

    func testRepairIsRefusedForVerdictsTheAppCannotFix() {
        var m = recordingModel()
        IslandReducer.reduce(&m, .captureFailed(InputHealthVerdict.permissionDenied.userMessage))
        m.captureCanRepair = false

        let effects = IslandReducer.reduce(&m, .repairCaptureRequested)
        XCTAssertTrue(effects.isEmpty,
                      "a repair button that cannot repair anything is the 2026-09-14 bug in miniature")
    }

    func testRepairIsRefusedWhenNotInAFailedState() {
        var m = recordingModel()
        m.captureCanRepair = true
        let effects = IslandReducer.reduce(&m, .repairCaptureRequested)
        XCTAssertTrue(effects.isEmpty)
    }

    func testRepairDoesNotItselfLeaveTheFailedState() {
        var m = recordingModel()
        IslandReducer.reduce(&m, .captureFailed("muted"))
        m.captureCanRepair = true
        IslandReducer.reduce(&m, .repairCaptureRequested)
        // The row clears only once AppState confirms the write landed and nils `captureFailure`.
        XCTAssertEqual(m.capture, .failed("muted"))
    }

    // MARK: - The failed row offers no capture controls

    func testFailedStateExposesNoRecordingActions() {
        var m = recordingModel()
        IslandReducer.reduce(&m, .captureFailed("no audio"))
        XCTAssertTrue(m.viewModel().availableActions.isEmpty,
                      "pause/stop on a recording that is not capturing is the lie we are fixing")
    }
}
