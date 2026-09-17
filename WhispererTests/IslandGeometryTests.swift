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

    /// A 2560×1600 non-retina display at origin zero, with a typical Dock/menu-bar inset.
    private var standardScreen: ScreenDescription {
        ScreenDescription(
            frame: NSRect(x: 0, y: 0, width: 2560, height: 1600),
            visibleFrame: NSRect(x: 0, y: 23, width: 2560, height: 1480),  // Dock on bottom, menu top
            backingScale: 2
        )
    }

    /// A 1920×1080 screen with no Dock inset.
    private var hdScreen: ScreenDescription {
        ScreenDescription(
            frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            backingScale: 2
        )
    }

    /// A display at a negative origin (multi-display to the left of primary).
    private var negativeOriginScreen: ScreenDescription {
        ScreenDescription(
            frame: NSRect(x: -1920, y: 0, width: 1920, height: 1200),
            visibleFrame: NSRect(x: -1920, y: 23, width: 1920, height: 1100),
            backingScale: 1
        )
    }

    /// Very narrow display (e.g. a small USB-C monitor at 500 pt wide).
    private var narrowScreen: ScreenDescription {
        ScreenDescription(
            frame: NSRect(x: 0, y: 0, width: 500, height: 600),
            visibleFrame: NSRect(x: 0, y: 23, width: 500, height: 537),
            backingScale: 1
        )
    }

    // MARK: - All frames share the same bottom anchor

    func testPeekFrameBottomAnchoredToVisibleFrameMinY() {
        let screen = standardScreen
        let frame  = geo.peekFrame(for: screen)
        // standardScreen has a bottom Dock (visibleFrame.minY 23 > frame.minY 0)
        XCTAssertEqual(frame.minY,
                       IslandGeometryProvider.bottomAnchor(for: screen),
                       accuracy: 0.5)
    }

    func testCompactFrameBottomAnchoredToVisibleFrameMinY() {
        let screen = standardScreen
        let frame  = geo.compactFrame(for: screen)
        XCTAssertEqual(frame.minY,
                       IslandGeometryProvider.bottomAnchor(for: screen),
                       accuracy: 0.5)
    }

    func testExpandedFrameBottomAnchoredToVisibleFrameMinY() {
        let screen = standardScreen
        let frame  = geo.expandedFrame(for: screen)
        XCTAssertEqual(frame.minY,
                       IslandGeometryProvider.bottomAnchor(for: screen),
                       accuracy: 0.5)
    }

    // MARK: - Dock-aware bottom anchor cases

    /// Screen WITH a bottom Dock: pill sits above the Dock by `dockGap`.
    func testBottomAnchor_withDock() {
        let screen = standardScreen   // visibleFrame.minY=23, frame.minY=0 → has obstruction
        XCTAssertTrue(IslandGeometryProvider.hasBottomObstruction(screen))
        XCTAssertEqual(IslandGeometryProvider.bottomAnchor(for: screen),
                       screen.visibleFrame.minY + IslandGeometryProvider.C.dockGap,
                       accuracy: 0.5)
    }

    /// Screen WITHOUT a bottom Dock: pill hugs the actual screen edge by `edgeInset`.
    func testBottomAnchor_withoutDock() {
        let screen = hdScreen   // visibleFrame.minY == frame.minY == 0
        XCTAssertFalse(IslandGeometryProvider.hasBottomObstruction(screen))
        XCTAssertEqual(IslandGeometryProvider.bottomAnchor(for: screen),
                       screen.frame.minY + IslandGeometryProvider.C.edgeInset,
                       accuracy: 0.5)
    }

    /// Auto-hidden Dock: macOS still insets `visibleFrame` by a ~4 pt reveal strip, but with
    /// nothing visibly on screen the Island must hug the real edge rather than float above
    /// a Dock that isn't there.
    func testBottomAnchor_withAutoHiddenDock() {
        let screen = ScreenDescription(
            frame:        NSRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 0, y: 4, width: 1920, height: 1051),
            backingScale: 2
        )
        XCTAssertFalse(IslandGeometryProvider.hasEdgeObstruction(screen, placement: .bottomCenter))
        XCTAssertEqual(IslandGeometryProvider.edgeAnchor(for: screen, placement: .bottomCenter),
                       screen.frame.minY + IslandGeometryProvider.C.edgeInset,
                       accuracy: 0.5)
    }

    /// The menu bar is far deeper than `chromeThreshold`, so the top edge still clears it.
    func testTopAnchor_clearsMenuBar() {
        let screen = standardScreen
        XCTAssertTrue(IslandGeometryProvider.hasEdgeObstruction(screen, placement: .topCenter))
    }

    /// Without a Dock the panel envelope can reach the raw screen bottom edge.
    func testEnvelopeReachesScreenEdge_withoutDock() {
        let screen = hdScreen
        let env    = geo.panelEnvelope(for: screen)
        XCTAssertEqual(env.minY, screen.frame.minY, accuracy: 1.0)
    }

    // MARK: - Tiers grow upward (larger frames have a higher top edge)

    func testCompactIsTallerThanPeek() {
        let peek    = geo.peekFrame(for: standardScreen)
        let compact = geo.compactFrame(for: standardScreen)
        XCTAssertGreaterThan(compact.height, peek.height)
        XCTAssertGreaterThan(compact.maxY, peek.maxY)
    }

    func testExpandedIsTallerThanCompact() {
        let compact  = geo.compactFrame(for: standardScreen)
        let expanded = geo.expandedFrame(for: standardScreen)
        XCTAssertGreaterThan(expanded.height, compact.height)
        XCTAssertGreaterThan(expanded.maxY, compact.maxY)
    }

    // MARK: - Horizontal centering

    func testPeekFrameCenteredHorizontally() {
        let screen = standardScreen
        let frame  = geo.peekFrame(for: screen)
        XCTAssertEqual(frame.midX, screen.frame.midX, accuracy: 1.0)
    }

    func testCompactFrameCenteredHorizontally() {
        let screen = standardScreen
        let frame  = geo.compactFrame(for: screen)
        XCTAssertEqual(frame.midX, screen.frame.midX, accuracy: 1.0)
    }

    func testExpandedFrameCenteredHorizontally() {
        let screen = standardScreen
        let frame  = geo.expandedFrame(for: screen)
        XCTAssertEqual(frame.midX, screen.frame.midX, accuracy: 1.0)
    }

    // MARK: - Dimensions match constants

    func testPeekFrameDimensions() {
        let frame = geo.peekFrame(for: standardScreen)
        XCTAssertEqual(frame.width,  IslandGeometryProvider.C.peekWidth,    accuracy: 0.5)
        XCTAssertEqual(frame.height, IslandGeometryProvider.C.peekHeight,   accuracy: 0.5)
    }

    func testCompactFrameDimensions() {
        let frame = geo.compactFrame(for: standardScreen)
        XCTAssertEqual(frame.width,  IslandGeometryProvider.C.compactWidth,  accuracy: 0.5)
        XCTAssertEqual(frame.height, IslandGeometryProvider.C.compactHeight, accuracy: 0.5)
    }

    func testExpandedFrameDimensions() {
        let frame = geo.expandedFrame(for: standardScreen)
        XCTAssertEqual(frame.width,  IslandGeometryProvider.C.expandedWidth,  accuracy: 0.5)
        XCTAssertEqual(frame.height, IslandGeometryProvider.C.expandedHeight, accuracy: 0.5)
    }

    // MARK: - Minimum horizontal clearance on narrow displays

    func testNarrowDisplayPeekClamped() {
        let screen = narrowScreen
        let frame  = geo.peekFrame(for: screen)
        let clr    = IslandGeometryProvider.C.minHClearance
        XCTAssertGreaterThanOrEqual(frame.minX - screen.frame.minX, clr - 1)
        XCTAssertGreaterThanOrEqual(screen.frame.maxX - frame.maxX, clr - 1)
    }

    func testNarrowDisplayCompactClamped() {
        let screen = narrowScreen
        let frame  = geo.compactFrame(for: screen)
        let clr    = IslandGeometryProvider.C.minHClearance
        XCTAssertGreaterThanOrEqual(frame.minX - screen.frame.minX, clr - 1)
        XCTAssertGreaterThanOrEqual(screen.frame.maxX - frame.maxX, clr - 1)
    }

    // MARK: - Panel envelope contains all tiers

    func testPanelEnvelopeContainsPeekFrame() {
        let env  = geo.panelEnvelope(for: standardScreen)
        let peek = geo.peekFrame(for: standardScreen)
        XCTAssertTrue(env.contains(peek))
    }

    func testPanelEnvelopeContainsCompactFrame() {
        let env     = geo.panelEnvelope(for: standardScreen)
        let compact = geo.compactFrame(for: standardScreen)
        XCTAssertTrue(env.contains(compact))
    }

    func testPanelEnvelopeContainsExpandedFrame() {
        let env      = geo.panelEnvelope(for: standardScreen)
        let expanded = geo.expandedFrame(for: standardScreen)
        XCTAssertTrue(env.contains(expanded))
    }

    func testPanelEnvelopeDoesNotExceedVisibleFrame() {
        let screen = standardScreen
        let env    = geo.panelEnvelope(for: screen)
        XCTAssertGreaterThanOrEqual(env.minX, screen.visibleFrame.minX - 1)
        XCTAssertLessThanOrEqual(env.maxX,    screen.visibleFrame.maxX + 1)
        // Bottom: envelope clamps to screen.frame.minY (raw edge), not visibleFrame.minY.
        XCTAssertGreaterThanOrEqual(env.minY, screen.frame.minY - 1)
        XCTAssertLessThanOrEqual(env.maxY,    screen.visibleFrame.maxY + 1)
    }

    // MARK: - Local (panel-relative) frames

    func testLocalPeekFrameIsOffsetFromGlobal() {
        let env    = geo.panelEnvelope(for: standardScreen)
        let global = geo.peekFrame(for: standardScreen)
        let local  = geo.localPeekFrame(for: standardScreen)
        XCTAssertEqual(local.origin.x, global.origin.x - env.origin.x, accuracy: 0.5)
        XCTAssertEqual(local.origin.y, global.origin.y - env.origin.y, accuracy: 0.5)
    }

    func testLocalCompactFrameIsOffsetFromGlobal() {
        let env    = geo.panelEnvelope(for: standardScreen)
        let global = geo.compactFrame(for: standardScreen)
        let local  = geo.localCompactFrame(for: standardScreen)
        XCTAssertEqual(local.origin.x, global.origin.x - env.origin.x, accuracy: 0.5)
        XCTAssertEqual(local.origin.y, global.origin.y - env.origin.y, accuracy: 0.5)
    }

    // MARK: - Negative-origin display

    func testNegativeOriginDisplayFramesAreInsideScreen() {
        let screen  = negativeOriginScreen
        let compact = geo.compactFrame(for: screen)
        XCTAssertGreaterThanOrEqual(compact.minX, screen.frame.minX)
        XCTAssertLessThanOrEqual(compact.maxX, screen.frame.maxX)
    }

    func testNegativeOriginDisplayBottomAnchor() {
        let screen = negativeOriginScreen   // has bottom Dock (visibleFrame.minY > frame.minY)
        let frame  = geo.compactFrame(for: screen)
        XCTAssertEqual(frame.minY,
                       IslandGeometryProvider.bottomAnchor(for: screen),
                       accuracy: 0.5)
    }

    // MARK: - Shadow always drawn

    func testShadowAlwaysDrawn() {
        XCTAssertTrue(geo.shouldDrawShadow(for: standardScreen))
        XCTAssertTrue(geo.shouldDrawShadow(for: narrowScreen))
        XCTAssertTrue(geo.shouldDrawShadow(for: negativeOriginScreen))
    }

    // MARK: - Corner radii

    func testPeekIsATrueCapsule() {
        let r = geo.cornerRadii(for: .peek)
        XCTAssertEqual(r.topLeading, IslandGeometryProvider.C.peekRadius)
        XCTAssertEqual(r.bottomLeading, r.topLeading,
                       "The nub floats above the screen edge, so it is a full capsule")
        XCTAssertEqual(r.topLeading, IslandGeometryProvider.C.peekHeight / 2, accuracy: 0.01)
    }

    /// With a bottom Dock the nub floats above it; without a Dock it clears the edge by edgeInset.
    func testFramesFloatAboveTheVisibleFrameBottom() {
        // Dock present: peekFrame.minY > visibleFrame.minY (the Dock's top edge)
        XCTAssertGreaterThan(geo.peekFrame(for: standardScreen).minY,
                             standardScreen.visibleFrame.minY)
        // No Dock: peekFrame.minY > raw screen edge
        XCTAssertGreaterThan(geo.peekFrame(for: hdScreen).minY,
                             hdScreen.frame.minY)
    }

    func testCompactIsFullPill() {
        let r = geo.cornerRadii(for: .compact)
        XCTAssertEqual(r.topLeading, r.bottomLeading)
        XCTAssertEqual(r.topLeading, IslandGeometryProvider.C.compactRadius)
    }

    func testExpandedIsFullPill() {
        let r = geo.cornerRadii(for: .expanded)
        XCTAssertEqual(r.topLeading, r.bottomLeading)
        XCTAssertEqual(r.topLeading, IslandGeometryProvider.C.expandedRadius)
    }

    // MARK: - Multi-placement anchor tests

    /// Compact frame lands on the anchored edge for bottomCenter.
    func testCompactFrameAnchoredEdge_bottomCenter() {
        var g = IslandGeometryProvider(); g.placement = .bottomCenter
        let s = standardScreen
        let f = g.compactFrame(for: s)
        XCTAssertEqual(f.minY, IslandGeometryProvider.edgeAnchor(for: s, placement: .bottomCenter),
                       accuracy: 0.5, "bottomCenter: compact minY must equal edgeAnchor")
    }

    /// Compact frame for topCenter: maxY touches the top anchor.
    func testCompactFrameAnchoredEdge_topCenter() {
        var g = IslandGeometryProvider(); g.placement = .topCenter
        let s = standardScreen
        let f = g.compactFrame(for: s)
        XCTAssertEqual(f.maxY, IslandGeometryProvider.edgeAnchor(for: s, placement: .topCenter),
                       accuracy: 0.5, "topCenter: compact maxY must equal edgeAnchor")
    }

    /// Compact frame for leftCenter: minX touches the left anchor.
    func testCompactFrameAnchoredEdge_leftCenter() {
        var g = IslandGeometryProvider(); g.placement = .leftCenter
        let s = standardScreen
        let f = g.compactFrame(for: s)
        XCTAssertEqual(f.minX, IslandGeometryProvider.edgeAnchor(for: s, placement: .leftCenter),
                       accuracy: 0.5, "leftCenter: compact minX must equal edgeAnchor")
    }

    /// Compact frame for rightCenter: maxX touches the right anchor.
    func testCompactFrameAnchoredEdge_rightCenter() {
        var g = IslandGeometryProvider(); g.placement = .rightCenter
        let s = standardScreen
        let f = g.compactFrame(for: s)
        XCTAssertEqual(f.maxX, IslandGeometryProvider.edgeAnchor(for: s, placement: .rightCenter),
                       accuracy: 0.5, "rightCenter: compact maxX must equal edgeAnchor")
    }

    /// Envelope contains all three tier frames for every placement.
    func testEnvelopeContainsAllTiers_allPlacements() {
        let screens = [standardScreen, hdScreen, negativeOriginScreen, narrowScreen]
        for placement in IslandPlacement.allCases {
            var g = IslandGeometryProvider(); g.placement = placement
            for s in screens {
                let env = g.panelEnvelope(for: s)
                XCTAssert(env.contains(g.peekFrame(for: s)),
                          "\(placement) on \(s.frame): envelope must contain peekFrame")
                XCTAssert(env.contains(g.compactFrame(for: s)),
                          "\(placement) on \(s.frame): envelope must contain compactFrame")
                XCTAssert(env.contains(g.expandedFrame(for: s)),
                          "\(placement) on \(s.frame): envelope must contain expandedFrame")
            }
        }
    }

    /// Pill stays within screen bounds for every placement × screen fixture.
    func testPillInsideScreenBounds_allPlacementsAllScreens() {
        let screens = [standardScreen, hdScreen, negativeOriginScreen, narrowScreen]
        for placement in IslandPlacement.allCases {
            var g = IslandGeometryProvider(); g.placement = placement
            for s in screens {
                let f = g.compactFrame(for: s)
                XCTAssertGreaterThanOrEqual(f.minX, s.frame.minX - 0.5,
                    "\(placement) on \(s.frame): pill left of screen")
                XCTAssertLessThanOrEqual(f.maxX, s.frame.maxX + 0.5,
                    "\(placement) on \(s.frame): pill right of screen")
                XCTAssertGreaterThanOrEqual(f.minY, s.frame.minY - 0.5,
                    "\(placement) on \(s.frame): pill below screen")
                XCTAssertLessThanOrEqual(f.maxY, s.frame.maxY + 0.5,
                    "\(placement) on \(s.frame): pill above screen")
            }
        }
    }

    /// Left Dock must be cleared when placement is leftCenter.
    func testLeftCenterClearsLeftDock() {
        let leftDockScreen = ScreenDescription(
            frame:        NSRect(x: 0, y: 0,   width: 2560, height: 1600),
            visibleFrame: NSRect(x: 80, y: 25, width: 2480, height: 1543),
            backingScale: 2
        )
        var g = IslandGeometryProvider(); g.placement = .leftCenter
        let f = g.compactFrame(for: leftDockScreen)
        let anchor = IslandGeometryProvider.edgeAnchor(for: leftDockScreen, placement: .leftCenter)
        XCTAssertGreaterThanOrEqual(f.minX, anchor - 0.5,
            "leftCenter pill must clear the left Dock")
    }
}
