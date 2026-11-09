//
//  SpeechTurnDetectorTests.swift
//  WhispererTests
//

import XCTest
@testable import whisperer

final class SpeechTurnDetectorTests: XCTestCase {

    private let buffer = 0.085   // the recorder's ~85 ms buffers

    /// Feeds `seconds` of one level; returns the time (from the start of this run) a turn fired.
    private func run(_ d: inout SpeechTurnDetector, level: Float, seconds: Double) -> Double? {
        var t = 0.0, fired: Double?
        while t < seconds {
            if d.observe(rms: level, seconds: buffer), fired == nil { fired = t + buffer }
            t += buffer
        }
        return fired
    }

    func testTurnFiresAfterThreeSecondsOfSpeechFollowingAPause() {
        var d = SpeechTurnDetector()
        _ = run(&d, level: 0.2, seconds: 5)          // speech: no pause yet, no turn
        XCTAssertNil(run(&d, level: 0.01, seconds: 1)) // a pause between speakers
        let fired = run(&d, level: 0.2, seconds: 5)
        XCTAssertEqual(fired ?? 99, 3.0, accuracy: 0.1)
    }

    func testPausesInsideATurnDoNotRestartIt() {
        var d = SpeechTurnDetector()
        _ = run(&d, level: 0.2, seconds: 5)
        _ = run(&d, level: 0.01, seconds: 1)
        XCTAssertNil(run(&d, level: 0.2, seconds: 1.5))
        XCTAssertNil(run(&d, level: 0.01, seconds: 0.8))   // a breath between phrases
        let fired = run(&d, level: 0.2, seconds: 3)
        XCTAssertEqual(fired ?? 99, 1.5, accuracy: 0.1, "3 s of speech in total, not 3 s after the breath")
    }

    func testLoudRoomStillFindsPauses() {
        // Speech through speakers in a noisy room: floor 0.05, speech 0.4.
        var d = SpeechTurnDetector()
        _ = run(&d, level: 0.4, seconds: 5)
        _ = run(&d, level: 0.05, seconds: 1)
        XCTAssertNotNil(run(&d, level: 0.4, seconds: 4))
    }

    func testContinuousSpeechWithoutAPauseNeverFires() {
        var d = SpeechTurnDetector()
        XCTAssertNil(run(&d, level: 0.2, seconds: 30))
    }
}

final class SpeechTurnDetectorReplayTests: XCTestCase {
    /// Opt-in: TEST_RUNNER_TURN_REPLAY=/path.wav prints where turns fire and the levels around them.
    func testPrintTurns() throws {
        guard let path = ProcessInfo.processInfo.environment["TURN_REPLAY"] else { throw XCTSkip("set TEST_RUNNER_TURN_REPLAY") }
        let samples = try loadAudioSamples(from: URL(fileURLWithPath: path))
        var d = SpeechTurnDetector()
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 1365, samples.count)
            let chunk = samples[offset..<end]
            let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
            let t = Double(offset) / 16_000
            let fired = d.observe(rms: rms, seconds: Double(chunk.count) / 16_000)
            if fired { print(String(format: "[Turn] fired at %.1fs", t)) }
            if t >= 95, t <= 103 { print(String(format: "[Turn] %.2fs rms %.4f floor %.4f", t, rms, d.noiseFloor ?? -1)) }
            offset = end
        }
    }
}
