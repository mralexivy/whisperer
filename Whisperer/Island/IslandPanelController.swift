//
//  IslandPanelController.swift
//  Whisperer
//
//  @MainActor controller that owns the IslandPanel's lifetime, placement, and display changes.
//
//  Responsibilities:
//  - Position the panel on the correct screen using IslandGeometryProvider.
//  - Rehome on NSApplication.didChangeScreenParametersNotification without touching capture state.
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

    private let geo = IslandGeometryProvider()
    private weak var coordinator: IslandCoordinator?

    // MARK: - Panel

    private var panel: IslandPanel?
    private var screenObserver: NSObjectProtocol?
    private var currentScreen: NSScreen?

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
    }

    // MARK: - Public API (called by IslandCoordinator)

    /// Apply a new view model snapshot. Creates the panel if needed, updates its frame and
    /// visibility. The SwiftUI content is updated reactively via the coordinator's @Published model.
    func apply(viewModel: IslandViewModel) {
        if viewModel.presentation == .hidden {
            hide()
            return
        }

        let screen = IslandGeometryProvider.activeScreen() ?? NSScreen.main!
        currentScreen = screen

        if panel == nil {
            buildPanel(on: screen)
        } else if let panel = panel, panel.screen != screen {
            // User has moved their pointer to a different display while recording.
            Logger.debug("Island rehoming to new screen", subsystem: .ui)
            buildPanel(on: screen)
        }

        showPanel()
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

    /// Records which of the two placements the display resolved to. A notched Mac that reports
    /// no auxiliary areas silently falls back to the floating pill, which looks like the island
    /// is "next to" the hardware notch rather than replacing it — this line tells them apart.
    private func logPlacement(for description: ScreenDescription, screen: NSScreen) {
        if let notch = geo.notchGeometry(for: description) {
            Logger.debug("""
                Island placement: NOTCHED on \(screen.localizedName) — \
                housing \(Int(notch.exclusionWidth))pt, inset \(Int(notch.topInset))pt, \
                bleed \(Int(geo.topBleed(for: description)))pt
                """, subsystem: .ui)
        } else {
            Logger.debug("""
                Island placement: FLOATING on \(screen.localizedName) — \
                safeAreaTop \(description.safeAreaTopInset), \
                auxLeft \(description.auxiliaryTopLeft.map(NSStringFromRect) ?? "nil"), \
                auxRight \(description.auxiliaryTopRight.map(NSStringFromRect) ?? "nil")
                """, subsystem: .ui)
        }
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
    }

    private func handleScreenChange() {
        Logger.debug("Island: screen parameters changed", subsystem: .ui)
        // Feed a displayChanged event so the coordinator re-queries geometry.
        coordinator?.send(.displayChanged)

        // Reposition the existing panel on the (possibly new) active screen.
        guard let panel = panel, panel.isVisible,
              let screen = IslandGeometryProvider.activeScreen() else { return }
        currentScreen = screen
        let envelope = geo.panelEnvelope(for: .from(screen))
        panel.setFrame(envelope, display: true)
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
