//
//  IslandGeometryProvider.swift
//  Whisperer
//
//  Pure, nonisolated struct computing Island frames from an injected ScreenDescription.
//  Unit-testable without a display: inject a synthetic ScreenDescription in tests.
//
//  Placement strategy (bottom-center, always):
//    - The Island lives at the BOTTOM of the screen, centered horizontally.
//    - Every tier (peek, compact, expanded) shares the same bottom anchor:
//      screen.visibleFrame.minY — above the Dock, following auto-hide.
//    - Growth is upward only, so the anchor never moves as tiers change.
//    - There is no notch / top-edge placement. Notch detection code is entirely removed.
//
//  Panel strategy:
//    - The panel frame is the UNION of all state frames plus 8 pt animation slack on each side.
//    - This lets the silhouette morph inside a fixed window, avoiding NSWindow resize jitter.
//
//  Coordinate system:
//    - NSRect uses bottom-left origin (Core Graphics / AppKit convention).
//    - "Bottom" in English = minY in NSRect terms.
//    - Negative-origin multi-display setups are fully handled.
//

import AppKit    // NSRect, NSScreen — no SwiftUI needed in this struct

// MARK: - Screen description (injectable)

/// An injectable description of one screen. Build from NSScreen on the main actor;
/// pass a synthetic value in unit tests.
struct ScreenDescription: Equatable {
    /// The screen's full frame in global CG coordinates (may have negative origin).
    var frame: NSRect
    /// Usable area (excludes Dock, menu bar).
    var visibleFrame: NSRect
    /// Backing scale factor (1 on non-Retina, 2 on Retina, etc.)
    var backingScale: CGFloat

    // MARK: Factory

    static func from(_ screen: NSScreen) -> ScreenDescription {
        ScreenDescription(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            backingScale: screen.backingScaleFactor
        )
    }
}

// MARK: - Provider

struct IslandGeometryProvider {

    // MARK: Constants

    // nonisolated so the pure IslandContentSizer can read these without an actor hop.
    nonisolated enum C {
        // Peek capsule — a real floating pill, not an edge slab. Carries dot + level + timer.
        static let peekWidth:           CGFloat = 208
        static let peekHeight:          CGFloat = 30
        static let peekRadius:          CGFloat = 15    // height / 2 → true capsule

        // Compact pill
        static let compactWidth:        CGFloat = 420
        static let compactHeight:       CGFloat = 60
        static let compactRadius:       CGFloat = 30    // height / 2 → true capsule

        // Expanded pill
        static let expandedWidth:       CGFloat = 460
        static let expandedHeight:      CGFloat = 150
        static let expandedRadius:      CGFloat = 34

        // Placement
        // Just enough of a gap that the pill reads as a deliberate floating object rather
        // than a rendering artifact welded to the screen edge — and no more. It sits on the
        // bottom edge (or on the Dock's top edge), not hovering above it.
        static let bottomInset:         CGFloat = 5
        static let minHClearance:       CGFloat = 16    // min horizontal margin from screen edge
        static let panelSlack:          CGFloat = 24    // envelope inflation — room for the shadow
    }

    // MARK: - Frame builders

    /// Frame for the peek nub.
    func peekFrame(for screen: ScreenDescription) -> NSRect {
        centeredFrame(width: C.peekWidth, height: C.peekHeight, screen: screen)
    }

    /// Frame for the compact recording row.
    func compactFrame(for screen: ScreenDescription) -> NSRect {
        centeredFrame(width: C.compactWidth, height: C.compactHeight, screen: screen)
    }

    /// Frame for the expanded pill (compact + secondary control row).
    func expandedFrame(for screen: ScreenDescription) -> NSRect {
        centeredFrame(width: C.expandedWidth, height: C.expandedHeight, screen: screen)
    }

    /// Horizontal center on screen, bottom edge at `visibleFrame.minY + bottomInset`.
    private func centeredFrame(width: CGFloat, height: CGFloat, screen: ScreenDescription) -> NSRect {
        var x = screen.frame.origin.x + (screen.frame.width - width) / 2
        let minX = screen.frame.origin.x + C.minHClearance
        let maxX = screen.frame.maxX - width - C.minHClearance
        x = max(minX, min(maxX, x))
        let y = screen.visibleFrame.minY + C.bottomInset
        return NSRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Panel envelope

    /// The union of all Island frames plus animation slack — the single fixed window size
    /// inside which the silhouette morphs. Kept stable per display so the NSPanel never resizes.
    func panelEnvelope(for screen: ScreenDescription) -> NSRect {
        let peek     = peekFrame(for: screen)
        let compact  = compactFrame(for: screen)
        let expanded = expandedFrame(for: screen)
        let union    = peek.union(compact).union(expanded)

        let s = C.panelSlack
        let inflated = NSRect(
            x:      union.origin.x - s,
            y:      union.origin.y - s,
            width:  union.width    + s * 2,
            height: union.height   + s * 2
        )

        // Clamp to visibleFrame (Dock-aware) on all edges.
        let minX = max(inflated.minX, screen.visibleFrame.minX)
        let maxX = min(inflated.maxX, screen.visibleFrame.maxX)
        let minY = max(inflated.minY, screen.visibleFrame.minY)
        let maxY = min(inflated.maxY, screen.visibleFrame.maxY)
        return NSRect(x: minX, y: minY,
                      width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    // MARK: - Local (panel-relative) frames

    /// Peek frame expressed relative to the panel envelope's origin.
    func localPeekFrame(for screen: ScreenDescription) -> NSRect {
        let env    = panelEnvelope(for: screen)
        let global = peekFrame(for: screen)
        return global.offsetBy(dx: -env.origin.x, dy: -env.origin.y)
    }

    /// Compact frame expressed relative to the panel envelope's origin.
    func localCompactFrame(for screen: ScreenDescription) -> NSRect {
        let env    = panelEnvelope(for: screen)
        let global = compactFrame(for: screen)
        return global.offsetBy(dx: -env.origin.x, dy: -env.origin.y)
    }

    /// Expanded frame expressed relative to the panel envelope's origin.
    func localExpandedFrame(for screen: ScreenDescription) -> NSRect {
        let env    = panelEnvelope(for: screen)
        let global = expandedFrame(for: screen)
        return global.offsetBy(dx: -env.origin.x, dy: -env.origin.y)
    }

    // MARK: - Corner radii

    struct CornerRadii: Equatable {
        var topLeading:     CGFloat
        var topTrailing:    CGFloat
        var bottomLeading:  CGFloat
        var bottomTrailing: CGFloat
    }

    func cornerRadii(for presentation: IslandPresentation) -> CornerRadii {
        switch presentation {
        case .peek:
            let r = C.peekRadius
            return CornerRadii(topLeading: r, topTrailing: r, bottomLeading: r, bottomTrailing: r)
        case .compact:
            let r = C.compactRadius
            return CornerRadii(topLeading: r, topTrailing: r, bottomLeading: r, bottomTrailing: r)
        case .expanded:
            let r = C.expandedRadius
            return CornerRadii(topLeading: r, topTrailing: r, bottomLeading: r, bottomTrailing: r)
        case .hidden:
            return CornerRadii(topLeading: 0, topTrailing: 0, bottomLeading: 0, bottomTrailing: 0)
        }
    }

    // MARK: - Shadow

    /// Shadow is always drawn — the Island always floats (no hardware notch to merge with).
    func shouldDrawShadow(for screen: ScreenDescription) -> Bool { true }
}

// MARK: - Screen-picking (main-actor, real NSScreen)

extension IslandGeometryProvider {
    /// Picks the screen the user is actively working on, using the same policy as OverlayPanel
    /// and MeetingLiveWindowManager: screen under the pointer, then NSScreen.main, then first.
    @MainActor
    static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
