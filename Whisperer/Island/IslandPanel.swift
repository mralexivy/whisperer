//
//  IslandPanel.swift
//  Whisperer
//
//  Non-activating NSPanel shell for the Whisperer Island.
//
//  Panel strategy: the panel frame is fixed to the union of all Island states (compact +
//  expanded) plus animation slack, computed once per display by IslandGeometryProvider.
//  The silhouette (IslandContentView) morphs inside the fixed panel via SwiftUI geometry
//  transitions — the panel itself never resizes, avoiding NSWindow resize jitter.
//
//  Click-through: clicks outside the current Island silhouette fall through to whatever
//  is underneath. This is implemented by overriding hitTest on the hosting container view.
//  The Island content publishes its current silhouette rect (panel-local coordinates) to
//  the container via IslandHitBox; the container returns nil for points outside that rect.
//
//  Scroll gesture: IslandContainerView overrides scrollWheel(with:) to forward scroll
//  deltas to IslandCoordinator — a local responder-chain override, no global event monitors.
//
//  Hover tracking: IslandContainerView overrides mouseMoved / mouseEntered / mouseExited
//  (backed by an NSTrackingArea) to forward hover state changes to IslandCoordinator.
//
//  Keyboard focus: IslandPanel.canBecomeKey is FALSE. The Island has no text fields or
//  keyboard-driven affordances, and `.nonactivatingPanel` with canBecomeKey = true causes
//  the panel to receive key events that the user directed at whichever app they are typing
//  in. Clicks still work because `acceptsFirstMouse` is overridden on both the container
//  and FirstMouseHostingView.
//

import AppKit
import SwiftUI

// MARK: - Coordinate bridging (pure, unit-testable)

/// SwiftUI publishes hit rects in TOP-LEFT origin coordinates; AppKit delivers mouse points in
/// BOTTOM-LEFT origin coordinates. Getting this wrong silently disables the entire Island: every
/// containment test fails, `hitTest` returns nil over the pill, and no click reaches any button.
nonisolated enum IslandHitTesting {

    /// Convert an AppKit view-local point into the SwiftUI top-left space of a view `height` tall.
    static func flip(_ point: CGPoint, inViewOfHeight height: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: height - point.y)
    }

    /// Containment test for an AppKit point against a SwiftUI-space rect.
    static func contains(_ rect: CGRect, appKitPoint point: CGPoint, viewHeight: CGFloat) -> Bool {
        guard !rect.isEmpty else { return false }
        return rect.contains(flip(point, inViewOfHeight: viewHeight))
    }
}

// MARK: - Hit box (shared between panel and content)

/// Thread-safe box the SwiftUI layer writes its current hit rects into.
/// The NSView override reads it on the main thread during hitTest.
@MainActor
final class IslandHitBox {
    /// Exact pill rect — click-through boundary
    var rect: NSRect = .zero
    /// Forgiving hover rect — 24 pt wider, 6 pt taller (Atoll's pattern)
    var hoverRect: NSRect = .zero

    // Callbacks set by IslandContentView.onAppear
    var onScrollWheel: ((CGFloat, NSEvent.Phase) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
}

// MARK: - Click-through container view

private final class IslandContainerView: NSView {
    weak var hitBox: IslandHitBox?
    weak var coordinator: IslandCoordinator?

    private var trackingArea: NSTrackingArea?

    private func flip(_ p: NSPoint) -> NSPoint {
        IslandHitTesting.flip(p, inViewOfHeight: bounds.height)
    }

    /// The point delivered to `hitTest` is in the SUPERVIEW's coordinate system (window coords
    /// when there is no superview), so convert first, then flip into SwiftUI's space.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hitBox else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return IslandHitTesting.contains(hitBox.rect, appKitPoint: local, viewHeight: bounds.height)
            ? super.hitTest(point)
            : nil
    }

    /// Non-activating panels do not become key on click; without this the first click on a
    /// button is swallowed to focus the window instead of firing the action.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        // Only intercept if cursor is inside the hover rect
        let loc = flip(convert(event.locationInWindow, from: nil))
        if let hitBox, hitBox.hoverRect.contains(loc) {
            coordinator?.handleScrollWheel(delta: delta, phase: event.phase)
            return
        }
        super.scrollWheel(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }

    override func mouseExited(with event: NSEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.coordinator?.handleHover(false)
        }
    }

    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }

    /// Re-check hover on every move — catches re-entry after spurious exits.
    private func updateHover(with event: NSEvent) {
        let loc = flip(convert(event.locationInWindow, from: nil))
        let inside = hitBox?.hoverRect.contains(loc) ?? false
        DispatchQueue.main.async { [weak self] in
            guard let coord = self?.coordinator, inside != coord.isHovering else { return }
            coord.handleHover(inside)
        }
    }

    // The Island is never a keyboard target — it has no text fields and no keyboard actions.
    // (acceptsFirstMouse above keeps clicks working in a non-key, nonactivating panel.)
    override var acceptsFirstResponder: Bool { false }
}

// MARK: - Hosting view that accepts the first mouse click

/// NSHostingView forwarded clicks without `acceptsFirstMouse` when the owning panel is not
/// key. Override it here so a single click on an Island button fires even when another app
/// is frontmost and the Island is a non-key, nonactivating panel.
private final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Panel

final class IslandPanel: NSPanel {

    let hitBox = IslandHitBox()

    private let container = IslandContainerView()

    /// Set by IslandPanelController so the container can forward scroll/hover events.
    weak var coordinator: IslandCoordinator? {
        didSet { container.coordinator = coordinator }
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel      = true
        // Belt-and-suspenders: even if something calls makeKey, we opt out.
        becomesKeyOnlyIfNeeded = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false   // SwiftUI draws the shadow
        acceptsMouseMovedEvents = true

        container.hitBox = hitBox
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        contentView = container
    }

    func setContent<V: View>(_ view: V) {
        container.subviews.forEach { $0.removeFromSuperview() }

        // Use FirstMouseHostingView so a single click on an Island button fires immediately
        // even though canBecomeKey is false and the app may not be frontmost.
        let hosting = FirstMouseHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // Never take keyboard focus. The Island is pointer-only; allowing key focus causes it
    // to intercept Return/Escape from whichever app the user is typing in.
    override var canBecomeKey:  Bool { false }
    override var canBecomeMain: Bool { false }
}
