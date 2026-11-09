//
//  BluetoothSilenceTests.swift
//  WhispererTests
//
//  AirPods gate their microphone to near zero whenever the wearer pauses. A pause must not read
//  as a dead microphone — that showed "No sound is reaching Whisperer. Trying to restart the
//  microphone…", played the error sound and rebuilt the engine mid-sentence.
//

import XCTest
@testable import whisperer

final class BluetoothSilenceTests: XCTestCase {

    func testBuiltInMicStillRecoversFast() {
        XCTAssertFalse(AudioRecorder.silenceMeansDeadInput(silentSeconds: 1.4, isBluetooth: false, hasHeardSignal: true))
        XCTAssertTrue(AudioRecorder.silenceMeansDeadInput(silentSeconds: 1.5, isBluetooth: false, hasHeardSignal: true))
        XCTAssertTrue(AudioRecorder.silenceMeansDeadInput(silentSeconds: 1.5, isBluetooth: false, hasHeardSignal: false))
    }

    func testAirPodsPauseIsNotADeadMicrophone() {
        // A thinking pause, a listener's turn in a meeting.
        for pause in [1.5, 3.0, 8.0, 15.0] {
            XCTAssertFalse(AudioRecorder.silenceMeansDeadInput(silentSeconds: pause, isBluetooth: true, hasHeardSignal: true),
                           "\(pause) s pause on AirPods read as a dead microphone")
        }
        XCTAssertTrue(AudioRecorder.silenceMeansDeadInput(silentSeconds: 20, isBluetooth: true, hasHeardSignal: true))
    }

    func testAirPodsBeforeTheFirstWord() {
        XCTAssertFalse(AudioRecorder.silenceMeansDeadInput(silentSeconds: 4, isBluetooth: true, hasHeardSignal: false))
        XCTAssertTrue(AudioRecorder.silenceMeansDeadInput(silentSeconds: 6, isBluetooth: true, hasHeardSignal: false))
    }
}

final class BluetoothInputLevelTests: XCTestCase {
    func testQuietAirPodsAreRaisedForTheRecording() {
        XCTAssertEqual(AudioRecorder.headsetLevelToApply(current: 0.208, isBluetooth: true), 1.0)
    }

    func testAUserChosenLevelIsLeftAlone() {
        XCTAssertNil(AudioRecorder.headsetLevelToApply(current: 0.6, isBluetooth: true))
        XCTAssertNil(AudioRecorder.headsetLevelToApply(current: 0.2, isBluetooth: false), "built-in mic: the user's choice")
        XCTAssertNil(AudioRecorder.headsetLevelToApply(current: nil, isBluetooth: true), "no volume control")
    }
}
