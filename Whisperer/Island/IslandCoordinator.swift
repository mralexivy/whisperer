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

    /// The launcher glyph currently under the pointer, if any.
    ///
    /// The bar is four bare icons with no captions, so it needs to name them on hover.
    /// The label is drawn by the root view *above* the pill — the pill itself is clipped
    /// to its capsule, so anything rendered inside it would be cut off.
    @Published private(set) var launcherHint: IslandLauncherHint?

    /// Progressive reveal phase for the idle launcher bar.
    /// Non-idle capture states are always `.revealed` (they bypass the gate).
    @Published private(set) var idleRevealPhase: IslandRevealPhase = .hidden

    /// Current placement (read by IslandContentView and IslandPanelController).
    @Published private(set) var placement: IslandPlacement = IslandPlacement.current

    // MARK: - Owned objects

    let levelBridge  = IslandLevelBridge()
    let elapsedTimer = IslandElapsedTimer()

    // MARK: - Private

    private var geo: IslandGeometryProvider = {
        var g = IslandGeometryProvider()
        g.placement = IslandPlacement.current
        return g
    }()
    private var model              = IslandModel.initial
    private(set) var panelController: IslandPanelController?
    private var cancellables       = Set<AnyCancellable>()
    private var hideWorkItem:      DispatchWorkItem?

    // Hover
    private var hoverTask:         Task<Void, Never>?
    /// Completes the reveal dwell without needing further mouse events. See
    /// `scheduleDwellCompletion(after:)`.
    private var dwellTask:         Task<Void, Never>?
    private var lastHapticDate:    Date = .distantPast
    private let peekDwell:         Double = 0.12  // peek → compact dwell (120 ms)
    private let hoverExitDebounce: Duration = .milliseconds(100)

    // Idle reveal gate
    private var revealGate: IslandRevealGate = IslandRevealGate()

    // AppState dedup snapshot — syncFromAppState() only runs when these 8 fields change.
    private var lastSnapshot: AppStateSnapshot?

    // Amplitude callback dedup
    private var amplitudeWiredToRecorder: ObjectIdentifier?

    // Teardown
    var teardownHook: (() -> Void)?

    /// The forgiving hover rect in global screen coordinates. Written by IslandContentView so
    /// the edge-retention test can check the pointer against the real island span.
    var hoverRectOnScreen: NSRect = .zero

    // MARK: - Init / Deinit

    init() {
        panelController = IslandPanelController(coordinator: self)
        wireAppState()
        wirePlacementNotification()
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
        cancelDwellTask()
    }

    // MARK: - Placement

    private func wirePlacementNotification() {
        NotificationCenter.default.addObserver(
            forName: .islandPlacementChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let p = IslandPlacement.current
            self.placement = p
            self.geo.placement = p
            // Reset the reveal gate so the bar doesn't appear at the new edge instantly.
            self.cancelDwellTask()
            self.revealGate.reset()
            self.idleRevealPhase = .hidden
            self.panelController?.applyPlacementChange(placement: p, screen: self.homeScreen)
        }
    }

    // MARK: - Pointer tracking (reveal gate)

    /// Called by IslandContainerView.updateHover on every NSMouseMoved event inside the panel.
    /// Drives the progressive reveal gate for the idle launcher.
    func handlePointerMoved(point: NSPoint, inside: Bool) {
        guard model.capture == .idle else {
            // Non-idle states are always fully revealed — no gate needed.
            if idleRevealPhase != .revealed { idleRevealPhase = .revealed }
            return
        }
        guard inside else {
            cancelDwellTask()
            applyRevealPhase(revealGate.step(point: point, inside: false,
                                             now: Date().timeIntervalSinceReferenceDate))
            return
        }
        guard idleRevealPhase != .revealed else { return }

        // Deliberately does NOT re-arm the timer on every move. The timer is armed once, on
        // hover-enter; letting each mouse-moved event cancel and reschedule it meant the
        // slightest tremor kept pushing the finish line away, so approaching the handle
        // "carefully" made it open later than approaching it carelessly. Only a move large
        // enough to re-anchor the gate — a genuine change of target, not aim wobble —
        // restarts the countdown.
        let now = Date().timeIntervalSinceReferenceDate
        let before = revealGate.timeUntilReveal(now: now)
        revealGate.step(point: point, inside: true, now: now)
        if let after = revealGate.timeUntilReveal(now: now),
           let before, after > before + 0.001 {
            scheduleDwellCompletion(after: after)
        }
    }

    private func applyRevealPhase(_ phase: IslandRevealPhase) {
        guard phase != idleRevealPhase else { return }
        withAnimation(.easeIn(duration: IslandUX.hintFadeDuration)) {
            idleRevealPhase = phase
        }
    }

    /// Arm the auto-expand the moment the pointer enters the hover zone.
    ///
    /// This is keyed off `isHovering` rather than off pointer-moved geometry on purpose.
    /// `isHovering` is driven by `mouseEntered`/`mouseExited`, which fire exactly once per
    /// crossing and are unaffected by the pointer then holding perfectly still — so the
    /// launcher opens on its own for a user who parks on the handle, which is the whole
    /// point. Re-testing a screen-space rect at fire time (the previous approach) could not
    /// be trusted: that rect is recomputed while the reveal is animating, so it was being
    /// read mid-flight against a pointer that had not moved at all.
    private func armRevealDwell() {
        guard model.capture == .idle, idleRevealPhase != .revealed else { return }
        revealGate.entered(point: NSEvent.mouseLocation,
                           now: Date().timeIntervalSinceReferenceDate)
        scheduleDwellCompletion(after: IslandUX.revealDelay)
    }

    /// Finish the dwell on a timer rather than on mouse events. Only fires while the pointer
    /// is still hovering, so a pointer that sweeps straight back out never opens the launcher.
    private func scheduleDwellCompletion(after delay: TimeInterval) {
        cancelDwellTask()
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled, let self else { return }
            guard self.isHovering, self.model.capture == .idle else { return }
            self.revealGate.forceReveal(point: NSEvent.mouseLocation,
                                        now: Date().timeIntervalSinceReferenceDate)
            // The launcher row only renders above .peek, so lift the tier too — otherwise
            // the dwell completes and the user still sees no icons.
            if self.currentViewModel.presentation == .peek { self.send(.expand) }
            self.applyRevealPhase(.revealed)
        }
    }

    private func cancelDwellTask() {
        dwellTask?.cancel()
        dwellTask = nil
    }

    /// Skip the dwell and open the launcher now. Called when the user clicks the resting
    /// handle, which is a deliberate act and should not be made to wait out a timer.
    func revealLauncherNow() {
        guard model.capture == .idle, idleRevealPhase != .revealed else { return }
        cancelDwellTask()
        revealGate.forceReveal(point: NSEvent.mouseLocation,
                               now: Date().timeIntervalSinceReferenceDate)
        withAnimation(.easeOut(duration: IslandUX.hintFadeDuration)) {
            idleRevealPhase = .revealed
        }
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
            armRevealDwell()

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
            // Debounce exit — check anchored-edge retention after delay
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: self?.hoverExitDebounce ?? .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                if self.shouldRetainHoverAtAnchoredEdge() { return }
                self.finishHoverExit()
            }
        }
    }

    /// Pointer entered or left a launcher glyph.
    ///
    /// Only the title is stored. The chip's position is resolved from `LauncherAnchorKey` at
    /// render time, so it cannot be stale — passing a snapshotted anchor in here is what let
    /// a fast hover paint the chip at the panel edge before the real centre arrived.
    ///
    /// Leaving is keyed on the title so a fast slide between two glyphs cannot have the
    /// outgoing button's exit clear the incoming button's hint.
    func setLauncherHint(_ title: String?) {
        if let title {
            launcherHint = IslandLauncherHint(title: title)
        } else {
            launcherHint = nil
        }
    }

    func clearLauncherHint(ifTitleIs title: String) {
        guard launcherHint?.title == title else { return }
        launcherHint = nil
    }

    private func finishHoverExit() {
        launcherHint = nil
        cancelDwellTask()
        revealGate.reset()
        withAnimation(.bouncy.speed(1.2)) {
            isHovering = false
            idleRevealPhase = .hidden
        }
        // Return to peek (or compact if state requires it).
        send(.peekRequested)
    }

    /// Ignore spurious hover-exit when the cursor parks on the anchored screen edge pixel row
    /// and is inside the hover rect. macOS reports these exits at every physical screen edge.
    private func shouldRetainHoverAtAnchoredEdge() -> Bool {
        let loc = NSEvent.mouseLocation
        let p = placement
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(loc)
                || abs($0.frame.minY - loc.y) < 2
                || abs($0.frame.maxY - loc.y) < 2
                || abs($0.frame.minX - loc.x) < 2
                || abs($0.frame.maxX - loc.x) < 2
        }) else { return false }
        // Only the anchored edge pixel strip produces spurious exits.
        switch p {
        case .bottomCenter: guard loc.y <= screen.frame.minY + 1.5 else { return false }
        case .topCenter:    guard loc.y >= screen.frame.maxY - 1.5 else { return false }
        case .leftCenter:   guard loc.x <= screen.frame.minX + 1.5 else { return false }
        case .rightCenter:  guard loc.x >= screen.frame.maxX - 1.5 else { return false }
        }
        let span = hoverRectOnScreen
        switch p {
        case .bottomCenter, .topCenter:
            guard span.width > 0 else { return false }
            return loc.x >= span.minX && loc.x <= span.maxX
        case .leftCenter, .rightCenter:
            guard span.height > 0 else { return false }
            return loc.y >= span.minY && loc.y <= span.maxY
        }
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

        // A capture failure outranks every stand-down rule below, and it is checked before
        // them on purpose. On 2026-09-14 the Island rendered a healthy 68-minute recording
        // while the mic delivered nothing but zeros, then simply vanished when the state
        // collapsed to `.idle`. The failure row has to survive `.idle`, an open meeting
        // window and a dictation HUD, because those are exactly the moments it is needed.
        //
        // Non-terminal trouble shows too: long-form recovery retries indefinitely, so waiting
        // for a terminal verdict could mean never telling the user at all.
        if appState.hasCompletedOnboarding, let failure = appState.captureFailure {
            model.captureCanRepair = failure.canSelfRepair
            if model.capture != .failed(failure.message) {
                send(.captureFailed(failure.message))
            }
            if model.presentation == .hidden { model.presentation = .compact }
            levelBridge.stopTimer(freezeAtCurrent: false)
            publishViewModel()
            return
        }
        if case .failed = model.capture, appState.captureFailure == nil {
            // Recovered or dismissed upstream — drop the row and fall through to normal sync.
            send(.dismissFailure)
        }

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

            case .clearCaptureFailure:
                AppState.shared.clearCaptureFailure()

            case .repairCapture:
                AppState.shared.repairCaptureInput()

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

    /// Re-read the home display's geometry and re-publish, WITHOUT re-picking which display
    /// the Island lives on.
    ///
    /// This is the right call for a Space switch: the only thing that changed is whether the
    /// Dock insets `visibleFrame`, and the Island should stay where it is. Re-picking via
    /// `activeScreen()` here is actively wrong — that follows the pointer, which on a Space
    /// switch can be over a different display, so the panel ends up framed for one screen
    /// while the SwiftUI content is laid out for another. That mismatch is what left the bar
    /// floating in dead space with its hit box somewhere else entirely.
    func refreshHomeScreenGeometry() {
        guard let screen = homeScreen else { return }
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
    /// Drives the `.failed` row. Included so a capture failure that arrives *after* the
    /// recording state has already collapsed to `.idle` still wakes the sync — without it the
    /// snapshot would compare equal and the Island would keep showing the last happy state.
    let captureFailure:         AppState.CaptureFailure?

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
        captureFailure         = a.captureFailure
    }
}
