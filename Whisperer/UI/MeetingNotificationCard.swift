//
//  MeetingNotificationCard.swift
//  Whisperer
//
//  Animated meeting detection notification card.
//

import SwiftUI

#if !APP_STORE

struct MeetingNotificationCard: View {
    let app: MeetingDetector.DetectedMeetingApp

    @State private var appeared = false
    @State private var isExiting = false
    @State private var borderRotation: Double = 0.0
    @State private var glowScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            glowLayer
            cardSurface
        }
        .frame(width: 380)
        .scaleEffect(cardScale)
        .offset(y: cardOffset)
        .opacity(cardOpacity)
        .onAppear(perform: startAnimations)
    }

    // MARK: - Card scale/offset/opacity

    private var cardScale: CGFloat {
        isExiting ? 0.94 : (appeared ? 1.0 : 0.90)
    }
    private var cardOffset: CGFloat {
        isExiting ? 10 : (appeared ? 0 : 24)
    }
    private var cardOpacity: Double {
        isExiting ? 0 : (appeared ? 1 : 0)
    }

    // MARK: - Layers

    private var glowLayer: some View {
        RadialGradient(
            colors: [
                Color(hex: "5B6CF7").opacity(0.06),
                Color(hex: "8B5CF6").opacity(0.03),
                .clear
            ],
            center: .center,
            startRadius: 0,
            endRadius: 220
        )
        .blur(radius: 20)
        .scaleEffect(glowScale)
    }

    private var cardSurface: some View {
        VStack(spacing: 0) {
            headerRow
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)
                .padding(.horizontal, 16)
            appRow
            actionRow
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(hex: "0C0C1A"))
        )
        .overlay(rotatingBorder)
    }

    private var rotatingBorder: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                AngularGradient(
                    colors: [
                        Color(hex: "5B6CF7").opacity(0.0),
                        Color(hex: "5B6CF7").opacity(0.0),
                        Color(hex: "5B6CF7").opacity(0.55),
                        Color(hex: "8B5CF6").opacity(0.85),
                        Color(hex: "5B6CF7").opacity(0.55),
                        Color(hex: "5B6CF7").opacity(0.0),
                        Color(hex: "5B6CF7").opacity(0.0),
                    ],
                    center: .center,
                    angle: .degrees(borderRotation)
                ),
                lineWidth: 1
            )
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("MEETING DETECTED")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(hex: "5B6CF7"), Color(hex: "8B5CF6")],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - App Row

    private var appRow: some View {
        HStack(spacing: 14) {
            iconWithRings
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text("Want to capture this meeting?")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var iconWithRings: some View {
        ZStack {
            // Outer ring — slowest, most transparent
            SonarRing(delay: 1.0, maxScale: 1.48, lineWidth: 0.5)
                .frame(width: 56, height: 56)
            // Mid ring
            SonarRing(delay: 0.5, maxScale: 1.32, lineWidth: 1.0)
                .frame(width: 56, height: 56)
            // Inner ring — fastest, most opaque
            SonarRing(delay: 0.0, maxScale: 1.18, lineWidth: 1.5)
                .frame(width: 56, height: 56)

            // Icon background
            Circle()
                .fill(Color(hex: "1C1C3A"))
                .frame(width: 44, height: 44)

            // SF Symbol with blue→purple gradient
            Image(systemName: app.iconSystemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(hex: "5B6CF7"), Color(hex: "8B5CF6")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .frame(width: 56, height: 56)
    }

    // MARK: - Action Row

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button { handleStartNotes() } label: {
                Text("Start Notes")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: "5B6CF7"), Color(hex: "8B5CF6")],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .clipShape(Capsule())
                    )
            }
            .buttonStyle(.plain)

            Button { handleDismiss() } label: {
                Text("Dismiss")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: - Animations

    private func startAnimations() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.70).delay(0.05)) {
            appeared = true
        }
        withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
            borderRotation = 360
        }
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
            glowScale = 1.12
        }
    }

    /// Runs exit animation then fires `action` after 350 ms when opacity reaches zero.
    private func animateOut(then action: @escaping @MainActor () -> Void) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            isExiting = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            action()
        }
    }

    // MARK: - Button Handlers

    private func handleStartNotes() {
        let capturedApp = app
        animateOut {
            AppState.shared.dismissMeetingNotification()
            Task { @MainActor in
                let session = MeetingSession()
                await session.startRecording(title: capturedApp.name)
                // activeMeetingSession is now set in AppState (strong @Published reference).
                HistoryWindowManager.shared.showWindowAndDismissMenu()
                NotificationCenter.default.post(name: .switchToMeetingStudioTab, object: nil)
            }
        }
    }

    private func handleDismiss() {
        animateOut {
            AppState.shared.dismissMeetingNotification()
            MeetingDetector.shared.onUserDismissed()
        }
    }
}

// MARK: - Sonar Ring

/// A single expanding-fading ring used in the sonar pulse animation.
/// Starts invisible, becomes visible after `delay` seconds, then loops: expand + fade out.
private struct SonarRing: View {
    let delay: Double
    let maxScale: CGFloat
    let lineWidth: CGFloat

    @State private var visible = false
    @State private var animating = false

    var body: some View {
        Circle()
            .stroke(Color(hex: "5B6CF7"), lineWidth: lineWidth)
            .scaleEffect(animating ? maxScale : 1.0)
            .opacity(visible ? (animating ? 0.0 : 0.7) : 0.0)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    visible = true
                    // repeatForever(autoreverses: false): scale 1.0→maxScale, opacity 0.7→0.0,
                    // then jumps back invisibly (opacity=0) and repeats as a sonar pulse.
                    withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                        animating = true
                    }
                }
            }
    }
}

#Preview {
    ZStack {
        Color.black
        MeetingNotificationCard(
            app: MeetingDetector.DetectedMeetingApp(
                name: "Slack",
                iconSystemName: "bubble.left.and.bubble.right.fill",
                iconColor: .purple,
                bundleID: "com.tinyspeck.slackmacgap"
            )
        )
        .padding(40)
    }
}

#endif
