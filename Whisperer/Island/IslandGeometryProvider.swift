//
//  IslandGeometryProvider.swift
//  Whisperer
//
//  Pure, nonisolated struct computing Island frames from an injected ScreenDescription.
//  Unit-testable without a display: inject a synthetic ScreenDescription in tests.
//
//  Notch detection:
//    - Both auxiliaryTopLeft and auxiliaryTopRight must exist.
//    - topRight.minX > topLeft.maxX  (positive exclusion span N).
//    - safeAreaTopInset > 0.
//    - Any ambiguous/non-positive dimension falls back to floating (notchless) placement.
//
//  Panel strategy:
//    - The panel frame is the UNION of all state frames plus 8 pt animation slack on each side.
//    - This lets the silhouette morph inside a fixed window, avoiding NSWindow resize jitter.
//    - Compact and expanded shapes animate purely within SwiftUI; the panel never resizes.
//
//  Coordinate system:
//    - NSRect uses bottom-left origin (Core Graphics / AppKit convention).
//    - "Top" in English descriptions corresponds to maxY in NSRect terms.
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
    /// Height of the safe-area inset at the top (notch depth equivalent).
    var safeAreaTopInset: CGFloat
    /// The auxiliary area to the left of the notch camera housing, if present.
    var auxiliaryTopLeft: NSRect?
    /// The auxiliary area to the right of the notch camera housing, if present.
    var auxiliaryTopRight: NSRect?
    /// Backing scale factor (1 on non-Retina, 2 on Retina, etc.)
    var backingScale: CGFloat

    // MARK: Factory

    static func from(_ screen: NSScreen) -> ScreenDescription {
        // auxiliaryTopLeftArea / auxiliaryTopRightArea are macOS 12+ and our target is 26.2.
        ScreenDescription(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea,
            backingScale: screen.backingScaleFactor
        )
    }
}

// MARK: - Provider

struct IslandGeometryProvider {

    // MARK: Constants (spec §2.1 / §2.4)

    enum C {
        // Notchless compact — wide pill matching iOS Dynamic Island style
        static let notchlessCompactWidth:   CGFloat = 380
        static let notchlessCompactHeight:  CGFloat = 56
        static let notchlessCompactRadius:  CGFloat = 28
        static let notchlessGapFromTop:     CGFloat = 8       // below visibleFrame.maxY
        static let notchlessMinHClearance:  CGFloat = 16

        // Status capsule widening (kept for compat)
        static let statusCapsuleMaxWidth:   CGFloat = 380

        // Notched compact — spans notch + wide wings
        static let notchedWingWidth:        CGFloat = 90      // wide wings for content
        static let notchedMinHeight:        CGFloat = 56

        // Notchless expanded
        static let notchlessExpandedWidth:  CGFloat = 380
        static let notchlessExpandedHeight: CGFloat = 120
        static let notchlessExpandedRadius: CGFloat = 28

        // Notched expanded
        static let notchedExpandedMinWidth: CGFloat = 380
        static let notchedBodyHeight:       CGFloat = 64      // control row height

        // Panel slack around each bounding box edge
        static let panelSlack:              CGFloat = 8

        // Extra window height past screen.maxY on physical-notch displays.
        // Atoll: `notchTopScreenBleedAmount` (matters.swift:364). Without it the black body
        // stops exactly on the last pixel row and a hairline of wallpaper — plus edge
        // antialiasing — shows between the island and the camera housing it is replacing.
        static let notchTopScreenBleed:     CGFloat = 4

        // Stand-in for the housing height on displays that have none, so the floating pill has
        // the same proportions as the real notch instead of an arbitrary slab height.
        static let notchlessClosedHeight:   CGFloat = 32

        // Floating shadow
        static let shadowOffsetY:           CGFloat = 6
        static let shadowRadius:            CGFloat = 16
    }

    // MARK: - Notch detection

    struct NotchGeometry: Equatable {
        let exclusionMinX: CGFloat     // left edge of camera housing in screen coords
        let exclusionMaxX: CGFloat     // right edge
        let exclusionWidth: CGFloat    // N
        let topInset: CGFloat          // T
        let leftWing: NSRect           // usable left auxiliary area
        let rightWing: NSRect          // usable right auxiliary area
    }

    /// Returns notch geometry if this screen has a hardware notch, nil otherwise.
    func notchGeometry(for screen: ScreenDescription) -> NotchGeometry? {
        guard let left = screen.auxiliaryTopLeft,
              let right = screen.auxiliaryTopRight else { return nil }

        let N = right.minX - left.maxX
        let T = screen.safeAreaTopInset
        guard N > 0, T > 0 else { return nil }

        return NotchGeometry(
            exclusionMinX: left.maxX,
            exclusionMaxX: right.minX,
            exclusionWidth: N,
            topInset: T,
            leftWing: left,
            rightWing: right
        )
    }

    // MARK: - Top edge

    /// Extra height the panel is allowed past `screen.frame.maxY`.
    /// Non-zero only on physical-notch displays, where the island replaces the camera housing
    /// and must bleed past the last pixel row to seal against it. Notchless displays float a
    /// detached pill below the menu bar instead and need no bleed — this mirrors Atoll's
    /// `notchTopScreenBleed(for:)` / `shouldUseDynamicIslandMode(for:)` split, where the pill
    /// shape is used only when `safeAreaInsets.top <= 0`.
    func topBleed(for screen: ScreenDescription) -> CGFloat {
        notchGeometry(for: screen) != nil ? C.notchTopScreenBleed : 0
    }

    /// The Y coordinate the island's top edge sits at, in screen coordinates.
    func topEdgeY(for screen: ScreenDescription) -> CGFloat {
        screen.frame.maxY + topBleed(for: screen)
    }

    // MARK: - Closed notch size (Atoll `getClosedNotchSize()`)

    /// The size of the thing the island replaces, before any wings are added.
    ///
    /// Atoll (`matters.swift:397`) computes this as
    /// `screen.frame.width - auxTopLeft.width - auxTopRight.width + 4` by `safeAreaInsets.top`
    /// — i.e. exactly the camera housing plus 4 pt, exactly as tall as the housing. Wings are
    /// added on top by `IslandContentSizer.extraWidth`; they are never baked in here. Building
    /// a fixed wide slab instead is what produced the giant dead zone in the middle of the pill.
    ///
    /// Width is **zero** on a notchless display: there is no housing to route content around,
    /// so the pill is continuous and a reserved center would just be a hole.
    func closedNotchSize(for screen: ScreenDescription) -> CGSize {
        guard let notch = notchGeometry(for: screen) else {
            return CGSize(width: 0, height: C.notchlessClosedHeight)
        }
        return CGSize(width: notch.exclusionWidth + 4, height: notch.topInset)
    }

    // MARK: - Compact frame

    /// Frame for the compact (recording) Island on `screen`.
    /// Returns a rect in the same coordinate system as `screen.frame`.
    func compactFrame(for screen: ScreenDescription) -> NSRect {
        if let notch = notchGeometry(for: screen) {
            return compactFrameNotched(screen: screen, notch: notch)
        }
        return compactFrameFloating(screen: screen)
    }

    private func compactFrameNotched(screen: ScreenDescription, notch: NotchGeometry) -> NSRect {
        let width  = notch.exclusionWidth + C.notchedWingWidth * 2
        let height = max(notch.topInset + 8, C.notchedMinHeight)
        // Anchor past the physical top edge so the body seals against the camera housing.
        let x = screen.frame.origin.x + (screen.frame.width - width) / 2
        let y = topEdgeY(for: screen) - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func compactFrameFloating(screen: ScreenDescription) -> NSRect {
        let width  = C.notchlessCompactWidth
        let height = C.notchlessCompactHeight
        var x = screen.frame.origin.x + (screen.frame.width - width) / 2
        // Clamp to minimum horizontal clearance
        let minX = screen.frame.origin.x + C.notchlessMinHClearance
        let maxX = screen.frame.maxX - width - C.notchlessMinHClearance
        x = max(minX, min(maxX, x))
        // 8 pt below the top of the *visible* frame (respects menu bar)
        let y = screen.visibleFrame.maxY - height - C.notchlessGapFromTop
        return NSRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Expanded frame

    /// Frame for the expanded Island on `screen`. Top edge is always fixed to compact top edge.
    func expandedFrame(for screen: ScreenDescription) -> NSRect {
        if let notch = notchGeometry(for: screen) {
            return expandedFrameNotched(screen: screen, notch: notch)
        }
        return expandedFrameFloating(screen: screen)
    }

    private func expandedFrameNotched(screen: ScreenDescription, notch: NotchGeometry) -> NSRect {
        let compactW = notch.exclusionWidth + C.notchedWingWidth * 2
        let compactH = max(notch.topInset + 8, C.notchedMinHeight)
        let width    = min(max(C.notchedExpandedMinWidth, compactW),
                          screen.frame.width - 32)
        let height   = compactH + C.notchedBodyHeight
        let x        = screen.frame.origin.x + (screen.frame.width - width) / 2
        let y        = topEdgeY(for: screen) - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func expandedFrameFloating(screen: ScreenDescription) -> NSRect {
        let compact  = compactFrameFloating(screen: screen)
        let width    = C.notchlessExpandedWidth
        let height   = C.notchlessExpandedHeight
        let x        = screen.frame.origin.x + (screen.frame.width - width) / 2
        // Top edge fixed to compact top edge
        let y        = compact.maxY - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Status capsule width override

    /// Maximum width for the compact island when a long status label ("Starting…") is shown.
    func statusCapsuleWidth(for screen: ScreenDescription) -> CGFloat {
        min(C.statusCapsuleMaxWidth, screen.frame.width - C.notchlessMinHClearance * 2)
    }

    // MARK: - Panel envelope

    /// The union of all Island frames plus animation slack — the single fixed window size
    /// inside which the silhouette morphs. Kept stable per display so the NSPanel never resizes.
    func panelEnvelope(for screen: ScreenDescription) -> NSRect {
        let compact  = compactFrame(for: screen)
        let expanded = expandedFrame(for: screen)
        let union    = compact.union(expanded)
        // Inflate by slack on all sides
        let s = C.panelSlack
        let inflated = NSRect(
            x:      union.origin.x - s,
            y:      union.origin.y - s,
            width:  union.width    + s * 2,
            height: union.height   + s * 2
        )

        // Clamp horizontally and at the bottom, but allow the top to reach `topEdgeY` — a plain
        // `.intersection(screen.frame)` clips off exactly the notch bleed the island needs to
        // seal against the camera housing, leaving a hairline of wallpaper above the black body.
        let minX = max(inflated.minX, screen.frame.minX)
        let maxX = min(inflated.maxX, screen.frame.maxX)
        let minY = max(inflated.minY, screen.frame.minY)
        let maxY = min(inflated.maxY, topEdgeY(for: screen))
        return NSRect(x: minX, y: minY,
                      width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    // MARK: - Local (panel-relative) frames

    /// Compact frame expressed relative to the panel envelope's origin.
    func localCompactFrame(for screen: ScreenDescription) -> NSRect {
        let env     = panelEnvelope(for: screen)
        let global  = compactFrame(for: screen)
        return global.offsetBy(dx: -env.origin.x, dy: -env.origin.y)
    }

    /// Expanded frame expressed relative to the panel envelope's origin.
    func localExpandedFrame(for screen: ScreenDescription) -> NSRect {
        let env     = panelEnvelope(for: screen)
        let global  = expandedFrame(for: screen)
        return global.offsetBy(dx: -env.origin.x, dy: -env.origin.y)
    }

    // MARK: - Corner radii

    struct CornerRadii: Equatable {
        var topLeading:    CGFloat
        var topTrailing:   CGFloat
        var bottomLeading: CGFloat
        var bottomTrailing:CGFloat
    }

    func compactCornerRadii(for screen: ScreenDescription) -> CornerRadii {
        if notchGeometry(for: screen) != nil {
            // Notched: flat top (merges with hardware), ~20 pt lower corners
            return CornerRadii(topLeading: 10, topTrailing: 10, bottomLeading: 20, bottomTrailing: 20)
        }
        // Floating pill
        let r = C.notchlessCompactRadius
        return CornerRadii(topLeading: r, topTrailing: r, bottomLeading: r, bottomTrailing: r)
    }

    func expandedCornerRadii(for screen: ScreenDescription) -> CornerRadii {
        if notchGeometry(for: screen) != nil {
            return CornerRadii(topLeading: 10, topTrailing: 10, bottomLeading: 28, bottomTrailing: 28)
        }
        let r = C.notchlessExpandedRadius
        return CornerRadii(topLeading: r, topTrailing: r, bottomLeading: r, bottomTrailing: r)
    }

    // MARK: - Shadow eligibility

    /// Shadow is only drawn in floating (notchless) mode and only when the Island
    /// is below the top edge of the screen (not clipped by the edge).
    func shouldDrawShadow(for screen: ScreenDescription) -> Bool {
        notchGeometry(for: screen) == nil
    }

    // MARK: - Notch exclusion zone (for content layout)

    /// The exclusion zone in panel-local coordinates — content must not be placed here.
    /// Returns nil on notchless displays.
    func localExclusionZone(for screen: ScreenDescription) -> NSRect? {
        guard let notch = notchGeometry(for: screen) else { return nil }
        let env = panelEnvelope(for: screen)
        return NSRect(
            x:      notch.exclusionMinX - env.origin.x,
            y:      screen.frame.maxY - notch.topInset - env.origin.y,
            width:  notch.exclusionWidth,
            height: notch.topInset
        )
    }
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
