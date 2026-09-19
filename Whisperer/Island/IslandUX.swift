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
    //
    // These are deliberately short. The long dwell they replaced existed because the idle
    // Island was invisible: the only protection against opening it by accident was to make
    // the user prove intent by waiting. Now that the handle is always on screen, the pointer
    // arriving on it is already a deliberate act of aiming, so the dwell only has to reject a
    // pointer *sweeping past* the screen edge — which a sweep fails simply by leaving the
    // zone, or by moving further than `stillnessRadius` and re-anchoring the clock.
    //
    // What the dwell really measures is *stopping*. A pointer that has come to rest on the
    // handle has already said everything it needs to say, so the wait after that should be
    // near-imperceptible — 0.18 s is short enough to read as "it opened when I stopped"
    // rather than as a delay to sit through. Anything in transit still gets filtered, because
    // in-transit pointers are by definition not still.

    /// Duration the pointer must dwell still before the sliver phase (seconds)
    static let sliverDelay: TimeInterval   = 0.07
    /// Duration the pointer must dwell still before the launcher row opens (seconds)
    static let revealDelay: TimeInterval   = 0.18
    /// Max pointer movement (pt) that counts as "still" during dwell.
    /// Roomier than it was: over a 0.28 s window the small corrections of aiming at the
    /// handle must not keep restarting the clock.
    static let stillnessRadius: CGFloat    = 18
    /// How long after hover-exit before the bar hides (seconds)
    static let hoverExitDebounce: TimeInterval = 0.10

    // MARK: - Hover padding (for hit box / hover rect)

    // The resting handle is only 9 pt thick, so the *visible* target is far too small to
    // aim at directly. These pads are what the pointer actually has to hit, and they are
    // sized so the handle can be acquired with a casual flick at the screen edge rather
    // than a deliberate hunt. Growing them costs nothing: the zone still sits at a screen
    // edge, and a pointer merely crossing it leaves again long before the dwell completes.

    /// Extra padding around the idle/peek pill for the hover zone (horizontal case)
    static let hoverHPadGenerous: CGFloat       = 0
    /// Extra upward padding for the idle/peek pill
    static let hoverVPadUpGenerous: CGFloat     = 0
    /// Extra downward padding for the idle/peek pill
    static let hoverVPadDownGenerous: CGFloat   = 0
    /// Standard narrow padding for a visible non-idle row
    static let hoverPadNarrow: CGFloat          = 12
    static let hoverVPadNarrowUp: CGFloat       = 3
    static let hoverVPadNarrowDown: CGFloat     = 3

    // MARK: - Hint label

    /// Fixed height reserved for the floating hint chip band above/below the pill
    static let hintBandHeight: CGFloat     = 31
    /// Fixed width reserved for the hint chip band beside a vertical (left/right) pill.
    /// Sized for the longest glyph name so the chip never overflows its band.
    static let hintBandWidth: CGFloat      = 104

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

    // MARK: - Tap targets

    /// Glyph capsule minimum (matches IslandContentSizer.launcherItemWidth)
    static let minTapTarget: CGFloat       = 28
    /// Full accessibility minimum
    static let minA11yTapTarget: CGFloat   = 44

    // MARK: - Hot-zone area cap

    /// Hover rect must cover ≤ this fraction of the screen (anti-hijack guard)
    static let maxHoverZoneFraction: CGFloat = 0.12
}
