//
//  IslandContentSizerTests.swift
//  WhispererTests
//
//  Covers the two classes of Island bug that are invisible in a build but fatal at runtime:
//
//   1. Coordinate-space mismatch between SwiftUI's top-left hit rects and AppKit's bottom-left
//      mouse points. When this is wrong, `hitTest` rejects every point over the pill and NO
//      control in the Island responds to a click — the UI looks perfect and does nothing.
//   2. Notch placement. On a notched Mac the Island replaces the camera housing, so it must be
//      flush with the physical screen top, at least as tall as the housing, and it must reserve
//      a centred dead zone so content is never laid out underneath it.
//

import XCTest
@testable import whisperer

final class IslandContentSizerTests: XCTestCase {

    // MARK: - Screen fixtures

    /// 14" MacBook Pro-like: notched, 1512 × 982, 37 pt safe area, 189 pt housing.
    private func notchedScreen() -> ScreenDescription {
        let width: CGFloat = 1512, height: CGFloat = 982, inset: CGFloat = 37
        let housing: CGFloat = 189
        let wing = (width - housing) / 2
        return ScreenDescription(
            frame: NSRect(x: 0, y: 0, width: width, height: height),
            visibleFrame: NSRect(x: 0, y: 0, width: width, height: height - inset - 12),
            safeAreaTopInset: inset,
            auxiliaryTopLeft:  NSRect(x: 0, y: height - inset, width: wing, height: inset),
            auxiliaryTopRight: NSRect(x: width - wing, y: height - inset, width: wing, height: inset),
            backingScale: 2
        )
    }

    /// External display: no notch, no safe area.
    private func floatingScreen(width: CGFloat = 1920) -> ScreenDescription {
        ScreenDescription(
            frame: NSRect(x: 0, y: 0, width: width, height: 1080),
            visibleFrame: NSRect(x: 0, y: 0, width: width, height: 1055),
            safeAreaTopInset: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil,
            backingScale: 2
        )
    }

    // MARK: - Coordinate flip (the bug that made every button dead)

    func testFlipInvertsYAgainstViewHeight() {
        let flipped = IslandHitTesting.flip(CGPoint(x: 40, y: 10), inViewOfHeight: 200)
        XCTAssertEqual(flipped.x, 40)
        XCTAssertEqual(flipped.y, 190)
    }

    func testAppKitPointNearWindowTopHitsSwiftUIRectNearZero() {
        // The pill lives at the TOP: y = 8...64 in SwiftUI space.
        let pill = CGRect(x: 100, y: 8, width: 400, height: 56)
        let viewHeight: CGFloat = 200

        // A click at the top of the window is y = 170 in AppKit space.
        XCTAssertTrue(IslandHitTesting.contains(pill, appKitPoint: CGPoint(x: 300, y: 170),
                                                viewHeight: viewHeight))
        // Without the flip this is what the old code compared, and it always missed.
        XCTAssertFalse(pill.contains(CGPoint(x: 300, y: 170)))
    }

    func testPointBelowThePillDoesNotHit() {
        let pill = CGRect(x: 100, y: 8, width: 400, height: 56)
        // AppKit y = 40 → SwiftUI y = 160, far below the pill.
        XCTAssertFalse(IslandHitTesting.contains(pill, appKitPoint: CGPoint(x: 300, y: 40),
                                                 viewHeight: 200))
    }

    func testEmptyRectNeverHits() {
        XCTAssertFalse(IslandHitTesting.contains(.zero, appKitPoint: CGPoint(x: 0, y: 0),
                                                 viewHeight: 200))
    }

    // MARK: - Notch replacement

    // MARK: - Three-zone strip (Atoll RecordingLiveActivity geometry)

    func testClosedNotchSizeIsExactlyTheHousing() {
        // Atoll `getClosedNotchSize()`: housing + 4 wide, safe-area inset tall. Anything larger
        // baked in here becomes dead width the content has to route around.
        let closed = IslandGeometryProvider().closedNotchSize(for: notchedScreen())
        XCTAssertEqual(closed.width, 189 + 4, accuracy: 0.01)
        XCTAssertEqual(closed.height, 37, accuracy: 0.01)
    }

    func testClosedNotchHasNoWidthOnAFloatingDisplay() {
        // No housing to route around, so no reserved center — a reserved center on a notchless
        // display is just a hole in the middle of the pill.
        XCTAssertEqual(IslandGeometryProvider().closedNotchSize(for: floatingScreen()).width, 0)
    }

    func testCompactStripIsAsTallAsTheHousingNotTaller() {
        let screen = notchedScreen()
        let size = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: screen,
            isHovering: false, gestureProgress: 0)
        // Atoll's compact HUD height IS the notch height — it must not hang below the menu bar.
        XCTAssertEqual(size.height, 37, accuracy: 0.01)
    }

    func testWidthIsTheHousingPlusWings() {
        let screen = notchedScreen()
        let size = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: screen,
            isHovering: false, gestureProgress: 0)
        XCTAssertEqual(size.width, 193 + IslandContentSizer.recordingExtraWidth, accuracy: 0.01)
    }

    func testTrailingZoneGetsFarMoreWidthThanTheLeadingBadge() {
        let screen = notchedScreen()
        let m = IslandContentSizer.rowMetrics(screen: screen, isHovering: false,
                                              gestureProgress: 0)
        let total = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: screen,
            isHovering: false, gestureProgress: 0).width
        let trailing = total - m.centerWidth - m.leadingWidth
        // The zones are deliberately asymmetric — an even split strands dead space mid-pill
        // and halves the waveform.
        XCTAssertGreaterThan(trailing, m.leadingWidth * 3)
    }

    func testCenterZoneCoversTheHousingAndWidensOnHover() {
        let screen = notchedScreen()
        let rest = IslandContentSizer.rowMetrics(screen: screen, isHovering: false,
                                                 gestureProgress: 0)
        let hovered = IslandContentSizer.rowMetrics(screen: screen, isHovering: true,
                                                    gestureProgress: 0)
        XCTAssertGreaterThanOrEqual(rest.centerWidth, 189)
        XCTAssertEqual(hovered.centerWidth - rest.centerWidth, 8, accuracy: 0.01)
    }

    func testControlsScaleToTheStripSoTheyFitTheNotch() {
        let m = IslandContentSizer.rowMetrics(screen: notchedScreen(), isHovering: false,
                                              gestureProgress: 0)
        XCTAssertLessThanOrEqual(m.controlSize, m.compactHeight)
        XCTAssertGreaterThanOrEqual(m.controlSize, 22)
        XCTAssertLessThanOrEqual(m.rowHeight, m.compactHeight)
    }

    func testCornerRadiusNeverExceedsHalfTheHeight() {
        let radii = IslandContentSizer.cornerRadii(
            capture: .recording, presentation: .compact, screen: notchedScreen())
        XCTAssertLessThanOrEqual(radii.bottom, 37 / 2)
    }

    func testTopSlackIsZeroOnNotchedDisplaySoTheIslandAbsorbsTheHousing() {
        // Flush with screen.frame.maxY — anything else leaves the hardware notch showing
        // above a floating pill, which is exactly what we are replacing.
        XCTAssertEqual(IslandContentSizer.topSlack(screen: notchedScreen()), 0, accuracy: 0.01)
    }

    func testTopSlackIsPositiveOnFloatingDisplay() {
        XCTAssertGreaterThan(IslandContentSizer.topSlack(screen: floatingScreen()), 0)
    }

    func testTopCornersAreSquareOnNotchedDisplay() {
        let radii = IslandContentSizer.cornerRadii(
            capture: .recording, presentation: .compact, screen: notchedScreen())
        XCTAssertEqual(radii.top, 0)
        XCTAssertGreaterThan(radii.bottom, 0)
    }

    func testAllCornersRoundedOnFloatingDisplay() {
        let radii = IslandContentSizer.cornerRadii(
            capture: .recording, presentation: .compact, screen: floatingScreen())
        XCTAssertEqual(radii.top, radii.bottom)
        XCTAssertGreaterThan(radii.top, 0)
    }

    // MARK: - Content-driven sizing (the "growing" behaviour)

    func testEachCaptureStateHasItsOwnWidth() {
        let screen = floatingScreen()
        func width(_ capture: IslandCaptureState) -> CGFloat {
            IslandContentSizer.targetSize(capture: capture, presentation: .compact,
                                          screen: screen, isHovering: false,
                                          gestureProgress: 0).width
        }
        let starting  = width(.starting)
        let recording = width(.recording)
        let finishing = width(.finalizing)

        XCTAssertLessThan(starting, recording, "Island must visibly GROW into the recording pill")
        XCTAssertLessThan(finishing, recording, "and contract into the finishing rule")
    }

    func testExpandedHeightMatchesTheRowsItRenders() {
        let screen = floatingScreen()
        let size = IslandContentSizer.targetSize(
            capture: .recording, presentation: .expanded, screen: screen,
            isHovering: false, gestureProgress: 0)
        let closed = IslandGeometryProvider().closedNotchSize(for: screen)
        // `IslandLayout` stacks a `compactHeight` strip over an `expandedExtraHeight` row.
        // Mismatch here clips or strands the expanded control row.
        XCTAssertEqual(size.height,
                       closed.height + IslandContentSizer.expandedExtraHeight,
                       accuracy: 0.01)
    }

    func testExpandedIsTallerAndWiderThanCompact() {
        let screen = floatingScreen()
        let compact = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: screen,
            isHovering: false, gestureProgress: 0)
        let expanded = IslandContentSizer.targetSize(
            capture: .recording, presentation: .expanded, screen: screen,
            isHovering: false, gestureProgress: 0)
        XCTAssertGreaterThan(expanded.height, compact.height)
        XCTAssertGreaterThan(expanded.width, compact.width)
    }

    func testHiddenPresentationIsZeroSized() {
        XCTAssertEqual(IslandContentSizer.targetSize(
            capture: .recording, presentation: .hidden, screen: floatingScreen(),
            isHovering: false, gestureProgress: 0), .zero)
    }

    func testHoverLiftsTheCompactPill() {
        let screen = floatingScreen()
        let rest = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: screen,
            isHovering: false, gestureProgress: 0)
        let lifted = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: screen,
            isHovering: true, gestureProgress: 0)
        XCTAssertGreaterThan(lifted.width, rest.width)
        // Height must NOT change on hover: the compact strip is exactly the housing height, and
        // growing it would push the island below the menu bar on a notched Mac.
        XCTAssertEqual(lifted.height, rest.height, accuracy: 0.01)
    }

    func testScrollGestureStretchesTheCompactPill() {
        let screen = floatingScreen()
        let rest = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: screen,
            isHovering: false, gestureProgress: 0)
        let pulled = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: screen,
            isHovering: false, gestureProgress: 20)
        XCTAssertGreaterThan(pulled.width, rest.width)
    }

    func testWidthIsClampedOnANarrowDisplay() {
        let narrow = floatingScreen(width: 320)
        let size = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: narrow,
            isHovering: false, gestureProgress: 0)
        XCTAssertLessThanOrEqual(size.width, narrow.frame.width - 32)
    }

    func testNotchedRecordingPillIsWiderThanFloatingToFitBothWings() {
        let notched = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: notchedScreen(),
            isHovering: false, gestureProgress: 0)
        let floating = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: floatingScreen(),
            isHovering: false, gestureProgress: 0)
        XCTAssertGreaterThan(notched.width, floating.width)
    }

    // MARK: - Top bleed (Atoll `notchTopScreenBleedAmount`)

    func testPanelExtendsAboveTheScreenTopOnANotchedDisplay() {
        let screen = notchedScreen()
        let geo = IslandGeometryProvider()
        // Atoll positions at `screenFrame.maxY + topBleed - height`. Clipping the envelope to
        // screen.frame — as the old `.intersection` did — leaves a hairline of wallpaper
        // between the black body and the camera housing.
        XCTAssertGreaterThan(geo.topBleed(for: screen), 0)
        XCTAssertEqual(geo.panelEnvelope(for: screen).maxY,
                       screen.frame.maxY + geo.topBleed(for: screen), accuracy: 0.01)
        XCTAssertEqual(geo.compactFrame(for: screen).maxY,
                       geo.topEdgeY(for: screen), accuracy: 0.01)
    }

    func testFloatingDisplayGetsNoBleedAndStaysOnScreen() {
        let screen = floatingScreen()
        let geo = IslandGeometryProvider()
        XCTAssertEqual(geo.topBleed(for: screen), 0)
        XCTAssertLessThanOrEqual(geo.panelEnvelope(for: screen).maxY, screen.frame.maxY)
    }

    func testTopSlackStaysZeroOnceTheBleedIsApplied() {
        // The island's top edge must land on `topEdgeY`, not `screen.frame.maxY` — otherwise
        // the bleed just pushes it down and cancels itself out.
        XCTAssertEqual(IslandContentSizer.topSlack(screen: notchedScreen()), 0, accuracy: 0.01)
    }

    func testEvenTheNarrowestStateStillCoversTheHousing() throws {
        let screen = notchedScreen()
        let notch = try XCTUnwrap(IslandGeometryProvider().notchGeometry(for: screen))
        // `.starting` has the smallest wings. If any state can shrink below the housing the
        // camera cutout reappears mid-morph.
        for capture in [IslandCaptureState.starting, .finalizing, .recording] {
            let size = IslandContentSizer.targetSize(
                capture: capture, presentation: .compact, screen: screen,
                isHovering: false, gestureProgress: 0)
            XCTAssertGreaterThanOrEqual(size.width, notch.exclusionWidth + 4)
            XCTAssertGreaterThanOrEqual(size.height, notch.topInset)
        }
    }

    func testWidthClampNeverFallsBelowTheHousing() {
        // A display narrower than housing + 32 must still not expose the cutout.
        let screen = notchedScreen()
        let closed = IslandGeometryProvider().closedNotchSize(for: screen)
        let size = IslandContentSizer.targetSize(
            capture: .recording, presentation: .compact, screen: screen,
            isHovering: false, gestureProgress: 0)
        XCTAssertGreaterThanOrEqual(size.width, closed.width)
    }
}
