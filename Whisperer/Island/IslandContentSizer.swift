//
//  IslandContentSizer.swift
//  Whisperer
//
//  Pure, nonisolated struct that maps (capture state, presentation, screen) → target geometry.
//
//  Three presentation tiers, all bottom-anchored:
//   - .peek     → capsule nub (plus hover swell)
//   - .compact  → content-driven width × compactHeight pill
//   - .expanded → compact + secondary control row
//
//  The Island is always on screen: while idle it rests as a near-transparent launcher nub,
//  which is deliberately smaller than the recording nub.
//
//  Sizes come from IslandGeometryProvider.C, which is nonisolated for exactly this reason.
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
    /// Mirrors GC.compactWidth.
    static let recordingWidth:   CGFloat = 420
    /// Width for single-line status rows (starting, finishing).
    static let statusWidth:      CGFloat = 280
    /// Width for the permission / failure rows (longer message).
    static let attentionWidth:   CGFloat = 340

    // MARK: - Idle launcher

    /// Resting launcher nub — deliberately smaller than the recording nub so an idle
    /// Island reads as an affordance rather than as an active capture.
    static let idlePeekWidth:    CGFloat = 104
    static let idlePeekHeight:   CGFloat = 24
    /// The launcher row the nub opens into: four bare 15 pt glyphs and a hairline divider.
    /// Captions and large targets belong in the workspace — this is a bar, so it stays
    /// SHORTER than the recording row rather than towering over it.
    /// 4 × 28 (item) + 4 × 2 (spacing) + 11 (divider + its padding) + 2 × 8 (row padding).
    static let idleCompactWidth:  CGFloat = 147
    static let idleCompactHeight: CGFloat = 36
    /// Width of one action in the launcher row — the glyph's hover capsule, nothing more.
    /// Drives the glyph size too: `IslandHoverButton` renders it at half the diameter.
    static let launcherItemWidth: CGFloat = 28

    /// Extra height added when expanded — the secondary control row.
    static let expandedExtraHeight: CGFloat = 84
    /// Extra width: GC.expandedWidth - GC.compactWidth = 56.
    static let expandedExtraWidth:  CGFloat = 56

    // MARK: - Hover lift for nub

    /// How much the nub widens on hover — gives immediate tactile feedback before the dwell fires.
    static let peekHoverLift: CGFloat = 30

    // MARK: - Target size

    /// The island springs to this CGSize per active content type.
    static func targetSize(
        capture: IslandCaptureState,
        presentation: IslandPresentation,
        screen: ScreenDescription,
        isHovering: Bool,
        gestureProgress: CGFloat
    ) -> CGSize {
        guard presentation != .hidden else { return .zero }

        let isIdle = capture == .idle

        // Peek tier: nub with optional hover swell.
        if presentation == .peek {
            let hoverExtra: CGFloat = isHovering ? peekHoverLift : 0
            let stretchExtra: CGFloat = max(gestureProgress * 0.5, 0)
            let base = isIdle ? idlePeekWidth : GC.peekWidth
            let width = min(base + hoverExtra + stretchExtra,
                            screen.frame.width - GC.minHClearance * 2)
            return CGSize(width: width, height: isIdle ? idlePeekHeight : GC.peekHeight)
        }

        // Idle never reaches the expanded tier — it has no controls to reveal.
        let isExpanded = presentation == .expanded && !isIdle

        // Hover widens the compact row by 8 pt.
        let hoverLift: CGFloat = isHovering && !isExpanded ? 8 : 0
        let stretch: CGFloat = max(gestureProgress * 0.8, 0)

        let baseW: CGFloat
        switch capture {
        case .idle:                        baseW = idleCompactWidth
        case .starting, .finalizing:       baseW = statusWidth
        case .permissionRequired, .failed: baseW = attentionWidth
        case .recording, .paused:          baseW = recordingWidth
        }

        let width = min(
            baseW + hoverLift + stretch + (isExpanded ? expandedExtraWidth : 0),
            screen.frame.width - GC.minHClearance * 2
        )
        let height = compactHeight(for: capture) + (isExpanded ? expandedExtraHeight : 0)
        return CGSize(width: max(width, 0), height: height)
    }

    /// Height of the compact strip. Only the idle launcher deviates — its captioned
    /// buttons need more vertical room than the recording row's inline controls.
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

    // MARK: - Bottom slack

    /// Padding below the island body inside the panel.
    ///
    /// Derived from the same `bottomAnchor` / `envelopeBottom` helpers that
    /// `IslandGeometryProvider` uses, so placement and the SwiftUI spacer always agree.
    static func bottomSlack(screen: ScreenDescription) -> CGFloat {
        max(0, IslandGeometryProvider.bottomAnchor(for: screen)
             - IslandGeometryProvider.envelopeBottom(for: screen))
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
            // Every compact row is a true capsule, so the idle launcher tracks its own height.
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
