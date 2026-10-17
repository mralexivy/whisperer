import XCTest
import CoreAudio
@testable import whisperer

final class PrivacyShieldControllerTests: XCTestCase {
    private var savedEnabled: Any?
    override func setUp() {
        super.setUp()
        savedEnabled = UserDefaults.standard.object(forKey: "privacyShieldAutomaticEnabled")
    }
    override func tearDown() {
        if let savedEnabled { UserDefaults.standard.set(savedEnabled, forKey: "privacyShieldAutomaticEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "privacyShieldAutomaticEnabled") }
        super.tearDown()
    }

    func testInstallerDiagnosticsDistinguishCancellationFromFailure() {
        XCTAssertTrue(PrivacyShieldController.installerFailureMessage(details: "User canceled. (-128)").contains("cancelled"))
        XCTAssertTrue(PrivacyShieldController.installerFailureMessage(details: "system audio did not restart").contains("Restart your Mac"))
        let failure = PrivacyShieldController.installerFailureMessage(details: "Operation not permitted (1)")
        XCTAssertTrue(failure.contains("log"))
        XCTAssertFalse(failure.contains("cancelled"))
    }

    func testAutomaticSelectionRejectsFeedbackRoutesAndInvalidRates() {
        XCTAssertTrue(PrivacyShieldController.isPhysicalInput(transport: kAudioDeviceTransportTypeBuiltIn, rate: 48000))
        XCTAssertTrue(PrivacyShieldController.isPhysicalInput(transport: kAudioDeviceTransportTypeUSB, rate: 44100))
        XCTAssertFalse(PrivacyShieldController.isPhysicalInput(transport: kAudioDeviceTransportTypeVirtual, rate: 48000))
        XCTAssertFalse(PrivacyShieldController.isPhysicalInput(transport: kAudioDeviceTransportTypeAggregate, rate: 48000))
        XCTAssertFalse(PrivacyShieldController.isPhysicalInput(transport: kAudioDeviceTransportTypeBuiltIn, rate: .nan))
    }

    @MainActor
    func testImmediateCancellationDoesNotBeginSetup() async {
        let app = AppState.shared
        let old = (app.privacyShield, app.state, app.pendingMeetingStarts)
        defer { (app.privacyShield, app.state, app.pendingMeetingStarts) = old }
        app.privacyShield = PrivacyShieldSnapshot(); app.state = .idle; app.pendingMeetingStarts = 0
        PrivacyShieldController.shared.start()
        XCTAssertEqual(app.privacyShield.phase, .starting)
        await PrivacyShieldController.shared.stop()
        await Task.yield()
        XCTAssertEqual(app.privacyShield.phase, .off)
        XCTAssertFalse(app.privacyShieldInstallerBusy)
        XCTAssertFalse(shield_capture_blocked())
    }

    @MainActor
    func testRepeatedImmediateTogglesCannotResurrectCancelledStartup() async {
        let app = AppState.shared
        let old = (app.privacyShield, app.state, app.pendingMeetingStarts)
        defer { (app.privacyShield, app.state, app.pendingMeetingStarts) = old }
        app.privacyShield = PrivacyShieldSnapshot(); app.state = .idle; app.pendingMeetingStarts = 0
        for _ in 0..<10 {
            PrivacyShieldController.shared.start()
            XCTAssertEqual(app.privacyShield.phase, .starting)
            await PrivacyShieldController.shared.stop()
        }
        await Task.yield()
        XCTAssertEqual(app.privacyShield.phase, .off)
        XCTAssertFalse(app.privacyShieldInstallerBusy)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "privacyShieldAutomaticEnabled"))
        XCTAssertFalse(shield_capture_blocked())
    }

    @MainActor
    func testPendingMeetingPreventsShieldStart() {
        let app = AppState.shared
        let old = (app.privacyShield, app.state, app.pendingMeetingStarts)
        defer { (app.privacyShield, app.state, app.pendingMeetingStarts) = old }
        app.privacyShield = PrivacyShieldSnapshot(); app.state = .idle; app.pendingMeetingStarts = 1
        PrivacyShieldController.shared.start()
        XCTAssertEqual(app.privacyShield.phase, .off)
        XCTAssertTrue(app.privacyShield.message.contains("Stop the current recording"))
    }

    @MainActor
    func testExplicitStopReleasesMutedCaptureGate() async {
        let app = AppState.shared
        let old = (app.privacyShield, app.errorMessage)
        defer { (app.privacyShield, app.errorMessage) = old }
        app.privacyShield.phase = .muted
        XCTAssertTrue(shield_capture_blocked())
        XCTAssertFalse(app.allowCaptureOutsidePrivacyShield())
        await PrivacyShieldController.shared.stop()
        XCTAssertEqual(app.privacyShield.phase, .off)
        XCTAssertFalse(shield_capture_blocked())
        XCTAssertTrue(app.privacyShield.message.contains("microphone"))
    }

    @MainActor
    func testInstallerBlocksBothCaptureGates() {
        let app = AppState.shared
        let old = (app.privacyShield, app.privacyShieldInstallerBusy, app.errorMessage)
        defer { (app.privacyShield, app.privacyShieldInstallerBusy, app.errorMessage) = old }
        app.privacyShield = PrivacyShieldSnapshot(); app.privacyShieldInstallerBusy = true
        XCTAssertTrue(shield_capture_blocked())
        XCTAssertFalse(app.allowCaptureOutsidePrivacyShield())
        app.privacyShield.message = "Refresh"
        XCTAssertTrue(shield_capture_blocked())
        app.privacyShieldInstallerBusy = false
        XCTAssertFalse(shield_capture_blocked())
    }
}
