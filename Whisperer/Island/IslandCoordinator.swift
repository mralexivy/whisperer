//
//  IslandCoordinator.swift
//  Whisperer
//
//  @MainActor ObservableObject orchestrator — the only Island component that touches AppState.
//
//  Responsibilities:
//  - Subscribe to AppState.objectWillChange and translate it into IslandEvents.
//  - Feed events into IslandReducer to produce a new IslandModel.
//  - Publish `currentViewModel` and `currentScreen` for IslandContentView to observe.
//  - Execute effects by calling AppState APIs.
//  - Own IslandLevelBridge (wired to AudioRecorder.onAmplitudeUpdate) and IslandElapsedTimer.
//  - Hover management: peek → compact after 120 ms dwell; compact → expanded via scroll/click.
//  - Scroll gesture: UP = expand (pull island out of bottom edge), DOWN = collapse.
//  - Bottom-edge hover retention: ignore spurious exit when cursor is at screen.frame.minY.
//  - Waveform timer gating: 60 Hz only when compact or expanded; silent during peek.
//  - Rate-limited haptic feedback (300 ms minimum between firings).
//  - Deterministic teardown via teardownHook before panel recycling.
//
//  Visibility rule: Island is shown iff `isMeetingMode && !meetingWindowIsVisible`.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class IslandCoordinator: ObservableObject {

    // MARK: - Published (observed by IslandContentView)

    @Published private(set) var currentViewModel:  IslandViewModel = .hidden
    @Published private(set) var currentScreen:     ScreenDescription = ScreenDescription(
        frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 837),
        backingScale: 2
    )

    // MARK: - Interaction state (observed by IslandContentView)

    /// True while the pointer is inside the hover rect (drives lift animation + shadow)
    @Published private(set) var isHovering: Bool = false
    /// 0–20 rubber-band value driven by upward scroll (feeds width stretch)
    @Published private(set) var gestureProgress: CGFloat = 0
    /// Toggles to trigger .alignment haptic; rate-limited to 300 ms
    @Published private(set) var hapticToken: Bool = false

    // MARK: - Owned objects

    let levelBridge  = IslandLevelBridge()
    let elapsedTimer = IslandElapsedTimer()

    // MARK: - Private

    private let geo                = IslandGeometryProvider()
    private var model              = IslandModel.initial
    private(set) var panelController: IslandPanelController?
    private var cancellables       = Set<AnyCancellable>()
    private var hideWorkItem:      DispatchWorkItem?

    // Hover
    private var hoverTask:         Task<Void, Never>?
    private var lastHapticDate:    Date = .distantPast
    private let peekDwell:         Double = 0.12  // peek → compact dwell (120 ms)
    private let hoverExitDebounce: Duration = .milliseconds(100)

    // AppState dedup snapshot — syncFromAppState() only runs when these 8 fields change.
    private var lastSnapshot: AppStateSnapshot?

    // Amplitude callback dedup
    private var amplitudeWiredToRecorder: ObjectIdentifier?

    // Teardown
    var teardownHook: (() -> Void)?

    /// The forgiving hover rect in global screen coordinates. Written by IslandContentView so
    /// the bottom-edge retention test can check the pointer against the real island span.
    var hoverRectOnScreen: NSRect = .zero

    // MARK: - Init / Deinit

    init() {
        panelController = IslandPanelController(coordinator: self)
        wireAppState()
    }

    deinit { }

    // MARK: - Teardown

    func callTeardown() {
        teardownHook?()
        teardownHook = nil
        cancelHoverTask()
    }

    func cancelHoverTask() {
        hoverTask?.cancel()
        hoverTask = nil
    }

    // MARK: - Public (events)

    func send(_ event: IslandEvent) {
        let effects = IslandReducer.reduce(&model, event)
        applyEffects(effects)
        publishViewModel()
    }

    // MARK: - Hover management

    func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        hoverTask = nil

        if hovering {
            withAnimation(.bouncy.speed(1.2)) { isHovering = true }
            triggerHapticIfAllowed()

            // Peek → compact dwell (120 ms). Only fires from .peek.
            let dwell = peekDwell
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(dwell))
                guard !Task.isCancelled, let self else { return }
                guard self.isHovering else { return }
                guard self.currentViewModel.presentation == .peek else { return }
                self.send(.expand)   // peek → compact
            }
        } else {
            // Debounce exit — check bottom-edge retention after delay
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: self?.hoverExitDebounce ?? .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                if self.shouldRetainHoverAtBottomEdge() { return }
                self.finishHoverExit()
            }
        }
    }

    private func finishHoverExit() {
        withAnimation(.bouncy.speed(1.2)) { isHovering = false }
        // Return to peek (or compact if state requires it).
        send(.peekRequested)
    }

    /// Ignore hover-exit when cursor parks on the screen's bottom pixel row and is inside
    /// the hover rect. macOS occasionally reports spurious exits at the screen edge.
    private func shouldRetainHoverAtBottomEdge() -> Bool {
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(loc) || abs($0.frame.minY - loc.y) < 2
        }) else { return false }
        // Only the very bottom pixel row produces the spurious exit.
        guard loc.y <= screen.frame.minY + 1.5 else { return false }
        let span = hoverRectOnScreen
        guard span.width > 0 else { return false }
        return loc.x >= span.minX && loc.x <= span.maxX
    }

    // MARK: - Scroll gesture
    //
    // Bottom-anchored island: scroll UP = expand (pull island up), scroll DOWN = collapse.
    // This is the inverse of the top-anchored Island where scrolling down opened it.

    func handleScrollWheel(delta: CGFloat, phase: NSEvent.Phase) {
        let sensitivity: CGFloat = 50
        let presentation = currentViewModel.presentation

        if phase == .ended || phase == .cancelled {
            withAnimation(.smooth) { gestureProgress = 0 }
            return
        }

        if delta < 0 {
            // Scroll up (negative delta on a standard trackpad) → stretch → expand
            guard presentation == .peek || presentation == .compact else { return }
            let progress = min(((-delta) / sensitivity) * 20, 20)
            withAnimation(.smooth) { gestureProgress = progress }

            if -delta > sensitivity {
                withAnimation(.smooth) { gestureProgress = 0 }
                send(.expand)
                triggerHapticIfAllowed()
            }
        } else if delta > 0 {
            // Scroll down → collapse
            guard presentation == .expanded || presentation == .compact else {
                withAnimation(.smooth) { gestureProgress = 0 }
                return
            }
            if delta > sensitivity {
                send(.collapse)
                withAnimation(.bouncy.speed(1.2)) { isHovering = false }
                withAnimation(.smooth) { gestureProgress = 0 }
                triggerHapticIfAllowed()
            }
        }
    }

    // MARK: - Haptics

    private func triggerHapticIfAllowed() {
        let now = Date()
        guard now.timeIntervalSince(lastHapticDate) > 0.3 else { return }
        lastHapticDate = now
        hapticToken.toggle()
    }

    // MARK: - Amplitude callback

    private func rewireAmplitudeCallback() {
        guard let recorder = AppState.shared.audioRecorder else { return }
        let recID = ObjectIdentifier(recorder)
        guard recID != amplitudeWiredToRecorder else { return }
        amplitudeWiredToRecorder = recID

        let existing = recorder.onAmplitudeUpdate
        recorder.onAmplitudeUpdate = { [weak self, weak recorder] rms in
            existing?(rms)
            guard let self, recorder != nil else { return }
            self.levelBridge.push(rms: rms)
        }
    }

    // MARK: - AppState subscription

    private func wireAppState() {
        AppState.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Rewire amplitude callback on every change — it is guard-guarded and fast.
                self.rewireAmplitudeCallback()
                // Expensive sync only when Island-relevant fields change.
                let snap = AppStateSnapshot()
                guard snap != self.lastSnapshot else { return }
                self.lastSnapshot = snap
                self.syncFromAppState()
            }
            .store(in: &cancellables)
        rewireAmplitudeCallback()
        lastSnapshot = AppStateSnapshot()
        syncFromAppState()
    }

    private func syncFromAppState() {
        rewireAmplitudeCallback()
        let appState = AppState.shared

        let inMeeting     = appState.isMeetingMode
        let windowVisible = appState.meetingWindowIsVisible

        // A dictation (or its transcribe/insert tail) puts the OverlayPanel HUD at
        // bottom-center — exactly where the Island lives. The HUD is the richer surface and
        // already carries pause/stop, so the Island yields the spot for the whole session.
        let dictationHUDVisible = !inMeeting && appState.state != .idle

        // The meeting window owns the live UI when it is up; onboarding owns the screen
        // outright. In all these cases the Island stands down entirely.
        if windowVisible || dictationHUDVisible || !appState.hasCompletedOnboarding {
            if model.presentation != .hidden {
                model.presentation = .hidden
                publishViewModel()
                levelBridge.stopTimer(freezeAtCurrent: false)
            }
            return
        }

        if !inMeeting {
            // No capture: rest as the idle launcher bar rather than disappearing.
            if model.capture != .idle {
                send(.captureEnded)
            } else {
                if model.presentation == .hidden { model.presentation = .compact }
                // Always publish. The panel is built lazily inside apply(), so skipping the
                // publish on an already-correct model means the panel is never created at all
                // and the Island stays absent until some later state change forces it.
                publishViewModel()
            }
            return
        }

        if model.capture == .idle {
            if let session = appState.activeMeetingSession,
               let sessionID = session.meetingID {
                send(.meetingStarted(sessionID: sessionID))
            }
        }

        if model.isMicMuted != appState.isMicMuted {
            model.isMicMuted = appState.isMicMuted
        }
        if model.isOutputMuted != appState.isOutputAudioMuted {
            model.isOutputMuted = appState.isOutputAudioMuted
        }

        if appState.isPaused {
            if model.capture == .recording { send(.capturePaused) }
        } else {
            if model.capture == .paused   { send(.captureResumed) }
            if model.capture == .starting { send(.captureConfirmed) }
        }

        levelBridge.setState(isMuted: appState.isMicMuted, isPaused: appState.isPaused)

        // Waveform timer only runs when the row is visible (compact or expanded).
        // During peek the 12 Hz peekLevel path handles the nub glow at much lower CPU cost.
        let waveformActive = model.presentation == .compact || model.presentation == .expanded
        if waveformActive && model.capture == .recording {
            levelBridge.startTimer()
        } else {
            levelBridge.stopTimer(freezeAtCurrent: appState.isPaused)
        }

        publishViewModel()
    }

    // MARK: - Effect execution

    private func applyEffects(_ effects: [IslandEffect]) {
        for effect in effects {
            switch effect {
            case .stopCapture:
                AppState.shared.stopActiveRecording()

            case .togglePause:
                AppState.shared.togglePause()
                if AppState.shared.isPaused {
                    elapsedTimer.pause()
                    levelBridge.stopTimer(freezeAtCurrent: true)
                } else {
                    elapsedTimer.resume()
                    levelBridge.startTimer()
                }

            case .toggleMicMute:
                AppState.shared.toggleMicMute()
                levelBridge.setState(isMuted: AppState.shared.isMicMuted,
                                     isPaused: AppState.shared.isPaused)

            case .toggleOutputMute:
                AppState.shared.toggleOutputAudioMute()

            case .openMeetingWindow:
                if let session = AppState.shared.activeMeetingSession {
                    MeetingLiveWindowManager.shared.show(session: session)
                }

            case .startDictation:
                // Hands-free: no key is held, so nothing will release to stop it. The dictation
                // HUD owns the bottom of the screen from here (the Island stands down in
                // syncFromAppState) and its stop button ends the session.
                let appState = AppState.shared
                appState.startRecording()
                // startRecording() bails silently when a model is still loading or a file
                // transcription holds the engine — only claim hands-free if it actually started.
                if appState.state.isRecording {
                    appState.isHandsFreeRecording = true
                } else {
                    Logger.info("Island dictate: startRecording() declined — leaving the launcher up",
                                subsystem: .ui)
                }

            case .openPasteBin:
                // Same surface Option+V drives, but as a toggle: the launcher icon is the
                // only way back out of a picker opened by mouse, since there is no Option
                // key to release. Dismissal routes through onDismiss → resetPickerVisible(),
                // so GlobalKeyListener's own flag stays consistent either way.
                let picker = TranscriptionPickerState.shared
                if picker.isVisible {
                    picker.dismiss()
                } else {
                    picker.show()
                }

            case .openWorkspace:
                HistoryWindowManager.shared.showWindow()

            case .startMeeting:
                let session = MeetingSession()
                Task { @MainActor in
                    await session.startRecording(
                        title: NSLocalizedString("island.newMeeting", value: "Meeting",
                                                 comment: "Default title for a meeting started from the Island"),
                        surface: .floatingWindow
                    )
                }

            case .scheduleHide(let delay):
                scheduleHide(after: delay)

            case .cancelHide:
                hideWorkItem?.cancel()
                hideWorkItem = nil
            }
        }
    }

    /// Selects a workspace sidebar section. Posted twice on purpose: `HistoryWindowView`
    /// subscribes in `onReceive`, which is not wired yet on the very first `showWindow()`,
    /// so the immediate post is a no-op on a cold open. Re-selecting the same section is
    /// idempotent, so the follow-up costs nothing when the first post already landed.
    private func postWorkspaceSection(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

    // MARK: - Publish

    private func publishViewModel() {
        currentViewModel = model.viewModel()

        // Elapsed timer: the recording nub shows the clock too, so it ticks on every
        // visible tier. Only a hidden Island pauses it.
        switch model.capture {
        case .recording:
            if model.presentation != .hidden {
                if let session = AppState.shared.activeMeetingSession {
                    elapsedTimer.sync(to: session.elapsedSeconds)
                }
            } else {
                elapsedTimer.pause()
            }
        case .paused:
            break // frozen
        default:
            elapsedTimer.stop()
        }

        updateHomeScreenIfSettled()

        // Waveform timer gating (also done in syncFromAppState — this catches reducer-driven
        // transitions like stop/collapse that don't go through syncFromAppState).
        let waveformActive = model.presentation == .compact || model.presentation == .expanded
        if waveformActive && model.capture == .recording {
            levelBridge.startTimer()
        } else {
            let freeze = model.capture == .paused
            levelBridge.stopTimer(freezeAtCurrent: freeze)
        }

        panelController?.apply(viewModel: currentViewModel, screen: homeScreen)
    }

    // MARK: - Home screen

    /// The one display the Island is placed on.
    ///
    /// Single source of truth on purpose. The panel frame and the SwiftUI content geometry
    /// used to resolve `activeScreen()` independently, one publish apart, so the pill could be
    /// laid out for one display inside a window framed for another — which is exactly what
    /// made placement look inconsistent between screens.
    private var homeScreen: NSScreen?

    /// Re-picks the home display, but only when the Island is a passive nub.
    ///
    /// `activeScreen()` follows the pointer, and `publishViewModel()` runs on every AppState
    /// change. Re-picking unconditionally would yank the bar out from under the pointer
    /// mid-hover and hop it between displays while a row is open.
    private func updateHomeScreenIfSettled() {
        let settled = homeScreen == nil || (model.presentation == .peek && !isHovering)
        guard settled,
              let screen = IslandGeometryProvider.activeScreen(),
              screen !== homeScreen else { return }
        homeScreen = screen
        currentScreen = ScreenDescription.from(screen)
    }

    /// Force the Island back onto the active display and re-publish. Called when the display
    /// configuration itself changes (resolution, Dock, monitor plugged in), where the settled
    /// guard above must not apply.
    func rehomeToActiveScreen() {
        guard let screen = IslandGeometryProvider.activeScreen() else { return }
        homeScreen = screen
        currentScreen = ScreenDescription.from(screen)
        publishViewModel()
    }

    // MARK: - Auto-hide

    private func scheduleHide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.send(.captureEnded)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// MARK: - AppState snapshot (Island dedup)

/// The 8 AppState fields that IslandCoordinator.syncFromAppState() reads.
/// A change in any other @Published AppState property is filtered out, eliminating
/// the per-property-change full sync that was the main source of redundant Island work.
private struct AppStateSnapshot: Equatable {
    let isMeetingMode:          Bool
    let meetingWindowIsVisible: Bool
    let state:                  RecordingState
    let hasCompletedOnboarding: Bool
    let isMicMuted:             Bool
    let isOutputAudioMuted:     Bool
    let isPaused:               Bool
    let activeMeetingID:        UUID?

    init() {
        let a = AppState.shared
        isMeetingMode          = a.isMeetingMode
        meetingWindowIsVisible = a.meetingWindowIsVisible
        state                  = a.state
        hasCompletedOnboarding = a.hasCompletedOnboarding
        isMicMuted             = a.isMicMuted
        isOutputAudioMuted     = a.isOutputAudioMuted
        isPaused               = a.isPaused
        activeMeetingID        = a.activeMeetingSession?.meetingID
    }
}
