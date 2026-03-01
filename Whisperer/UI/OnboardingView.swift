//
//  OnboardingView.swift
//  Whisperer
//
//  Professional dark-themed onboarding flow.
//  Two-column layout with content on the left and decorative panel on the right.
//

import AppKit
import SwiftUI

// MARK: - Dark Theme Colors

private enum OnboardingColors {
    static let background = Color(red: 0.047, green: 0.047, blue: 0.102)       // #0C0C1A
    static let cardSurface = Color(red: 0.078, green: 0.078, blue: 0.169)       // #14142B
    static let cardBorder = Color.white.opacity(0.06)
    static let rightPanel = Color(red: 0.071, green: 0.071, blue: 0.165)        // #12122A
    static let accentBlue = Color(red: 0.357, green: 0.424, blue: 0.969)        // #5B6CF7
    static let accentPurple = Color(red: 0.545, green: 0.361, blue: 0.965)      // #8B5CF6
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.5)
    static let textTertiary = Color.white.opacity(0.35)
    static let pillBackground = Color.white.opacity(0.08)
    static let dotInactive = Color.white.opacity(0.2)

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentBlue, accentPurple], startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Main View

struct OnboardingView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var permissionManager = PermissionManager.shared
    @State private var currentPage = 0

    var onComplete: (() -> Void)?

    private let totalPages = 4

    var body: some View {
        ZStack {
            // Background
            OnboardingColors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Close button
                HStack {
                    Button(action: { completeOnboarding() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(OnboardingColors.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(OnboardingColors.pillBackground)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.top, 16)
                .padding(.leading, 20)

                if currentPage == 0 {
                    // Full-width centered welcome splash
                    welcomeSplash
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Two-column content
                    HStack(spacing: 0) {
                        // Left content column
                        leftColumn
                            .frame(maxWidth: .infinity)

                        // Right decorative panel
                        rightPanel
                            .frame(width: 340)
                            .padding(.trailing, 20)
                            .padding(.vertical, 8)
                    }
                    .frame(maxHeight: .infinity)

                    // Bottom navigation
                    bottomNavigation
                        .padding(.horizontal, 28)
                        .padding(.bottom, 24)
                        .padding(.top, 8)
                }
            }
        }
        .frame(width: 860, height: 540)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(OnboardingColors.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Left Column

    @ViewBuilder
    private var leftColumn: some View {
        switch currentPage {
        case 1: featuresContent
        case 2: microphoneContent
        case 3: dictationContent
        default: EmptyView()
        }
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(OnboardingColors.rightPanel)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(OnboardingColors.cardBorder, lineWidth: 1)
                )

            // Decorative content per page
            rightPanelContent
        }
    }

    @ViewBuilder
    private var rightPanelContent: some View {
        switch currentPage {
        case 1: rightPanelFeatures
        case 2: rightPanelMicrophone
        case 3: rightPanelDictation
        default: EmptyView()
        }
    }

    // MARK: - Bottom Navigation

    private var bottomNavigation: some View {
        HStack(spacing: 0) {
            // Page dots
            HStack(spacing: 8) {
                ForEach(0..<totalPages, id: \.self) { page in
                    Capsule()
                        .fill(page == currentPage
                              ? OnboardingColors.accentBlue
                              : OnboardingColors.dotInactive)
                        .frame(width: page == currentPage ? 24 : 8, height: 8)
                        .animation(.easeInOut(duration: 0.25), value: currentPage)
                }
            }

            Spacer()

            // Skip button
            if currentPage < totalPages - 1 {
                Button(action: { completeOnboarding() }) {
                    Text("Skip")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(OnboardingColors.textSecondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
            }

            // Continue / Back
            HStack(spacing: 10) {
                if currentPage > 0 {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) { currentPage -= 1 }
                    }) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(OnboardingColors.textSecondary)
                            .frame(width: 40, height: 40)
                            .background(OnboardingColors.pillBackground)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                if currentPage < totalPages - 1 {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) { currentPage += 1 }
                    }) {
                        HStack(spacing: 6) {
                            Text("Continue")
                                .font(.system(size: 13, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(OnboardingColors.accentGradient)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Page 0: Welcome Splash

    private var welcomeSplash: some View {
        VStack(spacing: 0) {
            Spacer()

            // App icon — custom dark-themed rendering
            ZStack {
                // Glow behind icon
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [OnboardingColors.accentBlue.opacity(0.25), .clear],
                            center: .center,
                            startRadius: 20,
                            endRadius: 100
                        )
                    )
                    .frame(width: 180, height: 180)

                // Icon container
                RoundedRectangle(cornerRadius: 28)
                    .fill(
                        LinearGradient(
                            colors: [
                                OnboardingColors.accentBlue.opacity(0.18),
                                OnboardingColors.accentPurple.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28)
                            .stroke(OnboardingColors.accentBlue.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: OnboardingColors.accentBlue.opacity(0.2), radius: 20, y: 8)

                // Waveform icon
                Image(systemName: "waveform")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [OnboardingColors.accentBlue, OnboardingColors.accentPurple],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            // Title
            VStack(spacing: 6) {
                Text("Welcome to")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(OnboardingColors.textSecondary)
                Text("Whisperer")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [OnboardingColors.accentBlue, OnboardingColors.accentPurple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
            .padding(.top, 24)

            // Subtitle
            Text("Offline voice-to-text for your Mac.\nPowered by whisper.cpp with Apple Silicon GPU acceleration.")
                .font(.system(size: 14))
                .foregroundColor(OnboardingColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)

            // Feature pills — colorful with icons
            HStack(spacing: 8) {
                featurePill("Offline", icon: "wifi.slash", color: .cyan)
                featurePill("Privacy", icon: "lock.fill", color: .green)
                featurePill("Fast", icon: "bolt.fill", color: .orange)
                featurePill("100+ Languages", icon: "globe", color: OnboardingColors.accentPurple)
            }
            .padding(.top, 20)

            // Begin Onboarding button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.3)) { currentPage = 1 }
            }) {
                HStack(spacing: 6) {
                    Text("Start Onboarding")
                        .font(.system(size: 14, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(OnboardingColors.accentGradient)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 32)

            Spacer()
        }
    }

    // MARK: - Page 2: Features

    private var featuresContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                Text("Packed with\nFeatures")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(OnboardingColors.textPrimary)
                    .lineSpacing(2)

                Text("Transcribe, organize, and manage\nyour recordings from the menu bar.")
                    .font(.system(size: 14))
                    .foregroundColor(OnboardingColors.textSecondary)
                    .lineSpacing(3)
            }
            .padding(.leading, 36)

            // 2x3 feature grid
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ], spacing: 10) {
                featureGridCard(icon: "mic.fill", color: .red, title: "Record", subtitle: "Hold & speak")
                featureGridCard(icon: "text.bubble.fill", color: OnboardingColors.accentBlue, title: "Transcribe", subtitle: "Real-time text")
                featureGridCard(icon: "book.closed.fill", color: .orange, title: "Dictionary", subtitle: "Custom terms")
                featureGridCard(icon: "clock.fill", color: .red, title: "History", subtitle: "All recordings")
                featureGridCard(icon: "cpu", color: .cyan, title: "Models", subtitle: "Choose quality")
                featureGridCard(icon: "globe", color: .green, title: "Languages", subtitle: "100+ supported")
            }
            .padding(.leading, 36)
            .padding(.trailing, 24)
            .padding(.top, 20)

            Spacer()
        }
    }

    private var rightPanelFeatures: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [OnboardingColors.accentPurple.opacity(0.3), .clear],
                        center: .center,
                        startRadius: 20,
                        endRadius: 140
                    )
                )
                .frame(width: 280, height: 280)

            VStack(spacing: 24) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundColor(OnboardingColors.accentPurple)

                // Mini feature row
                HStack(spacing: 12) {
                    decorativeIcon("mic.fill", size: 22, color: .red)
                    decorativeIcon("text.bubble.fill", size: 22, color: OnboardingColors.accentBlue)
                    decorativeIcon("book.closed.fill", size: 22, color: .orange)
                    decorativeIcon("clock.fill", size: 22, color: .red)
                }
            }
        }
    }

    // MARK: - Page 3: Microphone

    private var microphoneContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                Text("Private by Design")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(OnboardingColors.textPrimary)

                Text("Whisperer processes everything on-device.\nGrant microphone access to start\ntranscribing — nothing leaves your Mac.")
                    .font(.system(size: 14))
                    .foregroundColor(OnboardingColors.textSecondary)
                    .lineSpacing(3)
            }
            .padding(.leading, 36)
            .padding(.trailing, 24)

            // Privacy feature cards — horizontal layout
            VStack(spacing: 10) {
                privacyCard(icon: "lock.shield.fill", color: OnboardingColors.accentBlue, title: "100% Offline", subtitle: "Audio never leaves your Mac")
                privacyCard(icon: "xmark.icloud.fill", color: .red, title: "No Internet", subtitle: "Works without any connection")
                privacyCard(icon: "checkmark.shield.fill", color: .green, title: "On-Device Only", subtitle: "All data stays on your Mac")
            }
            .padding(.leading, 36)
            .padding(.trailing, 24)
            .padding(.top, 20)

            // Grant button or status
            VStack(alignment: .leading, spacing: 8) {
                if permissionManager.microphoneStatus == .granted {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 18))
                        Text("Microphone access granted")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.green)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    .background(Color.green.opacity(0.1))
                    .clipShape(Capsule())
                } else {
                    Button(action: {
                        permissionManager.requestMicrophonePermission()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 13))
                            Text("Grant Microphone Access")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 24)
                        .background(OnboardingColors.accentGradient)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 36)
            .padding(.top, 20)

            Spacer()
        }
    }

    private var rightPanelMicrophone: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [OnboardingColors.accentBlue.opacity(0.25), .clear],
                        center: .center,
                        startRadius: 20,
                        endRadius: 140
                    )
                )
                .frame(width: 280, height: 280)

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(OnboardingColors.accentPurple.opacity(0.15), lineWidth: 1.5)
                        .frame(width: 140, height: 140)
                    Circle()
                        .stroke(OnboardingColors.accentBlue.opacity(0.3), lineWidth: 2)
                        .frame(width: 100, height: 100)

                    Image(systemName: "mic.fill")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [OnboardingColors.accentBlue, OnboardingColors.accentPurple],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }

                // Mini privacy icon row — matches features panel pattern
                HStack(spacing: 12) {
                    decorativeIcon("lock.shield.fill", size: 22, color: OnboardingColors.accentBlue)
                    decorativeIcon("xmark.icloud.fill", size: 22, color: .red)
                    decorativeIcon("checkmark.shield.fill", size: 22, color: .green)
                }

                if permissionManager.microphoneStatus == .granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.green)
                }
            }
        }
    }

    // MARK: - Page 4: System-Wide Dictation

    private var dictationContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Dictate\nAnywhere")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(OnboardingColors.textPrimary)
                        .lineSpacing(2)

                    Text("Optional")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(OnboardingColors.accentBlue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(OnboardingColors.accentBlue.opacity(0.15))
                        .clipShape(Capsule())
                }

                Text("Use Whisperer system-wide — dictate\ninto any app. For users who prefer\nvoice input or find typing difficult.")
                    .font(.system(size: 14))
                    .foregroundColor(OnboardingColors.textSecondary)
                    .lineSpacing(3)
            }
            .padding(.leading, 36)
            .padding(.trailing, 24)

            // How it works — horizontal cards with colorful icons
            VStack(spacing: 10) {
                privacyCard(icon: "keyboard.fill", color: OnboardingColors.accentBlue, title: "Hold Shortcut Key", subtitle: "Press and hold Fn to start")
                privacyCard(icon: "waveform", color: .red, title: "Speak Naturally", subtitle: "Talk at your normal pace")
                privacyCard(icon: "text.cursor", color: .green, title: "Release — Text Appears", subtitle: "Transcribed text is inserted instantly")
            }
            .padding(.leading, 36)
            .padding(.trailing, 24)
            .padding(.top, 20)

            // Action buttons
            VStack(alignment: .leading, spacing: 10) {
                Button(action: {
                    appState.systemWideDictationEnabled = true
                    completeOnboarding()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "globe")
                            .font(.system(size: 13))
                        Text("Enable System-Wide Dictation")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 24)
                    .background(OnboardingColors.accentGradient)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: { completeOnboarding() }) {
                    Text("Set Up Later")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(OnboardingColors.textSecondary)
                        .padding(.leading, 4)
                }
                .buttonStyle(.plain)

                Text("Requires Accessibility permission to detect\nshortcut key and paste transcribed text.")
                    .font(.system(size: 11))
                    .foregroundColor(OnboardingColors.textTertiary)
                    .lineSpacing(2)
                    .padding(.top, 4)
            }
            .padding(.leading, 36)
            .padding(.top, 20)

            Spacer()
        }
    }

    private var rightPanelDictation: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [OnboardingColors.accentBlue.opacity(0.3), .clear],
                        center: .center,
                        startRadius: 20,
                        endRadius: 140
                    )
                )
                .frame(width: 280, height: 280)

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(OnboardingColors.accentPurple.opacity(0.15), lineWidth: 1.5)
                        .frame(width: 140, height: 140)
                    Circle()
                        .stroke(OnboardingColors.accentBlue.opacity(0.3), lineWidth: 2)
                        .frame(width: 100, height: 100)

                    Image(systemName: "globe")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [OnboardingColors.accentBlue, OnboardingColors.accentPurple],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }

                // Mini dictation icon row — matches other panels
                HStack(spacing: 12) {
                    decorativeIcon("keyboard.fill", size: 22, color: OnboardingColors.accentBlue)
                    decorativeIcon("waveform", size: 22, color: .red)
                    decorativeIcon("text.cursor", size: 22, color: .green)
                }
            }
        }
    }

    // MARK: - Reusable Components

    private func featurePill(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    private func featureGridCard(icon: String, color: Color, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(OnboardingColors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(OnboardingColors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(OnboardingColors.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(OnboardingColors.cardBorder, lineWidth: 1)
        )
        .cornerRadius(12)
    }

    private func privacyCard(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(OnboardingColors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(OnboardingColors.textTertiary)
            }

            Spacer()
        }
        .padding(12)
        .background(OnboardingColors.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(OnboardingColors.cardBorder, lineWidth: 1)
        )
        .cornerRadius(12)
    }

    private func decorativeIcon(_ name: String, size: CGFloat, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .light))
            .foregroundColor(color.opacity(0.7))
            .frame(width: size + 20, height: size + 20)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: (size + 20) / 3.5))
    }

    // MARK: - Actions

    private func completeOnboarding() {
        appState.hasCompletedOnboarding = true
        onComplete?()
    }
}
