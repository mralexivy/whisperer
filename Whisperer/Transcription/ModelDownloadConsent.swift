//
//  ModelDownloadConsent.swift
//  Whisperer
//
//  App Store Guideline 4.2.3(ii): when the app needs extra resources before it can work, it must
//  say how big the download is and let the user choose to start it. Build 12 was rejected for
//  exactly this — the last onboarding page began fetching the ~550 MB speech model the moment it
//  appeared, and the meeting engines fetched a ~3.2 GB language model in the background.
//
//  The rule is one sentence: **nothing large is downloaded unless the user pressed a button that
//  named its size.** A button press records consent here; anything automatic (launch, a shortcut
//  press, meeting detection) may only download what the user already agreed to, and otherwise asks.
//

import AppKit
import Foundation

nonisolated enum ModelDownloadConsent {
    private static let speechPrefix = "modelDownloadConsent."
    private static let meetingKey = "meetingModelsDownloadConsent"

    // MARK: - Speech engines

    static func hasConsent(for asset: ModelAsset, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: speechPrefix + asset.testID)
    }

    /// Recorded when the user presses a download button (or accepts the prompt).
    static func grant(_ asset: ModelAsset, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: speechPrefix + asset.testID)
    }

    // MARK: - Smart Polish model (optional text-cleanup model)

    private static let polishKey = "polishModelDownloadConsent"

    static var hasPolishConsent: Bool { UserDefaults.standard.bool(forKey: polishKey) }

    static func grantPolish(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: polishKey)
    }

    // MARK: - Meeting engines (speaker, cleanup and notes models)

    static var hasMeetingConsent: Bool { UserDefaults.standard.bool(forKey: meetingKey) }

    static func grantMeeting(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: meetingKey)
    }
}

/// The question asked when something automatic needs a download the user has not agreed to yet
/// (for example the shortcut is pressed on a Mac whose onboarding was skipped).
@MainActor
enum ModelDownloadPrompt {
    /// True when the user chose to download. Names the model and its size and offers "Not Now".
    static func confirm(_ asset: ModelAsset) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Download \(asset.displayName)?"
        alert.informativeText = "Whisperer needs a one-time download of \(asset.sizeLabel) to turn speech into text on this Mac. "
            + "It is stored on this Mac and your audio never leaves it. You can also do this later from the menu bar, under Models."
        alert.addButton(withTitle: "Download (\(asset.sizeLabel))")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
