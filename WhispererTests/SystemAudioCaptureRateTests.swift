//
//  SystemAudioCaptureRateTests.swift
//  WhispererTests
//
//  A measured call-audio rate snaps to the standard rate the device is really running at — the
//  AirPods headset profile's 24 or 16 kHz rather than the 48 kHz the tap reported at start.
//

import XCTest
@testable import whisperer

final class SystemAudioCaptureRateTests: XCTestCase {
    func testMeasuredRatesSnapToTheDeviceRate() {
        XCTAssertEqual(SystemAudioCapture.nearestStandardRate(23_410), 24_000)
        XCTAssertEqual(SystemAudioCapture.nearestStandardRate(16_380), 16_000)
        XCTAssertEqual(SystemAudioCapture.nearestStandardRate(47_200), 48_000)
        XCTAssertEqual(SystemAudioCapture.nearestStandardRate(44_000), 44_100)
    }
}

/// Opt-in, real Core Audio: TEST_RUNNER_CALL_AUDIO_LIVE=1. A global tap on this Mac's output runs
/// for 4 s while a sound plays and must hand the mixer 16 kHz — no more, no less.
final class SystemAudioCaptureLiveRateTests: XCTestCase {
    func testDeliversSixteenKilohertz() throws {
        guard ProcessInfo.processInfo.environment["CALL_AUDIO_LIVE"] == "1" else { throw XCTSkip("set TEST_RUNNER_CALL_AUDIO_LIVE=1") }
        let mixer = SystemAudioMixer()
        let capture = SystemAudioCapture(mixer: mixer)
        try capture.start(target: .allExcept(processes: AudioProcessMonitor().ownProcessObjects()))
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.05", "/System/Library/Sounds/Submarine.aiff"]
        try? player.run()
        Thread.sleep(forTimeInterval: 4)
        capture.stop()
        let appended = Double(mixer.stats.appended)
        print("[CallAudioLive] appended \(Int(appended)) in 4 s = \(Int(appended / 4)) Hz, peak \(mixer.stats.peak)")
        XCTAssertEqual(appended / 4, 16_000, accuracy: 2_000)
    }
}
