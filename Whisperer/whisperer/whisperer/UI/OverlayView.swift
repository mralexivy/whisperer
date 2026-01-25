//
//  OverlayView.swift
//  Whisperer
//
//  FaceTime-style overlay bar
//

import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState = AppState.shared
    @State private var isPulsing = false

    private let darkGreen = Color(red: 0.12, green: 0.18, blue: 0.15)

    var body: some View {
        VStack(spacing: 8) {
            // Live transcription text (shown during recording)
            if appState.state.isRecording && !appState.liveTranscription.isEmpty {
                Text(appState.liveTranscription)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(darkGreen.opacity(0.95))
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
                    // Show transcribing indicator
                    TranscribingIndicator()
                } else if case .downloadingModel(let progress) = appState.state {
                    // Show download progress
                    DownloadIndicator(progress: progress)
                } else {
                    // Mic button
                    MicButton(isRecording: appState.state.isRecording)
                }

                // Right: Close button
                Button(action: {
                    appState.stopRecording()
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 36, height: 36)

                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
                .help("Stop and close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(darkGreen)
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

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(Color(red: 0.2, green: 0.25, blue: 0.22))
                .frame(width: 44, height: 44)

            // Mic icon
            Image(systemName: "mic.fill")
                .font(.system(size: 18))
                .foregroundColor(Color(red: 0.3, green: 0.85, blue: 0.5))

            // Pulsing green dot (recording indicator)
            Circle()
                .fill(Color(red: 0.2, green: 0.9, blue: 0.4))
                .frame(width: 10, height: 10)
                .scaleEffect(isRecording && isPulsing ? 1.2 : 1.0)
                .opacity(isRecording ? 1.0 : 0.5)
                .offset(x: 14, y: 14)
        }
    }
}

// MARK: - Mic Button

struct MicButton: View {
    let isRecording: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.2, green: 0.25, blue: 0.22))
                .frame(width: 36, height: 36)

            Image(systemName: isRecording ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.8))
        }
    }
}

// MARK: - Transcribing Indicator

struct TranscribingIndicator: View {
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.2, green: 0.25, blue: 0.22))
                .frame(width: 36, height: 36)

            Image(systemName: "waveform")
                .font(.system(size: 14))
                .foregroundColor(Color(red: 0.3, green: 0.85, blue: 0.5))
                .rotationEffect(.degrees(rotation))
        }
        .onAppear {
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Download Indicator

struct DownloadIndicator: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                .frame(width: 36, height: 36)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color(red: 0.3, green: 0.85, blue: 0.5), lineWidth: 3)
                .frame(width: 36, height: 36)
                .rotationEffect(.degrees(-90))

            Text("\(Int(progress * 100))")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        OverlayView()

        // Preview with mock recording state
        HStack(spacing: 12) {
            RecordingIndicator(isRecording: true, isPulsing: .constant(true))
            WaveformView(amplitudes: [0.3, 0.5, 0.8, 0.6, 0.4, 0.7, 0.9, 0.5])
                .frame(width: 100, height: 28)
            MicButton(isRecording: true)
            ZStack {
                Circle().fill(Color.red).frame(width: 36, height: 36)
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color(red: 0.12, green: 0.18, blue: 0.15)))
    }
    .padding(40)
    .background(Color.black)
}
