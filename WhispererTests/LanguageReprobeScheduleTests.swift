//
//  LanguageReprobeScheduleTests.swift
//  WhispererTests
//
//  Re-probes thin out while the language keeps being confirmed and snap back on a disagreement,
//  so a meeting pays ~1 probe a minute once settled and still follows a real switch.
//

import XCTest
@testable import whisperer

final class LanguageReprobeScheduleTests: XCTestCase {

    private let base = SystemLivePreviewBridge.reprobeIntervalSamples

    func testConfirmationsDoubleUpToTheCap() {
        var interval = base
        for _ in 0..<6 { interval = SystemLivePreviewBridge.nextReprobeInterval(current: interval, confirmed: true) }
        XCTAssertEqual(interval, SystemLivePreviewBridge.reprobeMaxIntervalSamples)
        XCTAssertEqual(SystemLivePreviewBridge.nextReprobeInterval(current: base, confirmed: true), base * 2)
    }

    func testDisagreementSnapsBack() {
        XCTAssertEqual(SystemLivePreviewBridge.nextReprobeInterval(
            current: SystemLivePreviewBridge.reprobeMaxIntervalSamples, confirmed: false), base)
    }

    func testCapKeepsASwitchWithinAboutAMinute() {
        // Worst case after a long settled stretch: one capped wait, then the second agreeing probe.
        let worst = Double(SystemLivePreviewBridge.reprobeMaxIntervalSamples + base) / 16_000
        XCTAssertLessThanOrEqual(worst, 80)
    }
}
