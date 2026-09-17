//
//  UserAlertNotifier.swift
//  Whisperer
//
//  Posts a macOS notification for the small number of events the user must know about even
//  when Whisperer is nowhere on screen.
//
//  Whisperer is a menu bar app. Its entire failure vocabulary — the overlay panel, the Island,
//  the `errorMessage` banner — lives inside surfaces the user is not looking at during a
//  meeting, and two of the three disappear the moment `AppState.state` returns to `.idle`.
//  On 2026-09-14 a meeting recorded 58 minutes of silence and the user found out at the end.
//  A notification is the one channel that reaches somebody full-screen in Zoom or Teams.
//
//  Deliberately narrow: this is not a general notification service. Authorization is requested
//  lazily on first use, so a user who never hits a failure is never prompted. Works under the
//  App Store sandbox with no additional entitlement.
//

import Foundation
import UserNotifications

@MainActor
final class UserAlertNotifier {
    static let shared = UserAlertNotifier()

    private enum Authorization {
        case unknown
        case requesting
        case granted
        case denied
    }

    private var authorization: Authorization = .unknown
    /// Alerts posted while authorization was still being resolved, replayed once it lands.
    private var pending: [(title: String, body: String)] = []

    /// Suppresses duplicates: recovery can re-diagnose the same condition repeatedly, and one
    /// banner per buffer would be its own failure.
    private var lastPosted: (body: String, at: Date)?
    private let duplicateWindow: TimeInterval = 30

    private init() {}

    /// Posts an alert-style notification. Safe to call before authorization is known.
    func post(title: String, body: String) {
        if let last = lastPosted, last.body == body,
           Date().timeIntervalSince(last.at) < duplicateWindow {
            return
        }
        lastPosted = (body, Date())

        switch authorization {
        case .granted:
            deliver(title: title, body: body)
        case .denied:
            // Nothing to do — the Island row and the error sound still fire.
            return
        case .requesting:
            pending.append((title, body))
        case .unknown:
            authorization = .requesting
            pending.append((title, body))
            requestAuthorization()
        }
    }

    private func requestAuthorization() {
        // `UNUserNotificationCenter.current()` traps in a process with no bundle identifier,
        // which is exactly the situation in a unit-test host.
        guard Bundle.main.bundleIdentifier != nil else {
            authorization = .denied
            pending.removeAll()
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    Logger.warning("Notification authorization failed: \(error.localizedDescription)", subsystem: .app)
                }
                self.authorization = granted ? .granted : .denied
                let queued = self.pending
                self.pending.removeAll()
                guard granted else { return }
                for alert in queued { self.deliver(title: alert.title, body: alert.body) }
            }
        }
    }

    private func deliver(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil  // SoundPlayer.playErrorSound() already handles the audible part.

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger.warning("Notification delivery failed: \(error.localizedDescription)", subsystem: .app)
            }
        }
    }
}
