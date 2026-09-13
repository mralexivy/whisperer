//
//  IslandRevealGateTests.swift
//  WhispererTests
//
//  Tests for IslandRevealGate — pure dwell+stillness gate, no display required.
//  Run with: xcodebuild test -only-testing:WhispererTests/IslandRevealGateTests
//

import XCTest
@testable import whisperer

final class IslandRevealGateTests: XCTestCase {

    private let origin = NSPoint(x: 400, y: 100)
    private let t0: TimeInterval = 1000

    // MARK: - Helpers

    /// Returns a gate after a single step with given elapsed time.
    private func gate(elapsed: TimeInterval, moved: CGFloat = 0, inside: Bool = true) -> IslandRevealPhase {
        var g = IslandRevealGate()
        // Prime the entry.
        g.entered(point: origin, now: t0)
        let pt = NSPoint(x: origin.x + moved, y: origin.y)
        return g.step(point: pt, inside: inside, now: t0 + elapsed)
    }

    // MARK: - Basic phase progression

    func testBeforeAnyDwell_isHidden() {
        // Pointer enters but we immediately poll before any dwell.
        var g = IslandRevealGate()
        g.entered(point: origin, now: t0)
        XCTAssertEqual(g.currentPhase, .hidden)
    }

    func testBelowSliverDelay_isHidden() {
        XCTAssertEqual(gate(elapsed: IslandUX.sliverDelay - 0.05), .hidden)
    }

    func testAtSliverDelay_isSliver() {
        XCTAssertEqual(gate(elapsed: IslandUX.sliverDelay), .sliver)
    }

    func testBetweenSliverAndReveal_isSliver() {
        let mid = (IslandUX.sliverDelay + IslandUX.revealDelay) / 2
        XCTAssertEqual(gate(elapsed: mid), .sliver)
    }

    func testAtRevealDelay_isRevealed() {
        XCTAssertEqual(gate(elapsed: IslandUX.revealDelay), .revealed)
    }

    func testAfterRevealDelay_staysRevealed() {
        XCTAssertEqual(gate(elapsed: IslandUX.revealDelay + 5), .revealed)
    }

    // MARK: - Zone exit resets

    func testExitZoneResetsToHidden() {
        var g = IslandRevealGate()
        g.entered(point: origin, now: t0)
        g.step(point: origin, inside: true, now: t0 + IslandUX.revealDelay)
        XCTAssertEqual(g.currentPhase, .revealed)
        g.step(point: origin, inside: false, now: t0 + IslandUX.revealDelay + 0.05)
        XCTAssertEqual(g.currentPhase, .hidden)
    }

    func testExitDuringSliver_resetsToHidden() {
        var g = IslandRevealGate()
        g.entered(point: origin, now: t0)
        g.step(point: origin, inside: true, now: t0 + IslandUX.sliverDelay)
        XCTAssertEqual(g.currentPhase, .sliver)
        g.step(point: origin, inside: false, now: t0 + IslandUX.sliverDelay + 0.01)
        XCTAssertEqual(g.currentPhase, .hidden)
    }

    // MARK: - Stillness radius

    func testJitterUnderStillnessRadius_doesNotReset() {
        // Jitter of stillnessRadius - 1 should not reset the clock.
        var g = IslandRevealGate()
        g.entered(point: origin, now: t0)
        let jitter = IslandUX.stillnessRadius - 1
        let jitteredPt = NSPoint(x: origin.x + jitter, y: origin.y)
        let phase = g.step(point: jitteredPt, inside: true, now: t0 + IslandUX.revealDelay)
        XCTAssertEqual(phase, .revealed, "Jitter < stillnessRadius must not reset the clock")
    }

    func testMoveBeyondStillnessRadius_reseetsPhase() {
        var g = IslandRevealGate()
        g.entered(point: origin, now: t0)
        // Dwell enough to get to sliver.
        g.step(point: origin, inside: true, now: t0 + IslandUX.sliverDelay)
        XCTAssertEqual(g.currentPhase, .sliver)
        // Move > stillnessRadius.
        let farPt = NSPoint(x: origin.x + IslandUX.stillnessRadius + 1, y: origin.y)
        g.step(point: farPt, inside: true, now: t0 + IslandUX.sliverDelay + 0.01)
        XCTAssertEqual(g.currentPhase, .hidden, "Moving > stillnessRadius should restart clock")
    }

    func testDragThatResetsClockNeverReveals() {
        // Move beyond stillnessRadius faster than sliverDelay — clock always resets.
        // Each "step" takes sliverDelay*0.8 seconds but moves stillnessRadius+2 pt,
        // which exceeds the stillness threshold and re-anchors before the sliver fires.
        var g = IslandRevealGate()
        g.entered(point: origin, now: t0)
        var t = t0
        var x = origin.x
        for i in 0..<20 {
            x += IslandUX.stillnessRadius + 2   // always exceeds threshold
            t += IslandUX.sliverDelay * 0.8     // always less than sliverDelay from last anchor
            let p = NSPoint(x: x, y: origin.y)
            let phase = g.step(point: p, inside: true, now: t)
            XCTAssertEqual(phase, .hidden, "Drag (step \(i)) should stay hidden — clock resets every step")
        }
    }

    func testFastPassThroughNeverReveals() {
        // Simulate pointer sweeping through: big moves but total time < sliverDelay.
        var g = IslandRevealGate()
        g.entered(point: origin, now: t0)
        let totalTime = IslandUX.sliverDelay * 0.8
        let steps = 20
        for i in 1...steps {
            let t = t0 + totalTime * Double(i) / Double(steps)
            let x = origin.x + CGFloat(i) * 5   // moves 5 pt per step → large total
            let p = NSPoint(x: x, y: origin.y)
            let phase = g.step(point: p, inside: true, now: t)
            // Each big move resets, so phase stays hidden.
            XCTAssertEqual(phase, .hidden, "Fast sweep step \(i) must stay hidden")
        }
    }

    // MARK: - Revealed phase is sticky

    func testOnceRevealedStillnessNoLongerApplies() {
        var g = IslandRevealGate()
        g.entered(point: origin, now: t0)
        g.step(point: origin, inside: true, now: t0 + IslandUX.revealDelay)
        XCTAssertEqual(g.currentPhase, .revealed)
        // Move far while still inside — should stay revealed.
        let farPt = NSPoint(x: origin.x + IslandUX.stillnessRadius * 3, y: origin.y)
        let phase = g.step(point: farPt, inside: true, now: t0 + IslandUX.revealDelay + 0.1)
        XCTAssertEqual(phase, .revealed, "Revealed must be sticky while still inside the zone")
    }

    // MARK: - Reset

    func testManualReset_returnsToHidden() {
        var g = IslandRevealGate()
        g.entered(point: origin, now: t0)
        g.step(point: origin, inside: true, now: t0 + IslandUX.revealDelay)
        XCTAssertEqual(g.currentPhase, .revealed)
        g.reset()
        XCTAssertEqual(g.currentPhase, .hidden)
    }

    // MARK: - Approach-and-rest pattern

    func testApproachAndRest_revealsAfterSettling() {
        // Simulate pointer moving toward the zone then settling.
        var g = IslandRevealGate()
        // Burst of movement.
        g.entered(point: NSPoint(x: 0, y: 100), now: t0)
        for i in 1...8 {
            let x = CGFloat(i) * 50  // large fast moves
            g.step(point: NSPoint(x: x, y: 100), inside: true, now: t0 + Double(i) * 0.02)
        }
        // Pointer settles at x=400.
        let settledPt = NSPoint(x: 400, y: 100)
        let settleTime = t0 + 8 * 0.02
        g.step(point: settledPt, inside: true, now: settleTime)
        // After full reveal delay of stillness, must be revealed.
        let phase = g.step(point: settledPt, inside: true, now: settleTime + IslandUX.revealDelay)
        XCTAssertEqual(phase, .revealed, "Pointer at rest must eventually reach .revealed")
    }
}
