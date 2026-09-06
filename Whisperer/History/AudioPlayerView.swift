//
//  AudioPlayerView.swift
//  Whisperer
//
//  Audio playback with waveform visualization — Matching Whisperer design.
//  Backed by SeekableAudioPlayer (AVAudioEngine) so seeks on Ogg Opus files
//  actually reposition the decoder.
//

import SwiftUI
import AVFoundation

struct AudioPlayerView: View {
    @Environment(\.colorScheme) var colorScheme
    let audioURL: URL
    /// Metadata duration used as a placeholder label until the file finishes loading.
    let duration: Double

    @StateObject private var player = SeekableAudioPlayer()
    @State private var waveformData: [Float] = []

    // Scrub state
    @State private var scrubProgress: CGFloat = 0
    @State private var lastThrottledSeek: Date = .distantPast
    private let seekThrottleInterval: TimeInterval = 0.1

    var body: some View {
        VStack(spacing: 16) {
            // Waveform
            waveformView
                .frame(height: 56)
                .padding(.horizontal, 8)

            // Controls
            HStack(spacing: 16) {
                playButton
                timeDisplay
                Spacer()
                speedControl
            }
        }
        .onAppear {
            player.load(url: audioURL)
            waveformData = WaveformGenerator.generateWaveform(from: audioURL, sampleCount: 70)
        }
        .onDisappear {
            player.stop()
        }
    }

    // MARK: - Waveform

    private var waveformView: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background bars
                HStack(spacing: 2) {
                    ForEach(0..<waveformData.count, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(WhispererColors.secondaryText(colorScheme).opacity(0.25))
                            .frame(height: max(4, CGFloat(waveformData[index]) * 56))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .mask(verticalFadeMask)

                // Progress bars
                HStack(spacing: 2) {
                    ForEach(0..<waveformData.count, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(WhispererColors.accent)
                            .frame(height: max(4, CGFloat(waveformData[index]) * 56))
                            .shadow(color: WhispererColors.accent.opacity(0.4), radius: 3, y: 0)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .mask(
                    Rectangle()
                        .frame(width: geometry.size.width * displayProgress)
                        .frame(maxWidth: .infinity, alignment: .leading)
                )
                .mask(verticalFadeMask)

                // Playhead
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: WhispererColors.accent.opacity(0.5), radius: 4, y: 2)
                    .shadow(color: Color.white.opacity(0.3), radius: 2, y: 0)
                    .offset(x: geometry.size.width * displayProgress - 5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard player.duration > 0 else { return }
                        let p = max(0, min(1, value.location.x / geometry.size.width))
                        scrubProgress = p
                        player.isScrubbing = true

                        // Throttle actual seeks to ~10 Hz
                        let now = Date()
                        if now.timeIntervalSince(lastThrottledSeek) > seekThrottleInterval {
                            lastThrottledSeek = now
                            player.seek(to: Double(p) * player.duration)
                        }
                    }
                    .onEnded { value in
                        guard player.duration > 0 else { return }
                        let p = max(0, min(1, value.location.x / geometry.size.width))
                        player.seek(to: Double(p) * player.duration)
                        player.isScrubbing = false
                        // Restart playback if it was playing before the drag.
                        if player.isPlaying { player.play() }
                    }
            )
        }
    }

    /// Progress fraction for the playhead UI: uses the scrub position while dragging.
    private var displayProgress: CGFloat {
        player.isScrubbing ? scrubProgress : CGFloat(player.progress)
    }

    private var verticalFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: 0.15),
                .init(color: .white, location: 0.85),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Play Button

    @State private var isPlayButtonHovered = false

    private var playButton: some View {
        Button(action: togglePlayback) {
            ZStack {
                Circle()
                    .fill(WhispererColors.accent)
                    .frame(width: 44, height: 44)
                    .shadow(
                        color: WhispererColors.accent.opacity(isPlayButtonHovered ? 0.4 : 0.25),
                        radius: isPlayButtonHovered ? 10 : 6,
                        y: isPlayButtonHovered ? 3 : 2
                    )

                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .offset(x: player.isPlaying ? 0 : 1)
            }
            .scaleEffect(isPlayButtonHovered ? 1.06 : 1.0)
        }
        .buttonStyle(.plain).pointerOnHover()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isPlayButtonHovered = hovering
            }
        }
        .disabled(player.duration == 0)
    }

    // MARK: - Time Display

    private var timeDisplay: some View {
        HStack(spacing: 6) {
            // Show scrub position while dragging; use player's loaded duration once known.
            let displayTime = player.isScrubbing
                ? scrubProgress * CGFloat(player.duration > 0 ? player.duration : duration)
                : CGFloat(player.currentTime)
            let displayDuration = player.duration > 0 ? player.duration : duration

            Text(timeString(Double(displayTime)))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(WhispererColors.primaryText(colorScheme))

            Text("/")
                .font(.system(size: 11))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))

            Text(timeString(displayDuration))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))
        }
    }

    // MARK: - Speed Control

    @State private var isSpeedHovered = false

    private func speedLabel(_ rate: Float) -> String {
        if rate == 1.0 { return "1x" }
        if rate == floor(rate) { return "\(Int(rate))x" }
        return "\(String(format: "%.2g", rate))x"
    }

    private var speedAccentColor: Color {
        player.playbackRate != 1.0 ? .orange : WhispererColors.secondaryText(colorScheme)
    }

    private var speedControl: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { rate in
                Button(action: { player.setRate(rate) }) {
                    HStack {
                        Text(speedLabel(rate))
                        if player.playbackRate == rate {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(speedAccentColor.opacity(0.15))
                        .frame(width: 22, height: 22)
                    Image(systemName: "speedometer")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(speedAccentColor)
                }
                Text(speedLabel(player.playbackRate))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(speedAccentColor)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(speedAccentColor.opacity(0.6))
            }
            .padding(.leading, 5)
            .padding(.trailing, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(speedAccentColor.opacity(isSpeedHovered ? 0.12 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(speedAccentColor.opacity(isSpeedHovered ? 0.2 : 0.1), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isSpeedHovered = hovering
            }
        }
    }

    // MARK: - Actions

    private func togglePlayback() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
