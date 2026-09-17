//
//  IslandContentSizerTests.swift
//  WhispererTests
//
//  Covers three classes of Island bug that are invisible in a build but fatal at runtime:
//
//   1. Coordinate-space mismatch between SwiftUI's top-left hit rects and AppKit's bottom-left
//      mouse points. When wrong, `hitTest` rejects every point over the pill and NO control
//      responds to a click — the UI looks perfect and does nothing.
//   2. Wrong size for each presentation tier (peek / compact / expanded).
//   3. bottomSlack: the spacer that keeps the island flush to the bottom of the panel.
//

import XCTest
@testable import whisperer

final class IslandContentSizerTests: XCTestCase {

    // MARK: - Screen fixtures

    private func standardScreen() -> ScreenDescription {
        ScreenDescription(
            frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 0, y: 23, width: 1920, height: 1000),
            backingScale: 2
        )
    }

    private func narrowScreen(width: CGFloat = 320) -> ScreenDescription {
        ScreenDescription(
            frame: NSRect(x: 0, y: 0, width: width, height: 600),
            visibleFrame: NSRect(x: 0, y: 0, width: width, height: 537),
            backingScale: 1
        )
    }

    // MARK: - Coordinate flip (the bug that made every button dead)

    func testFlipInvertsYAgainstViewHeight() {
        let flipped = IslandHitTesting.flip(CGPoint(x: 40, y: 10), inViewOfHeight: 200)
        XCTAssertEqual(flipped.x, 40)
        XCTAssertEqual(flipped.y, 190)
    }

    /// Island now lives at the bottom — a click near the window's BOTTOM is near the pill
    /// (unlike the top-anchored island where the pill was near y=0 in SwiftUI space).
    func testAppKitPointNearWindowBottomHitsSwiftUIRectNearBottom() {
        // Pill lives near the panel bottom: y = 140...150 in SwiftUI top-left space (panel 160 pt tall)
        let pill = CGRect(x: 100, y: 140, width: 120, height: 10)
        let viewHeight: CGFloat = 160

        // AppKit y = 12 (near bottom of window) → SwiftUI y = 148, which is inside the pill.
        XCTAssertTrue(IslandHitTesting.contains(pill, appKitPoint: CGPoint(x: 160, y: 12),
                                                viewHeight: viewHeight))
        // Without the flip: raw y=10 is NOT in the pill rect (y range 140–150).
        XCTAssertFalse(pill.contains(CGPoint(x: 160, y: 10)))
    }

    func testPointAboveThePillDoesNotHit() {
        let pill = CGRect(x: 100, y: 140, width: 120, height: 10)
        // AppKit y = 150 → SwiftUI y = 50, well above the pill.
        XCTAssertFalse(IslandHitTesting.contains(pill, appKitPoint: CGPoint(x: 160, y: 150),
                                                 viewHeight: 200))
    }

    func testEmptyRectNeverHits() {
        XCTAssertFalse(IslandHitTesting.contains(.zero, appKitPoint: CGPoint(x: 0, y: 0),
                                                 viewHeight: 200))
    }

    // MARK: - Peek tier size

    func testPeekSizeMatchesConstants() {
        let screen = standardScreen()
        let size = IslandContentSizer.targetSize(
            capture: .recording, presentation: .peek, screen: screen,
            isHovering: false, gestureProgress: 0)
        XCTAssertEqual(size.width,  IslandGeometryProvider.C.peekWidth,  accuracy: 0.5)
        XCTAssertEqual(size.height, IslandGeometryProvider.C.peekHeight, accuracy: 0.5)
    }

    func testPeekHoverSwellsWidth() {
        let screen = standardScreen()
        let rest = IslandContentSizer.targetSize(
            capture: .recording, presentation: .peek, screen: screen,
            isHovering: false, gestureProgress: 0)
        let hovered = IslandContentSizer.targetSize(
            capture: .recording, presentation: .peek, screen: screen,
            isHovering: true, gestureProgress: 0)
        XCTAssertGreaterThan(hovered.width, rest.width,
                             "Hover must immediately swell the nub before the dwell fires")
        // Height must NOT change on hover.
        XCTAssertEqual(hovered.height, rest.height, accuracy: 0.01)
    }

    func testPeekScrollGestureStretchesWidth() {
        let screen = standardScreen()
        let rest = IslandContentSizer.targetSize(
            capture: .recording, presentation: .peek, screen: screen,
            isHovering: false, gestureProgress: 0)
        let pulled = IslandContentSizer.targetSize(
            capture: .recording, presentation: .peek, screen: screen,
            isHovering: false, gestureProgress: 15)
        XCTAssertGreaterThan(pulled.width, rest.width)
    }

    /// The Island is always on screen: idle rests as a launcher nub, deliberately smaller
    /// than the recording nub so it does not read as an active capture.
    func testIdlePeekIsASmallerVisibleNub() {
        let screen = standardScreen()
        let idle = IslandContentSizer.targetSize(
            capture: .idle, presentation: .peek, screen: screen,
            isHovering: false, gestureProgress: 0)
        let recording = IslandContentSizer.targetSize(
            capture: .recording, presentation: .peek, screen: screen,
            isHovering: false, gestureProgress: 0)

        XCTAssertEqual(idle.width,  IslandContentSizer.idlePeekWidth,  accuracy: 0.5)
        XCTAssertEqual(idle.height, IslandContentSizer.idlePeekHeight, accuracy: 0.5)
        XCTAssertLessThan(idle.width,  recording.width)
        XCTAssertLessThan(idle.height, recording.height)
    }

    func testIdleCompactIsTheLauncherRow() {
        let size = IslandContentSizer.targetSize(
            capture: .idle, presentation: .compact, screen: standardScreen(),
            isHovering: false, gestureProgress: 0)
        XCTAssertEqual(size.width, IslandContentSizer.idleCompactWidth, accuracy: 0.5)
        XCTAssertEqual(size.height, IslandContentSizer.idleCompactHeight, accuracy: 0.5)
    }

    /// The launcher is a bar, not a toolbar: it must stay smaller than the recording row
    /// in both axes while still fitting four glyphs and the divider.
    func testLauncherRowStaysSmallerThanTheRecordingRow() {
        XCTAssertLessThan(IslandContentSizer.idleCompactHeight,
                          IslandGeometryProvider.C.compactHeight)
        XCTAssertLessThan(IslandContentSizer.idleCompactWidth,
                          IslandContentSizer.recordingWidth)
        XCTAssertGreaterThanOrEqual(IslandContentSizer.idleCompactWidth,
                                    IslandContentSizer.launcherItemWidth * 4)
    }

    /// The launcher is the one tier that is a softened rounded-rect rather than a capsule, so
    /// its leading and trailing glyphs sit in flat space instead of against a curve. Every
    /// other tier — and the resting handle — stays a true capsule; `testPeekIsATrueCapsule`
    /// and the handle tests guard that side.
    func testIdleLauncherRowIsASoftenedRectNotACapsule() {
        let radii = IslandContentSizer.cornerRadii(capture: .idle, presentation: .compact,
                                                   screen: standardScreen())
        let expected = IslandContentSizer.idleCompactHeight * IslandContentSizer.idleCornerFraction
        XCTAssertEqual(radii.top, expected, accuracy: 0.01)
        XCTAssertEqual(radii.top, radii.bottom)
        XCTAssertLessThan(radii.top, IslandContentSizer.idleCompactHeight / 2)
    }

    /// The recording row is unaffected by the launcher's softened corners.
    func testRecordingRowIsStillATrueCapsule() {
        let radii = IslandContentSizer.cornerRadii(capture: .recording, presentation: .compact,
                                                   screen: standardScreen())
        XCTAssertEqual(radii.top, IslandGeometryProvider.C.compactHeight / 2, accuracy: 0.01)
    }

    /// Idle has no secondary control row, so .expanded must not add the extra height.
    func testIdleNeverGrowsIntoTheExpandedTier() {
        let compact = IslandContentSizer.targetSize(
            capture: .idle, presentation: .compact, screen: standardScreen(),
            isHovering: false, gestureProgress: 0)
        let expanded = IslandContentSizer.targetSize(
            capture: .idle, presentation: .expanded, screen: standardScreen(),
            isHovering: false, gestureProgress: 0)
        XCTAssertEqual(expanded, compact)
    }

    // MARK: - Compact tier size

    func testCompactRecordingWidthMatchesConstant() {
        let screen = standardScreen()
        let size = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: screen,
            isHovering: false, gestureProgress: 0)
        XCTAssertEqual(size.width, IslandContentSizer.recordingWidth, accuracy: 0.5)
    }

    func testCompactHeightMatchesConstant() {
        let screen = standardScreen()
        let size = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: screen,
            isHovering: false, gestureProgress: 0)
        XCTAssertEqual(size.height, IslandGeometryProvider.C.compactHeight, accuracy: 0.5)
    }

    func testEachCaptureStateHasItsOwnWidth() {
        let screen = standardScreen()
        func width(_ capture: IslandCaptureState) -> CGFloat {
            IslandContentSizer.targetSize(capture: capture, presentation: .compact,
                                          screen: screen, isHovering: false,
                                          gestureProgress: 0).width
        }
        let starting  = width(.starting)
        let recording = width(.recording)
        let finishing = width(.finalizing)

        XCTAssertLessThan(starting,  recording, "Island must visibly GROW into the recording pill")
        XCTAssertLessThan(finishing, recording, "and contract into the finishing rule")
    }

    func testCompactHoverLift() {
        let screen = standardScreen()
        let rest = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: screen,
            isHovering: false, gestureProgress: 0)
        let lifted = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: screen,
            isHovering: true, gestureProgress: 0)
        XCTAssertGreaterThan(lifted.width, rest.width)
        XCTAssertEqual(lifted.height, rest.height, accuracy: 0.01,
                       "Height must not change on hover")
    }

    func testCompactScrollGestureStretch() {
        let screen = standardScreen()
        let rest = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: screen,
            isHovering: false, gestureProgress: 0)
        let pulled = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: screen,
            isHovering: false, gestureProgress: 20)
        XCTAssertGreaterThan(pulled.width, rest.width)
    }

    // MARK: - Expanded tier size

    func testExpandedIsTallerAndWiderThanCompact() {
        let screen = standardScreen()
        let compact = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: screen,
            isHovering: false, gestureProgress: 0)
        let expanded = IslandContentSizer.targetSize(
            capture: .recording, presentation: .expanded, screen: screen,
            isHovering: false, gestureProgress: 0)
        XCTAssertGreaterThan(expanded.height, compact.height)
        XCTAssertGreaterThan(expanded.width, compact.width)
    }

    func testExpandedHeightIsCompactPlusExtraRow() {
        let screen = standardScreen()
        let size = IslandContentSizer.targetSize(
            capture: .recording, presentation: .expanded, screen: screen,
            isHovering: false, gestureProgress: 0)
        XCTAssertEqual(size.height,
                       IslandGeometryProvider.C.compactHeight + IslandContentSizer.expandedExtraHeight,
                       accuracy: 0.01)
    }

    // MARK: - Hidden / idle returns zero

    func testHiddenPresentationIsZeroSized() {
        XCTAssertEqual(IslandContentSizer.targetSize(
            capture: .recording, presentation: .hidden, screen: standardScreen(),
            isHovering: false, gestureProgress: 0), .zero)
    }

    // MARK: - Narrow display clamping

    func testWidthIsClampedOnNarrowDisplay() {
        let narrow = narrowScreen()
        let size = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: narrow,
            isHovering: false, gestureProgress: 0)
        XCTAssertLessThanOrEqual(
            size.width,
            narrow.frame.width - IslandGeometryProvider.C.minHClearance * 2 + 1
        )
    }

    // MARK: - Corner radii

    func testCornerRadiiDelegateToGeometryProvider() {
        let screen = standardScreen()
        let compact  = IslandContentSizer.cornerRadii(capture: .recording, presentation: .compact,
                                                      screen: screen)
        let expanded = IslandContentSizer.cornerRadii(capture: .recording, presentation: .expanded,
                                                      screen: screen)
        // Both are full pills.
        XCTAssertEqual(compact.top, compact.bottom)
        XCTAssertEqual(expanded.top, expanded.bottom)
        XCTAssertGreaterThan(compact.top, 0)

        // The peek nub is a true capsule — radius is exactly half its height.
        let peek = IslandContentSizer.cornerRadii(capture: .recording, presentation: .peek,
                                                  screen: screen)
        XCTAssertEqual(peek.top, peek.bottom)
        XCTAssertEqual(peek.top, IslandGeometryProvider.C.peekHeight / 2, accuracy: 0.01)
    }

    // MARK: - Bottom slack

    /// Core invariant: bottomSlack == peekFrame.minY - panelEnvelope.minY.
    /// This catches drift between the envelope clamp and the SwiftUI spacer.
    func testBottomSlackMatchesTheClampedEnvelope() {
        let screen = standardScreen()
        let envelope = IslandGeometryProvider().panelEnvelope(for: screen)
        let peek     = IslandGeometryProvider().peekFrame(for: screen)

        XCTAssertEqual(IslandContentSizer.bottomSlack(screen: screen),
                       peek.minY - envelope.minY,
                       accuracy: 0.01)
    }

    /// Dock-present: the pill bottom lands at `visibleFrame.minY + dockGap`.
    func testIslandBottomEdge_withDock() {
        let screen     = standardScreen()   // visibleFrame.minY=23, frame.minY=0
        let envelope   = IslandGeometryProvider().panelEnvelope(for: screen)
        let pillBottom = envelope.minY + IslandContentSizer.bottomSlack(screen: screen)
        XCTAssertEqual(pillBottom,
                       screen.visibleFrame.minY + IslandGeometryProvider.C.dockGap,
                       accuracy: 0.01)
    }

    /// No Dock: the pill bottom lands at `frame.minY + edgeInset`.
    /// `narrowScreen()` has visibleFrame.minY == frame.minY == 0 → no bottom obstruction.
    func testIslandBottomEdge_withoutDock() {
        let screen     = narrowScreen()
        let envelope   = IslandGeometryProvider().panelEnvelope(for: screen)
        let pillBottom = envelope.minY + IslandContentSizer.bottomSlack(screen: screen)
        XCTAssertEqual(pillBottom,
                       screen.frame.minY + IslandGeometryProvider.C.edgeInset,
                       accuracy: 0.01)
    }

    // MARK: - Row metrics

    func testRowMetricsControlSizeWithinRange() {
        let m = IslandContentSizer.rowMetrics(screen: standardScreen(), isHovering: false,
                                              gestureProgress: 0)
        XCTAssertLessThanOrEqual(m.controlSize, m.compactHeight)
        XCTAssertGreaterThanOrEqual(m.controlSize, 22)
        XCTAssertLessThanOrEqual(m.rowHeight, m.compactHeight)
    }
}
