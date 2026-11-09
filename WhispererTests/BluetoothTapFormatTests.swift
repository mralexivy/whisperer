//
//  BluetoothTapFormatTests.swift
//  WhispererTests
//
//  Opening the AirPods microphone switches them to call mode (16/24 kHz) while the input node
//  still reports 48 kHz. Installing the tap at 48 kHz failed AVAudioEngine's hardware-rate check
//  three times and the dictation never started (2026-11-09).
//

import AVFoundation
import XCTest
@testable import whisperer

final class BluetoothTapFormatTests: XCTestCase {

    private let node48 = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    func testAgreeingHardwareKeepsTheNodeFormat() {
        let format = AudioEngineLifecycle.tapInstallFormat(node: node48, hardwareRate: 48_000, nominalRate: 48_000, attempt: 1)
        XCTAssertEqual(format, node48)
    }

    func testAirPodsCallModeUsesTheHardwareRate() {
        let format = AudioEngineLifecycle.tapInstallFormat(node: node48, hardwareRate: 24_000, nominalRate: 24_000, attempt: 1)
        XCTAssertEqual(format.sampleRate, 24_000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, node48.commonFormat)
    }

    func testLastAttemptFallsBackToTheNominalRate() {
        // The hardware read still says 48 kHz but the HAL has negotiated 16 kHz.
        let format = AudioEngineLifecycle.tapInstallFormat(node: node48, hardwareRate: 48_000, nominalRate: 16_000, attempt: 3)
        XCTAssertEqual(format.sampleRate, 16_000)
        XCTAssertEqual(AudioEngineLifecycle.tapInstallFormat(node: node48, hardwareRate: 48_000, nominalRate: 16_000, attempt: 1),
                       node48, "earlier attempts trust the hardware read")
    }

    func testUnreadableHardwareRateKeepsTheNodeFormat() {
        XCTAssertEqual(AudioEngineLifecycle.tapInstallFormat(node: node48, hardwareRate: 0, nominalRate: nil, attempt: 1), node48)
    }
}
