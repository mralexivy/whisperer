//
//  IslandPanelController.swift
//  Whisperer
//
//  @MainActor controller that owns the IslandPanel's lifetime, placement, and display changes.
//
//  Responsibilities:
//  - Position the panel on the correct screen using IslandGeometryProvider.
//  - Rehome on NSApplication.didChangeScreenParametersNotification and on
//    NSWorkspace.activeSpaceDidChangeNotification, without touching capture state.
//  - Close orphaned IslandPanel windows left by window restoration.
//  - Show / hide the panel based on the IslandViewModel forwarded by IslandCoordinator.
//  - Forward tap-outside / keyboard events to IslandCoordinator as IslandEvents.
//
//  This controller does NOT drive the state machine — it is driven by IslandCoordinator,
//  which feeds it `IslandViewModel` snapshots.
//

import AppKit
import SwiftUI

@MainActor
final class IslandPanelController {

    // MARK: - Dependencies

    private var geo: IslandGeometryProvider = {
        var g = IslandGeometryProvider()
        g.placement = IslandPlacement.current
        return g
    }()
    private weak var coordinator: IslandCoordinator?

    // MARK: - Panel

    private var panel: IslandPanel?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var currentScreen: NSScreen?
    /// Pending settle work items for the current Space transition.
    private var spaceSettleWork: [DispatchWorkItem] = []

    // MARK: - Init / Deinit

    init(coordinator: IslandCoordinator) {
        self.coordinator = coordinator
        closeOrphanedPanels()
        observeScreenChanges()
    }

    deinit {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        spaceSettleWork.forEach { $0.cancel() }
    }

    // MARK: - Public API (called by IslandCoordinator)

    /// Apply a new view model snapshot. Creates the panel if needed, updates its frame and
    /// visibility. The SwiftUI content is updated reactively via the coordinator's @Published model.
    /// `screen` is the coordinator's home display — the same one its `currentScreen` describes.
    /// The controller must NOT pick its own, or the window frame and the SwiftUI layout inside
    /// it end up describing different displays.
    func apply(viewModel: IslandViewModel, screen: NSScreen?) {
        if viewModel.presentation == .hidden {
            hide()
            return
        }

        guard let screen = screen
                ?? IslandGeometryProvider.activeScreen()
                ?? NSScreen.main else { return }

        if panel == nil || currentScreen !== screen {
            if panel != nil {
                Logger.debug("Island rehoming to \(screen.localizedName)", subsystem: .ui)
            }
            currentScreen = screen
            buildPanel(on: screen)
        } else if let panel = panel {
            // Same display, but its visibleFrame may have moved (Dock shown / hidden / relocated).
            // Reframing in place keeps the hosting view — and its hover state — alive.
            let envelope = geo.panelEnvelope(for: .from(screen))
            if panel.frame != envelope {
                panel.setFrame(envelope, display: true)
            }
        }

        showPanel()
    }

    /// Update placement without rebuilding the panel — teleports the window to the new edge.
    /// Called when the user changes the placement setting while the Island is visible.
    func applyPlacementChange(placement: IslandPlacement, screen: NSScreen?) {
        geo.placement = placement
        guard let screen = screen ?? currentScreen ?? NSScreen.main,
              let panel = panel else { return }
        let envelope = geo.panelEnvelope(for: .from(screen))
        // No animation — the bar teleports; a sliding transition across the desktop is jarring.
        panel.setFrame(envelope, display: true)
        Logger.debug("Island placement changed to \(placement.rawValue)", subsystem: .ui)
    }

    /// Dismiss the panel with a fade animation.
    func hide() {
        guard let panel = panel, panel.isVisible else { return }
        coordinator?.callTeardown()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
            panel?.alphaValue = 1
        }
    }

    /// Force-close the panel without animation (e.g., on app quit).
    func close() {
        coordinator?.callTeardown()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    // MARK: - Panel lifecycle

    private func buildPanel(on screen: NSScreen) {
        // Call deterministic teardown before recycling the panel
        coordinator?.callTeardown()

        panel?.orderOut(nil)
        panel?.close()

        let newPanel = IslandPanel()
        self.panel = newPanel

        let description = ScreenDescription.from(screen)
        logPlacement(for: description, screen: screen)
        let envelope = geo.panelEnvelope(for: description)
        newPanel.setFrame(envelope, display: false)

        if let coordinator = coordinator {
            // Wire coordinator into the container so scroll/hover NSView overrides work
            newPanel.coordinator = coordinator

            let hitBox = newPanel.hitBox
            newPanel.setContent(
                IslandContentView(coordinator: coordinator, hitBox: hitBox)
            )
        }
    }

    private func logPlacement(for description: ScreenDescription, screen: NSScreen) {
        Logger.debug("""
            Island placement: \(geo.placement.rawValue) on \(screen.localizedName) — \
            envelope \(geo.panelEnvelope(for: description))
            """, subsystem: .ui)
    }

    private func showPanel() {
        guard let panel = panel else { return }
        if !panel.isVisible {
            panel.orderFrontRegardless()
            panel.alphaValue = 1
        }
    }

    // MARK: - Screen changes

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }

        // The Dock's presence — not `visibleFrame` — is what decides the anchor, and the Dock
        // leaves the window server's on-screen list DURING the Space-switch animation. Polling
        // it is therefore strictly earlier than `activeSpaceDidChangeNotification`, which macOS
        // only posts once the animation has finished. Driving the anchor from the poll is what
        // makes the Island already be in the right place when the new Space lands.
        DockPresenceMonitor.shared.onChange = { [weak self] present in
            guard let self else { return }
            Logger.debug("Island: dock presence → \(present) at t=\(Self.nowMS())ms", subsystem: .ui)
            self.reframeInPlace()
        }
        DockPresenceMonitor.shared.start()

        // Kept only as a backstop: it catches Space switches where the Dock state does not change
        // at all (Desktop 2 → Desktop 3), which the poll cannot see.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSpaceChange() }
        }
    }

    /// Monotonic milliseconds, for comparing the poll's timing against the notification's.
    private static func nowMS() -> Int {
        Int(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    /// A Space switch changes only whether the Dock insets `visibleFrame` — the Island must
    /// stay on the display it is already on. So this reframes in place and must NOT rehome by
    /// pointer location.
    ///
    /// `NSScreen.visibleFrame` is updated by macOS asynchronously after the Space switch —
    /// it can lag by anywhere from 200 ms to well over a second. We fire immediately (will
    /// likely get the stale Dock inset) then at several increasing intervals so one of the
    /// retries lands after macOS has committed the new geometry.
    /// The panel envelope is Dock-independent, so a Space switch never resizes or moves the
    /// window — the only thing that changes is `anchorSlack` inside it, which SwiftUI applies in
    /// a single layout pass. There is therefore nothing to hide and nothing to fade: just
    /// re-publish the geometry synchronously.
    private func handleSpaceChange() {
        Logger.debug("Island: activeSpaceDidChange at t=\(Self.nowMS())ms", subsystem: .ui)
        cancelSpaceSettle()
        reframeInPlace()
    }

    private func cancelSpaceSettle() {
        spaceSettleWork.forEach { $0.cancel() }
        spaceSettleWork.removeAll()
    }

    /// Recompute the envelope for the display the panel already lives on and apply it.
    private func reframeInPlace() {
        guard let panel, let screen = currentScreen else {
            Logger.debug("Island: reframeInPlace skipped — panel=\(panel != nil) screen=\(currentScreen != nil)", subsystem: .ui)
            return
        }
        let desc = ScreenDescription.from(screen)
        let newEnvelope = geo.panelEnvelope(for: desc)
        Logger.debug("""
            Island: reframeInPlace — \
            frame=\(desc.frame) visibleFrame=\(desc.visibleFrame) \
            dockOnSpace=\(desc.isDockOnActiveSpace) \
            anchor=\(IslandGeometryProvider.edgeAnchor(for: desc, placement: geo.placement)) \
            hasObstruction=\(IslandGeometryProvider.hasEdgeObstruction(desc, placement: geo.placement)) \
            envelope: \(panel.frame) → \(newEnvelope)
            """, subsystem: .ui)
        if panel.frame != newEnvelope {
            panel.setFrame(newEnvelope, display: true)
        }
        coordinator?.refreshHomeScreenGeometry()
    }

    private func handleScreenChange() {
        Logger.debug("Island: screen parameters changed", subsystem: .ui)
        coordinator?.send(.displayChanged)

        // If the current screen still exists this is likely a Dock/menu-bar geometry change
        // (happens when switching to a fullscreen Space). Reframe in place to avoid the
        // pointer-chasing rehome that repositions on the wrong display.
        // Only rehome fully when the home screen itself has disappeared.
        if let current = currentScreen, NSScreen.screens.contains(current) {
            reframeInPlace()
        } else {
            coordinator?.rehomeToActiveScreen()
        }
    }

    // MARK: - Orphan cleanup

    private func closeOrphanedPanels() {
        let orphans = NSApp.windows.filter { $0 is IslandPanel && $0 !== panel }
        guard !orphans.isEmpty else { return }
        Logger.warning("Closing \(orphans.count) orphaned IslandPanel(s)", subsystem: .ui)
        for orphan in orphans {
            orphan.orderOut(nil)
            orphan.close()
        }
    }
}
