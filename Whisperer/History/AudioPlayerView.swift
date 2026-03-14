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

                // Playhead — outside the mask so it doesn't get clipped
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: WhispererColors.accent.opacity(0.5), radius: 4, y: 2)
                    .shadow(color: Color.white.opacity(0.3), radius: 2, y: 0)
                    .offset(x: geometry.size.width * CGFloat(player.progress) - 5)
            }
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
                Button(action: { player.setPlaybackRate(rate) }) {
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

    override init() {
        super.init()
        if UserDefaults.standard.object(forKey: "audioPlaybackSpeed") != nil {
            playbackRate = UserDefaults.standard.float(forKey: "audioPlaybackSpeed")
        }
    }

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
        UserDefaults.standard.set(rate, forKey: "audioPlaybackSpeed")
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
