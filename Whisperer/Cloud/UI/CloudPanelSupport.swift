//
//  CloudPanelSupport.swift
//  Whisperer
//
//  The seams the Cloud panel binds to, so the UI can be driven by a stub in tests and by the real engine
//  in the app:
//    - `CloudAccountDriving`: the account state machine (`CloudAccountController` adopts it unchanged);
//    - `CloudSyncStatusSource`: what the sync engine tells the panel (the engine adopts it; until it does,
//      `NoopCloudSyncStatusSource` stands in);
//    - `CloudPanelEnvironment`: every side effect that touches the outside (pasteboard, save panel, print,
//      Apple's plan picker, system sheets), injectable so click tests never touch the real ones.
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Account

@MainActor
protocol CloudAccountDriving: ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    var state: CloudAccountState { get }
    var identity: CloudAccountIdentity? { get }
    var accountInfo: CloudAccountInfo? { get }
    var lastError: String? { get }
    var isPurchasePending: Bool { get }

    func refresh() async
    func recheckKey() async
    func purchase(_ product: CloudProduct) async
    func restorePurchases() async
    func submitRecoveryKey(_ text: String) async
    func createRecoveryKey() async
    func finishRecoveryKey()
    func resetLibrary(confirmation: String) async
    func refreshAccount() async
    func revokeDevice(id: String) async
    func startOver() async
}

extension CloudAccountController: CloudAccountDriving {}

/// Stands in until the service is configured: shows the honest "unavailable" screen with Try again.
@MainActor
final class CloudUnconfiguredAccount: CloudAccountDriving {
    var state: CloudAccountState { .unavailable(.server(code: "not_configured")) }
    var identity: CloudAccountIdentity? { nil }
    var accountInfo: CloudAccountInfo? { nil }
    var lastError: String? { nil }
    var isPurchasePending: Bool { false }
    func refresh() async {}
    func recheckKey() async {}
    func purchase(_ product: CloudProduct) async {}
    func restorePurchases() async {}
    func submitRecoveryKey(_ text: String) async {}
    func createRecoveryKey() async {}
    func finishRecoveryKey() {}
    func resetLibrary(confirmation: String) async {}
    func refreshAccount() async {}
    func revokeDevice(id: String) async {}
    func startOver() async {}
}

// MARK: - Sync status

nonisolated enum CloudSyncStatus: Equatable, Sendable {
    case idle
    /// `progress` is 0...1 when the engine knows it (the first upload), nil otherwise.
    case syncing(progress: Double?)
    case offline
    case paused
    case readOnly
    case needsKey
    case overQuota
    case error(String)
}

/// What the Cloud panel needs from the sync engine. The engine adopts this; the panel never reaches into it.
@MainActor
protocol CloudSyncStatusSource: ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    var status: CloudSyncStatus { get }
    var lastSyncedAt: Date? { get }
    /// Changes on this Mac that have not reached the cloud yet.
    var pendingChanges: Int { get }
    func pause()
    func resume()
    /// Runs a sync now and returns when it is done.
    func syncNow() async
}

/// The default until the engine adopts the protocol: always idle, never synced. Pause and Resume only
/// move its own flag so the controls stay coherent.
@MainActor
final class NoopCloudSyncStatusSource: CloudSyncStatusSource {
    @Published private(set) var status: CloudSyncStatus = .idle
    var lastSyncedAt: Date? { nil }
    var pendingChanges: Int { 0 }
    func pause() { status = .paused }
    func resume() { status = .idle }
    func syncNow() async {}
}

// MARK: - Environment

@MainActor
struct CloudPanelEnvironment {
    /// Apple's plan picker, shown in place. `onPurchased` runs after a completed purchase.
    var plansView: (_ onPurchased: @escaping @MainActor () async -> Void) -> AnyView
    /// `sensitive` marks the text so clipboard managers skip it.
    var copy: (_ text: String, _ sensitive: Bool) -> Void
    var readClipboard: () -> String?
    /// Returns true when a file was written.
    var saveRecoveryKeyFile: (_ key: String) -> Bool
    var printRecoveryKey: (_ key: String) -> Void
    /// Manage Subscription: StoreKit's sheet is not available on macOS, so this opens the App Store's subscriptions page.
    var openSubscriptionManagement: () -> Void
    var now: () -> Date

    static let live = CloudPanelEnvironment(
        plansView: { onPurchased in
            AnyView(CloudSubscriptionView(showsHeader: false, onPurchased: onPurchased))
        },
        copy: { text, sensitive in
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(text, forType: .string)
            if sensitive { board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
        },
        readClipboard: { NSPasteboard.general.string(forType: .string) },
        saveRecoveryKeyFile: { key in
            let panel = NSSavePanel()
            panel.title = "Save Recovery Key"
            panel.message = "Keep this file somewhere safe and private. It is not stored anywhere else."
            panel.nameFieldStringValue = "Whisperer Cloud Recovery Key.txt"
            panel.allowedContentTypes = [.plainText]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            do {
                try CloudPanelEnvironment.keyFileText(key).write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                Logger.error("Cloud: the recovery key file could not be written", subsystem: .app)
                return false
            }
        },
        printRecoveryKey: { key in
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
            view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            view.string = keyFileText(key)
            NSPrintOperation(view: view).run()
        },
        openSubscriptionManagement: {
            if let url = URL(string: "macappstore://apps.apple.com/account/subscriptions") { NSWorkspace.shared.open(url) }
        },
        now: Date.init)

    nonisolated static func keyFileText(_ key: String) -> String {
        """
        Whisperer Cloud recovery key

        \(key)

        Keep this private and somewhere safe. If you ever lose access to your iCloud Keychain, this key is the only
        way to read your cloud history on a new Mac. Whisperer cannot recover your data without it.
        """
    }
}
