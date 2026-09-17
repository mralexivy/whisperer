//
//  InputHealthProbeTests.swift
//  WhispererTests
//
//  Covers the decision half of `InputHealthProbe` — the part that turns HAL readings into a
//  named cause. `verdict(for:)` is pure by design so this suite needs no microphone.
//
//  Regression anchor: 2026-09-14. A meeting captured 58 minutes of zero-filled buffers and the
//  app's entire diagnostic vocabulary was "silence_1.5s". Every case below is a condition that
//  produces that exact signature and that the recorder must now be able to tell apart.
//

import AVFoundation
import XCTest
@testable import whisperer

final class InputHealthProbeTests: XCTestCase {

    // MARK: - Verdict mapping

    func testHealthyDeviceReportsHealthy() {
        let facts = InputHealthFacts(
            authorization: .authorized,
            isMuted: false,
            inputVolume: 0.8
        )
        XCTAssertEqual(InputHealthProbe.verdict(for: facts), .healthy)
    }

    func testMutedInputIsDiagnosedAsMuted() {
        let facts = InputHealthFacts(authorization: .authorized, isMuted: true, inputVolume: 0.8)
        XCTAssertEqual(InputHealthProbe.verdict(for: facts), .muted)
    }

    func testZeroGainIsDiagnosedAsGainZero() {
        let facts = InputHealthFacts(authorization: .authorized, isMuted: false, inputVolume: 0)
        XCTAssertEqual(InputHealthProbe.verdict(for: facts), .gainZero)
    }

    /// macOS stores the slider as a float; a control nudged and returned to zero can read 1e-7.
    func testSubThresholdGainIsStillGainZero() {
        let facts = InputHealthFacts(authorization: .authorized, isMuted: false, inputVolume: 1e-7)
        XCTAssertEqual(InputHealthProbe.verdict(for: facts), .gainZero)
    }

    func testGainJustAboveThresholdIsHealthy() {
        let facts = InputHealthFacts(
            authorization: .authorized,
            isMuted: false,
            inputVolume: InputHealthProbe.zeroGainThreshold * 2
        )
        XCTAssertEqual(InputHealthProbe.verdict(for: facts), .healthy)
    }

    /// Aggregates and virtual devices expose no mute or volume control at all. Absent controls
    /// must not be read as "muted" or "zero" — that would misdiagnose every Teams/Zoom device.
    func testMissingControlsAreNotTreatedAsFailures() {
        let facts = InputHealthFacts(authorization: .authorized, isMuted: nil, inputVolume: nil)
        XCTAssertEqual(InputHealthProbe.verdict(for: facts), .healthy)
    }

    func testDeniedPermissionOutranksEveryDeviceReading() {
        // A denied TCC grant leaves the HAL reporting a perfectly healthy device that simply
        // feeds the process zeros — so the permission check has to come first.
        let facts = InputHealthFacts(
            authorization: .denied,
            deviceExists: true,
            isAlive: true,
            hasInputStreams: true,
            isMuted: false,
            inputVolume: 1.0
        )
        XCTAssertEqual(InputHealthProbe.verdict(for: facts), .permissionDenied)
    }

    func testRestrictedPermissionMapsToDenied() {
        let facts = InputHealthFacts(authorization: .restricted)
        XCTAssertEqual(InputHealthProbe.verdict(for: facts), .permissionDenied)
    }

    func testNotDeterminedPermissionIsItsOwnVerdict() {
        let facts = InputHealthFacts(authorization: .notDetermined)
        XCTAssertEqual(InputHealthProbe.verdict(for: facts), .permissionNotDetermined)
    }

    func testMissingDeviceIsDeviceGone() {
        let facts = InputHealthFacts(authorization: .authorized, deviceExists: false)
        XCTAssertEqual(InputHealthProbe.verdict(for: facts), .deviceGone)
    }

    func testDeadDeviceIsDeviceGone() {
        let facts = InputHealthFacts(authorization: .authorized, deviceExists: true, isAlive: false)
        XCTAssertEqual(InputHealthProbe.verdict(for: facts), .deviceGone)
    }

    func testDeviceWithoutInputStreamsIsDiagnosedSeparately() {
        let facts = InputHealthFacts(authorization: .authorized, hasInputStreams: false)
        XCTAssertEqual(InputHealthProbe.verdict(for: facts), .noInputStreams)
    }

    /// Another app holding the device hot is normal — CoreAudio shares inputs happily.
    func testRunningSomewhereDoesNotByItselfIndicateFailure() {
        let facts = InputHealthFacts(
            authorization: .authorized,
            isMuted: false,
            inputVolume: 0.9,
            isRunningSomewhere: true
        )
        XCTAssertEqual(InputHealthProbe.verdict(for: facts), .healthy)
    }

    // MARK: - Response policy
    //
    // The 2026-09-14 recovery burned all three attempts rebuilding an AVAudioEngine, which
    // cannot un-mute a device, raise a gain slider or grant a permission. These assertions pin
    // the rule that stops it happening again.

    func testRebuildIsOnlyAttemptedWhereItCouldPlausiblyWork() {
        XCTAssertTrue(InputHealthVerdict.healthy.rebuildCanHelp)
        XCTAssertTrue(InputHealthVerdict.deviceGone.rebuildCanHelp)

        XCTAssertFalse(InputHealthVerdict.muted.rebuildCanHelp)
        XCTAssertFalse(InputHealthVerdict.gainZero.rebuildCanHelp)
        XCTAssertFalse(InputHealthVerdict.permissionDenied.rebuildCanHelp)
        XCTAssertFalse(InputHealthVerdict.permissionNotDetermined.rebuildCanHelp)
        XCTAssertFalse(InputHealthVerdict.noInputStreams.rebuildCanHelp)
    }

    func testDeviceSwitchIsPointlessOnlyForPermissionFailures() {
        XCTAssertFalse(InputHealthVerdict.permissionDenied.otherDeviceCanHelp)
        XCTAssertFalse(InputHealthVerdict.permissionNotDetermined.otherDeviceCanHelp)

        XCTAssertTrue(InputHealthVerdict.deviceGone.otherDeviceCanHelp)
        XCTAssertTrue(InputHealthVerdict.noInputStreams.otherDeviceCanHelp)
        XCTAssertTrue(InputHealthVerdict.muted.otherDeviceCanHelp)
        XCTAssertTrue(InputHealthVerdict.gainZero.otherDeviceCanHelp)
    }

    func testOnlyMuteAndGainAreSelfRepairable() {
        XCTAssertTrue(InputHealthVerdict.muted.isSelfRepairable)
        XCTAssertTrue(InputHealthVerdict.gainZero.isSelfRepairable)

        for verdict: InputHealthVerdict in [.healthy, .deviceGone, .noInputStreams,
                                            .permissionDenied, .permissionNotDetermined] {
            XCTAssertFalse(verdict.isSelfRepairable, "\(verdict) is not something the app can fix")
        }
    }

    // MARK: - Reporting

    func testEveryVerdictCarriesADistinctLogCodeAndAMessage() {
        let all: [InputHealthVerdict] = [.healthy, .permissionDenied, .permissionNotDetermined,
                                         .deviceGone, .noInputStreams, .muted, .gainZero]
        XCTAssertEqual(Set(all.map(\.logCode)).count, all.count, "log codes must be distinguishable")
        for verdict in all {
            XCTAssertFalse(verdict.userMessage.isEmpty, "\(verdict) needs user-facing copy")
        }
    }

    /// The old log line said `reason=silence_1.5s` and nothing else. The dump has to carry the
    /// readings that produced the verdict, or the next incident is just as unanalysable.
    func testLogFieldsCarryTheReadingsBehindTheVerdict() {
        let facts = InputHealthFacts(
            authorization: .authorized,
            isMuted: true,
            inputVolume: 0.0,
            isRunningSomewhere: true
        )
        let fields = InputHealthProbe.logFields(facts, .muted)

        // `MetadataValue` is `CustomStringConvertible`, not `Equatable` — compare the rendering,
        // which is also exactly what lands in the log line and the stall dump.
        XCTAssertEqual(fields["verdict"]?.description, "input_muted")
        XCTAssertEqual(fields["alive"]?.description, "true")
        XCTAssertEqual(fields["streams"]?.description, "true")
        XCTAssertEqual(fields["hot"]?.description, "true")
        XCTAssertEqual(fields["muted"]?.description, "true")
        XCTAssertNotNil(fields["gain"])
    }

    func testLogFieldsOmitControlsTheDeviceDoesNotExpose() {
        let facts = InputHealthFacts(authorization: .authorized, isMuted: nil, inputVolume: nil)
        let fields = InputHealthProbe.logFields(facts, .healthy)

        XCTAssertNil(fields["muted"], "an absent mute control must not be logged as false")
        XCTAssertNil(fields["gain"])
    }

    // MARK: - Probe against the real HAL

    /// A device ID that does not exist must resolve, not hang or crash. `kAudioObjectUnknown`
    /// is what `cachedEngineDeviceID` holds before any engine is built.
    func testProbingAnUnknownDeviceReportsDeviceGone() {
        let (facts, verdict) = InputHealthProbe.probe(deviceID: nil)
        XCTAssertFalse(facts.deviceExists)
        // On a CI host with no TCC grant the permission verdict legitimately wins.
        XCTAssertTrue(verdict == .deviceGone
                      || verdict == .permissionDenied
                      || verdict == .permissionNotDetermined,
                      "unexpected verdict \(verdict)")
    }
}
