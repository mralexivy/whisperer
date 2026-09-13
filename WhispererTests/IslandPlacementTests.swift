//
//  IslandPlacementTests.swift
//  WhispererTests
//
//  Tests for IslandPlacement persistence and the full reveal → reset flow.
//  Run with: xcodebuild test -only-testing:WhispererTests/IslandPlacementTests
//

import XCTest
@testable import whisperer

final class IslandPlacementTests: XCTestCase {

    private let key = IslandPlacement.defaultsKey

    // Restore UserDefaults before each test so tests are isolated.
    private var savedValue: String?

    override func setUp() {
        super.setUp()
        savedValue = UserDefaults.standard.string(forKey: key)
    }

    override func tearDown() {
        if let saved = savedValue {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    // MARK: - Default

    func testDefaultValueIsBottomCenter() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(IslandPlacement.current, .bottomCenter)
    }

    func testDefaultValueMatchesDeclaration() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(IslandPlacement.current, IslandPlacement.defaultValue)
    }

    // MARK: - Persistence round-trips

    func testSaveAndReadTopCenter() {
        IslandPlacement.save(.topCenter)
        XCTAssertEqual(IslandPlacement.current, .topCenter)
    }

    func testSaveAndReadLeftCenter() {
        IslandPlacement.save(.leftCenter)
        XCTAssertEqual(IslandPlacement.current, .leftCenter)
    }

    func testSaveAndReadRightCenter() {
        IslandPlacement.save(.rightCenter)
        XCTAssertEqual(IslandPlacement.current, .rightCenter)
    }

    func testSaveAndReadBottomCenter() {
        IslandPlacement.save(.bottomCenter)
        XCTAssertEqual(IslandPlacement.current, .bottomCenter)
    }

    // MARK: - isVertical

    func testIsVertical_leftCenterAndRightCenter() {
        XCTAssertTrue(IslandPlacement.leftCenter.isVertical)
        XCTAssertTrue(IslandPlacement.rightCenter.isVertical)
    }

    func testIsVertical_topCenterAndBottomCenter() {
        XCTAssertFalse(IslandPlacement.topCenter.isVertical)
        XCTAssertFalse(IslandPlacement.bottomCenter.isVertical)
    }

    // MARK: - Display names

    func testAllPlacementsHaveNonEmptyDisplayNames() {
        for p in IslandPlacement.allCases {
            XCTAssertFalse(p.displayName.isEmpty, "\(p) has an empty displayName")
        }
    }

    func testAllPlacementsHaveNonEmptySettingsGlyphs() {
        for p in IslandPlacement.allCases {
            XCTAssertFalse(p.settingsGlyph.isEmpty, "\(p) has an empty settingsGlyph")
        }
    }

    // MARK: - Identifiable / CaseIterable

    func testAllCasesHasExactlyFourEntries() {
        XCTAssertEqual(IslandPlacement.allCases.count, 4)
    }

    func testIdMatchesRawValue() {
        for p in IslandPlacement.allCases {
            XCTAssertEqual(p.id, p.rawValue)
        }
    }

    // MARK: - Gate resets on placement change

    func testRevealGateResetsAfterPlacementChange() {
        var gate = IslandRevealGate()
        let origin = NSPoint(x: 200, y: 100)
        gate.entered(point: origin, now: 1000)
        gate.step(point: origin, inside: true, now: 1000 + IslandUX.revealDelay)
        XCTAssertEqual(gate.currentPhase, .revealed)
        gate.reset()
        XCTAssertEqual(gate.currentPhase, .hidden, "Gate must reset to hidden after placement change")
    }
}
