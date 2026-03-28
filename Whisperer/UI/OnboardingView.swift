//
//  OnboardingView.swift
//  Whisperer
//
//  Professional dark-themed onboarding flow.
//  Two-column layout with content on the left and decorative panel on the right.
//

import AppKit
import Combine
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
    @State private var ringRotation: Double = 0
    @State private var orbitAngle: Double = 0

    var onComplete: (() -> Void)?

    #if APP_STORE
    private let totalPages = 6
    #else
    private let totalPages = 7
    #endif

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
                    .buttonStyle(.plain).pointerOnHover()
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
        #if APP_STORE
        case 4: languageShortlistContent
        case 5: modelDownloadContent
        #else
        case 4: accessibilityContent
        case 5: languageShortlistContent
        case 6: modelDownloadContent
        #endif
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
        #if APP_STORE
        case 4: rightPanelLanguages
        case 5: rightPanelModelDownload
        #else
        case 4: rightPanelAccessibility
        case 5: rightPanelLanguages
        case 6: rightPanelModelDownload
        #endif
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
                    .buttonStyle(.plain).pointerOnHover()
                }

                // Show Continue on features page and language shortlist page
                #if APP_STORE
                let languagePage = 4
                #else
                let languagePage = 5
                #endif
                if currentPage == 1 || currentPage == languagePage {
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
                    .buttonStyle(.plain).pointerOnHover()
                }
            }
        }

    }

    // MARK: - Page 0: Welcome Splash

    private var welcomeSplash: some View {
        VStack(spacing: 0) {
            Spacer()

            // Orbital hero — concentric rings with orbiting feature icons
            ZStack {
                // Outer ring (slow rotation)
                Circle()
                    .stroke(OnboardingColors.accentPurple.opacity(0.04), lineWidth: 1)
                    .frame(width: 210, height: 210)
                    .rotationEffect(.degrees(ringRotation))

                // Middle ring
                Circle()
                    .stroke(OnboardingColors.accentBlue.opacity(0.06), lineWidth: 1.5)
                    .frame(width: 156, height: 156)

                // Inner ring (gradient)
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [OnboardingColors.accentBlue.opacity(0.10), OnboardingColors.accentPurple.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: 106, height: 106)

                // Radial glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [OnboardingColors.accentPurple.opacity(0.12), .clear],
                            center: .center,
                            startRadius: 10,
                            endRadius: 105
                        )
                    )
                    .frame(width: 210, height: 210)

                // Central app icon
                ZStack {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(
                            LinearGradient(
                                colors: [
                                    OnboardingColors.accentPurple.opacity(0.14),
                                    OnboardingColors.accentBlue.opacity(0.10)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22)
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            OnboardingColors.accentPurple.opacity(0.16),
                                            OnboardingColors.accentBlue.opacity(0.10)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5
                                )
                        )
                        .shadow(color: OnboardingColors.accentPurple.opacity(0.08), radius: 16, y: 4)

                    Image(systemName: "waveform")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [OnboardingColors.accentBlue, OnboardingColors.accentPurple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                // Orbiting feature icons — each icon is offset upward then the whole
                // thing is rotated around center. Counter-rotate the icon to stay upright.
                orbitingIcon("mic.fill", color: .red, baseAngle: 0, radius: 96)
                orbitingIcon("bolt.fill", color: .orange, baseAngle: 72, radius: 92)
                orbitingIcon("globe", color: .blue, baseAngle: 144, radius: 96)
                orbitingIcon("lock.fill", color: .green, baseAngle: 216, radius: 90)
                orbitingIcon("text.cursor", color: .cyan, baseAngle: 288, radius: 94)
            }
            .frame(height: 220)
            .onAppear {
                withAnimation(.linear(duration: 60).repeatForever(autoreverses: false)) {
                    ringRotation = 360
                }
                withAnimation(.linear(duration: 40).repeatForever(autoreverses: false)) {
                    orbitAngle = 360
                }
            }

            // Title
            VStack(spacing: 4) {
                Text("Welcome to")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(OnboardingColors.textSecondary)
                Text("Whisperer")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [OnboardingColors.accentBlue, OnboardingColors.accentPurple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
            .padding(.top, 10)

            // Subtitle
            Text("Offline voice-to-text for your Mac.\nPowered by whisper.cpp with Apple Silicon GPU acceleration.")
                .font(.system(size: 13))
                .foregroundColor(OnboardingColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 8)

            // Feature pills — colorful with icons
            HStack(spacing: 8) {
                featurePill("Offline", icon: "wifi.slash", color: .cyan)
                featurePill("Privacy", icon: "lock.fill", color: .green)
                featurePill("Fast", icon: "bolt.fill", color: .orange)
                featurePill("100+ Languages", icon: "globe", color: OnboardingColors.accentPurple)
            }
            .padding(.top, 12)

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
                .shadow(color: OnboardingColors.accentBlue.opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(.plain).pointerOnHover()
            .padding(.top, 18)

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

                Text("Whisperer processes everything on-device.\nMicrophone access is needed to\ntranscribe — nothing leaves your Mac.")
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

            // Action buttons
            VStack(alignment: .leading, spacing: 10) {
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
                    .onAppear {
                        // Auto-advance after granting
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            withAnimation(.easeInOut(duration: 0.3)) { currentPage = 3 }
                        }
                    }
                } else {
                    Button(action: {
                        permissionManager.requestMicrophonePermission()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 13))
                            Text("Continue")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 24)
                        .background(OnboardingColors.accentGradient)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain).pointerOnHover()
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
                privacyCard(icon: "keyboard.fill", color: OnboardingColors.accentBlue, title: "Fn Hold to Dictate · ⌥+V Paste Transcription", subtitle: "Press and hold Fn to start")
                privacyCard(icon: "waveform", color: .red, title: "Speak Naturally", subtitle: "Talk at your normal pace")
                privacyCard(icon: "text.cursor", color: .green, title: "Release — Text Appears", subtitle: "Transcribed text is inserted instantly")
            }
            .padding(.leading, 36)
            .padding(.trailing, 24)
            .padding(.top, 20)

            // Action buttons
            VStack(alignment: .leading, spacing: 10) {
                if appState.systemWideDictationEnabled {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 18))
                        Text("System-Wide Dictation enabled")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.green)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    .background(Color.green.opacity(0.1))
                    .clipShape(Capsule())
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            withAnimation(.easeInOut(duration: 0.3)) { currentPage = 4 }
                        }
                    }
                } else {
                    Button(action: {
                        appState.systemWideDictationEnabled = true
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
                    .buttonStyle(.plain).pointerOnHover()

                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) { currentPage = 4 }
                    }) {
                        Text("Continue")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(OnboardingColors.textSecondary)
                            .padding(.leading, 4)
                    }
                    .buttonStyle(.plain).pointerOnHover()

                    Text("No special permissions required.\nUses the Fn key to start and stop recording.")
                        .font(.system(size: 11))
                        .foregroundColor(OnboardingColors.textTertiary)
                        .lineSpacing(2)
                        .padding(.top, 4)
                }
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

    // MARK: - Language Shortlist Page

    /// Common languages shown in the onboarding shortlist
    private static let commonLanguages: [TranscriptionLanguage] = [
        .english, .spanish, .french, .german, .italian, .portuguese,
        .russian, .chinese, .japanese, .korean, .arabic, .hebrew,
        .hindi, .turkish, .polish, .dutch, .swedish, .norwegian,
        .danish, .finnish, .czech, .greek, .romanian, .hungarian,
        .thai, .vietnamese, .indonesian, .ukrainian
    ]

    @State private var selectedLanguages: Set<TranscriptionLanguage> = [.english]
    @State private var selectedPrimary: TranscriptionLanguage = .english

    private var languageShortlistContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 16) {
                Text("Your Languages")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(OnboardingColors.textPrimary)

                Text("Select the languages you speak. Whisperer will automatically detect which one you're using and route to the best model.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(OnboardingColors.textSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                // Language grid
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ], spacing: 8) {
                        ForEach(Self.commonLanguages, id: \.self) { lang in
                            languageChip(lang)
                        }
                    }
                }
                .frame(height: 240)

                // Primary language selector
                if selectedLanguages.count > 1 {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                        Text("Primary:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(OnboardingColors.textSecondary)

                        Picker("", selection: $selectedPrimary) {
                            ForEach(Array(selectedLanguages).sorted(by: { $0.displayName < $1.displayName }), id: \.self) { lang in
                                Text(lang.displayName).tag(lang)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 28)

            Spacer()
        }
        .onAppear {
            // Pre-select English + system locale
            selectedLanguages = [.english]
            if let localeCode = Locale.current.language.languageCode?.identifier,
               let lang = TranscriptionLanguage(rawValue: localeCode),
               lang != .english {
                selectedLanguages.insert(lang)
            }
            selectedPrimary = .english

            // Load existing config if available
            let config = appState.routingConfig
            if config.allowedLanguages.count > 1 {
                selectedLanguages = Set(config.allowedLanguages)
                selectedPrimary = config.primaryLanguage ?? .english
            }
        }
        .onChange(of: selectedLanguages) { newValue in
            saveLanguageConfig()
        }
        .onChange(of: selectedPrimary) { _ in
            saveLanguageConfig()
        }
    }

    private func languageChip(_ lang: TranscriptionLanguage) -> some View {
        let isSelected = selectedLanguages.contains(lang)
        return Button(action: {
            if isSelected && selectedLanguages.count > 1 {
                selectedLanguages.remove(lang)
                if selectedPrimary == lang {
                    selectedPrimary = selectedLanguages.first ?? .english
                }
            } else {
                selectedLanguages.insert(lang)
            }
        }) {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                }
                Text(lang.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .white : OnboardingColors.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? OnboardingColors.accentBlue.opacity(0.25) : OnboardingColors.cardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? OnboardingColors.accentBlue : OnboardingColors.cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func saveLanguageConfig() {
        var config = appState.routingConfig
        config.allowedLanguages = Array(selectedLanguages)
        config.primaryLanguage = selectedPrimary
        appState.routingConfig = config
        config.save()
    }

    private var rightPanelLanguages: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.green.opacity(0.25), .clear],
                        center: .center,
                        startRadius: 20,
                        endRadius: 140
                    )
                )
                .frame(width: 280, height: 280)

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(Color.green.opacity(0.15), lineWidth: 1.5)
                        .frame(width: 140, height: 140)
                    Circle()
                        .stroke(OnboardingColors.accentBlue.opacity(0.3), lineWidth: 2)
                        .frame(width: 100, height: 100)

                    Image(systemName: "globe")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.green, OnboardingColors.accentBlue],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }

                HStack(spacing: 12) {
                    decorativeIcon("globe", size: 22, color: .green)
                    decorativeIcon("arrow.triangle.branch", size: 22, color: OnboardingColors.accentBlue)
                    decorativeIcon("cpu", size: 22, color: .orange)
                }
            }
        }
    }

    // MARK: - Page 5: Auto-Paste (Accessibility) — non-App Store only

    #if !APP_STORE
    private var accessibilityContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Auto-Paste")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(OnboardingColors.textPrimary)

                    Text("Optional")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(OnboardingColors.accentPurple)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(OnboardingColors.accentPurple.opacity(0.15))
                        .clipShape(Capsule())
                }

                Text("Automatically paste transcribed text\ninto the focused app. Without this,\ntext is copied to your clipboard.")
                    .font(.system(size: 14))
                    .foregroundColor(OnboardingColors.textSecondary)
                    .lineSpacing(3)
            }
            .padding(.leading, 36)
            .padding(.trailing, 24)

            // How it works
            VStack(spacing: 10) {
                privacyCard(icon: "doc.on.clipboard", color: OnboardingColors.accentPurple, title: "With Auto-Paste", subtitle: "Text appears where you're typing instantly")
                privacyCard(icon: "clipboard", color: .cyan, title: "Without Auto-Paste", subtitle: "Text is copied to clipboard — press ⌘V to paste")
            }
            .padding(.leading, 36)
            .padding(.trailing, 24)
            .padding(.top, 20)

            // Action buttons
            VStack(alignment: .leading, spacing: 10) {
                if appState.autoPasteEnabled && permissionManager.accessibilityStatus == .granted {
                    // Fully granted — show success and auto-complete
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 18))
                        Text("Auto-Paste enabled")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.green)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    .background(Color.green.opacity(0.1))
                    .clipShape(Capsule())
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            withAnimation(.easeInOut(duration: 0.3)) { currentPage = 5 }
                        }
                    }
                } else if appState.autoPasteEnabled {
                    // Enabled but waiting for accessibility grant in System Settings
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Waiting for Accessibility permission…")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.orange)
                                Text("System Settings should have opened.\nClick + → navigate to Whisperer → toggle ON")
                                    .font(.system(size: 11))
                                    .foregroundColor(OnboardingColors.textTertiary)
                                    .lineSpacing(2)
                            }
                        }

                        Button(action: {
                            PermissionManager.shared.openSystemSettings(for: .accessibility)
                        }) {
                            Text("Open System Settings again")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(OnboardingColors.accentBlue)
                        }
                        .buttonStyle(.plain).pointerOnHover()
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
                        // Poll for accessibility grant while user is in System Settings
                        permissionManager.recheckAccessibilityIfNeeded()
                    }

                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) { currentPage = 5 }
                    }) {
                        Text("Continue")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(OnboardingColors.textSecondary)
                            .padding(.leading, 4)
                    }
                    .buttonStyle(.plain).pointerOnHover()
                } else {
                    Button(action: {
                        appState.autoPasteEnabled = true
                        PermissionManager.shared.requestAccessibilityPermission()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 13))
                            Text("Enable Auto-Paste")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 24)
                        .background(OnboardingColors.accentGradient)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain).pointerOnHover()

                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) { currentPage = 5 }
                    }) {
                        Text("Use Clipboard Mode")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(OnboardingColors.textSecondary)
                            .padding(.leading, 4)
                    }
                    .buttonStyle(.plain).pointerOnHover()

                    Text("Requires Accessibility permission to simulate\npaste into the focused application.")
                        .font(.system(size: 11))
                        .foregroundColor(OnboardingColors.textTertiary)
                        .lineSpacing(2)
                        .padding(.top, 4)
                }
            }
            .padding(.leading, 36)
            .padding(.top, 20)

            Spacer()
        }
    }

    private var rightPanelAccessibility: some View {
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
                ZStack {
                    Circle()
                        .stroke(OnboardingColors.accentBlue.opacity(0.15), lineWidth: 1.5)
                        .frame(width: 140, height: 140)
                    Circle()
                        .stroke(OnboardingColors.accentPurple.opacity(0.3), lineWidth: 2)
                        .frame(width: 100, height: 100)

                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 44, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [OnboardingColors.accentBlue, OnboardingColors.accentPurple],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }

                HStack(spacing: 12) {
                    decorativeIcon("doc.on.clipboard", size: 22, color: OnboardingColors.accentPurple)
                    decorativeIcon("text.cursor", size: 22, color: .cyan)
                    decorativeIcon("checkmark.circle.fill", size: 22, color: .green)
                }
            }
        }
    }
    #endif

    // MARK: - Page 6: Model Download

    private var modelDownloadContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                Text("Almost Ready")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(OnboardingColors.textPrimary)

                Text("Downloading the recommended model\nfor transcription. This may take a minute.")
                    .font(.system(size: 14))
                    .foregroundColor(OnboardingColors.textSecondary)
                    .lineSpacing(3)
            }
            .padding(.leading, 36)
            .padding(.trailing, 24)

            // Model info card
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.cyan.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "cpu")
                        .font(.system(size: 17))
                        .foregroundColor(.cyan)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.selectedModel.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(OnboardingColors.textPrimary)
                    Text(appState.selectedModel.sizeDescription)
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
            .padding(.leading, 36)
            .padding(.trailing, 24)
            .padding(.top, 20)

            // Download progress
            VStack(alignment: .leading, spacing: 10) {
                if appState.isModelLoaded {
                    // Model loaded — success
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 18))
                        Text("Model ready")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.green)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    .background(Color.green.opacity(0.1))
                    .clipShape(Capsule())
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            completeOnboarding()
                        }
                    }
                } else if appState.downloadingModel != nil {
                    // Downloading
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: appState.downloadProgress)
                            .tint(OnboardingColors.accentBlue)

                        Text("Downloading... \(Int(appState.downloadProgress * 100))%")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(OnboardingColors.textSecondary)
                    }
                } else if ModelDownloader.shared.isModelDownloaded(appState.selectedModel) {
                    // Downloaded but not yet loaded
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading model...")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(OnboardingColors.textSecondary)
                    }
                } else {
                    // Not yet started (brief moment before onAppear triggers)
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing download...")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(OnboardingColors.textSecondary)
                    }
                }

                Button(action: { completeOnboarding() }) {
                    Text("Skip for Now")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(OnboardingColors.textSecondary)
                        .padding(.leading, 4)
                }
                .buttonStyle(.plain).pointerOnHover()

                if !appState.isModelLoaded {
                    Text("You can download models later\nfrom the menu bar Settings tab.")
                        .font(.system(size: 11))
                        .foregroundColor(OnboardingColors.textTertiary)
                        .lineSpacing(2)
                        .padding(.top, 4)
                }
            }
            .padding(.leading, 36)
            .padding(.trailing, 24)
            .padding(.top, 20)

            Spacer()
        }
        .onAppear {
            startModelDownloadIfNeeded()
        }
    }

    private var rightPanelModelDownload: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.cyan.opacity(0.25), .clear],
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
                        .stroke(Color.cyan.opacity(0.3), lineWidth: 2)
                        .frame(width: 100, height: 100)

                    Image(systemName: "cpu")
                        .font(.system(size: 44, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [OnboardingColors.accentBlue, .cyan],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }

                HStack(spacing: 12) {
                    decorativeIcon("cpu", size: 22, color: .cyan)
                    decorativeIcon("waveform", size: 22, color: OnboardingColors.accentBlue)
                    decorativeIcon("bolt.fill", size: 22, color: .orange)
                }
            }
        }
    }

    private func startModelDownloadIfNeeded() {
        let model = appState.selectedModel
        if ModelDownloader.shared.isModelDownloaded(model) {
            appState.preloadModel()
        } else {
            Task {
                await appState.downloadModel(model)
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

    /// Orbiting icon: offset upward by `radius`, then rotated around center by `baseAngle + orbitAngle`.
    /// The icon itself is counter-rotated so it stays upright while orbiting.
    private func orbitingIcon(_ name: String, color: Color, baseAngle: Double, radius: CGFloat) -> some View {
        let totalAngle = baseAngle + orbitAngle

        return ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(color.opacity(0.10))
                .frame(width: 32, height: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(color.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: color.opacity(0.06), radius: 4, y: 1)

            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(color.opacity(0.6))
        }
        // Counter-rotate to stay upright
        .rotationEffect(.degrees(-totalAngle))
        // Push out from center
        .offset(y: -radius)
        // Rotate into orbital position
        .rotationEffect(.degrees(totalAngle))
    }

    // MARK: - Actions

    private func completeOnboarding() {
        appState.hasCompletedOnboarding = true
        onComplete?()
    }
}
