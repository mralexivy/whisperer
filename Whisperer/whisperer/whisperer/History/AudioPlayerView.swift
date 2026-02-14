//
//  AudioPlayerView.swift
//  Whisperer
//
//  Audio playback with waveform visualization - Matching Whisperer design
//

import SwiftUI
import AVFoundation
import Combine

struct AudioPlayerView: View {
    @Environment(\.colorScheme) var colorScheme
    let audioURL: URL
    let duration: Double

    @StateObject private var player = AudioPlayer()
    @State private var waveformData: [Float] = []
    @State private var isHoveringWaveform = false
    @State private var hoverProgress: CGFloat = 0

    var body: some View {
        VStack(spacing: 16) {
            // Waveform
            waveformView
                .frame(height: 56)
                .padding(.horizontal, 4)

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

                // Progress bars with glow
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
                        .frame(width: geometry.size.width * CGFloat(player.progress))
                        .frame(maxWidth: .infinity, alignment: .leading)
                )

                // Playhead
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: WhispererColors.accent.opacity(0.5), radius: 4, y: 2)
                    .offset(x: geometry.size.width * CGFloat(player.progress) - 5)
            }
            // Vertical fade — bars fade out at top and bottom edges
            .mask(
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
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let progress = max(0, min(1, value.location.x / geometry.size.width))
                        player.seek(to: Double(progress) * duration)
                    }
            )
        }
    }

    // MARK: - Play Button

    private var playButton: some View {
        Button(action: togglePlayback) {
            ZStack {
                Circle()
                    .fill(WhispererColors.accent)
                    .frame(width: 44, height: 44)

                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .offset(x: player.isPlaying ? 0 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Time Display

    private var timeDisplay: some View {
        HStack(spacing: 6) {
            Text(timeString(player.currentTime))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(WhispererColors.primaryText(colorScheme))

            Text("/")
                .font(.system(size: 11))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))

            Text(timeString(duration))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))
        }
    }

    // MARK: - Speed Control

    private var speedControl: some View {
        Menu {
            Button("0.5x") { player.setPlaybackRate(0.5) }
            Button("0.75x") { player.setPlaybackRate(0.75) }
            Button("1x") { player.setPlaybackRate(1.0) }
            Button("1.25x") { player.setPlaybackRate(1.25) }
            Button("1.5x") { player.setPlaybackRate(1.5) }
            Button("2x") { player.setPlaybackRate(2.0) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "speedometer")
                    .font(.system(size: 11))
                Text(player.playbackRate == 1.0 ? "1x" : "\(String(format: "%.2g", player.playbackRate))x")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(WhispererColors.secondaryText(colorScheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(WhispererColors.elevatedBackground(colorScheme))
            )
        }
        .menuStyle(.borderlessButton)
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
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Audio Player

class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var progress: Double = 0
    @Published var playbackRate: Float = 1.0

    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?

    func load(url: URL) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.enableRate = true
            audioPlayer?.prepareToPlay()
        } catch {
            Logger.error("Failed to load audio: \(error)", subsystem: .app)
        }
    }

    func play() {
        audioPlayer?.rate = playbackRate
        audioPlayer?.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        audioPlayer?.stop()
        isPlaying = false
        stopTimer()
    }

    func seek(to time: Double) {
        audioPlayer?.currentTime = time
        updateProgress()
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            audioPlayer?.rate = rate
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateProgress()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateProgress() {
        guard let player = audioPlayer else { return }
        currentTime = player.currentTime
        progress = player.duration > 0 ? player.currentTime / player.duration : 0
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        stopTimer()
        currentTime = 0
        progress = 0
    }
}
