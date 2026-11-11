//
//  MeetingMicrophonePolicyTests.swift
//  WhispererTests
//
//  A meeting never switches a headset into its call profile on its own: it records from the
//  headset only when the call app already does.
//

import XCTest
import CoreAudio
@testable import whisperer

final class MeetingMicrophonePolicyTests: XCTestCase {
    private let airPods = MeetingMicrophonePolicy.Device(id: 70, uid: "AA-BB:input", name: "AirPods Pro",
                                                         transport: kAudioDeviceTransportTypeBluetooth)
    private let builtIn = MeetingMicrophonePolicy.Device(id: 90, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
                                                         transport: kAudioDeviceTransportTypeBuiltIn)
    private let usb = MeetingMicrophonePolicy.Device(id: 40, uid: "usb-mic", name: "Yeti", transport: kAudioDeviceTransportTypeUSB)

    func testHeadsetTheCallDoesNotUseIsLeftInPlaybackQuality() {
        let choice = MeetingMicrophonePolicy.choose(route: .systemDefault, defaultInput: airPods, builtIn: builtIn, callAppInputs: [90])
        XCTAssertEqual(choice, .useBuiltIn(builtIn, reason: "keeps AirPods Pro in high-quality playback"))
    }

    func testHeadsetTheCallAlreadyUsesIsRecorded() {
        let choice = MeetingMicrophonePolicy.choose(route: .systemDefault, defaultInput: airPods, builtIn: builtIn, callAppInputs: [70])
        guard case .keep = choice else { return XCTFail("\(choice)") }
    }

    func testBeforeTheCallOpensAnyMicrophoneTheBuiltInIsUsed() {
        let choice = MeetingMicrophonePolicy.choose(route: .systemDefault, defaultInput: airPods, builtIn: builtIn, callAppInputs: [])
        guard case .useBuiltIn = choice else { return XCTFail("\(choice)") }
    }

    func testExplicitChoiceIsKept() {
        let choice = MeetingMicrophonePolicy.choose(route: .explicit(uid: "AA-BB:input", deviceID: 70), defaultInput: airPods,
                                                    builtIn: builtIn, callAppInputs: [])
        guard case .keep = choice else { return XCTFail("\(choice)") }
    }

    func testWiredAndBuiltInDefaultsAreKept() {
        for input in [usb, builtIn] {
            let choice = MeetingMicrophonePolicy.choose(route: .systemDefault, defaultInput: input, builtIn: builtIn, callAppInputs: [])
            guard case .keep = choice else { return XCTFail("\(input.name): \(choice)") }
        }
    }

    func testNoBuiltInMicrophoneKeepsTheHeadset() {
        let choice = MeetingMicrophonePolicy.choose(route: .systemDefault, defaultInput: airPods, builtIn: nil, callAppInputs: [])
        guard case .keep = choice else { return XCTFail("\(choice)") }
    }
}
