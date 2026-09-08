//
//  IslandReducer.swift
//  Whisperer
//
//  Pure, dependency-free state machine for the Whisperer Island.
//
//  Contract:
//  - No UIKit, AppKit, SwiftUI, or Combine imports.
//  - All methods are static so tests never allocate/deallocate a @MainActor class,
//    sidestepping the SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor deinit hazard.
//  - Presentation is independent of capture: expand/collapse/escape never mutate capture.
//  - Stop is idempotent: the first .stopRequested emits .stopCapture once and marks
//    stopInFlight; subsequent .stopRequested events emit nothing.
//  - Events carrying a stale sessionID are silently dropped.
//  - Escape collapses only — it never stops or discards capture.
//  - Failures persist until .dismissFailure.
//

import Foundation

enum IslandReducer {

    // MARK: - Public entry point

    /// Apply `event` to `state`, returning the side effects the coordinator must execute.
    /// `state` is mutated in-place; effects are fire-and-forget commands.
    @discardableResult
    static func reduce(_ state: inout IslandModel, _ event: IslandEvent) -> [IslandEffect] {
        switch event {

        // MARK: Capture lifecycle

        case .meetingStarted(let id):
            // New session always supersedes a stale one.
            state = IslandModel(
                sessionID: id,
                revision: state.revision &+ 1,
                capture: .starting,
                presentation: .compact,
                isMicMuted: state.isMicMuted,
                isOutputMuted: state.isOutputMuted,
                isPaused: false,
                stopInFlight: false
            )
            return [.cancelHide]

        case .captureConfirmed:
            guard state.capture == .starting else { return [] }
            state.capture = .recording
            state.isPaused = false
            state.revision &+= 1
            return []

        case .capturePaused:
            guard case .recording = state.capture else { return [] }
            state.capture = .paused
            state.isPaused = true
            state.revision &+= 1
            return []

        case .captureResumed:
            guard case .paused = state.capture else { return [] }
            state.capture = .recording
            state.isPaused = false
            state.revision &+= 1
            return []

        case .captureFinalizing:
            state.capture = .finalizing
            state.isPaused = false
            state.revision &+= 1
            return []

        case .captureEnded:
            state.capture = .idle
            state.presentation = .hidden
            state.stopInFlight = false
            state.revision &+= 1
            return [.cancelHide]

        case .captureFailed(let msg):
            state.capture = .failed(msg)
            // Stay visible (compact if not already expanded) — spec §2.2 failure rule.
            if state.presentation == .hidden { state.presentation = .compact }
            state.revision &+= 1
            return []

        case .permissionRequired:
            state.capture = .permissionRequired
            if state.presentation == .hidden { state.presentation = .compact }
            state.revision &+= 1
            return []

        // MARK: User actions — session-gated

        case .stopRequested(let id):
            guard id == state.sessionID else { return [] }
            // Idempotency: only fire stopCapture once per session.
            guard !state.stopInFlight else { return [] }
            state.stopInFlight = true
            state.capture = .finalizing
            state.revision &+= 1
            return [.stopCapture]

        case .pauseResumeRequested(let id):
            guard id == state.sessionID else { return [] }
            switch state.capture {
            case .recording:
                state.capture = .paused
                state.isPaused = true
                state.revision &+= 1
                return [.togglePause]
            case .paused:
                state.capture = .recording
                state.isPaused = false
                state.revision &+= 1
                return [.togglePause]
            default:
                return []
            }

        case .micMuteRequested(let id):
            guard id == state.sessionID else { return [] }
            state.isMicMuted.toggle()
            state.revision &+= 1
            return [.toggleMicMute]

        case .outputMuteRequested(let id):
            guard id == state.sessionID else { return [] }
            state.isOutputMuted.toggle()
            state.revision &+= 1
            return [.toggleOutputMute]

        case .openWindowRequested:
            return [.openMeetingWindow]

        // MARK: Presentation — never touch capture

        case .expand:
            guard state.presentation != .hidden else { return [] }
            state.presentation = .expanded
            return []

        case .collapse:
            guard state.presentation == .expanded else { return [] }
            state.presentation = .compact
            return []

        case .escape:
            // Escape collapses only — spec §2.3 "Escape collapses only; never stops or discards recording"
            if state.presentation == .expanded {
                state.presentation = .compact
            }
            return []

        case .displayChanged:
            // Geometry refresh; no state mutation needed — coordinator re-queries geometry.
            return []

        case .dismissFailure:
            guard case .failed = state.capture else { return [] }
            state.capture = .idle
            state.presentation = .hidden
            state.revision &+= 1
            return [.cancelHide]
        }
    }
}
