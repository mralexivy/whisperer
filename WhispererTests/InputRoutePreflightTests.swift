//
//  InputRoutePreflightTests.swift
//  WhispererTests
//
//  Tests for the pure decision logic in InputRoutePreflight.readiness(for:).
//  These tests do NOT touch CoreAudio — they construct RoutePreflightFacts directly
//  and verify the verdict, mirroring the pattern used by InputHealthProbeTests.
//

import XCTest
import CoreAudio
@testable import whisperer

final class InputRoutePreflightTests: XCTestCase {

    // MARK: - Aggregate wrapper

    func test_aggregateUID_returnsAggregateWrapper() {
        var facts = RoutePreflightFacts()
        facts.uid = "CADefaultDeviceAggregate-2849-1"
        facts.transportType = kAudioDeviceTransportTypeBluetooth
        facts.isRunningSomewhere = false
        facts.healthVerdict = .healthy

        XCTAssertEqual(InputRoutePreflight.readiness(for: facts), .aggregateWrapper)
    }

    func test_aggregateUIDPrefix_returnsAggregateWrapper() {
        var facts = RoutePreflightFacts()
        facts.uid = kCADefaultDeviceAggregatePrefix + "-999-0"
        facts.transportType = kAudioDeviceTransportTypeBuiltIn
        facts.isRunningSomewhere = true
        facts.healthVerdict = .healthy

        XCTAssertEqual(InputRoutePreflight.readiness(for: facts), .aggregateWrapper)
    }

    func test_nonAggregateUID_doesNotHitAggregateWrapperPath() {
        var facts = RoutePreflightFacts()
        facts.uid = "BuiltInMicrophoneDevice"
        facts.transportType = kAudioDeviceTransportTypeBuiltIn
        facts.isRunningSomewhere = true
        facts.healthVerdict = .healthy

        XCTAssertEqual(InputRoutePreflight.readiness(for: facts), .ready)
    }

    // MARK: - Unusable (health delegation)

    func test_mutedDevice_returnsUnusable() {
        var facts = RoutePreflightFacts()
        facts.uid = "SomeMic"
        facts.transportType = kAudioDeviceTransportTypeUSB
        facts.isRunningSomewhere = true
        facts.healthVerdict = .muted

        XCTAssertEqual(InputRoutePreflight.readiness(for: facts), .unusable(.muted))
    }

    func test_gainZeroDevice_returnsUnusable() {
        var facts = RoutePreflightFacts()
        facts.uid = "SomeMic"
        facts.transportType = kAudioDeviceTransportTypeBuiltIn
        facts.isRunningSomewhere = true
        facts.healthVerdict = .gainZero

        XCTAssertEqual(InputRoutePreflight.readiness(for: facts), .unusable(.gainZero))
    }

    func test_goneDevice_returnsUnusable() {
        var facts = RoutePreflightFacts()
        facts.uid = "SomeMic"
        facts.transportType = kAudioDeviceTransportTypeBluetooth
        facts.isRunningSomewhere = false
        facts.healthVerdict = .deviceGone

        // deviceGone takes precedence over the cold-BT check
        XCTAssertEqual(InputRoutePreflight.readiness(for: facts), .unusable(.deviceGone))
    }

    // MARK: - Cold Bluetooth → needsWarmup

    func test_coldBluetooth_returnsNeedsWarmup() {
        var facts = RoutePreflightFacts()
        facts.uid = "AirPodsPro-1234"
        facts.transportType = kAudioDeviceTransportTypeBluetooth
        facts.isRunningSomewhere = false   // handed off to iPhone
        facts.healthVerdict = .healthy

        guard case .needsWarmup(let ms) = InputRoutePreflight.readiness(for: facts) else {
            XCTFail("Expected .needsWarmup, got \(InputRoutePreflight.readiness(for: facts))")
            return
        }
        XCTAssertGreaterThan(ms, 0)
    }

    func test_coldBLE_returnsNeedsWarmup() {
        var facts = RoutePreflightFacts()
        facts.uid = "BLEHeadset"
        facts.transportType = kAudioDeviceTransportTypeBluetoothLE
        facts.isRunningSomewhere = false
        facts.healthVerdict = .healthy

        guard case .needsWarmup = InputRoutePreflight.readiness(for: facts) else {
            XCTFail("Expected .needsWarmup")
            return
        }
    }

    func test_warmBluetooth_returnsReady() {
        var facts = RoutePreflightFacts()
        facts.uid = "AirPodsPro-1234"
        facts.transportType = kAudioDeviceTransportTypeBluetooth
        facts.isRunningSomewhere = true   // already active on this Mac
        facts.healthVerdict = .healthy

        XCTAssertEqual(InputRoutePreflight.readiness(for: facts), .ready)
    }

    // MARK: - Built-in and USB → ready

    func test_builtInMic_returnsReady() {
        var facts = RoutePreflightFacts()
        facts.uid = "BuiltInMicrophoneDevice"
        facts.transportType = kAudioDeviceTransportTypeBuiltIn
        facts.isRunningSomewhere = false   // built-ins are not always "running" when idle
        facts.healthVerdict = .healthy

        XCTAssertEqual(InputRoutePreflight.readiness(for: facts), .ready)
    }

    func test_usbMic_returnsReady() {
        var facts = RoutePreflightFacts()
        facts.uid = "USBMicrophone-XY"
        facts.transportType = kAudioDeviceTransportTypeUSB
        facts.isRunningSomewhere = false
        facts.healthVerdict = .healthy

        XCTAssertEqual(InputRoutePreflight.readiness(for: facts), .ready)
    }

    // MARK: - RouteReadiness properties

    func test_needsWarmup_shouldAttempt() {
        let r = RouteReadiness.needsWarmup(estimatedMs: 1500)
        XCTAssertTrue(r.shouldAttempt)
        XCTAssertGreaterThan(r.suggestedSettleDelay, 0)
        XCTAssertGreaterThan(r.firstBufferDeadline, 0)
    }

    func test_aggregateWrapper_shouldNotAttempt() {
        XCTAssertFalse(RouteReadiness.aggregateWrapper.shouldAttempt)
    }

    func test_unusable_shouldNotAttempt() {
        XCTAssertFalse(RouteReadiness.unusable(.muted).shouldAttempt)
    }

    func test_ready_settleDelayIsPositive() {
        XCTAssertGreaterThan(RouteReadiness.ready.suggestedSettleDelay, 0)
    }

    func test_needsWarmup_settleDelayLargerThanReady() {
        XCTAssertGreaterThan(
            RouteReadiness.needsWarmup(estimatedMs: 1500).suggestedSettleDelay,
            RouteReadiness.ready.suggestedSettleDelay
        )
    }

    func test_needsWarmup_firstBufferDeadlineLargerThanReady() {
        XCTAssertGreaterThan(
            RouteReadiness.needsWarmup(estimatedMs: 1500).firstBufferDeadline,
            RouteReadiness.ready.firstBufferDeadline
        )
    }

    // MARK: - Shared constant

    func test_prefixConstantMatchesFilterInDeviceManager() {
        // The same constant must be used by both InputRoutePreflight and AudioDeviceManager.
        // This test encodes the value so a rename of the constant triggers a compile error.
        XCTAssertEqual(kCADefaultDeviceAggregatePrefix, "CADefaultDeviceAggregate")
    }
}
