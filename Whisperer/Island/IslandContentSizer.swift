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

    // MARK: - Idle handle (always-on resting affordance)
    //
    // The idle Island is never fully invisible. At rest it is a small glass capsule with a
    // single hairline inside it — enough to say "something lives here" without competing
    // with whatever the user is actually working on. Hovering grows it along its long axis
    // and fills the inner line as the dwell clock runs; completing the dwell blossoms it
    // into the full launcher row.

    /// Long-axis length of the resting handle.
    ///
    /// Constant whether or not the pointer is near. An intermediate "swell" step used to sit
    /// here, but it made the approach read as two separate, competing animations — a small
    /// grow, then a jump to the full launcher — and every size change re-ran the hit-box
    /// math mid-approach, which is what made the target feel like it needed precise aim.
    /// Hover feedback is now purely tonal (see `IslandLayout.handleBody`), so the only
    /// geometry change in the whole interaction is the single spring into the launcher.
    static let idleHandleRestLength:  CGFloat = 56
    /// Thickness of the handle capsule. Constant across rest and hover so only the
    /// length animates — a capsule that changes thickness reads as a wobble.
    static let idleHandleThickness:   CGFloat = 9
    /// Thickness of the hairline / progress fill drawn inside the handle.
    static let idleHandleLineThickness: CGFloat = 2.5

    /// Size of the resting/dwelling handle for a given placement and hover state.
    static func idleHandleSize(isHovering: Bool, placement: IslandPlacement) -> CGSize {
        _ = isHovering   // Size is intentionally hover-invariant — see idleHandleRestLength.
        let long  = idleHandleRestLength
        let thick = idleHandleThickness
        return placement.isVertical
            ? CGSize(width: thick, height: long)
            : CGSize(width: long,  height: thick)
    }
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
        // Hidden presentation always zero. This is the Island standing down entirely
        // (meeting window up, dictation HUD up, onboarding) — distinct from the idle
        // handle below, which is the resting *visible* state.
        guard presentation != .hidden else { return .zero }

        // Pre-reveal idle: the always-on handle. `.hidden` is the resting capsule and
        // `.sliver` is the same capsule grown by hover — both are real geometry so the
        // glass surface draws the rounded container and hit-testing stays honest.
        if capture == .idle && revealPhase != .revealed {
            return idleHandleSize(isHovering: isHovering, placement: placement)
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
        screen: ScreenDescription,
        revealPhase: IslandRevealPhase = .revealed
    ) -> (top: CGFloat, bottom: CGFloat) {
        // The pre-reveal idle handle is a capsule regardless of which tier it sits in.
        if capture == .idle && revealPhase != .revealed {
            let r = idleHandleThickness / 2
            return (top: r, bottom: r)
        }
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
