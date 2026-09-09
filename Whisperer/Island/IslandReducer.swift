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
//  - Presentation tiers: hidden → peek → compact → expanded.
//  - Peek is the default while idle (launcher nub) and while recording/paused;
//    transient and error states floor at compact so their label stays legible.
//  - .hidden is now only used when another surface owns the meeting UI.
//  - expand: peek→compact, compact→expanded.
//  - collapse / escape: expanded→compact, compact→peek.
//  - peekRequested: any visible tier → peek (floors at compact for non-recording states).
//  - Stop is idempotent: the first .stopRequested emits .stopCapture once and marks
//    stopInFlight; subsequent .stopRequested events emit nothing.
//  - Events carrying a stale sessionID are silently dropped.
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
            // New session always supersedes a stale one. Start at peek.
            state = IslandModel(
                sessionID: id,
                revision: state.revision &+ 1,
                capture: .starting,
                presentation: .peek,
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
            // Promote peek to compact — the nub cannot show "Starting…" legibly.
            if state.presentation == .peek { state.presentation = .compact }
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
            // Finalizing must be legible.
            if state.presentation == .peek { state.presentation = .compact }
            return []

        case .captureEnded:
            state.capture = .idle
            // The Island never disappears — it falls back to the idle launcher nub.
            state.presentation = .peek
            state.stopInFlight = false
            state.revision &+= 1
            return [.cancelHide]

        case .captureFailed(let msg):
            state.capture = .failed(msg)
            // Failure must be legible — floor at compact regardless of current tier.
            if state.presentation == .hidden || state.presentation == .peek {
                state.presentation = .compact
            }
            state.revision &+= 1
            return []

        case .permissionRequired:
            state.capture = .permissionRequired
            // Permission message must be legible — floor at compact.
            if state.presentation == .hidden || state.presentation == .peek {
                state.presentation = .compact
            }
            state.revision &+= 1
            return []

        // MARK: User actions — session-gated

        case .stopRequested(let id):
            guard id == state.sessionID else { return [] }
            guard !state.stopInFlight else { return [] }
            state.stopInFlight = true
            state.capture = .finalizing
            if state.presentation == .peek { state.presentation = .compact }
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

        // MARK: Idle launcher row
        //
        // None of these mutate presentation. Whatever they launch takes over the screen
        // (the dictation HUD, the meeting window, the workspace), and the coordinator
        // re-derives the Island's tier from the resulting AppState.

        case .dictateRequested:
            guard state.capture == .idle else { return [] }
            return [.startDictation]

        case .startMeetingRequested:
            guard state.capture == .idle else { return [] }
            return [.startMeeting]

        case .transcribeFileRequested:
            return [.openFileTranscription]

        case .openWorkspaceRequested:
            return [.openWorkspace]

        // MARK: Presentation — never touch capture

        case .expand:
            switch state.presentation {
            case .peek:    state.presentation = .compact
            // Idle has no secondary control row to reveal.
            case .compact: if state.capture != .idle { state.presentation = .expanded }
            default:       break
            }
            return []

        case .collapse:
            switch state.presentation {
            case .expanded: state.presentation = .compact
            case .compact:  state.presentation = peekOrCompact(for: state.capture)
            default:        break
            }
            return []

        case .escape:
            // Escape always goes to peek/compact — never stops or discards recording.
            guard state.presentation != .hidden else { return [] }
            state.presentation = peekOrCompact(for: state.capture)
            return []

        case .peekRequested:
            // Hover exit — return to nub if capture allows it, else stay at compact.
            guard state.presentation != .hidden else { return [] }
            state.presentation = peekOrCompact(for: state.capture)
            return []

        case .displayChanged:
            // Geometry refresh; no state mutation needed — coordinator re-queries geometry.
            return []

        case .dismissFailure:
            guard case .failed = state.capture else { return [] }
            state.capture = .idle
            state.presentation = .peek
            state.revision &+= 1
            return [.cancelHide]
        }
    }

    // MARK: - Helpers

    /// Returns .peek when the capture state can legitimately show the nub, else .compact.
    /// Idle (launcher), recording and paused can sit at peek; transient and error states
    /// must show a label, so they floor at compact.
    private static func peekOrCompact(for capture: IslandCaptureState) -> IslandPresentation {
        switch capture {
        case .idle, .recording, .paused: return .peek
        default:                         return .compact
        }
    }
}
