//
//  AppleLanguageIDTests.swift
//  WhispererTests
//
//  The lead of the most confident locale is the probability, so the probe's thresholds
//  (0.85 confident, 0.95 sure) mean on Apple what they meant on Whisper. Values from the
//  2026-11-09 benchmark.
//

import XCTest
@testable import whisperer

final class AppleLanguageIDTests: XCTestCase {

    func testClearWinnerIsSure() {
        // en_1922.wav: en 0.91, ru 0.30, he 0.10
        let p = AppleLanguageID.probabilities(from: [.english: 0.91, .russian: 0.30, .hebrew: 0.10])
        XCTAssertEqual(p[.english] ?? 0, 1.0, accuracy: 0.001)
    }

    func testModerateLeadIsConfidentNotSure() {
        // ru_1923.wav: ru 0.70, lead 0.37
        let p = AppleLanguageID.probabilities(from: [.russian: 0.70, .english: 0.33, .hebrew: 0.10])
        XCTAssertEqual(p[.russian] ?? 0, 0.87, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(p[.russian] ?? 0, LanguageReprobeTracker.confidentProbability)
        XCTAssertLessThan(p[.russian] ?? 0, SystemLivePreviewBridge.turnSwitchProbability)
    }

    func testTheBenchmarkMistakesStayBelowConfident() {
        // Near-silent clips the benchmark got wrong: lead 0.05 and 0.18.
        let a = AppleLanguageID.probabilities(from: [.russian: 0.27, .hebrew: 0.22, .english: 0.10])
        let b = AppleLanguageID.probabilities(from: [.english: 0.30, .hebrew: 0.12, .russian: 0.05])
        XCTAssertLessThan(a.values.max() ?? 1, LanguageReprobeTracker.confidentProbability)
        XCTAssertLessThan(b.values.max() ?? 1, LanguageReprobeTracker.confidentProbability)
    }

    func testProbabilitiesSumToOne() {
        let p = AppleLanguageID.probabilities(from: [.hebrew: 0.62, .english: 0.04, .russian: 0.02])
        XCTAssertEqual(p.values.reduce(0, +), 1, accuracy: 0.001)
    }
}
