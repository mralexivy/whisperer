//
//  MeetingConsentView.swift
//  Whisperer
//
//  Meeting recording consent modal (Guideline 2.5.14).
//  Shown once before the first meeting recording ever starts, from every entry point.
//

import AppKit
import SwiftUI

/// Gate every meeting start goes through. Presents the consent in its own window: it used to be
/// an `.overlay` on the dictation HUD panel, which is 340–520 pt wide and shrinks to 80 pt when
/// idle, so the sheet was clipped — the buttons fell outside the panel and consent could never
/// be given, which meant no meeting could ever start on a Mac that had not consented before.
@MainActor
final class MeetingConsentPrompt: NSObject, NSWindowDelegate {
    static let shared = MeetingConsentPrompt()

    private var window: NSWindow?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    /// True when recording may start: already consented, or the user accepts now.
    static func ensureConsent() async -> Bool {
        if AppState.shared.hasConsentedToMeetingRecording { return true }
        return await shared.ask()
    }

    private func ask() async -> Bool {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            present()
        }
    }

    private func present() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = MeetingConsentView(
            onAccept: { [weak self] in self?.finish(accepted: true) },
            onDecline: { [weak self] in self?.finish(accepted: false) }
        )
        let win = NSWindow(contentViewController: NSHostingController(rootView: view))
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.title = "Meeting Recording"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = NSColor(red: 0.047, green: 0.047, blue: 0.102, alpha: 1.0)
        // Above the call window the meeting was detected in.
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(accepted: Bool) {
        if accepted { AppState.shared.hasConsentedToMeetingRecording = true }
        let closing = window
        window = nil
        closing?.delegate = nil
        closing?.close()
        resumeAll(accepted)
    }

    /// The title-bar close button counts as declining.
    func windowWillClose(_ notification: Notification) {
        window = nil
        resumeAll(false)
    }

    private func resumeAll(_ accepted: Bool) {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(returning: accepted) }
    }
}

struct MeetingConsentView: View {
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Self.accentBlue)
                Text("Meeting Recording")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
            }

            // Consent explanation
            VStack(alignment: .leading, spacing: 12) {
                Text("Before you start recording, please note:")
                    .font(.body)
                    .foregroundStyle(.secondary)

                bulletPoint(
                    icon: "mic.fill",
                    title: "What is recorded",
                    detail: "Your microphone only. Whisperer never records system audio or other participants' audio streams."
                )

                bulletPoint(
                    icon: "folder.fill",
                    title: "Where it is stored",
                    detail: "Locally on your Mac in ~/Library/Application Support/Whisperer/Sessions/. Nothing leaves your device."
                )

                bulletPoint(
                    icon: "hand.raised.fill",
                    title: "Your responsibility",
                    detail: "You are responsible for obtaining consent from other meeting participants where required by law."
                )

                bulletPoint(
                    icon: "lock.fill",
                    title: "Privacy",
                    detail: "All transcription happens on-device. No audio or transcripts are sent to external servers."
                )
            }
            .padding(.vertical, 8)

            // Actions
            HStack(spacing: 12) {
                Button("Decline") {
                    onDecline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    onAccept()
                } label: {
                    Text("I Understand")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                        .background(
                            LinearGradient(colors: [Self.accentBlue, Self.accentPurple],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)    // clears the transparent title bar
        .padding(.bottom, 24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(Self.navy)
        .preferredColorScheme(.dark)
    }

    private static let navy = Color(red: 0.047, green: 0.047, blue: 0.102)         // #0C0C1A
    private static let accentBlue = Color(red: 0.357, green: 0.424, blue: 0.969)   // #5B6CF7
    private static let accentPurple = Color(red: 0.545, green: 0.361, blue: 0.965) // #8B5CF6

    private func bulletPoint(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Self.accentBlue)
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    MeetingConsentView(onAccept: {}, onDecline: {})
}
