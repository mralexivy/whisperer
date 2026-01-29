//
//  OverlayView.swift
//  Whisperer
//
//  Adaptive overlay bar matching macOS appearance (light/dark mode)
//

import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState = AppState.shared
    @State private var isPulsing = false
    @Environment(\.colorScheme) var colorScheme

    // Adaptive colors based on appearance
    private var backgroundColor: Color {
        colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.98)
    }

    private var transcriptionBackground: Color {
        colorScheme == .dark ? Color(white: 0.2) : Color.white
    }

    private var shadowOpacity: Double {
        colorScheme == .dark ? 0.4 : 0.15
    }

    private var strokeOpacity: Double {
        colorScheme == .dark ? 0.2 : 0.1
    }

    private let greenAccent = Color(red: 0.2, green: 0.78, blue: 0.35)  // Apple green

    // Show last N characters of transcription for ticker effect
    private var displayedTranscription: String {
        let text = appState.liveTranscription
        let maxChars = 120  // Show approximately 2 lines worth
        if text.count <= maxChars {
            return text
        }
        // Find a word boundary to trim at
        let suffix = String(text.suffix(maxChars))
        if let firstSpace = suffix.firstIndex(of: " ") {
            return "..." + String(suffix[suffix.index(after: firstSpace)...])
        }
        return "..." + suffix
    }

    var body: some View {
        VStack(spacing: 8) {
            // Live transcription text (shown during recording)
            if appState.state.isRecording && !appState.liveTranscription.isEmpty {
                Text(displayedTranscription)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 300, alignment: .trailing)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(transcriptionBackground)
                            .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 8, x: 0, y: 2)
                    )
                    .animation(.easeOut(duration: 0.15), value: displayedTranscription)
            }

            // Processing indicator (shown during final pass)
            if case .stopping = appState.state {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                    Text("Processing audio...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(transcriptionBackground)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 6, x: 0, y: 2)
                )
            }

            // Main control bar
            HStack(spacing: 12) {
                // Left: Recording indicator with pulsing dot
                RecordingIndicator(isRecording: appState.state.isRecording, isPulsing: $isPulsing)

                // Center: Waveform
                WaveformView(amplitudes: appState.waveformAmplitudes)
                    .frame(width: 100, height: 28)

                // Status indicator or mic button
                if case .transcribing = appState.state {
                    TranscribingIndicator()
                } else if case .downloadingModel(let progress) = appState.state {
                    DownloadIndicator(progress: progress)
                } else {
                    MicButton(isRecording: appState.state.isRecording)
                }

                // Right: Close button
                Button(action: {
                    appState.stopRecording()
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.1))
                            .frame(width: 36, height: 36)

                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.red)
                    }
                }
                .buttonStyle(.plain)
                .help("Stop and close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(backgroundColor)
                    .shadow(color: .black.opacity(shadowOpacity), radius: 12, x: 0, y: 4)
            )
            .overlay(
                Capsule()
                    .stroke(Color.gray.opacity(strokeOpacity), lineWidth: 1)
            )
        }
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

    private let greenAccent = Color(red: 0.2, green: 0.78, blue: 0.35)

    var body: some View {
        ZStack {
            // Background circle - light with green tint
            Circle()
                .fill(greenAccent.opacity(0.12))
                .frame(width: 44, height: 44)

            // Mic icon
            Image(systemName: "mic.fill")
                .font(.system(size: 18))
                .foregroundColor(greenAccent)

            // Pulsing dot (recording indicator)
            Circle()
                .fill(greenAccent)
                .frame(width: 10, height: 10)
                .scaleEffect(isRecording && isPulsing ? 1.3 : 1.0)
                .opacity(isRecording ? 1.0 : 0.4)
                .offset(x: 14, y: 14)
        }
    }
}

// MARK: - Mic Button

struct MicButton: View {
    let isRecording: Bool

    private let greenAccent = Color(red: 0.2, green: 0.78, blue: 0.35)

    var body: some View {
        ZStack {
            Circle()
                .fill(greenAccent.opacity(0.12))
                .frame(width: 36, height: 36)

            Image(systemName: isRecording ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 14))
                .foregroundColor(isRecording ? greenAccent : .secondary)
        }
    }
}

// MARK: - Transcribing Indicator

struct TranscribingIndicator: View {
    @State private var isAnimating = false

    private let greenAccent = Color(red: 0.2, green: 0.78, blue: 0.35)

    var body: some View {
        ZStack {
            Circle()
                .fill(greenAccent.opacity(0.12))
                .frame(width: 36, height: 36)

            // Animated dots
            HStack(spacing: 3) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(greenAccent)
                        .frame(width: 5, height: 5)
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

// MARK: - Download Indicator

struct DownloadIndicator: View {
    let progress: Double

    private let greenAccent = Color(red: 0.2, green: 0.78, blue: 0.35)

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.2), lineWidth: 3)
                .frame(width: 36, height: 36)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(greenAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 36, height: 36)
                .rotationEffect(.degrees(-90))

            Text("\(Int(progress * 100))")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.primary)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        OverlayView()
    }
    .padding(40)
    .background(Color.gray.opacity(0.3))
}
