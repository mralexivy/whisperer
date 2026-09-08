//
//  IslandContentSizer.swift
//  Whisperer
//
//  Pure, nonisolated struct that maps (capture state, presentation, screen) → target geometry.
//  This is Whisperer's equivalent of Atoll's `dynamicNotchSize` computed property and
//  `getClosedNotchSize()` / `openNotchSize` helpers in matters.swift.
//
//  The island body springs to a different CGSize per active content type. Width changing
//  per state is the entire "growing" illusion — a narrow "Starting…" capsule widens into
//  the recording pill, then contracts into the "Finishing…" rule.
//
//  The IslandPanel frame stays at its fixed union envelope (IslandGeometryProvider.panelEnvelope);
//  only the SwiftUI content frame moves, giving Atoll's morph without NSWindow resize jitter.
//

import AppKit

/// The horizontal zones of the compact row, mirroring Atoll's `RecordingLiveActivity` geometry.
nonisolated struct IslandRowMetrics: Equatable {
    /// Camera-housing dead zone. Must stay empty. Zero on notchless displays.
    var centerWidth: CGFloat
    /// Leading badge wing — one square glyph, nothing more.
    var leadingWidth: CGFloat
    /// Height of the content inside the compact strip (housing height minus breathing room).
    var rowHeight: CGFloat
    /// Height of the whole compact strip — the housing height, so the island stays flush.
    var compactHeight: CGFloat
    /// Diameter for inline controls, scaled to the strip rather than fixed.
    var controlSize: CGFloat
}

nonisolated struct IslandContentSizer {

    // MARK: - Wing widths (Atoll `RecordingHUDPresentation.extraWidth`)

    /// Wing width added to the closed notch for the recording / paused row. Everything the
    /// island shows lives in these wings — the center is the housing and is unusable.
    static let recordingExtraWidth: CGFloat = 248
    /// Wing width for the single-line status rows (starting, finishing).
    static let statusExtraWidth: CGFloat = 210
    /// Wing width for the permission / failure rows, which carry a longer message.
    static let attentionExtraWidth: CGFloat = 260
    /// Extra height added when expanded — the secondary control row. Atoll uses 70; ours is
    /// taller because our secondary buttons are labelled.
    static let expandedExtraHeight: CGFloat = 84
    /// Extra width added when expanded (Atoll: 132 compact → 140 opened). The secondary row is
    /// three 40 pt labelled buttons at 24 pt spacing, so the opened pill must be wider than the
    /// compact one or the labels crush — and a morph that only grows downwards reads as a drawer
    /// sliding out, not as the island opening.
    static let expandedExtraWidth: CGFloat = 56

    // MARK: - Target size

    /// Atoll's `hudWidth` / `hudHeight`: the island is the closed notch **plus** wings, never a
    /// fixed slab. That is what keeps the compact row flush with the housing on a notched Mac
    /// and continuous (no dead center) on a notchless one.
    static func targetSize(
        capture: IslandCaptureState,
        presentation: IslandPresentation,
        screen: ScreenDescription,
        isHovering: Bool,
        gestureProgress: CGFloat
    ) -> CGSize {
        guard presentation != .hidden, capture != .idle else { return .zero }

        let closed = IslandGeometryProvider().closedNotchSize(for: screen)
        let isExpanded = presentation == .expanded
        // Hover widens the center by 8 pt (Atoll `centerWidth`); it does not change the height.
        let hoverLift: CGFloat = isHovering && !isExpanded ? 8 : 0
        let stretch: CGFloat = max(gestureProgress * 0.8, 0)

        let extraW: CGFloat
        switch capture {
        case .idle:                        extraW = 0
        case .starting, .finalizing:       extraW = statusExtraWidth
        case .permissionRequired, .failed: extraW = attentionExtraWidth
        case .recording, .paused:          extraW = recordingExtraWidth
        }

        var size = CGSize(
            width:  closed.width + extraW + hoverLift + stretch
                    + (isExpanded ? expandedExtraWidth : 0),
            height: closed.height + (isExpanded ? expandedExtraHeight : 0)
        )
        // Clamp to screen width with minimum side clearance, but never below the housing.
        size.width = max(min(size.width, screen.frame.width - 32), closed.width)
        return size
    }

    // MARK: - Row metrics (Atoll `leadingWidth` / `centerWidth` / `rowHeight`)

    /// The three horizontal zones of the compact row. `centerWidth` is the camera housing and
    /// must stay empty; `leadingWidth` is a single square badge; everything else is trailing.
    static func rowMetrics(
        screen: ScreenDescription,
        isHovering: Bool,
        gestureProgress: CGFloat
    ) -> IslandRowMetrics {
        let closed = IslandGeometryProvider().closedNotchSize(for: screen)
        let rowHeight = max(closed.height - 12, 18)
        return IslandRowMetrics(
            centerWidth:  closed.width > 0 ? closed.width + (isHovering ? 8 : 0) : 0,
            leadingWidth: max(0, rowHeight + max(gestureProgress, 0) / 2),
            rowHeight:    rowHeight,
            compactHeight: closed.height,
            controlSize:  min(max(closed.height - 8, 22), 30)
        )
    }

    // MARK: - Notch-aware placement

    /// Horizontal dead zone the camera housing occupies. Content must flank it — nothing may be
    /// laid out under the housing, or it is simply invisible. Zero on notchless displays.
    /// Superseded for layout by `rowMetrics(...).centerWidth`; kept as the geometry query.
    static func notchGap(screen: ScreenDescription) -> CGFloat {
        IslandGeometryProvider().closedNotchSize(for: screen).width
    }

    /// Distance from the top of the panel envelope down to where the island's top edge belongs.
    /// Notched: flush with the physical screen top so the black body merges with the housing
    /// instead of floating a rounded pill next to it. Notchless: 8 pt below the menu bar.
    static func topSlack(screen: ScreenDescription) -> CGFloat {
        let geo = IslandGeometryProvider()
        let envelope = geo.panelEnvelope(for: screen)
        // On a notched display the top edge is `topEdgeY` — `screen.frame.maxY` plus the bleed
        // that seals the body against the camera housing. Using the raw maxY here would push
        // the island down by exactly the bleed and reopen the hairline it exists to close.
        let desiredTopY = geo.notchGeometry(for: screen) != nil
            ? geo.topEdgeY(for: screen)
            : screen.visibleFrame.maxY - IslandGeometryProvider.C.notchlessGapFromTop
        return max(0, envelope.maxY - desiredTopY)
    }

    /// Top corners are square on a notched display so the body reads as one shape with the
    /// hardware housing; the bottom corners carry the pill radius.
    static func cornerRadii(
        capture: IslandCaptureState,
        presentation: IslandPresentation,
        screen: ScreenDescription
    ) -> (top: CGFloat, bottom: CGFloat) {
        let geo = IslandGeometryProvider()
        let height = targetSize(capture: capture, presentation: presentation, screen: screen,
                                isHovering: false, gestureProgress: 0).height
        // Never round more than half the height, or the strip collapses into a lozenge.
        let r = min(cornerRadius(capture: capture, presentation: presentation), height / 2)
        if geo.notchGeometry(for: screen) != nil {
            return (top: 0, bottom: r)
        }
        return (top: r, bottom: r)
    }

    // MARK: - Corner radius

    /// Atoll `dynamicIslandPillCornerRadiusInsets` (matters.swift:355): 16 closed, 24 opened.
    /// The old 22–28 pt values were larger than half the compact strip's height, which rounds
    /// the pill into a lozenge instead of a notch.
    static func cornerRadius(
        capture: IslandCaptureState,
        presentation: IslandPresentation
    ) -> CGFloat {
        guard presentation != .hidden, capture != .idle else { return 0 }
        return presentation == .expanded ? 24 : 16
    }
}
