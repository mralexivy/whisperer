//
//  IslandUX.swift
//  Whisperer
//
//  Single authoritative source for Island UX constants.
//  Both views and tests read from here — a single edit is the only way to drift.
//

import Foundation

nonisolated enum IslandUX {

    // MARK: - Reveal timing

    /// Duration the pointer must dwell still before the sliver appears (seconds)
    static let sliverDelay: TimeInterval   = 0.25
    /// Duration the pointer must dwell still before the full bar appears (seconds)
    static let revealDelay: TimeInterval   = 0.70
    /// Max pointer movement (pt) that counts as "still" during dwell
    static let stillnessRadius: CGFloat    = 12
    /// How long after hover-exit before the bar hides (seconds)
    static let hoverExitDebounce: TimeInterval = 0.10

    // MARK: - Hover padding (for hit box / hover rect)

    /// Extra padding around the idle/peek pill for the hover zone (horizontal case)
    static let hoverHPadGenerous: CGFloat       = 40
    /// Extra upward padding for the idle/peek pill
    static let hoverVPadUpGenerous: CGFloat     = 22
    /// Extra downward padding for the idle/peek pill
    static let hoverVPadDownGenerous: CGFloat   = 12
    /// Standard narrow padding for a visible non-idle row
    static let hoverPadNarrow: CGFloat          = 12
    static let hoverVPadNarrowUp: CGFloat       = 3
    static let hoverVPadNarrowDown: CGFloat     = 3

    // MARK: - Hint label

    /// Fixed height reserved for the floating hint chip band above/beside the pill
    static let hintBandHeight: CGFloat     = 31

    // MARK: - Animation durations / springs

    /// Open spring response (seconds)
    static let springResponseOpen: Double  = 0.42
    /// Close spring response (seconds)
    static let springResponseClose: Double = 0.45
    /// Hint chip cross-fade duration (seconds)
    static let hintFadeDuration: Double    = 0.18
    /// Max allowed animation duration for any reveal-path animation (for UX invariant tests)
    static let maxRevealAnimDuration: Double = 0.45
    /// ReduceMotion linear duration (seconds)
    static let reduceMotionDuration: Double = 0.12

    // MARK: - Sliver

    /// Thickness of the progressive sliver (pt) on the anchored edge
    static let sliverThickness: CGFloat    = 3

    // MARK: - Tap targets

    /// Glyph capsule minimum (matches IslandContentSizer.launcherItemWidth)
    static let minTapTarget: CGFloat       = 28
    /// Full accessibility minimum
    static let minA11yTapTarget: CGFloat   = 44

    // MARK: - Hot-zone area cap

    /// Hover rect must cover ≤ this fraction of the screen (anti-hijack guard)
    static let maxHoverZoneFraction: CGFloat = 0.12
}
