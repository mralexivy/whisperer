//
//  OverlayPanel.swift
//  Whisperer
//
//  Non-activating floating panel for overlay UI
//

import AppKit
import SwiftUI

class OverlayPanel: NSPanel {
    private var stateObserver: NSObjectProtocol?

    init() {
        // Create the panel with proper style - fits transcription card + HUD capsule + shadows
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Configure panel behavior
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.isMovableByWindowBackground = false
        self.backgroundColor = NSColor.clear
        self.isOpaque = false
        self.hasShadow = false  // No window shadow - SwiftUI capsule has its own

        // Create SwiftUI content
        let overlayView = OverlayView()
            .frame(maxWidth: .infinity)
            .background(Color.clear)

        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        // Container view fills the panel; hosting view is pinned to its bottom
        // so content always appears at the bottom of the panel regardless of
        // NSHostingView's intrinsic sizing behavior.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.contentView = container

        // Position at bottom-center of screen
        positionAtBottomCenter()

        // Start hidden
        self.alphaValue = 0.0
        self.orderOut(nil)

        // Observe state changes to show/hide panel
        stateObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateVisibility()
        }

        // Check initial state
        updateVisibility()
    }

    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }

        let screenRect = screen.visibleFrame
        let panelWidth: CGFloat = 420
        let panelHeight: CGFloat = 220
        let bottomMargin: CGFloat = 10

        let xPos = screenRect.origin.x + (screenRect.width - panelWidth) / 2
        let yPos = screenRect.origin.y + bottomMargin

        self.setFrame(
            NSRect(x: xPos, y: yPos, width: panelWidth, height: panelHeight),
            display: true
        )
    }

    private func updateVisibility() {
        let appState = AppState.shared
        let shouldShow = appState.state != .idle

        if shouldShow && !self.isVisible {
            // Reposition at bottom-center every time we show
            positionAtBottomCenter()
            self.orderFrontRegardless()
            self.animator().alphaValue = 1.0
        } else if !shouldShow && self.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.animator().alphaValue = 0.0
            } completionHandler: {
                self.orderOut(nil)
                self.alphaValue = 1.0
            }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    deinit {
        if let observer = stateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
