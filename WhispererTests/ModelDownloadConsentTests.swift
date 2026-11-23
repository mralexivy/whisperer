//
//  ModelDownloadConsentTests.swift
//  WhispererTests
//
//  App Store Guideline 4.2.3(ii) (build 12 rejection, 2026-11-23): a download the app needs must
//  name its size and start only when the user chooses it. These tests pin that rule.
//

import XCTest
@testable import whisperer

final class ModelDownloadConsentTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "ModelDownloadConsentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testNothingIsAgreedByDefault() {
        let defaults = freshDefaults()
        XCTAssertFalse(ModelDownloadConsent.hasConsent(for: .nemotron, defaults: defaults))
        XCTAssertFalse(ModelDownloadConsent.hasConsent(for: .whisper(.largeTurboQ5), defaults: defaults))
    }

    func testConsentIsPerModel() {
        let defaults = freshDefaults()
        ModelDownloadConsent.grant(.qwen3, defaults: defaults)
        XCTAssertTrue(ModelDownloadConsent.hasConsent(for: .qwen3, defaults: defaults))
        XCTAssertFalse(ModelDownloadConsent.hasConsent(for: .nemotron, defaults: defaults),
                       "agreeing to a 2.5 GB model is not agreeing to a different one")
    }

    /// Every size a button shows must come from the same place the download uses.
    func testEverySpeechModelStatesASize() {
        for asset in [ModelAsset.nemotron, .nemotronHebrew, .qwen3, .whisperKit, .parakeet(.v3),
                      .whisper(.largeTurboQ5)] {
            XCTAssertGreaterThan(asset.approximateBytes, 0, asset.displayName)
            XCTAssertFalse(asset.sizeLabel.isEmpty, asset.displayName)
        }
    }

    func testMeetingAndPolishConsentAreSeparate() {
        // Uses the standard defaults: remember and restore so the machine's own state is untouched.
        let defaults = UserDefaults.standard
        let meeting = defaults.object(forKey: "meetingModelsDownloadConsent")
        let polish = defaults.object(forKey: "polishModelDownloadConsent")
        defer {
            defaults.set(meeting, forKey: "meetingModelsDownloadConsent")
            defaults.set(polish, forKey: "polishModelDownloadConsent")
        }
        defaults.removeObject(forKey: "meetingModelsDownloadConsent")
        defaults.removeObject(forKey: "polishModelDownloadConsent")
        XCTAssertFalse(ModelDownloadConsent.hasMeetingConsent)
        XCTAssertFalse(ModelDownloadConsent.hasPolishConsent)
        ModelDownloadConsent.grantMeeting()
        XCTAssertTrue(ModelDownloadConsent.hasMeetingConsent)
        XCTAssertFalse(ModelDownloadConsent.hasPolishConsent, "meeting models do not imply the polish model")
    }

    /// The App Store entitlements must not carry the camera entitlement: no code captures video
    /// (Guideline 2.4.5(i), 2026-11-23).
    func testAppStoreEntitlementsHaveNoCamera() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Whisperer/whisperer.entitlements")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        XCTAssertNil(plist["com.apple.security.device.camera"])
        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true)
    }
}
