//
//  IslandGeometryProvider.swift
//  Whisperer
//
//  Pure, nonisolated struct computing Island frames from an injected ScreenDescription.
//  Unit-testable without a display: inject a synthetic ScreenDescription + set placement.
//
//  Placement strategy (edge-anchored, Dock/chrome-aware):
//    - The Island lives at one of four screen edges: bottom-center (default), top-center,
//      left-center, or right-center.
//    - The anchored edge uses `edgeAnchor(for:placement:)`:
//        • OS chrome present on that edge (Dock, menu bar, Stage Manager strip)
//          → visibleFrame inset + C.dockGap.
//        • No chrome → raw screen edge + C.edgeInset.
//      Top always has the menu bar, so it always takes the inset branch.
//      Auto-hidden Docks are treated as present (~4 pt reveal strip).
//    - Growth is away from the anchored edge only, so the anchor never moves as tiers change.
//    - Left/right placements swap the long and thick axes: the pill becomes a vertical column.
//
//  Panel strategy:
//    - The panel frame is the UNION of all state frames plus 8 pt animation slack on each side.
//    - This lets the silhouette morph inside a fixed window, avoiding NSWindow resize jitter.
//
//  Coordinate system:
//    - NSRect uses bottom-left origin (Core Graphics / AppKit convention).
//    - Negative-origin multi-display setups are fully handled.
//

import AppKit

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
        static let dockGap:             CGFloat = 6     // gap above/beside a Dock or auto-hide strip
        static let edgeInset:           CGFloat = 2     // gap from the raw screen edge
        static let minHClearance:       CGFloat = 16    // min margin from screen edge (both axes)
        static let panelSlack:          CGFloat = 24    // envelope inflation — room for the shadow
    }

    // MARK: - Placement

    /// Which screen edge the Island is anchored to. Defaults to .bottomCenter.
    var placement: IslandPlacement = .bottomCenter

    // MARK: - Frame builders

    /// Frame for the peek nub.
    func peekFrame(for screen: ScreenDescription) -> NSRect {
        if placement.isVertical {
            return anchoredFrame(long: IslandContentSizer.idlePeekWidth,
                                 thick: IslandContentSizer.idlePeekHeight, screen: screen)
        }
        return anchoredFrame(long: C.peekWidth, thick: C.peekHeight, screen: screen)
    }

    /// Frame for the compact recording row.
    func compactFrame(for screen: ScreenDescription) -> NSRect {
        if placement.isVertical {
            return anchoredFrame(long: C.compactWidth, thick: C.compactHeight, screen: screen)
        }
        return anchoredFrame(long: C.compactWidth, thick: C.compactHeight, screen: screen)
    }

    /// Frame for the expanded pill (compact + secondary control row).
    func expandedFrame(for screen: ScreenDescription) -> NSRect {
        if placement.isVertical {
            return anchoredFrame(long: C.expandedWidth, thick: C.expandedHeight, screen: screen)
        }
        return anchoredFrame(long: C.expandedWidth, thick: C.expandedHeight, screen: screen)
    }

    // MARK: - Internal frame math

    /// Axis-agnostic frame: `long` runs along the anchored edge, `thick` is the pill's depth.
    /// Growth is always away from the anchored edge.
    private func anchoredFrame(long: CGFloat, thick: CGFloat, screen: ScreenDescription) -> NSRect {
        let anchor = IslandGeometryProvider.edgeAnchor(for: screen, placement: placement)

        switch placement {
        case .bottomCenter:
            // Horizontal pill, bottom-anchored. minY == anchor, grows upward.
            var x = screen.frame.origin.x + (screen.frame.width - long) / 2
            let minX = screen.frame.origin.x + C.minHClearance
            let maxX = screen.frame.maxX - long - C.minHClearance
            x = max(minX, min(maxX, x))
            return NSRect(x: x, y: anchor, width: long, height: thick)

        case .topCenter:
            // Horizontal pill, top-anchored. maxY == anchor, grows downward.
            var x = screen.frame.origin.x + (screen.frame.width - long) / 2
            let minX = screen.frame.origin.x + C.minHClearance
            let maxX = screen.frame.maxX - long - C.minHClearance
            x = max(minX, min(maxX, x))
            return NSRect(x: x, y: anchor - thick, width: long, height: thick)

        case .leftCenter:
            // Vertical pill, left-anchored. minX == anchor, grows rightward.
            // long runs along Y axis, thick along X axis.
            let clampedLong = min(long, screen.frame.height - C.minHClearance * 2)
            var y = screen.frame.origin.y + (screen.frame.height - clampedLong) / 2
            let minY = screen.frame.origin.y + C.minHClearance
            let maxY = screen.frame.maxY - clampedLong - C.minHClearance
            y = max(minY, min(maxY, y))
            return NSRect(x: anchor, y: y, width: thick, height: clampedLong)

        case .rightCenter:
            // Vertical pill, right-anchored. maxX == anchor, grows leftward.
            let clampedLong = min(long, screen.frame.height - C.minHClearance * 2)
            var y = screen.frame.origin.y + (screen.frame.height - clampedLong) / 2
            let minY = screen.frame.origin.y + C.minHClearance
            let maxY = screen.frame.maxY - clampedLong - C.minHClearance
            y = max(minY, min(maxY, y))
            return NSRect(x: anchor - thick, y: y, width: thick, height: clampedLong)
        }
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

        let outerEdge = IslandGeometryProvider.envelopeOuterEdge(for: screen, placement: placement)

        switch placement {
        case .bottomCenter:
            let minX = max(inflated.minX, screen.visibleFrame.minX)
            let maxX = min(inflated.maxX, screen.visibleFrame.maxX)
            let maxY = min(inflated.maxY, screen.visibleFrame.maxY)
            return NSRect(x: minX, y: outerEdge,
                          width: max(0, maxX - minX), height: max(0, maxY - outerEdge))

        case .topCenter:
            let minX = max(inflated.minX, screen.visibleFrame.minX)
            let maxX = min(inflated.maxX, screen.visibleFrame.maxX)
            let minY = max(inflated.minY, screen.visibleFrame.minY)
            return NSRect(x: minX, y: minY,
                          width: max(0, maxX - minX), height: max(0, outerEdge - minY))

        case .leftCenter:
            let minY = max(inflated.minY, screen.visibleFrame.minY)
            let maxY = min(inflated.maxY, screen.visibleFrame.maxY)
            let maxX = min(inflated.maxX, screen.visibleFrame.maxX)
            return NSRect(x: outerEdge, y: minY,
                          width: max(0, maxX - outerEdge), height: max(0, maxY - minY))

        case .rightCenter:
            let minY = max(inflated.minY, screen.visibleFrame.minY)
            let maxY = min(inflated.maxY, screen.visibleFrame.maxY)
            let minX = max(inflated.minX, screen.visibleFrame.minX)
            return NSRect(x: minX, y: minY,
                          width: max(0, outerEdge - minX), height: max(0, maxY - minY))
        }
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

    /// Shadow is always drawn — the Island always floats.
    func shouldDrawShadow(for screen: ScreenDescription) -> Bool { true }
}

// MARK: - Generic edge anchor (nonisolated, shared with IslandContentSizer)

extension IslandGeometryProvider {

    /// True when the OS (Dock, Stage Manager, menu bar, etc.) insets `visibleFrame`
    /// from `frame` by more than 1 pt on the given edge.
    nonisolated static func hasEdgeObstruction(_ s: ScreenDescription,
                                               placement: IslandPlacement) -> Bool {
        switch placement {
        case .bottomCenter: return s.visibleFrame.minY - s.frame.minY > 1
        case .topCenter:    return s.frame.maxY - s.visibleFrame.maxY > 1
        case .leftCenter:   return s.visibleFrame.minX - s.frame.minX > 1
        case .rightCenter:  return s.frame.maxX - s.visibleFrame.maxX > 1
        }
    }

    /// Global coordinate of the pill's edge that touches the screen border.
    nonisolated static func edgeAnchor(for s: ScreenDescription,
                                       placement: IslandPlacement) -> CGFloat {
        switch placement {
        case .bottomCenter:
            return hasEdgeObstruction(s, placement: .bottomCenter)
                ? s.visibleFrame.minY + C.dockGap
                : s.frame.minY        + C.edgeInset
        case .topCenter:
            return hasEdgeObstruction(s, placement: .topCenter)
                ? s.visibleFrame.maxY - C.dockGap
                : s.frame.maxY        - C.edgeInset
        case .leftCenter:
            return hasEdgeObstruction(s, placement: .leftCenter)
                ? s.visibleFrame.minX + C.dockGap
                : s.frame.minX        + C.edgeInset
        case .rightCenter:
            return hasEdgeObstruction(s, placement: .rightCenter)
                ? s.visibleFrame.maxX - C.dockGap
                : s.frame.maxX        - C.edgeInset
        }
    }

    /// Outer-edge coordinate for the panel envelope clamp (slack extended outward).
    nonisolated static func envelopeOuterEdge(for s: ScreenDescription,
                                              placement: IslandPlacement) -> CGFloat {
        switch placement {
        case .bottomCenter:
            return max(edgeAnchor(for: s, placement: .bottomCenter) - C.panelSlack, s.frame.minY)
        case .topCenter:
            return min(edgeAnchor(for: s, placement: .topCenter) + C.panelSlack, s.frame.maxY)
        case .leftCenter:
            return max(edgeAnchor(for: s, placement: .leftCenter) - C.panelSlack, s.frame.minX)
        case .rightCenter:
            return min(edgeAnchor(for: s, placement: .rightCenter) + C.panelSlack, s.frame.maxX)
        }
    }

    // MARK: - Deprecated forwarding aliases

    @available(*, deprecated, renamed: "edgeAnchor(for:placement:)")
    nonisolated static func bottomAnchor(for s: ScreenDescription) -> CGFloat {
        edgeAnchor(for: s, placement: .bottomCenter)
    }

    @available(*, deprecated, renamed: "hasEdgeObstruction(_:placement:)")
    nonisolated static func hasBottomObstruction(_ s: ScreenDescription) -> Bool {
        hasEdgeObstruction(s, placement: .bottomCenter)
    }

    @available(*, deprecated, renamed: "envelopeOuterEdge(for:placement:)")
    nonisolated static func envelopeBottom(for s: ScreenDescription) -> CGFloat {
        envelopeOuterEdge(for: s, placement: .bottomCenter)
    }
}

// MARK: - Screen-picking (main-actor, real NSScreen)

extension IslandGeometryProvider {
    /// Picks the screen the user is actively working on.
    @MainActor
    static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
