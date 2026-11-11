//
//  SystemAudioCaptureRateTests.swift
//  WhispererTests
//
//  A measured call-audio rate snaps to the standard rate the device is really running at — the
//  AirPods headset profile's 24 or 16 kHz rather than the 48 kHz the tap reported at start.
//

import XCTest
import AVFoundation
@testable import whisperer

final class SystemAudioCaptureRateTests: XCTestCase {
    func testMeasuredRatesSnapToTheDeviceRate() {
        XCTAssertEqual(SystemAudioCapture.nearestStandardRate(23_410), 24_000)
        XCTAssertEqual(SystemAudioCapture.nearestStandardRate(16_380), 16_000)
        XCTAssertEqual(SystemAudioCapture.nearestStandardRate(47_200), 48_000)
        XCTAssertEqual(SystemAudioCapture.nearestStandardRate(44_000), 44_100)
    }
}

/// Opt-in, real Core Audio and real headphones: TEST_RUNNER_CALL_AUDIO_LIVE=1. Speech plays
/// through the default output while a tap captures it, first with the microphone closed, then
/// open (which moves AirPods into the headset profile and changes the tap's rate under it). The
/// mixer must receive 16 kHz in both phases.
final class SystemAudioCaptureLiveRateTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    private func rate(_ mixer: SystemAudioMixer, over seconds: Double) -> Double {
        let before = mixer.stats.appended
        Thread.sleep(forTimeInterval: seconds)
        return Double(mixer.stats.appended - before) / seconds
    }

    func testDeliversSixteenKilohertzAcrossTheHeadsetSwitch() throws {
        guard ProcessInfo.processInfo.environment["CALL_AUDIO_LIVE"] == "1" else { throw XCTSkip("set TEST_RUNNER_CALL_AUDIO_LIVE=1") }
        let (route, name) = SystemAudioCapture.currentOutputRoute()
        print("[CallAudioLive] output \(name) (\(route.rawValue))")
        let speech = Process()
        speech.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speech.arguments = ["-r", "160", String(repeating: "This is the other side of the call, speaking steadily so the tap has something to hear. ", count: 12)]
        try speech.run()
        Thread.sleep(forTimeInterval: 1)

        let mixer = SystemAudioMixer()
        let capture = SystemAudioCapture(mixer: mixer)
        Self.keepAlive += [mixer, capture]
        try capture.start(target: .allExcept(processes: AudioProcessMonitor().ownProcessObjects()))
        Thread.sleep(forTimeInterval: 1)
        let closed = rate(mixer, over: 5)
        print(String(format: "[CallAudioLive] mic closed: %.0f Hz, peak %.3f", closed, mixer.stats.peak))

        let engine = AVAudioEngine()
        Self.keepAlive.append(engine)
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { _, _ in }
        try engine.start()
        print("[CallAudioLive] microphone open at \(Int(input.outputFormat(forBus: 0).sampleRate)) Hz")
        Thread.sleep(forTimeInterval: 3)                 // the profile switch and the rate check
        let open = rate(mixer, over: 6)
        print(String(format: "[CallAudioLive] mic open: %.0f Hz, peak %.3f", open, mixer.stats.peak))
        engine.stop()
        capture.stop()
        speech.terminate()

        XCTAssertEqual(closed, 16_000, accuracy: 1_600, "rate with the microphone closed")
        XCTAssertEqual(open, 16_000, accuracy: 1_600, "rate after the headset switch")
        XCTAssertGreaterThan(mixer.stats.peak, 0.01, "the tap heard nothing")
    }
}

/// Opt-in, switches this Mac's output: TEST_RUNNER_CALL_AUDIO_SWITCH=<path to a speech file>.
/// AirPods → speakers → AirPods mid-capture, the way a call moves when headphones are picked.
/// The tap rebuilt on the new device must deliver 16 kHz; the original output is restored.
final class SystemAudioCaptureOutputSwitchTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    private func setDefaultOutput(_ device: AudioDeviceID) {
        var address = SystemAudioCapture.address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = device
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    }

    private func device(named fragment: String) -> AudioDeviceID? {
        var address = SystemAudioCapture.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        return ids.first { (SystemAudioCapture.stringProperty($0, kAudioObjectPropertyName) ?? "").contains(fragment) }
    }

    private func measure(_ label: String, target: CallAudioTapTarget, seconds: Double = 8) throws -> (Double, Float) {
        let mixer = SystemAudioMixer()
        let capture = SystemAudioCapture(mixer: mixer)
        Self.keepAlive += [mixer, capture]
        try capture.start(target: target)
        var perSecond: [Int] = []
        var last = mixer.stats.appended
        for _ in 0..<Int(seconds) {
            Thread.sleep(forTimeInterval: 1)
            let now = mixer.stats.appended
            perSecond.append(now - last)
            last = now
        }
        print("[OutputSwitch] \(label) per second: \(perSecond)")
        // Steady state: after the rate check has had its two windows.
        let steady = perSecond.suffix(4)
        let rate = Double(steady.reduce(0, +)) / Double(steady.count)
        capture.stop()
        print(String(format: "[OutputSwitch] %@ (%@): %.0f Hz, peak %.3f", label, SystemAudioCapture.currentOutputRoute().1, rate, mixer.stats.peak))
        return (rate, mixer.stats.peak)
    }

    func testTapFollowsTheOutputSwitch() throws {
        guard let path = ProcessInfo.processInfo.environment["CALL_AUDIO_SWITCH"] else { throw XCTSkip("set TEST_RUNNER_CALL_AUDIO_SWITCH") }
        guard let original = SystemAudioCapture.defaultOutputDeviceID(),
              let speakers = device(named: "MacBook Pro Speakers") else { throw XCTSkip("no speakers") }
        defer { setDefaultOutput(original) }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/bin/sh")
        player.arguments = ["-c", "for i in 1 2 3 4 5 6; do afplay -v 0.08 '\(path)'; done"]
        try player.run()
        defer { player.terminate() }
        let target = CallAudioTapTarget.allExcept(processes: AudioProcessMonitor().ownProcessObjects())

        let first = try measure("start", target: target)
        setDefaultOutput(speakers)
        Thread.sleep(forTimeInterval: 1.5)
        let moved = try measure("after switch", target: target)
        setDefaultOutput(original)
        Thread.sleep(forTimeInterval: 2)
        let back = try measure("switched back", target: target)

        for (label, result) in [("start", first), ("after switch", moved), ("switched back", back)] {
            XCTAssertEqual(result.0, 16_000, accuracy: 1_600, label)
            XCTAssertGreaterThan(result.1, 0.005, "\(label): heard nothing")
        }
    }
}
