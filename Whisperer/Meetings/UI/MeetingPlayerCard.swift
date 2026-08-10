//
//  MeetingPlayerCard.swift
//  Whisperer
//
//  Audio player card — identical structure to the Audio Recording section
//  in TranscriptionDetailView: section label + reveal-in-finder + AudioPlayerView layout.
//

import SwiftUI
import AVFoundation
import Combine

// MARK: - Player model

@MainActor
class MeetingAudioPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var isLoading = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var playbackRate: Float = 1.0
    @Published var loadedURL: URL?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    func load(url: URL) {
        stop()
        isLoading = true
        let capturedURL = url
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let p = try? AVAudioPlayer(contentsOf: capturedURL) else {
                await MainActor.run { self?.isLoading = false }
                return
            }
            p.enableRate = true
            p.prepareToPlay()
            let dur = p.duration
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.player = p
                self.duration = dur
                self.currentTime = 0
                self.isLoading = false
                self.loadedURL = capturedURL
            }
        }
    }

    func play() {
        guard let p = player else { return }
        p.rate = playbackRate
        p.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        player?.stop()
        isPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        loadedURL = nil
        stopTimer()
    }

    func seek(to time: Double) {
        currentTime = max(0, min(time, duration))
        player?.currentTime = currentTime
    }

    func skipBack(_ seconds: Double = 15) { seek(to: currentTime - seconds) }
    func skipForward(_ seconds: Double = 30) { seek(to: currentTime + seconds) }

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { player?.rate = rate }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            Task { @MainActor in
                self.currentTime = p.currentTime
                if !p.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    self.currentTime = 0
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Card view

struct MeetingPlayerCard: View {
    let meeting: MeetingRecord?
    @ObservedObject var session: MeetingSession
    @ObservedObject var player: MeetingAudioPlayer

    @State private var waveformData: [Float] = []
    @State private var isPlayButtonHovered = false
    @State private var isSpeedHovered = false

    private var audioURL: URL? { meeting?.resolvedAudioURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — matches audioSection header in TranscriptionDetailView
            HStack {
                audioSectionLabel
                Spacer()
                if let url = audioURL, FileManager.default.fileExists(atPath: url.path) {
                    RevealInFinderButton(url: url, colorScheme: .dark)
                        .help("Show in Finder")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            // Player — matches AudioPlayerView layout exactly
            VStack(spacing: 16) {
                waveformView
                    .frame(height: 56)
                    .padding(.horizontal, 8)

                HStack(spacing: 16) {
                    playButton
                    timeDisplay
                    Spacer()
                    speedControl
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(WhispererColors.cardBackground(.dark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(WhispererColors.border(.dark), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 4, y: 1)
        .overlay(playerLoadingOverlay)
        .onChange(of: meeting?.id) { _, _ in loadWaveform() }
        .onChange(of: meeting?.audioFileURL) { _, _ in loadWaveform() }
        .onChange(of: player.loadedURL) { _, url in
            if let url, waveformData.isEmpty { loadWaveformFrom(url) }
        }
        .onAppear { loadWaveform() }
    }

    // MARK: - Loading overlay

    @ViewBuilder
    private var playerLoadingOverlay: some View {
        if player.isLoading {
            RoundedRectangle(cornerRadius: 14)
                .fill(WhispererColors.cardBackground(.dark).opacity(0.85))
                .overlay(
                    VStack(spacing: 10) {
                        PlayerLoadingDots()
                        Text("Loading recording…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                    }
                )
        }
    }

    // MARK: - Section label (matches sectionLabel in TranscriptionDetailView)

    private var audioSectionLabel: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.red.opacity(0.15))
                    .frame(width: 24, height: 24)
                    .shadow(color: Color.red.opacity(0.06), radius: 2, y: 1)

                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.red)
            }

            Text("AUDIO RECORDING")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(WhispererColors.secondaryText(.dark))
                .tracking(0.8)
        }
    }

    // MARK: - Waveform (matches AudioPlayerView exactly)

    private var waveformView: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background bars
                HStack(spacing: 2) {
                    ForEach(0..<waveformData.count, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(WhispererColors.secondaryText(.dark).opacity(0.25))
                            .frame(height: max(4, CGFloat(waveformData[index]) * 56))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .mask(fadeMask)

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
                        .frame(width: geometry.size.width * CGFloat(player.progress))
                        .frame(maxWidth: .infinity, alignment: .leading)
                )
                .mask(fadeMask)

                // Playhead
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
                        guard player.duration > 0 else { return }
                        let p = max(0, min(1, value.location.x / geometry.size.width))
                        player.seek(to: Double(p) * player.duration)
                    }
            )
        }
    }

    private var fadeMask: some View {
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

    private func loadWaveform() {
        guard let url = audioURL ?? player.loadedURL else { waveformData = []; return }
        loadWaveformFrom(url)
    }

    private func loadWaveformFrom(_ url: URL) {
        let capturedURL = url
        Task.detached(priority: .userInitiated) {
            let samples = WaveformGenerator.generateWaveform(from: capturedURL, sampleCount: 70)
            await MainActor.run { self.waveformData = samples }
        }
    }

    // MARK: - Play button (matches AudioPlayerView exactly)

    private var playButton: some View {
        Button(action: { player.isPlaying ? player.pause() : player.play() }) {
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
        .buttonStyle(.plain)
        .pointerOnHover()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isPlayButtonHovered = hovering }
        }
        .disabled(player.duration == 0)
    }

    // MARK: - Time display (matches AudioPlayerView exactly)

    private var timeDisplay: some View {
        HStack(spacing: 6) {
            Text(timeString(player.currentTime))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(WhispererColors.primaryText(.dark))
            Text("/")
                .font(.system(size: 11))
                .foregroundColor(WhispererColors.secondaryText(.dark))
            Text(timeString(player.duration))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(WhispererColors.secondaryText(.dark))
        }
    }

    // MARK: - Speed control (matches AudioPlayerView exactly)

    private var speedAccentColor: Color {
        player.playbackRate != 1.0 ? .orange : WhispererColors.secondaryText(.dark)
    }

    private var speedControl: some View {
        Menu {
            ForEach([Float(0.5), 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
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
            withAnimation(.easeOut(duration: 0.15)) { isSpeedHovered = hovering }
        }
    }

    private func speedLabel(_ rate: Float) -> String {
        if rate == 1.0 { return "1x" }
        if rate == floor(rate) { return "\(Int(rate))x" }
        return "\(String(format: "%.2g", rate))x"
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Loading dots animation

private struct PlayerLoadingDots: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(WhispererColors.accent.opacity(0.7))
                    .frame(width: 7, height: 7)
                    .scaleEffect(animate ? 1.0 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever()
                            .delay(Double(i) * 0.18),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}
