//
//  IslandState.swift
//  Whisperer
//
//  Pure vocabulary for the Whisperer Island — no UIKit/AppKit/SwiftUI imports.
//  All types are Equatable so the reducer can do simple equality comparisons
//  and views can suppress re-renders on no-op updates.
//

import Foundation

// MARK: - Capture state

/// The current audio/capture state, independent of how the Island is presented.
nonisolated enum IslandCaptureState: Equatable {
    case idle
    case starting
    case permissionRequired
    case recording
    case paused
    case finalizing
    case failed(String)
}

// MARK: - Presentation state

/// How the Island panel is displayed, independent of capture state.
/// Tiers ordered by size: hidden → peek → compact → expanded.
nonisolated enum IslandPresentation: Equatable {
    case hidden
    /// Minimal bottom nub. Near-transparent launcher while idle; dot + level glow while recording.
    case peek
    case compact
    case expanded
}

// MARK: - Actions (drives the footer control row)

enum IslandAction: Equatable, Hashable {
    case stop
    case pauseResume
    case micMute
    case outputMute
    case openWindow
}

// MARK: - Events fed into the reducer

enum IslandEvent {
    // Capture lifecycle
    case meetingStarted(sessionID: UUID)
    case captureConfirmed                  // audio started — waveform may appear
    case capturePaused
    case captureResumed
    case captureFinalizing
    case captureEnded                      // recording is over — hide after dwell
    case captureFailed(String)
    case permissionRequired

    // User actions
    case stopRequested(sessionID: UUID)
    case pauseResumeRequested(sessionID: UUID)
    case micMuteRequested(sessionID: UUID)
    case outputMuteRequested(sessionID: UUID)
    case openWindowRequested

    // Idle launcher row — one event per action.
    case dictateRequested                   // start a hands-free dictation
    case startMeetingRequested              // start a meeting recording
    case openPasteBinRequested              // open recent transcriptions (paste bin)
    case openWorkspaceRequested             // open the workspace

    // Presentation / UI
    case expand                             // peek→compact, compact→expanded
    case collapse                           // expanded→compact, compact→peek
    case escape                             // never stops, always goes to peek
    case peekRequested                      // hover exit — return to nub (floors at compact for non-recording states)
    case displayChanged                     // relayout without touching capture

    // Session corrections
    case dismissFailure
    /// "Unmute" / "Restore level" on the failure row — only offered for verdicts the app can
    /// actually fix itself (input muted, input gain at zero).
    case repairCaptureRequested
}

// MARK: - Effects emitted by the reducer (executed by the coordinator)

enum IslandEffect: Equatable {
    case stopCapture
    case togglePause
    case toggleMicMute
    case toggleOutputMute
    case openMeetingWindow
    case startDictation
    case startMeeting
    case openPasteBin
    case openWorkspace
    case scheduleHide(after: TimeInterval)   // auto-hide after dwell
    case cancelHide
    /// Clear `AppState.captureFailure`. Without this the coordinator's sync would re-emit
    /// `.captureFailed` on the very next pass and the row could never be dismissed.
    case clearCaptureFailure
    /// Un-mute the input device / restore its gain, per the stored verdict.
    case repairCapture
}

// MARK: - Internal model (reducer-private structure)

/// The full mutable model owned by the reducer. The coordinator projects this
/// into an `IslandViewModel` for the view layer.
struct IslandModel: Equatable {
    var sessionID: UUID
    var revision: UInt64                    // monotonically increasing per session
    var capture: IslandCaptureState
    var presentation: IslandPresentation
    var isMicMuted: Bool
    var isOutputMuted: Bool
    var isPaused: Bool
    var stopInFlight: Bool                  // idempotency guard
    /// Whether the current failure is one the app can fix itself. Written by the coordinator
    /// from `AppState.captureFailure`, not by the reducer — same pattern as `isMicMuted`.
    var captureCanRepair: Bool = false

    static let initial = IslandModel(
        sessionID: UUID(),
        revision: 0,
        capture: .idle,
        presentation: .compact,
        isMicMuted: false,
        isOutputMuted: false,
        isPaused: false,
        stopInFlight: false
    )
}

// MARK: - Launcher hint

/// The name of the launcher glyph under the pointer.
///
/// Position is deliberately NOT stored here. The chip reads the glyph's live centre from
/// `LauncherAnchorKey` when it renders, which keeps it correct through the open spring and
/// makes an unset/stale anchor impossible.
nonisolated struct IslandLauncherHint: Equatable {
    var title: String
}

// MARK: - View model (immutable snapshot sent to SwiftUI)

struct IslandViewModel: Equatable {
    var capture: IslandCaptureState
    var presentation: IslandPresentation
    var statusLabel: String
    var isMicMuted: Bool
    var isOutputMuted: Bool
    var isPaused: Bool
    var availableActions: [IslandAction]
    var sessionID: UUID
    /// Non-nil during model preparation (engine download/compile). 0–1.
    var preparationProgress: Double?
    /// Drives the repair button on the failure row.
    var captureCanRepair: Bool = false

    static let hidden = IslandViewModel(
        capture: .idle,
        presentation: .hidden,
        statusLabel: "",
        isMicMuted: false,
        isOutputMuted: false,
        isPaused: false,
        availableActions: [],
        sessionID: UUID(),
        preparationProgress: nil
    )
}

// MARK: - ViewModel projection

extension IslandModel {
    func viewModel() -> IslandViewModel {
        var actions: [IslandAction] = []
        // Peek tier has no visible hit targets — actions are only surfaced in compact/expanded.
        if presentation != .peek {
            switch capture {
            case .recording, .paused:
                actions = [.pauseResume, .micMute, .outputMute, .openWindow, .stop]
            case .starting:
                actions = [.openWindow]
            case .finalizing:
                actions = [.openWindow]
            default:
                actions = []
            }
        }

        let label: String
        switch capture {
        case .idle:              label = NSLocalizedString("island.start",      value: "Start meeting",     comment: "Island launcher: start a meeting recording")
        case .starting:          label = NSLocalizedString("island.starting",  value: "Starting…",         comment: "Island compact status: starting up")
        case .permissionRequired:label = NSLocalizedString("island.permission", value: "Microphone needed", comment: "Island compact status: permission required")
        case .recording:         label = NSLocalizedString("island.meeting",    value: "Meeting",           comment: "Island compact status: meeting in progress")
        case .paused:            label = NSLocalizedString("island.paused",     value: "Paused",            comment: "Island compact status: recording paused")
        case .finalizing:        label = NSLocalizedString("island.finishing",  value: "Finishing…",        comment: "Island compact status: finalizing")
        case .failed(let msg):   label = msg
        }

        return IslandViewModel(
            capture: capture,
            presentation: presentation,
            statusLabel: label,
            isMicMuted: isMicMuted,
            isOutputMuted: isOutputMuted,
            isPaused: isPaused,
            availableActions: actions,
            sessionID: sessionID,
            preparationProgress: nil,  // filled in by coordinator when engines are preparing
            captureCanRepair: captureCanRepair
        )
    }
}
