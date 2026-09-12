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

    /// Returns a model fresh off meetingStarted. Asserts cancelHide is emitted.
    private func freshModel(sessionID: UUID = UUID()) -> IslandModel {
        var m = IslandModel.initial
        let effects = IslandReducer.reduce(&m, .meetingStarted(sessionID: sessionID))
        XCTAssertTrue(effects.contains(.cancelHide))
        return m
    }

    // MARK: - meetingStarted lands at .peek

    func testMeetingStartedLandsAtPeek() {
        let m = freshModel()
        // Island starts minimally visible — not blasting a full pill on the user immediately.
        XCTAssertEqual(m.presentation, .peek)
        XCTAssertEqual(m.capture, .starting)
    }

    // MARK: - captureConfirmed promotes peek to compact

    func testCaptureConfirmedFromStartingProducesRecording() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)
        XCTAssertEqual(m.capture, .recording)
        // Starting rows need to be legible — cannot stay in peek.
        XCTAssertEqual(m.presentation, .compact,
                       "captureConfirmed must promote peek to compact for legible recording row")
    }

    // MARK: - Three-tier ladder: peek → compact → expanded

    func testExpandFromPeekGoesToCompact() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)    // .recording, .compact
        // Manually set back to peek to simulate hover entry.
        m.presentation = .peek

        IslandReducer.reduce(&m, .expand)
        XCTAssertEqual(m.presentation, .compact)
    }

    func testExpandFromCompactGoesToExpanded() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)    // .recording, .compact

        IslandReducer.reduce(&m, .expand)
        XCTAssertEqual(m.presentation, .expanded)
    }

    func testExpandFromExpandedIsNoOp() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)
        IslandReducer.reduce(&m, .expand)              // → .expanded

        IslandReducer.reduce(&m, .expand)
        XCTAssertEqual(m.presentation, .expanded, "Expand from expanded must not change state")
    }

    // MARK: - Collapse walks down one tier

    func testCollapseFromExpandedGoesToCompact() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)
        IslandReducer.reduce(&m, .expand)   // .expanded

        IslandReducer.reduce(&m, .collapse)
        XCTAssertEqual(m.presentation, .compact)
    }

    func testCollapseFromCompactGoesToPeekWhenRecording() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)   // .recording, .compact

        IslandReducer.reduce(&m, .collapse)
        XCTAssertEqual(m.presentation, .peek,
                       "Collapse from compact while recording should retreat to peek")
    }

    func testCollapseFromPeekIsNoOp() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)
        m.presentation = .peek

        IslandReducer.reduce(&m, .collapse)
        XCTAssertEqual(m.presentation, .peek, "Collapse from peek must not go to hidden")
    }

    // MARK: - Escape always goes to peek/compact

    func testEscapeFromExpandedGoesToPeekWhenRecording() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)
        IslandReducer.reduce(&m, .expand)   // .expanded

        IslandReducer.reduce(&m, .escape)
        XCTAssertEqual(m.presentation, .peek)
    }

    func testEscapeFromCompactGoesToPeekWhenRecording() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)   // .compact

        IslandReducer.reduce(&m, .escape)
        XCTAssertEqual(m.presentation, .peek)
    }

    func testEscapeDoesNotStopCapture() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)
        IslandReducer.reduce(&m, .expand)

        IslandReducer.reduce(&m, .escape)
        XCTAssertEqual(m.capture, .recording, "Escape must never touch capture state")
    }

    // MARK: - peekRequested floors at compact for non-recording states

    func testPeekRequestedFromStartingStaysAtCompact() {
        var m = freshModel()
        // .starting capture → cannot peek
        m.presentation = .compact

        IslandReducer.reduce(&m, .peekRequested)
        XCTAssertEqual(m.presentation, .compact,
                       "peekRequested must stay at compact when capture is .starting")
    }

    func testPeekRequestedFromFailedStaysAtCompact() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)
        IslandReducer.reduce(&m, .captureFailed("Error"))
        // .failed → floor at compact

        IslandReducer.reduce(&m, .peekRequested)
        XCTAssertEqual(m.presentation, .compact)
    }

    func testPeekRequestedFromRecordingGoesToPeek() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)
        IslandReducer.reduce(&m, .expand)   // .expanded

        IslandReducer.reduce(&m, .peekRequested)
        XCTAssertEqual(m.presentation, .peek)
    }

    func testPeekRequestedFromPausedGoesToPeek() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)
        IslandReducer.reduce(&m, .capturePaused)

        IslandReducer.reduce(&m, .peekRequested)
        XCTAssertEqual(m.presentation, .peek)
    }

    func testPeekRequestedWhenHiddenIsNoOp() {
        var m = IslandModel.initial
        m.presentation = .hidden   // another surface owns the meeting UI
        IslandReducer.reduce(&m, .peekRequested)
        XCTAssertEqual(m.presentation, .hidden)
    }

    // MARK: - Always-on idle launcher

    func testInitialModelRestsAtTheIdleLauncherBar() {
        let m = IslandModel.initial
        XCTAssertEqual(m.capture, .idle)
        XCTAssertEqual(m.presentation, .compact,
                       "Idle has a single tier — the launcher bar. The view hides it until hover.")
    }

    /// Idle has exactly one tier. Collapse, escape and hover-exit must all leave the
    /// launcher bar at compact — the view, not the reducer, is what hides it at rest.
    func testIdleNeverCollapsesBelowTheLauncherBar() {
        for event: IslandEvent in [.collapse, .escape, .peekRequested] {
            var m = IslandModel.initial
            IslandReducer.reduce(&m, event)
            XCTAssertEqual(m.presentation, .compact, "\(event) must not drop idle below compact")
        }
    }

    func testIdleNeverReachesExpanded() {
        var m = IslandModel.initial
        IslandReducer.reduce(&m, .expand)   // .compact
        IslandReducer.reduce(&m, .expand)
        XCTAssertEqual(m.presentation, .compact,
                       "Idle has no secondary control row to reveal")
    }

    func testStartMeetingRequestedEmitsStartEffect() {
        var m = IslandModel.initial
        let effects = IslandReducer.reduce(&m, .startMeetingRequested)
        XCTAssertEqual(effects, [.startMeeting])
    }

    func testStartMeetingRequestedIsIgnoredWhileRecording() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)
        XCTAssertTrue(IslandReducer.reduce(&m, .startMeetingRequested).isEmpty)
    }

    func testDictateRequestedEmitsStartDictationEffect() {
        var m = IslandModel.initial
        XCTAssertEqual(IslandReducer.reduce(&m, .dictateRequested), [.startDictation])
    }

    func testDictateRequestedIsIgnoredWhileRecording() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)
        XCTAssertTrue(IslandReducer.reduce(&m, .dictateRequested).isEmpty)
    }

    /// Opening a workspace surface is always allowed — it never touches the recorder.
    func testWorkspaceLauncherActionsEmitTheirEffects() {
        var m = IslandModel.initial
        XCTAssertEqual(IslandReducer.reduce(&m, .openPasteBinRequested), [.openPasteBin])
        XCTAssertEqual(IslandReducer.reduce(&m, .openWorkspaceRequested), [.openWorkspace])
    }

    /// The launcher row must stay put while its action starts up — the surface it opens
    /// is what changes, and the coordinator re-derives the tier from AppState.
    func testLauncherActionsDoNotChangePresentation() {
        var m = IslandModel.initial
        m.presentation = .compact
        for event: IslandEvent in [.dictateRequested, .startMeetingRequested,
                                   .openPasteBinRequested, .openWorkspaceRequested] {
            IslandReducer.reduce(&m, event)
            XCTAssertEqual(m.presentation, .compact)
            XCTAssertEqual(m.capture, .idle)
        }
    }

    // MARK: - Non-recording states floor at compact

    func testCaptureFailed_PromotesPeekToCompact() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)
        m.presentation = .peek

        IslandReducer.reduce(&m, .captureFailed("Oops"))
        XCTAssertEqual(m.presentation, .compact)
        XCTAssertEqual(m.capture, .failed("Oops"))
    }

    func testPermissionRequired_PromotesPeekToCompact() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)
        m.presentation = .peek

        IslandReducer.reduce(&m, .permissionRequired)
        XCTAssertEqual(m.presentation, .compact)
    }

    func testStopRequested_PromotesPeekToCompact() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        IslandReducer.reduce(&m, .captureConfirmed)
        m.presentation = .peek

        IslandReducer.reduce(&m, .stopRequested(sessionID: id))
        XCTAssertEqual(m.presentation, .compact,
                       "Finalizing state must not stay at peek — label must be legible")
    }

    // MARK: - Session correctness

    func testStaleSessionEventsAreDropped() {
        let realID = UUID()
        var m = freshModel(sessionID: realID)
        let staleID = UUID()

        let effects = IslandReducer.reduce(&m, .stopRequested(sessionID: staleID))
        XCTAssertTrue(effects.isEmpty, "Stale session stop must emit no effects")
        XCTAssertFalse(m.stopInFlight)
        XCTAssertEqual(m.capture, .starting)
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
        XCTAssertEqual(m.presentation, .peek, "New session always starts at peek")
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
        XCTAssertTrue(effects2.isEmpty, "Second stop must emit nothing")
        XCTAssertTrue(m.stopInFlight)
    }

    // MARK: - Pause / Resume

    func testPauseResumeCycle() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        IslandReducer.reduce(&m, .captureConfirmed)
        XCTAssertEqual(m.capture, .recording)

        IslandReducer.reduce(&m, .capturePaused)
        XCTAssertEqual(m.capture, .paused)
        XCTAssertTrue(m.isPaused)

        IslandReducer.reduce(&m, .captureResumed)
        XCTAssertEqual(m.capture, .recording)
        XCTAssertFalse(m.isPaused)
    }

    // MARK: - captureEnded hides

    func testCaptureEndedReturnsToTheIdleLauncher() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)

        IslandReducer.reduce(&m, .captureEnded)
        XCTAssertEqual(m.capture, .idle)
        XCTAssertEqual(m.presentation, .compact,
                       "Capture end falls back to the idle launcher, never to hidden")
    }

    // MARK: - dismissFailure

    func testDismissFailureReturnsToTheIdleLauncher() {
        var m = freshModel()
        IslandReducer.reduce(&m, .captureConfirmed)
        IslandReducer.reduce(&m, .captureFailed("Error"))

        let effects = IslandReducer.reduce(&m, .dismissFailure)
        XCTAssertTrue(effects.contains(.cancelHide))
        XCTAssertEqual(m.presentation, .compact)
        XCTAssertEqual(m.capture, .idle)
    }

    // MARK: - displayChanged is a no-op

    func testDisplayChangedIsNoOp() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        IslandReducer.reduce(&m, .captureConfirmed)
        let before = m

        let effects = IslandReducer.reduce(&m, .displayChanged)
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(m, before)
    }

    // MARK: - Mic / output mute toggle

    func testMicMuteToggles() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        IslandReducer.reduce(&m, .captureConfirmed)
        XCTAssertFalse(m.isMicMuted)

        IslandReducer.reduce(&m, .micMuteRequested(sessionID: id))
        XCTAssertTrue(m.isMicMuted)

        IslandReducer.reduce(&m, .micMuteRequested(sessionID: id))
        XCTAssertFalse(m.isMicMuted)
    }

    func testOutputMuteToggles() {
        let id = UUID()
        var m = freshModel(sessionID: id)
        IslandReducer.reduce(&m, .captureConfirmed)
        XCTAssertFalse(m.isOutputMuted)

        IslandReducer.reduce(&m, .outputMuteRequested(sessionID: id))
        XCTAssertTrue(m.isOutputMuted)
    }
}
