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

    private var scale: CGFloat {
        (OverlaySize(rawValue: overlaySizeRaw) ?? .medium).scale
    }

    // Dark navy palette — always dark, matches workspace & onboarding
    private let hudBackground = Color(red: 0.078, green: 0.078, blue: 0.169)      // #14142B
    private let hudBorder = Color.white.opacity(0.06)
    private let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969)          // #5B6CF7
    private let purpleAccent = Color(red: 0.545, green: 0.361, blue: 0.965)        // #8B5CF6

    private var accentColor: Color {
        appState.activeMode == .rewrite ? purpleAccent : blueAccent
    }

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
            if appState.showModelLoadingToast {
                ModelLoadingIndicator(scale: scale)
            } else if appState.state != .idle {
                // Live transcription card (shown during recording)
                if appState.liveTranscriptionEnabled && appState.state.isRecording {
                    LiveTranscriptionCard(appState: appState)
                }

                // Processing indicator (shown during final pass)
                if case .stopping = appState.state {
                    ProcessingIndicator(scale: scale)
                }

                // Download indicator (shown during model download)
                if case .downloadingModel = appState.state {
                    DownloadingIndicator(scale: scale)
                }

                // Rewrite mode label
                if appState.activeMode == .rewrite {
                    Text("REWRITE MODE")
                        .font(.system(size: 10 * scale, weight: .bold, design: .rounded))
                        .tracking(1.0)
                        .foregroundColor(purpleAccent)
                }

                // Main control bar
                HStack(spacing: spacing) {
                    // Left: Recording indicator with pulsing dot
                    RecordingIndicator(isRecording: appState.state.isRecording, isPulsing: $isPulsing, scale: scale)

                    // Target app icon
                    if let icon = appState.targetAppIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: appIconSize, height: appIconSize)
                            .clipShape(RoundedRectangle(cornerRadius: 4 * scale))
                    }

                    // Center: Waveform
                    WaveformView(amplitudes: appState.waveformAmplitudes)
                        .frame(width: waveformWidth, height: waveformHeight)

                    // Status indicator or mic button
                    if case .transcribing = appState.state {
                        TranscribingIndicator(scale: scale)
                    } else if case .downloadingModel(let progress) = appState.state {
                        DownloadIndicator(progress: progress, scale: scale)
                    } else {
                        MicButton(isRecording: appState.state.isRecording, scale: scale)
                    }

                    // Right: Close button
                    Button(action: {
                        appState.stopRecording()
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.red.opacity(0.1))
                                .frame(width: buttonSize, height: buttonSize)

                            Image(systemName: "xmark")
                                .font(.system(size: 14 * scale, weight: .bold))
                                .foregroundColor(.red)
                        }
                    }
                    .buttonStyle(.plain).pointerOnHover()
                    .help("Stop and close")
                    .accessibilityLabel("Stop recording and close")
                }
                .padding(.horizontal, hPadding)
                .padding(.vertical, vPadding)
                .background(
                    Capsule()
                        .fill(hudBackground)
                )
                .overlay(
                    Capsule()
                        .stroke(hudBorder, lineWidth: 1)
                )
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

    private let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969)  // #5B6CF7

    var body: some View {
        ZStack {
            Circle()
                .fill(blueAccent.opacity(0.15))
                .frame(width: 44 * scale, height: 44 * scale)

            Image(systemName: "mic.fill")
                .font(.system(size: 18 * scale))
                .foregroundColor(blueAccent)

            Circle()
                .fill(blueAccent)
                .frame(width: 10 * scale, height: 10 * scale)
                .scaleEffect(isRecording && isPulsing ? 1.3 : 1.0)
                .opacity(isRecording ? 1.0 : 0.4)
                .offset(x: 14 * scale, y: 14 * scale)
        }
    }
}

// MARK: - Mic Button

struct MicButton: View {
    let isRecording: Bool
    var scale: CGFloat = 1.0

    private let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969)  // #5B6CF7

    var body: some View {
        ZStack {
            Circle()
                .fill(blueAccent.opacity(0.15))
                .frame(width: 36 * scale, height: 36 * scale)

            Image(systemName: isRecording ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 14 * scale))
                .foregroundColor(isRecording ? blueAccent : .white.opacity(0.4))
        }
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
        .onAppear { isAnimating = true }
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

#Preview {
    VStack(spacing: 20) {
        OverlayView()
    }
    .padding(40)
    .background(Color.black)
}
