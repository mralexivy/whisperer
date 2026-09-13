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
        if elapsed >= IslandUX.revealDelay {
            phase = .revealed
        } else if elapsed >= IslandUX.sliverDelay {
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

    /// Reset to hidden and clear the clock. Called on zone exit or placement change.
    mutating func reset() {
        phase      = .hidden
        entryPoint = .zero
        entryTime  = 0
    }

    /// Current phase without advancing (read-only snapshot).
    var currentPhase: IslandRevealPhase { phase }
}
