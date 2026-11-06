//
//  SystemAudioMixerTests.swift
//  WhispererTests
//
//  Meeting call-audio capture: the pure parts — mixing the far end into the mic stream with the
//  microphone as the clock, the backlog cap, pausing, channel downmix, the echo (output route)
//  decision and the tap-target choice. The Core Audio tap itself needs a real call.
//
//  Run with: xcodebuild test -only-testing:WhispererTests/SystemAudioMixerTests
//

import CoreAudio
import XCTest
@testable import whisperer

final class SystemAudioMixerTests: XCTestCase {

    // MARK: - Mixing

    func testMixKeepsMicLengthAndSumsFarEnd() {
        let mixer = SystemAudioMixer()
        mixer.append([0.1, 0.2, 0.3, 0.4, 0.5])
        let out = mixer.mix(mic: [0.1, 0.1, 0.1])
        XCTAssertEqual(out.count, 3, "the microphone is the clock")
        XCTAssertEqual(out[0], 0.2, accuracy: 1e-6)
        XCTAssertEqual(out[2], 0.4, accuracy: 1e-6)
        XCTAssertEqual(mixer.backlog, 2, "unconsumed far-end samples wait for the next mic buffer")
        let next = mixer.mix(mic: [0, 0, 0])
        XCTAssertEqual(next[0], 0.4, accuracy: 1e-6)
        XCTAssertEqual(next[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(next[2], 0, "a short backlog pads with silence")
    }

    func testMixWithNothingPendingIsTheMicUnchanged() {
        let mixer = SystemAudioMixer()
        XCTAssertEqual(mixer.mix(mic: [0.3, -0.3]), [0.3, -0.3])
    }

    func testMixClampsToUnitRange() {
        let mixer = SystemAudioMixer()
        mixer.append([0.8, -0.8])
        XCTAssertEqual(mixer.mix(mic: [0.7, -0.7]), [1, -1])
    }

    func testBacklogIsCappedByDroppingOldest() {
        let mixer = SystemAudioMixer()
        let cap = SystemAudioMixer.maxBacklogSamples
        mixer.append([Float](repeating: 0.1, count: cap))
        mixer.append([0.5, 0.5])
        XCTAssertEqual(mixer.backlog, cap)
        XCTAssertEqual(mixer.stats.dropped, 2)
        // The newest samples survive at the tail.
        let out = mixer.mix(mic: [Float](repeating: 0, count: cap))
        XCTAssertEqual(out[cap - 1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(out[0], 0.1, accuracy: 1e-6)
    }

    func testDisabledMixPassesMicButStillDrains() {
        let mixer = SystemAudioMixer()
        mixer.isMixEnabled = false
        mixer.append([0.5, 0.5])
        XCTAssertEqual(mixer.mix(mic: [0.1, 0.1]), [0.1, 0.1])
        XCTAssertEqual(mixer.backlog, 0, "re-enabling must not replay stale call audio")
    }

    func testDiscardPendingDropsBacklog() {
        let mixer = SystemAudioMixer()
        mixer.append([0.5, 0.5, 0.5])
        mixer.discardPending()
        XCTAssertEqual(mixer.mix(mic: [0, 0]), [0, 0], "a paused span must not leak into the next buffer")
    }

    // MARK: - Downmix

    func testDownmixInterleavedStereo() {
        let data: [Float] = [1, 0, 0.5, 0.5, -1, 1]
        let mono = data.withUnsafeBufferPointer { SystemAudioMixer.downmixInterleaved($0, channels: 2) }
        XCTAssertEqual(mono, [0.5, 0.5, 0])
    }

    func testDownmixInterleavedMonoIsIdentity() {
        let data: [Float] = [0.1, 0.2]
        let mono = data.withUnsafeBufferPointer { SystemAudioMixer.downmixInterleaved($0, channels: 1) }
        XCTAssertEqual(mono, data)
    }

    func testDownmixPlanarTruncatesToShortest() {
        let left: [Float] = [1, 1, 1]
        let right: [Float] = [0, 0]
        let mono = left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in SystemAudioMixer.downmixPlanar([l, r]) }
        }
        XCTAssertEqual(mono, [0.5, 0.5])
    }

    // MARK: - Echo decision

    func testBuiltInSpeakersDoNotMix() {
        let route = CallAudioOutputRoute.classify(transport: kAudioDeviceTransportTypeBuiltIn,
                                                  dataSource: CallAudioOutputRoute.fourCC("ispk"),
                                                  name: "MacBook Pro Speakers")
        XCTAssertEqual(route, .speakers)
        XCTAssertFalse(route.shouldMixFarEnd)
    }

    func testBuiltInHeadphonesMix() {
        XCTAssertEqual(CallAudioOutputRoute.classify(transport: kAudioDeviceTransportTypeBuiltIn,
                                                     dataSource: CallAudioOutputRoute.fourCC("hdpn"), name: nil),
                       .headphones)
        XCTAssertEqual(CallAudioOutputRoute.classify(transport: kAudioDeviceTransportTypeBuiltIn,
                                                     dataSource: nil, name: "External Headphones"),
                       .headphones)
    }

    func testBluetoothAndUSBMix_DisplaysDoNot_VirtualIsUnknown() {
        XCTAssertTrue(CallAudioOutputRoute.classify(transport: kAudioDeviceTransportTypeBluetooth,
                                                    dataSource: nil, name: "AirPods Pro").shouldMixFarEnd)
        XCTAssertTrue(CallAudioOutputRoute.classify(transport: kAudioDeviceTransportTypeUSB,
                                                    dataSource: nil, name: "Jabra").shouldMixFarEnd)
        XCTAssertEqual(CallAudioOutputRoute.classify(transport: kAudioDeviceTransportTypeHDMI,
                                                     dataSource: nil, name: "LG"), .speakers)
        let virtual = CallAudioOutputRoute.classify(transport: kAudioDeviceTransportTypeVirtual,
                                                    dataSource: nil, name: "ZoomAudioDevice")
        XCTAssertEqual(virtual, .unknown)
        XCTAssertTrue(virtual.shouldMixFarEnd)
    }

    // MARK: - Tap target

    func testTargetPrefersDetectedApp() {
        let target = CallAudioTapTarget.choose(
            sourceBundleID: "us.zoom.xos", capturingBundleIDs: ["com.google.Chrome"],
            ownBundleID: "com.ivy.whisperer",
            processesFor: { $0 == "us.zoom.xos" ? [41, 42] : [7] }, ownProcesses: [1])
        XCTAssertEqual(target, .app(bundleID: "us.zoom.xos", processes: [41, 42]))
    }

    func testTargetFallsBackToSoleCapturingApp() {
        let target = CallAudioTapTarget.choose(
            sourceBundleID: nil, capturingBundleIDs: ["com.google.Chrome", "com.ivy.whisperer"],
            ownBundleID: "com.ivy.whisperer",
            processesFor: { $0 == "com.google.Chrome" ? [9] : [] }, ownProcesses: [1])
        XCTAssertEqual(target, .app(bundleID: "com.google.Chrome", processes: [9]))
    }

    func testTargetFallsBackToSystemExcludingSelf() {
        // Ambiguous: two apps on the mic.
        let ambiguous = CallAudioTapTarget.choose(
            sourceBundleID: nil, capturingBundleIDs: ["a", "b"], ownBundleID: "me",
            processesFor: { _ in [5] }, ownProcesses: [1])
        XCTAssertEqual(ambiguous, .allExcept(processes: [1]))
        // Detected app has no audio process yet (the call has not started).
        let notPlaying = CallAudioTapTarget.choose(
            sourceBundleID: "us.zoom.xos", capturingBundleIDs: [], ownBundleID: "me",
            processesFor: { _ in [] }, ownProcesses: [1])
        XCTAssertEqual(notPlaying, .allExcept(processes: [1]))
    }

    func testTargetNeverTapsWhispererItself() {
        let target = CallAudioTapTarget.choose(
            sourceBundleID: "me", capturingBundleIDs: ["me"], ownBundleID: "me",
            processesFor: { _ in [1] }, ownProcesses: [1])
        XCTAssertEqual(target, .allExcept(processes: [1]))
    }
}
