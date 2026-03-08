//
//  OverlayPanel.swift
//  Whisperer
//
//  Non-activating floating panel for overlay UI
//

import AppKit
import SwiftUI

enum OverlayPosition: String, CaseIterable {
    case bottomCenter = "Bottom Center"
    case topCenter = "Top Center"
    case bottomLeft = "Bottom Left"
    case bottomRight = "Bottom Right"
}

enum OverlaySize: String, CaseIterable {
    case small = "Small"
    case medium = "Medium"
    case large = "Large"

    var dimensions: (width: CGFloat, height: CGFloat) {
        switch self {
        case .small: return (340, 240)
        case .medium: return (420, 300)
        case .large: return (520, 360)
        }
    }

    /// Scale factor relative to medium (1.0)
    var scale: CGFloat {
        switch self {
        case .small: return 0.78
        case .medium: return 1.0
        case .large: return 1.2
        }
    }

    static var current: OverlaySize {
        let raw = UserDefaults.standard.string(forKey: "overlaySize") ?? OverlaySize.medium.rawValue
        return OverlaySize(rawValue: raw) ?? .medium
    }
}

// MARK: - Environment Key for Overlay Scale

private struct OverlayScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var overlayScale: CGFloat {
        get { self[OverlayScaleKey.self] }
        set { self[OverlayScaleKey.self] = newValue }
    }
}

class OverlayPanel: NSPanel {
    private var stateObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var generation: UInt64 = 0

    init() {
        // Create the panel with proper style - fits transcription card + HUD capsule + shadows
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
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

        // Create SwiftUI content with size-aware scale
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

        // Observe overlay settings changes
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .overlaySettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.positionAtBottomCenter()
        }

        // Check initial state
        updateVisibility()
    }

    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }

        let screenRect = screen.visibleFrame

        let positionPref = UserDefaults.standard.string(forKey: "overlayPosition")
            .flatMap { OverlayPosition(rawValue: $0) } ?? .bottomCenter
        let sizePref = UserDefaults.standard.string(forKey: "overlaySize")
            .flatMap { OverlaySize(rawValue: $0) } ?? .medium

        let dims = sizePref.dimensions
        let panelWidth = dims.width
        let panelHeight = dims.height
        let margin: CGFloat = 10

        let xPos: CGFloat
        let yPos: CGFloat

        switch positionPref {
        case .bottomCenter:
            xPos = screenRect.origin.x + (screenRect.width - panelWidth) / 2
            yPos = screenRect.origin.y + margin
        case .topCenter:
            xPos = screenRect.origin.x + (screenRect.width - panelWidth) / 2
            yPos = screenRect.origin.y + screenRect.height - panelHeight - margin
        case .bottomLeft:
            xPos = screenRect.origin.x + margin
            yPos = screenRect.origin.y + margin
        case .bottomRight:
            xPos = screenRect.origin.x + screenRect.width - panelWidth - margin
            yPos = screenRect.origin.y + margin
        }

        self.setFrame(
            NSRect(x: xPos, y: yPos, width: panelWidth, height: panelHeight),
            display: true
        )
    }

    private func updateVisibility() {
        generation &+= 1
        let capturedGen = generation

        let appState = AppState.shared
        let shouldShow = appState.state != .idle || appState.showModelLoadingToast

        if shouldShow && !self.isVisible {
            // Reposition at bottom-center every time we show
            positionAtBottomCenter()
            self.orderFrontRegardless()
            self.alphaValue = 1.0  // Instant show (no animation delay)
            Logger.debug("Overlay panel shown (state=\(appState.state), toast=\(appState.showModelLoadingToast))", subsystem: .ui)
        } else if !shouldShow && self.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.animator().alphaValue = 0.0
            } completionHandler: { [weak self] in
                guard let self = self, self.generation == capturedGen else { return }
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
