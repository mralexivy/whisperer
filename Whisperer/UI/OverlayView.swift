//
//  OverlayView.swift
//  Whisperer
//
//  Overlay bar — dark navy theme matching workspace & onboarding
//

import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState = AppState.shared
    @AppStorage("overlaySize") private var overlaySizeRaw: String = OverlaySize.medium.rawValue
    @State private var isPulsing = false
    @State private var isCloseHovered = false

    private var scale: CGFloat {
        (OverlaySize(rawValue: overlaySizeRaw) ?? .medium).scale
    }

    // Dark navy palette — always dark, matches workspace & onboarding
    private let hudBackground = Color(red: 0.078, green: 0.078, blue: 0.169)      // #14142B
    private let hudBorder = Color.white.opacity(0.06)
    private let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969)          // #5B6CF7
    private let purpleAccent = Color(red: 0.545, green: 0.361, blue: 0.965)        // #8B5CF6

    #if APP_STORE
    private var accentColor: Color { blueAccent }
    #else
    private var accentColor: Color {
        appState.activeMode == .rewrite ? purpleAccent : blueAccent
    }
    #endif

    // Scaled dimensions
    private var circleSize: CGFloat { 44 * scale }
    private var buttonSize: CGFloat { 36 * scale }
    private var waveformWidth: CGFloat { 100 * scale }
    private var waveformHeight: CGFloat { 28 * scale }
    private var appIconSize: CGFloat { 20 * scale }
    private var hPadding: CGFloat { 16 * scale }
    private var vPadding: CGFloat { 10 * scale }
    private var spacing: CGFloat { 12 * scale }

    var body: some View {
        VStack(spacing: 8 * scale) {
            if appState.showClipboardToast {
                ClipboardToastIndicator(scale: scale)
            } else if appState.showModelLoadingToast {
                ModelLoadingIndicator(scale: scale)
            } else if appState.state != .idle {
                // Live transcription card (shown during recording)
                if appState.liveTranscriptionEnabled && appState.state.isRecording {
                    LiveTranscriptionCard(appState: appState)
                }

                // Processing indicator (shown during final pass or rewrite)
                if case .stopping = appState.state {
                    if let aiModeName = appState.activeAIModeName {
                        AnimatedStatusCapsule(
                            text: aiModeName,
                            borderColor: purpleAccent,
                            scale: scale
                        )
                    } else {
                        ProcessingIndicator(scale: scale)
                    }
                } else if case .rewriting = appState.state {
                    AnimatedStatusCapsule(
                        text: appState.activeAIModeName ?? "Rewriting",
                        borderColor: purpleAccent,
                        scale: scale
                    )
                }

                // Download indicator (shown during model download)
                if case .downloadingModel = appState.state {
                    DownloadingIndicator(scale: scale)
                }

                // Main control bar — crossfades to hands-free toast when activated
                ZStack {
                    // Normal recording controls
                    HStack(spacing: spacing) {
                        RecordingIndicator(isRecording: appState.state.isRecording, isPulsing: $isPulsing, scale: scale)

                        if let icon = appState.targetAppIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: appIconSize, height: appIconSize)
                                .clipShape(RoundedRectangle(cornerRadius: 4 * scale))
                        }

                        WaveformView(amplitudes: appState.waveformAmplitudes)
                            .frame(width: waveformWidth, height: waveformHeight)

                        if case .transcribing = appState.state {
                            TranscribingIndicator(scale: scale)
                        } else if case .rewriting = appState.state {
                            TranscribingIndicator(scale: scale)
                        } else if case .downloadingModel(let progress) = appState.state {
                            DownloadIndicator(progress: progress, scale: scale)
                        } else {
                            MicMuteButton(isMuted: $appState.isMicMuted, scale: scale)
                        }

                        Button(action: {
                            appState.stopRecording()
                        }) {
                            ZStack {
                                Circle()
                                    .fill(Color.red.opacity(isCloseHovered ? 0.25 : 0.1))
                                    .frame(width: buttonSize, height: buttonSize)

                                Image(systemName: "xmark")
                                    .font(.system(size: 14 * scale, weight: .bold))
                                    .foregroundColor(isCloseHovered ? .red.opacity(1) : .red.opacity(0.7))
                            }
                            .scaleEffect(isCloseHovered ? 1.12 : 1.0)
                            .animation(.easeOut(duration: 0.15), value: isCloseHovered)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            isCloseHovered = hovering
                        }
                        .help("Stop and close")
                        .accessibilityLabel("Stop recording and close")
                    }
                    .opacity(appState.showHandsFreeToast ? 0 : 1)

                    // Hands-free toast (replaces controls for 3s)
                    if appState.showHandsFreeToast {
                        HandsFreeToastContent(scale: scale)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, hPadding)
                .padding(.vertical, vPadding)
                .background(
                    Capsule()
                        .fill(hudBackground)
                )
                .overlay(
                    Capsule()
                        .stroke(appState.showHandsFreeToast ? blueAccent.opacity(0.2) : hudBorder, lineWidth: 1)
                )
                .shadow(color: appState.showHandsFreeToast ? blueAccent.opacity(0.1) : .clear, radius: 8, y: 2)
                .animation(.easeInOut(duration: 0.3), value: appState.showHandsFreeToast)
            }
        }
        .environment(\.overlayScale, scale)
        .background(Color.clear)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

// MARK: - Recording Indicator

struct RecordingIndicator: View {
    let isRecording: Bool
    @Binding var isPulsing: Bool
    var scale: CGFloat = 1.0
    @State private var dotPulsing = false

    private let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969)  // #5B6CF7

    var body: some View {
        ZStack {
            Circle()
                .fill(blueAccent.opacity(0.15))
                .frame(width: 44 * scale, height: 44 * scale)

            Image(systemName: "mic.fill")
                .font(.system(size: 18 * scale))
                .foregroundColor(blueAccent)

            // Recording dot — gentle breathing pulse
            Circle()
                .fill(blueAccent)
                .frame(width: 10 * scale, height: 10 * scale)
                .scaleEffect(dotPulsing ? 1.2 : 0.9)
                .opacity(dotPulsing ? 1.0 : 0.55)
                .offset(x: 14 * scale, y: 14 * scale)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: dotPulsing)
        }
        .onChange(of: isRecording) { recording in
            dotPulsing = recording
        }
        .onAppear {
            if isRecording {
                dotPulsing = true
            }
        }
    }
}

// MARK: - Mic Mute Button

struct MicMuteButton: View {
    @Binding var isMuted: Bool
    var scale: CGFloat = 1.0
    @State private var isHovered = false

    private let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969)  // #5B6CF7

    var body: some View {
        Button(action: {
            isMuted.toggle()
        }) {
            ZStack {
                Circle()
                    .fill(isMuted
                        ? Color.orange.opacity(isHovered ? 0.3 : 0.15)
                        : blueAccent.opacity(isHovered ? 0.3 : 0.15))
                    .frame(width: 36 * scale, height: 36 * scale)

                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 14 * scale))
                    .foregroundColor(isMuted ? .orange : blueAccent)
            }
            .scaleEffect(isHovered ? 1.12 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(isMuted ? "Unmute microphone" : "Mute microphone")
        .accessibilityLabel(isMuted ? "Unmute microphone" : "Mute microphone")
    }
}

// MARK: - Transcribing Indicator

struct TranscribingIndicator: View {
    var scale: CGFloat = 1.0
    @State private var isAnimating = false

    private let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969)  // #5B6CF7

    var body: some View {
        ZStack {
            Circle()
                .fill(blueAccent.opacity(0.15))
                .frame(width: 36 * scale, height: 36 * scale)

            HStack(spacing: 3 * scale) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(blueAccent)
                        .frame(width: 5 * scale, height: 5 * scale)
                        .scaleEffect(isAnimating ? 1.0 : 0.5)
                        .animation(
                            .easeInOut(duration: 0.5)
                            .repeatForever()
                            .delay(Double(index) * 0.15),
                            value: isAnimating
                        )
                }
            }
        }
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Animated Status Capsule (shared by Processing, Downloading, Loading)

private struct AnimatedStatusCapsule: View {
    let text: String
    let borderColor: Color
    var scale: CGFloat = 1.0
    @State private var isAnimating = false

    private let hudBackground = Color(red: 0.078, green: 0.078, blue: 0.169)
    private let accentBlue = Color(red: 0.357, green: 0.424, blue: 0.969)
    private let accentPurple = Color(red: 0.545, green: 0.361, blue: 0.965)

    var body: some View {
        HStack(spacing: 8 * scale) {
            HStack(spacing: 3 * scale) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5 * scale)
                        .fill(
                            LinearGradient(
                                colors: [accentBlue, accentPurple],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 3 * scale, height: isAnimating ? barHeight(for: index) : 4 * scale)
                        .animation(
                            .easeInOut(duration: duration(for: index))
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.12),
                            value: isAnimating
                        )
                }
            }
            .frame(height: 14 * scale)

            Text(text)
                .font(.system(size: 12 * scale, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(.horizontal, 14 * scale)
        .padding(.vertical, 8 * scale)
        .background(
            Capsule()
                .fill(hudBackground)
                .overlay(
                    Capsule()
                        .stroke(borderColor.opacity(0.15), lineWidth: 1)
                )
        )
        .onAppear {
            isAnimating = false
            DispatchQueue.main.async {
                isAnimating = true
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let heights: [CGFloat] = [10, 14, 8, 12]
        return heights[index % heights.count] * scale
    }

    private func duration(for index: Int) -> Double {
        [0.5, 0.4, 0.6, 0.45][index % 4]
    }
}

// MARK: - Processing Indicator

struct ProcessingIndicator: View {
    var scale: CGFloat = 1.0
    private let accentPurple = Color(red: 0.545, green: 0.361, blue: 0.965)

    var body: some View {
        AnimatedStatusCapsule(text: "Processing", borderColor: accentPurple, scale: scale)
    }
}

// MARK: - Download Indicator (top bar — animated like ProcessingIndicator)

struct DownloadingIndicator: View {
    var scale: CGFloat = 1.0
    private let accentBlue = Color(red: 0.357, green: 0.424, blue: 0.969)

    var body: some View {
        AnimatedStatusCapsule(text: "Downloading...", borderColor: accentBlue, scale: scale)
    }
}

// MARK: - Download Indicator (inline, for HUD bar)

struct DownloadIndicator: View {
    let progress: Double
    var scale: CGFloat = 1.0

    private let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969)  // #5B6CF7

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 3 * scale)
                .frame(width: 36 * scale, height: 36 * scale)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(blueAccent, style: StrokeStyle(lineWidth: 3 * scale, lineCap: .round))
                .frame(width: 36 * scale, height: 36 * scale)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: progress)

            Text("\(Int(progress * 100))")
                .font(.system(size: 10 * scale, weight: .bold))
                .foregroundColor(.white)
                .monospacedDigit()
        }
    }
}

// MARK: - Model Loading Toast

struct ModelLoadingIndicator: View {
    var scale: CGFloat = 1.0
    private let accentPurple = Color(red: 0.545, green: 0.361, blue: 0.965)

    var body: some View {
        AnimatedStatusCapsule(text: "Loading model...", borderColor: accentPurple, scale: scale)
    }
}

// MARK: - Clipboard Toast Indicator

struct ClipboardToastIndicator: View {
    var scale: CGFloat = 1.0
    @State private var checkmarkScale: CGFloat = 0.0
    @State private var checkmarkOpacity: Double = 0.0
    @State private var textOpacity: Double = 0.0
    @State private var ringProgress: CGFloat = 0.0

    private let hudBackground = Color(red: 0.078, green: 0.078, blue: 0.169)
    private let accentGreen = Color(red: 0.286, green: 0.824, blue: 0.506)   // #49D281
    private let accentBlue = Color(red: 0.357, green: 0.424, blue: 0.969)    // #5B6CF7

    var body: some View {
        HStack(spacing: 12 * scale) {
            // Animated checkmark circle
            ZStack {
                // Background ring
                Circle()
                    .stroke(accentGreen.opacity(0.15), lineWidth: 2 * scale)
                    .frame(width: 30 * scale, height: 30 * scale)

                // Animated progress ring
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(accentGreen, style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
                    .frame(width: 30 * scale, height: 30 * scale)
                    .rotationEffect(.degrees(-90))

                // Checkmark icon
                Image(systemName: "checkmark")
                    .font(.system(size: 13 * scale, weight: .bold))
                    .foregroundColor(accentGreen)
                    .scaleEffect(checkmarkScale)
                    .opacity(checkmarkOpacity)
            }

            // Text content
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text("Copied to Clipboard")
                    .font(.system(size: 13 * scale, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                HStack(spacing: 4 * scale) {
                    Text("Press")
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))

                    // Key cap style ⌘V
                    HStack(spacing: 2 * scale) {
                        Text("⌘")
                            .font(.system(size: 11 * scale, weight: .semibold))
                        Text("V")
                            .font(.system(size: 10 * scale, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 5 * scale)
                    .padding(.vertical, 2 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 4 * scale)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4 * scale)
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                    )

                    Text("to paste")
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            .opacity(textOpacity)
        }
        .padding(.horizontal, 16 * scale)
        .padding(.vertical, 10 * scale)
        .background(
            Capsule()
                .fill(hudBackground)
                .overlay(
                    Capsule()
                        .stroke(accentGreen.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: accentGreen.opacity(0.1), radius: 8, y: 2)
        )
        .onAppear {
            // Ring draws in
            withAnimation(.easeOut(duration: 0.4)) {
                ringProgress = 1.0
            }
            // Checkmark pops in after ring completes
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6).delay(0.3)) {
                checkmarkScale = 1.0
                checkmarkOpacity = 1.0
            }
            // Text fades in
            withAnimation(.easeOut(duration: 0.3).delay(0.15)) {
                textOpacity = 1.0
            }
        }
    }
}

// MARK: - Hands-Free Toast Content (displayed inside the HUD capsule)

struct HandsFreeToastContent: View {
    var scale: CGFloat = 1.0
    @State private var iconScale: CGFloat = 0.0
    @State private var iconOpacity: Double = 0.0
    @State private var textOpacity: Double = 0.0
    @State private var ringProgress: CGFloat = 0.0

    private let accentBlue = Color(red: 0.357, green: 0.424, blue: 0.969)      // #5B6CF7

    var body: some View {
        HStack(spacing: 12 * scale) {
            // Animated icon circle
            ZStack {
                Circle()
                    .stroke(accentBlue.opacity(0.15), lineWidth: 2 * scale)
                    .frame(width: 30 * scale, height: 30 * scale)

                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(accentBlue, style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
                    .frame(width: 30 * scale, height: 30 * scale)
                    .rotationEffect(.degrees(-90))

                Image(systemName: "mic.fill")
                    .font(.system(size: 13 * scale, weight: .bold))
                    .foregroundColor(accentBlue)
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)
            }

            // Text content
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text("Hands-Free Mode")
                    .font(.system(size: 13 * scale, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                HStack(spacing: 4 * scale) {
                    Text("Press")
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))

                    Text("Fn")
                        .font(.system(size: 10 * scale, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 5 * scale)
                        .padding(.vertical, 2 * scale)
                        .background(
                            RoundedRectangle(cornerRadius: 4 * scale)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4 * scale)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )

                    Text("to stop")
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            .opacity(textOpacity)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                ringProgress = 1.0
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6).delay(0.3)) {
                iconScale = 1.0
                iconOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.3).delay(0.15)) {
                textOpacity = 1.0
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        OverlayView()
        ClipboardToastIndicator()
        HandsFreeToastContent()
    }
    .padding(40)
    .background(Color.black)
}
