//
//  IslandCoordinator.swift
//  Whisperer
//
//  @MainActor ObservableObject orchestrator — the only Island component that touches AppState.
//
//  Responsibilities:
//  - Subscribe to AppStateChanged and translate it into IslandEvents.
//  - Feed events into IslandReducer to produce a new IslandModel.
//  - Publish `currentViewModel` and `currentScreen` for IslandContentView to observe.
//  - Execute effects by calling AppState APIs.
//  - Own IslandLevelBridge (wired to AudioRecorder.onAmplitudeUpdate) and IslandElapsedTimer.
//  - Manage hover-to-open with dwell/debounce/top-edge retention (Atoll DynamicIslandViewModel).
//  - Forward scroll wheel gestures from IslandContainerView as rubber-band expand/collapse.
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
        safeAreaTopInset: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil, backingScale: 2
    )

    // MARK: - Interaction state (observed by IslandContentView)

    /// True while the pointer is inside the hover rect (drives lift animation + shadow)
    @Published private(set) var isHovering: Bool = false
    /// 0–20 rubber-band value driven by downward scroll (feeds width stretch)
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
    private let hoverDwell:        Double = 0.18  // seconds before auto-expand
    private let hoverExitDebounce: Duration = .milliseconds(100)

    // Amplitude callback dedup
    private var amplitudeWiredToRecorder: ObjectIdentifier?

    // Teardown
    var teardownHook: (() -> Void)?

    /// The forgiving hover rect in global screen coordinates. Written by IslandContentView so
    /// the top-edge retention test can check the pointer against the real island span.
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

    // MARK: - Hover management (Atoll DynamicIslandViewModel.handleHover equivalent)

    func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        hoverTask = nil

        if hovering {
            withAnimation(.bouncy.speed(1.2)) { isHovering = true }
            triggerHapticIfAllowed()

            // Dwell → auto-expand (only while compact, not finalizing/starting etc.)
            let dwell = hoverDwell
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(dwell))
                guard !Task.isCancelled, let self else { return }
                guard self.isHovering else { return }
                guard self.currentViewModel.presentation == .compact else { return }
                guard case .recording = self.currentViewModel.capture else { return }
                self.send(.expand)
            }
        } else {
            // Debounce exit — check top-edge retention after delay
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: self?.hoverExitDebounce ?? .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                if self.shouldRetainHoverAtTopEdge() { return }
                self.finishHoverExit()
            }
        }
    }

    private func finishHoverExit() {
        withAnimation(.bouncy.speed(1.2)) { isHovering = false }
        if currentViewModel.presentation == .expanded {
            send(.collapse)
        }
    }

    /// Ignore hover-exit when cursor parks on the screen's top pixel row and is inside
    /// the hover rect. macOS reports a spurious exit there — Atoll's shouldRetainHoverAtScreenTopEdge.
    private func shouldRetainHoverAtTopEdge() -> Bool {
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(loc) || abs($0.frame.maxY - loc.y) < 2
        }) else { return false }
        // Only the very top pixel row produces the spurious exit.
        guard loc.y >= screen.frame.maxY - 1.5 else { return false }
        // CGRect.contains is half-open on the max edges, so test the horizontal span inclusively.
        let span = hoverRectOnScreen
        guard span.width > 0 else { return false }
        return loc.x >= span.minX && loc.x <= span.maxX
    }

    // MARK: - Scroll gesture (Atoll handleOpenScrollGesture / handleCloseScrollGesture)

    func handleScrollWheel(delta: CGFloat, phase: NSEvent.Phase) {
        let sensitivity: CGFloat = 50
        let presentation = currentViewModel.presentation

        if phase == .ended || phase == .cancelled {
            withAnimation(.smooth) { gestureProgress = 0 }
            return
        }

        if delta > 0 {
            // Scroll down → stretch → expand
            guard presentation == .compact else { return }
            let progress = min((delta / sensitivity) * 20, 20)
            withAnimation(.smooth) { gestureProgress = progress }

            if delta > sensitivity {
                withAnimation(.smooth) { gestureProgress = 0 }
                send(.expand)
                triggerHapticIfAllowed()
            }
        } else if delta < 0 {
            // Scroll up → collapse
            guard presentation == .expanded else {
                withAnimation(.smooth) { gestureProgress = 0 }
                return
            }
            if delta < -sensitivity {
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

    /// Observe AppState directly rather than the "AppStateChanged" notification.
    ///
    /// That notification is posted by only a handful of `didSet` blocks — `isPaused`,
    /// `isMicMuted`, `isOutputAudioMuted` and `activeMeetingSession` do NOT post it. Listening
    /// to it alone left the Island blind to every control it is supposed to reflect: pausing
    /// from the menu bar never froze the bars, muting never swapped the glyph, and a meeting
    /// starting only surfaced the Island by luck of some other property changing.
    ///
    /// `objectWillChange` fires for every `@Published` on the singleton. It fires *before* the
    /// value lands, so hop through the main run loop to read the settled state.
    private func wireAppState() {
        AppState.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncFromAppState() }
            .store(in: &cancellables)
        rewireAmplitudeCallback()
        syncFromAppState()
    }

    private func syncFromAppState() {
        rewireAmplitudeCallback()
        let appState = AppState.shared

        let inMeeting     = appState.isMeetingMode
        let windowVisible = appState.meetingWindowIsVisible
        let islandActive  = inMeeting && !windowVisible

        if !inMeeting {
            if model.capture != .idle { send(.captureEnded) }
            return
        }

        if !islandActive {
            // A meeting window is handling the UI — suppress Island without stopping capture
            if model.presentation != .hidden {
                model.presentation = .hidden
                publishViewModel()
                levelBridge.stopTimer(freezeAtCurrent: false)
            }
            return
        }

        // Ensure session is started
        if model.capture == .idle {
            if let session = appState.activeMeetingSession,
               let sessionID = session.meetingID {
                send(.meetingStarted(sessionID: sessionID))
            }
        }

        // Mirror the authoritative mute flags — the reducer's optimistic toggle is only a
        // placeholder until AppState confirms, and mutes can also change from the menu bar.
        if model.isMicMuted != appState.isMicMuted {
            model.isMicMuted = appState.isMicMuted
        }
        if model.isOutputMuted != appState.isOutputAudioMuted {
            model.isOutputMuted = appState.isOutputAudioMuted
        }

        // Sync mute / pause / recording state
        if appState.isPaused {
            if model.capture == .recording { send(.capturePaused) }
        } else {
            if model.capture == .paused   { send(.captureResumed) }
            if model.capture == .starting { send(.captureConfirmed) }
        }

        levelBridge.setState(isMuted: appState.isMicMuted, isPaused: appState.isPaused)

        if model.presentation != .hidden && model.capture == .recording {
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

            case .scheduleHide(let delay):
                scheduleHide(after: delay)

            case .cancelHide:
                hideWorkItem?.cancel()
                hideWorkItem = nil
            }
        }
    }

    // MARK: - Publish

    private func publishViewModel() {
        currentViewModel = model.viewModel()

        // Sync elapsed display
        switch model.capture {
        case .recording:
            if let session = AppState.shared.activeMeetingSession {
                elapsedTimer.sync(to: session.elapsedSeconds)
            }
        case .paused:
            break // frozen
        default:
            elapsedTimer.stop()
        }

        // Update screen description
        if let screen = IslandGeometryProvider.activeScreen() {
            currentScreen = ScreenDescription.from(screen)
        }

        panelController?.apply(viewModel: currentViewModel)
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
