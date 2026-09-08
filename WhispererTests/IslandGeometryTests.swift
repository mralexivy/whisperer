//
//  IslandGeometryTests.swift
//  WhispererTests
//
//  Tests for IslandGeometryProvider using synthetic ScreenDescriptions — no display required.
//  Run with: xcodebuild test -only-testing:WhispererTests/IslandGeometryTests
//

import XCTest
@testable import whisperer

final class IslandGeometryTests: XCTestCase {

    let geo = IslandGeometryProvider()

    // MARK: - Helpers

    /// A 2560×1600 non-retina notchless display at origin zero.
    private var notchlessScreen: ScreenDescription {
        ScreenDescription(
            frame: NSRect(x: 0, y: 0, width: 2560, height: 1600),
            visibleFrame: NSRect(x: 0, y: 0, width: 2560, height: 1537),  // 63pt menu bar
            safeAreaTopInset: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            backingScale: 2
        )
    }

    /// A 3456×2234 Liquid Retina XDR (16" MBP) with a notch (N ≈ 250pt, T = 32pt).
    private var notchedScreen: ScreenDescription {
        ScreenDescription(
            frame: NSRect(x: 0, y: 0, width: 1728, height: 1117),   // logical points @2x
            visibleFrame: NSRect(x: 0, y: 0, width: 1728, height: 1085),
            safeAreaTopInset: 32,
            auxiliaryTopLeft:  NSRect(x: 0,    y: 1085, width: 739,  height: 32),
            auxiliaryTopRight: NSRect(x: 989,  y: 1085, width: 739,  height: 32),
            backingScale: 2
        )
    }

    /// A display at a negative origin (multi-display left of primary).
    private var negativeOriginScreen: ScreenDescription {
        ScreenDescription(
            frame: NSRect(x: -1920, y: 0, width: 1920, height: 1200),
            visibleFrame: NSRect(x: -1920, y: 0, width: 1920, height: 1137),
            safeAreaTopInset: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            backingScale: 1
        )
    }

    /// A very narrow display (e.g. a USB-C monitor at 800pt wide).
    private var narrowScreen: ScreenDescription {
        ScreenDescription(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 537),
            safeAreaTopInset: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            backingScale: 1
        )
    }

    // MARK: - Notch detection

    func testNotchDetected() {
        XCTAssertNotNil(geo.notchGeometry(for: notchedScreen))
    }

    func testNotchlessNotDetected() {
        XCTAssertNil(geo.notchGeometry(for: notchlessScreen))
    }

    func testMissingOneAuxiliaryFallsBack() {
        var s = notchedScreen
        s.auxiliaryTopLeft = nil
        XCTAssertNil(geo.notchGeometry(for: s))
    }

    func testZeroInsetFallsBack() {
        var s = notchedScreen
        s.safeAreaTopInset = 0
        XCTAssertNil(geo.notchGeometry(for: s))
    }

    func testNonPositiveExclusionFallsBack() {
        var s = notchedScreen
        // Make right.minX <= left.maxX
        s.auxiliaryTopRight = NSRect(x: 700, y: 1085, width: 100, height: 32)
        // left.maxX = 739, right.minX = 700 → N = -39
        XCTAssertNil(geo.notchGeometry(for: s))
    }

    // MARK: - Notchless compact frame

    func testNotchlessCompactDimensions() {
        let frame = geo.compactFrame(for: notchlessScreen)
        XCTAssertEqual(frame.width,  IslandGeometryProvider.C.notchlessCompactWidth,  accuracy: 0.5)
        XCTAssertEqual(frame.height, IslandGeometryProvider.C.notchlessCompactHeight, accuracy: 0.5)
    }

    func testNotchlessCompactCenteredHorizontally() {
        let screen = notchlessScreen
        let frame  = geo.compactFrame(for: screen)
        let center = frame.midX
        XCTAssertEqual(center, screen.frame.midX, accuracy: 1.0)
    }

    func testNotchlessCompactBelowVisibleTop() {
        let screen = notchlessScreen
        let frame  = geo.compactFrame(for: screen)
        let expectedMaxY = screen.visibleFrame.maxY - IslandGeometryProvider.C.notchlessGapFromTop
        XCTAssertLessThanOrEqual(frame.maxY, expectedMaxY + 0.5)
    }

    // MARK: - Notched compact frame

    func testNotchedCompactWidth() {
        guard let notch = geo.notchGeometry(for: notchedScreen) else {
            return XCTFail("Expected notch")
        }
        let frame = geo.compactFrame(for: notchedScreen)
        let expectedW = notch.exclusionWidth + IslandGeometryProvider.C.notchedWingWidth * 2
        XCTAssertEqual(frame.width, expectedW, accuracy: 0.5)
    }

    func testNotchedCompactAnchoredToTop() {
        let frame = geo.compactFrame(for: notchedScreen)
        // maxY sits at `topEdgeY` — the top of the screen PLUS the notch bleed, so the black
        // body seals against the camera housing instead of stopping on the last pixel row.
        XCTAssertEqual(frame.maxY, geo.topEdgeY(for: notchedScreen), accuracy: 0.5)
        XCTAssertGreaterThan(frame.maxY, notchedScreen.frame.maxY)
    }

    func testNotchedCompactNothingBehindNotch() {
        // The exclusion zone must not overlap the compact wing content area
        guard let notch = geo.notchGeometry(for: notchedScreen) else { return XCTFail() }
        let exclusion = NSRect(x: notch.exclusionMinX, y: 0,
                               width: notch.exclusionWidth,
                               height: notchedScreen.frame.height)
        // The LEFT wing (0..exclusionMinX) should not intersect the exclusion zone in X
        XCTAssertLessThanOrEqual(notch.leftWing.maxX, notch.exclusionMinX)
        XCTAssertGreaterThanOrEqual(notch.rightWing.minX, notch.exclusionMaxX)
        _ = exclusion // silence unused warning
    }

    // MARK: - Negative-origin display

    func testNegativeOriginCompactInsideScreen() {
        let screen = negativeOriginScreen
        let frame  = geo.compactFrame(for: screen)
        XCTAssertGreaterThanOrEqual(frame.minX, screen.frame.minX)
        XCTAssertLessThanOrEqual(frame.maxX, screen.frame.maxX)
    }

    // MARK: - Narrow display clamping

    func testNarrowDisplayMinClearance() {
        let screen = narrowScreen
        let frame  = geo.compactFrame(for: screen)
        let minClearance = IslandGeometryProvider.C.notchlessMinHClearance
        XCTAssertGreaterThanOrEqual(frame.minX - screen.frame.minX, minClearance - 1)
        XCTAssertGreaterThanOrEqual(screen.frame.maxX - frame.maxX, minClearance - 1)
    }

    // MARK: - Expanded frame top edge pinned to compact top edge

    func testNotchlessExpandedTopEdgePinnedToCompact() {
        let compact  = geo.compactFrame(for: notchlessScreen)
        let expanded = geo.expandedFrame(for: notchlessScreen)
        XCTAssertEqual(expanded.maxY, compact.maxY, accuracy: 0.5)
    }

    func testNotchedExpandedTopEdgePinnedToCompact() {
        let compact  = geo.compactFrame(for: notchedScreen)
        let expanded = geo.expandedFrame(for: notchedScreen)
        XCTAssertEqual(expanded.maxY, compact.maxY, accuracy: 0.5)
    }

    // MARK: - Panel envelope contains all states

    func testPanelEnvelopeContainsCompact() {
        let env     = geo.panelEnvelope(for: notchlessScreen)
        let compact = geo.compactFrame(for: notchlessScreen)
        XCTAssertTrue(env.contains(compact))
    }

    func testPanelEnvelopeContainsExpanded() {
        let env      = geo.panelEnvelope(for: notchlessScreen)
        let expanded = geo.expandedFrame(for: notchlessScreen)
        XCTAssertTrue(env.contains(expanded))
    }

    func testPanelEnvelopeWithinScreen() {
        let screen = notchedScreen
        let env    = geo.panelEnvelope(for: screen)
        XCTAssertGreaterThanOrEqual(env.minX, screen.frame.minX - 1)
        XCTAssertLessThanOrEqual(env.maxX, screen.frame.maxX + 1)
        XCTAssertGreaterThanOrEqual(env.minY, screen.frame.minY - 1)
        // The top is clamped to `topEdgeY`, not `frame.maxY` — the bleed is intentional.
        XCTAssertLessThanOrEqual(env.maxY, geo.topEdgeY(for: screen) + 1)
    }

    // MARK: - Shadow eligibility

    func testShadowNotDrawnOnNotchedDisplay() {
        XCTAssertFalse(geo.shouldDrawShadow(for: notchedScreen))
    }

    func testShadowDrawnOnNotchlessDisplay() {
        XCTAssertTrue(geo.shouldDrawShadow(for: notchlessScreen))
    }

    // MARK: - Status capsule width

    func testStatusCapsuleWidthDoesNotExceedScreen() {
        let w = geo.statusCapsuleWidth(for: narrowScreen)
        XCTAssertLessThanOrEqual(
            w,
            narrowScreen.frame.width - IslandGeometryProvider.C.notchlessMinHClearance * 2 + 1
        )
    }
}
