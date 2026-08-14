//
//  MeetingNotificationCard.swift
//  Whisperer
//
//  Minimal meeting detection toast — one row, one action.
//

import SwiftUI

#if !APP_STORE

struct MeetingNotificationCard: View {
    let app: MeetingDetector.DetectedMeetingApp

    @State private var appeared = false
    @State private var isExiting = false
    @State private var dotPulse = false
    @State private var startHovering = false
    @State private var dismissHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: app.iconSystemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting detected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(hex: "5B6CF7"))
                        .frame(width: 5, height: 5)
                        .opacity(dotPulse ? 0.35 : 1.0)
                    Text(app.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
            }

            Spacer(minLength: 12)

            startButton
            dismissButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(hex: "0C0C1A"))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .fixedSize(horizontal: true, vertical: false)
        .scaleEffect(isExiting ? 0.96 : (appeared ? 1.0 : 0.94))
        .offset(y: isExiting ? 8 : (appeared ? 0 : 16))
        .opacity(isExiting ? 0 : (appeared ? 1 : 0))
        .onAppear(perform: startAnimations)
    }

    // MARK: - Actions

    private var startButton: some View {
        Button(action: handleStartNotes) {
            HStack(spacing: 7) {
                // Whisperer mark on a dark tile so the template waveform reads on white
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hex: "0C0C1A"))
                        .frame(width: 18, height: 18)
                    Image("MenuBarIcon")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 11, height: 11)
                        .foregroundColor(.white)
                }
                Text("Start Whispering")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Color(hex: "0C0C1A"))
            }
            .padding(.leading, 7)
            .padding(.trailing, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.white.opacity(startHovering ? 1.0 : 0.92))
            )
        }
        .buttonStyle(.plain)
        .onHover { startHovering = $0 }
    }

    private var dismissButton: some View {
        Button(action: handleDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(dismissHovering ? 0.7 : 0.3))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { dismissHovering = $0 }
    }

    // MARK: - Animations

    private func startAnimations() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78).delay(0.03)) {
            appeared = true
        }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            dotPulse = true
        }
    }

    /// Runs exit animation then fires `action` after 250 ms when opacity reaches zero.
    private func animateOut(then action: @escaping @MainActor () -> Void) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isExiting = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            action()
        }
    }

    // MARK: - Button Handlers

    /// Recording starts on the click, not after the exit animation — the toast is
    /// already gone visually while capture is coming up, so nothing is missed.
    private func handleStartNotes() {
        let capturedApp = app
        Task { @MainActor in
            let session = MeetingSession()
            await session.startRecording(title: capturedApp.name, surface: .floatingWindow)
            // activeMeetingSession is now set in AppState (strong @Published reference).
        }
        animateOut {
            AppState.shared.dismissMeetingNotification()
        }
    }

    private func handleDismiss() {
        animateOut {
            AppState.shared.dismissMeetingNotification()
            MeetingDetector.shared.onUserDismissed()
        }
    }
}

#Preview {
    ZStack {
        Color.black
        MeetingNotificationCard(
            app: MeetingDetector.DetectedMeetingApp(
                name: "Google Meet",
                iconSystemName: "video.fill",
                iconColor: .purple,
                bundleID: "com.google.Chrome"
            )
        )
        .padding(40)
    }
}

#endif
