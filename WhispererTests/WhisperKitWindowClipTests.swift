//
//  WhisperKitWindowClipTests.swift
//  WhispererTests
//

import XCTest
@testable import whisperer

final class WhisperKitWindowClipTests: XCTestCase {
    /// Speech under a second must end before WhisperKit's 1 s end-of-clip guard.
    func testShortAudioIsPaddedPastTheGuard() {
        let yes = [Float](repeating: 0.1, count: 8_800)            // "Да", 0.55 s
        let padded = WhisperKitBridge.padForWindowClip(yes)
        XCTAssertEqual(padded.count, 8_800 + 16_000)
        XCTAssertTrue(padded.prefix(8_800).allSatisfy { $0 == 0.1 }, "speech untouched")
        XCTAssertTrue(padded.suffix(16_000).allSatisfy { $0 == 0 }, "only silence is clipped")
        XCTAssertLessThan(0, padded.count - 16_000, "the decode loop now starts")
        XCTAssertTrue(WhisperKitBridge.padForWindowClip([]).isEmpty)
    }
}
