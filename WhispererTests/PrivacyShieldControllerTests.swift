import XCTest
@testable import whisperer

final class PrivacyShieldControllerTests: XCTestCase {
    @MainActor
    func testHeadphonesRequiredBeforeOpeningAudio() {
        let app = AppState.shared
        let old = (app.privacyShield, app.privacyShieldHeadphones, app.state, app.pendingMeetingStarts)
        defer { (app.privacyShield, app.privacyShieldHeadphones, app.state, app.pendingMeetingStarts) = old }
        app.privacyShield = PrivacyShieldSnapshot()
        app.privacyShieldHeadphones = false; app.state = .idle; app.pendingMeetingStarts = 0
        PrivacyShieldController.shared.start()
        XCTAssertEqual(app.privacyShield.phase, .off)
        XCTAssertTrue(app.privacyShield.message.contains("headphones"))
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
        XCTAssertTrue(app.privacyShield.message.contains("silent"))
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
