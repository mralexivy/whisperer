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
//      Auto-hidden Docks are treated as absent — their ~4 pt reveal strip is below
//      `C.chromeThreshold`, so the Island hugs the real screen edge when no Dock is showing.
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
import CoreGraphics

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
    /// Whether the Dock process has a window actually rendered on the active Space right now.
    ///
    /// `visibleFrame` always reserves Dock space (e.g. 74 pt at bottom) regardless of which
    /// Space is active, because the reservation is a global screen-level property. But the Dock
    /// only renders on one Space at a time on single-monitor setups — when you switch to another
    /// Space the Dock is absent even though `visibleFrame` still shows the inset.
    ///
    /// `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` returns what the window server is
    /// actually drawing right now. If "Dock" is not in that list, no chrome clearance is needed.
    ///
    /// Defaults to `true` so synthetic `ScreenDescription` values used in unit tests behave
    /// conservatively (treat obstruction as present, matching the old behaviour).
    var isDockOnActiveSpace: Bool = true

    // MARK: Factory

    /// Reads Dock presence from `DockPresenceMonitor`'s cached value rather than scanning the
    /// window list here. The scan is ~780 µs and this factory runs on every `publishViewModel`;
    /// the monitor keeps the answer hot for ~104 µs per 16 ms tick.
    @MainActor
    static func from(_ screen: NSScreen) -> ScreenDescription {
        ScreenDescription(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            backingScale: screen.backingScaleFactor,
            isDockOnActiveSpace: DockPresenceMonitor.shared.isDockOnScreen
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
        static let dockGap:             CGFloat = 6     // gap above/beside a visible Dock
        static let edgeInset:           CGFloat = 5     // gap from the raw screen edge when no chrome
        /// An auto-hidden Dock still insets `visibleFrame` by a ~4 pt reveal strip. Treating
        /// that as a real Dock lifted the Island ~10 pt off the screen edge with nothing
        /// visibly there. Only an inset past this is real chrome worth clearing.
        static let chromeThreshold:     CGFloat = 8
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

    /// The single fixed window inside which the silhouette morphs.
    ///
    /// Deliberately **Dock-independent**: it is the union of the envelope computed with the Dock
    /// present and with the Dock absent. Both variants are precomputed here, so switching Spaces
    /// never changes the window frame and `NSWindow.setFrame` never runs on the switch path.
    ///
    /// That matters because a `setFrame` is an async round trip to the window server — it lands a
    /// frame or two after the Space has already been composited, which is exactly the "appears in
    /// the old position, then jumps" flicker. With a constant envelope the only thing that moves is
    /// `IslandContentSizer.anchorSlack` inside the window, which SwiftUI resolves in one layout
    /// pass with no window-server involvement.
    func panelEnvelope(for screen: ScreenDescription) -> NSRect {
        var withDock = screen
        withDock.isDockOnActiveSpace = true
        var withoutDock = screen
        withoutDock.isDockOnActiveSpace = false
        return rawEnvelope(for: withDock).union(rawEnvelope(for: withoutDock))
    }

    /// The envelope for one specific Dock state. Only `panelEnvelope` should call this.
    private func rawEnvelope(for screen: ScreenDescription) -> NSRect {
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
    /// from `frame` by more than `C.chromeThreshold` on the given edge.
    ///
    /// For the Dock edge (bottom by default), `visibleFrame` always reserves the Dock's height
    /// regardless of which Space is active — it is a global screen property, not a per-Space one.
    /// We therefore also require that the Dock is actually rendered on the active Space
    /// (`s.isDockOnActiveSpace`). When the Dock is absent on the current Space the Island hugs
    /// the real screen edge even though `visibleFrame` still shows a large inset.
    nonisolated static func hasEdgeObstruction(_ s: ScreenDescription,
                                               placement: IslandPlacement) -> Bool {
        // If the Dock process isn't rendering on this Space, there is no bottom-edge chrome.
        // (The menu bar and Stage Manager are never on the bottom edge, so this check is safe.)
        if !s.isDockOnActiveSpace {
            switch placement {
            case .bottomCenter, .leftCenter, .rightCenter:
                return false   // Dock absent → no obstruction on the Dock edge
            case .topCenter:
                break          // menu bar is always present at the top; fall through
            }
        }

        let inset: CGFloat
        switch placement {
        case .bottomCenter: inset = s.visibleFrame.minY - s.frame.minY
        case .topCenter:    inset = s.frame.maxY - s.visibleFrame.maxY
        case .leftCenter:   inset = s.visibleFrame.minX - s.frame.minX
        case .rightCenter:  inset = s.frame.maxX - s.visibleFrame.maxX
        }
        return inset > C.chromeThreshold
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

    /// Outer-edge coordinate for the panel envelope — the physical screen edge.
    ///
    /// Intentionally **not** derived from `edgeAnchor`, because that moves with the Dock. Pinning
    /// the envelope's outer edge to the raw screen border keeps the window frame constant across
    /// Spaces, and pushes the entire Dock-present/absent difference into `anchorSlack`, which is a
    /// pure SwiftUI layout value. The window then never has to move when the Dock comes and goes.
    nonisolated static func envelopeOuterEdge(for s: ScreenDescription,
                                              placement: IslandPlacement) -> CGFloat {
        switch placement {
        case .bottomCenter: return s.frame.minY
        case .topCenter:    return s.frame.maxY
        case .leftCenter:   return s.frame.minX
        case .rightCenter:  return s.frame.maxX
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
