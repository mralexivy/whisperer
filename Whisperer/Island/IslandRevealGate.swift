//
//  IslandRevealGate.swift
//  Whisperer
//
//  Pure, nonisolated dwell+stillness state machine for the idle Island reveal.
//  `nonisolated` so it is safe to unit-test without the @MainActor deinit crash (CLAUDE.md).
//
//  Reveal progression:
//    .hidden  → (dwell sliverDelay, pointer still)  → .sliver
//    .sliver  → (dwell revealDelay total, still)     → .revealed
//    .revealed → stays revealed while inside zone
//    any phase → exit zone → .hidden (instant, clock reset)
//    any phase → move > stillnessRadius while inside → re-anchor, clock restart
//
//  Once revealed, stillness no longer applies so buttons remain reachable
//  even with normal hand tremor.
//

import Foundation
import CoreGraphics

nonisolated struct IslandRevealGate {

    /// Slack on the dwell threshold comparisons.
    ///
    /// `elapsed` is the difference of two large absolute timestamps
    /// (`timeIntervalSinceReferenceDate` is ~8×10⁸), so it carries rounding error: a pointer
    /// polled at exactly `entryTime + revealDelay` can compute an `elapsed` a few ULPs
    /// *below* the threshold and stall one phase short. One microsecond of slack is far
    /// below anything a human or the event loop can resolve, and removes the boundary
    /// flake entirely.
    private static let thresholdEpsilon: TimeInterval = 1e-6

    // MARK: - State

    private var entryPoint: NSPoint      = .zero
    private var entryTime:  TimeInterval = 0       // 0 = not yet primed
    private var phase:      IslandRevealPhase = .hidden

    // MARK: - Advance

    /// Feed every pointer-moved event into this. Returns the new phase.
    ///
    /// - Parameters:
    ///   - point:  Current pointer location in screen coordinates.
    ///   - inside: Whether the pointer is currently inside the hover zone.
    ///   - now:    Current time (`CACurrentMediaTime()` or equivalent).
    @discardableResult
    mutating func step(point: NSPoint, inside: Bool, now: TimeInterval) -> IslandRevealPhase {
        guard inside else {
            reset()
            return .hidden
        }

        // Not yet primed — prime now (covers calls that skip `entered()`).
        if entryTime == 0 {
            entryPoint = point
            entryTime  = now
            return .hidden
        }

        // Revealed is sticky while inside.
        if phase == .revealed { return .revealed }

        // Stillness check: large movement re-anchors and resets the clock.
        let dx    = point.x - entryPoint.x
        let dy    = point.y - entryPoint.y
        let moved = sqrt(dx * dx + dy * dy)
        if moved > IslandUX.stillnessRadius {
            entryPoint = point
            entryTime  = now
            phase      = .hidden
            return .hidden
        }

        let elapsed = now - entryTime
        if elapsed >= IslandUX.revealDelay - Self.thresholdEpsilon {
            phase = .revealed
        } else if elapsed >= IslandUX.sliverDelay - Self.thresholdEpsilon {
            phase = .sliver
        }
        return phase
    }

    /// Prime the entry anchor when the pointer enters the zone.
    /// Subsequent `step` calls measure elapsed time from this moment.
    mutating func entered(point: NSPoint, now: TimeInterval) {
        entryPoint = point
        entryTime  = now
        phase      = .hidden
    }

    /// Jump straight to revealed, skipping the dwell. Used when the user clicks the resting
    /// handle — an explicit click is a stronger statement of intent than any dwell, so it
    /// should not have to wait one out. `.revealed` is sticky while the pointer stays inside,
    /// so subsequent `step` calls will not undo this.
    mutating func forceReveal(point: NSPoint, now: TimeInterval) {
        entryPoint = point
        entryTime  = now
        phase      = .revealed
    }

    /// Reset to hidden and clear the clock. Called on zone exit or placement change.
    mutating func reset() {
        phase      = .hidden
        entryPoint = .zero
        entryTime  = 0
    }

    /// Current phase without advancing (read-only snapshot).
    var currentPhase: IslandRevealPhase { phase }

    /// Seconds remaining until the dwell would reach `.revealed`, or nil if it already has
    /// (or the gate is not primed).
    ///
    /// The gate is stepped from `mouseMoved`, but it also *demands stillness* — and a still
    /// pointer produces no `mouseMoved` events. Without this, parking on the handle stops
    /// the clock exactly when it should be running and the launcher never opens. The caller
    /// uses this to arm a timer so the final transition happens on its own.
    func timeUntilReveal(now: TimeInterval) -> TimeInterval? {
        guard entryTime != 0, phase != .revealed else { return nil }
        return max(0, (entryTime + IslandUX.revealDelay) - now)
    }
}
