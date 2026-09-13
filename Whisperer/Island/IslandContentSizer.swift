//
//  IslandContentSizer.swift
//  Whisperer
//
//  Pure, nonisolated struct that maps (capture state, presentation, screen, placement,
//  revealPhase) → target geometry.
//
//  Three presentation tiers:
//   - .peek     → capsule nub (plus hover swell)
//   - .compact  → content-driven width × compactHeight pill
//   - .expanded → compact + secondary control row
//
//  Placement awareness:
//   - Horizontal placements (topCenter, bottomCenter): long axis = width, thick axis = height.
//   - Vertical placements (leftCenter, rightCenter): axes are swapped.
//   - The long axis is always clamped against the screen dimension it runs along.
//
//  Progressive reveal:
//   - .hidden  → zero size (standard)
//   - .sliver  → a 3-pt stripe at the anchored edge (real geometry so hit-testing stays correct)
//   - .revealed → normal target size
//

import AppKit

private typealias GC = IslandGeometryProvider.C

/// The horizontal zones of the compact row.
/// There is no center dead zone — the Island no longer has a notch to route around.
nonisolated struct IslandRowMetrics: Equatable {
    /// Height of the content inside the compact strip.
    var rowHeight:     CGFloat
    /// Height of the whole compact strip (the pill height).
    var compactHeight: CGFloat
    /// Diameter for inline controls, scaled to the strip.
    var controlSize:   CGFloat
}

nonisolated struct IslandContentSizer {

    // MARK: - Content-driven widths for the compact row

    /// Width for the recording / paused row (waveform + timer + controls).
    static let recordingWidth:   CGFloat = 420
    /// Width for single-line status rows (starting, finishing).
    static let statusWidth:      CGFloat = 280
    /// Width for the permission / failure rows (longer message).
    static let attentionWidth:   CGFloat = 340

    // MARK: - Idle launcher

    /// Resting launcher nub — deliberately smaller than the recording nub.
    static let idlePeekWidth:    CGFloat = 104
    static let idlePeekHeight:   CGFloat = 24
    /// 4 × 28 (item) + 4 × 2 (spacing) + 11 (divider + padding) + 2 × 8 (row padding).
    static let idleCompactWidth:  CGFloat = 147
    static let idleCompactHeight: CGFloat = 32
    /// Width of one action in the launcher row.
    static let launcherItemWidth: CGFloat = 28

    /// Extra height added when expanded — the secondary control row.
    static let expandedExtraHeight: CGFloat = 84
    /// Extra width: GC.expandedWidth - GC.compactWidth = 56.
    static let expandedExtraWidth:  CGFloat = 56

    // MARK: - Hover lift for nub

    static let peekHoverLift: CGFloat = 30

    // MARK: - Target size

    /// CGSize the Island springs to. For vertical placements, width/height are swapped
    /// so that `width` is always the thick axis and `height` the long axis.
    static func targetSize(
        capture: IslandCaptureState,
        presentation: IslandPresentation,
        screen: ScreenDescription,
        isHovering: Bool,
        gestureProgress: CGFloat,
        placement: IslandPlacement = .bottomCenter,
        revealPhase: IslandRevealPhase = .revealed
    ) -> CGSize {
        // Hidden phase always zero.
        guard presentation != .hidden else { return .zero }

        // Sliver phase: a real 3-pt stripe at the anchored edge.
        // Width/height are assigned so that the sliver occupies the anchored edge correctly.
        if revealPhase == .sliver && capture == .idle {
            let sliver = IslandUX.sliverThickness
            let longAxis = placement.isVertical
                ? min(idlePeekWidth, screen.frame.height - GC.minHClearance * 2)
                : min(idlePeekWidth, screen.frame.width  - GC.minHClearance * 2)
            return placement.isVertical
                ? CGSize(width: sliver, height: longAxis)
                : CGSize(width: longAxis, height: sliver)
        }

        let isIdle = capture == .idle

        // --- Peek tier ---
        if presentation == .peek {
            let hoverExtra:   CGFloat = isHovering ? peekHoverLift : 0
            let stretchExtra: CGFloat = max(gestureProgress * 0.5, 0)
            let baseLong = isIdle ? idlePeekWidth : GC.peekWidth
            let baseThick = isIdle ? idlePeekHeight : GC.peekHeight
            let maxLong = placement.isVertical
                ? screen.frame.height - GC.minHClearance * 2
                : screen.frame.width  - GC.minHClearance * 2
            let long  = min(baseLong + hoverExtra + stretchExtra, maxLong)
            let thick = baseThick
            return placement.isVertical
                ? CGSize(width: thick, height: long)
                : CGSize(width: long,  height: thick)
        }

        // --- Compact / Expanded tiers ---
        let isExpanded  = presentation == .expanded && !isIdle
        let hoverLift:  CGFloat = isHovering && !isExpanded ? 8 : 0
        let stretch:    CGFloat = max(gestureProgress * 0.8, 0)

        let baseW: CGFloat
        switch capture {
        case .idle:                        baseW = idleCompactWidth
        case .starting, .finalizing:       baseW = statusWidth
        case .permissionRequired, .failed: baseW = attentionWidth
        case .recording, .paused:          baseW = recordingWidth
        }

        let maxLong = placement.isVertical
            ? screen.frame.height - GC.minHClearance * 2
            : screen.frame.width  - GC.minHClearance * 2
        let long  = min(baseW + hoverLift + stretch + (isExpanded ? expandedExtraWidth : 0),
                        maxLong)
        let thick = compactHeight(for: capture) + (isExpanded ? expandedExtraHeight : 0)
        return placement.isVertical
            ? CGSize(width: max(thick, 0), height: max(long, 0))
            : CGSize(width: max(long, 0),  height: max(thick, 0))
    }

    /// Height of the compact strip (or long-axis thickness for vertical).
    static func compactHeight(for capture: IslandCaptureState) -> CGFloat {
        capture == .idle ? idleCompactHeight : GC.compactHeight
    }

    // MARK: - Row metrics

    static func rowMetrics(
        screen: ScreenDescription,
        isHovering: Bool,
        gestureProgress: CGFloat
    ) -> IslandRowMetrics {
        let height = GC.compactHeight
        let rowH = max(height - 12, 18)
        return IslandRowMetrics(
            rowHeight:     rowH,
            compactHeight: height,
            controlSize:   min(max(height - 8, 22), 30)
        )
    }

    // MARK: - Anchor slack

    /// Padding between the Island body and the anchored screen edge, inside the panel envelope.
    /// This generalises the old `bottomSlack` to all four placements.
    static func anchorSlack(screen: ScreenDescription,
                            placement: IslandPlacement = .bottomCenter) -> CGFloat {
        let anchor = IslandGeometryProvider.edgeAnchor(for: screen, placement: placement)
        let outer  = IslandGeometryProvider.envelopeOuterEdge(for: screen, placement: placement)
        return max(0, abs(anchor - outer))
    }

    // MARK: - Deprecated alias

    @available(*, deprecated, renamed: "anchorSlack(screen:placement:)")
    static func bottomSlack(screen: ScreenDescription) -> CGFloat {
        anchorSlack(screen: screen, placement: .bottomCenter)
    }

    // MARK: - Corner radius

    static func cornerRadii(
        capture: IslandCaptureState,
        presentation: IslandPresentation,
        screen: ScreenDescription
    ) -> (top: CGFloat, bottom: CGFloat) {
        switch presentation {
        case .peek:
            let r: CGFloat = capture == .idle ? idlePeekHeight / 2 : GC.peekHeight / 2
            return (top: r, bottom: r)
        case .compact:
            let r = compactHeight(for: capture) / 2
            return (top: r, bottom: r)
        case .expanded:
            let r = capture == .idle ? GC.compactRadius : GC.expandedRadius
            return (top: r, bottom: r)
        case .hidden:
            return (top: 0, bottom: 0)
        }
    }
}
