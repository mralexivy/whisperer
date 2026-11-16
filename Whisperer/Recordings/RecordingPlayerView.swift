//
//  RecordingPlayerView.swift
//  Whisperer
//
//  The two faces of the one playback session: a full card pinned above the sidebar tabs, and a compact
//  bar pinned under the reader when the sidebar is hidden. Both read `RecordingPlaybackController`;
//  neither owns audio. The look is the app's existing audio card (`MeetingPlayerCard`): rounded fading
//  waveform bars, a glowing playhead, the accent play button, mono time and the speed pill.
//

import SwiftUI

struct RecordingPlayerView: View {
    enum Style { case full, compact }

    @ObservedObject var controller: RecordingPlaybackController
    @ObservedObject var player: SeekableAudioPlayer
    let style: Style
    @Environment(\.uiTestScope) private var testScope

    init(controller: RecordingPlaybackController, style: Style) {
        self.controller = controller
        self.player = controller.player
        self.style = style
    }

    var body: some View {
        Group {
            switch controller.availability {
            case .none: EmptyView()
            case .noAudio: unavailable("No audio was kept for this recording.")
            case .missing: unavailable("The audio file is no longer on this Mac.")
            case .ready: style == .full ? AnyView(fullPlayer) : AnyView(compactPlayer)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio player")
        #if DEBUG
        .onAppear { RecordingPlayerProbe.live["\(testScope)|\(style == .full ? "full" : "compact")", default: 0] += 1 }
        .onDisappear { RecordingPlayerProbe.live["\(testScope)|\(style == .full ? "full" : "compact")", default: 0] -= 1 }
        #endif
    }

    // MARK: Full

    private var fullPlayer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionLabel
                Spacer()
                if let url = player.loadedURL {
                    RevealInFinderButton(url: url, colorScheme: .dark).help("Show in Finder")
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)

            VStack(spacing: 16) {
                PlayerWaveform(controller: controller, player: player, height: 56)
                    .padding(.horizontal, 8)
                    .uiTestFrame("recordings.player.scrub.full")
                HStack(spacing: 12) {
                    PlayerPlayButton(player: player, size: 44, action: controller.togglePlay)
                        .uiTestFrame("recordings.player.play.full")
                    PlayerTime(player: player, size: 13)
                    Spacer(minLength: 8)
                    PlayerSpeed(player: player)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(WhispererColors.cardBackground(.dark)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(WhispererColors.border(.dark), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.06), radius: 4, y: 1)
        .overlay(loadingOverlay)
    }

    private var sectionLabel: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.15)).frame(width: 24, height: 24)
                Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).foregroundColor(.red)
            }
            Text("AUDIO RECORDING")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(WhispererColors.secondaryText(.dark)).tracking(0.8).lineLimit(1)
        }
    }

    // MARK: Compact

    private var compactPlayer: some View {
        HStack(spacing: 14) {
            PlayerPlayButton(player: player, size: 36, action: controller.togglePlay)
                .uiTestFrame("recordings.player.play.compact")
            PlayerTime(player: player, size: 12)
            PlayerWaveform(controller: controller, player: player, height: 30)
                .uiTestFrame("recordings.player.scrub.compact")
            PlayerSpeed(player: player)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14).fill(WhispererColors.cardBackground(.dark)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(WhispererColors.border(.dark), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.25), radius: 10, y: 3)
        .overlay(loadingOverlay)
    }

    @ViewBuilder private var loadingOverlay: some View {
        if player.isLoading {
            RoundedRectangle(cornerRadius: 14).fill(WhispererColors.cardBackground(.dark).opacity(0.85))
                .overlay(
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading recording…").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.45))
                    })
        }
    }

    private func unavailable(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.slash").font(.system(size: 13)).foregroundColor(.white.opacity(0.35))
            Text(message).font(.system(size: 12.5)).foregroundColor(.white.opacity(0.5))
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(WhispererColors.cardBackground(.dark)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(WhispererColors.border(.dark), lineWidth: 1))
    }
}

// MARK: - Waveform

/// Rounded waveform bars that fade top and bottom, accent progress with a soft glow, a white playhead dot,
/// and drag-to-scrub. The same drawing the meeting player card has always used.
private struct PlayerWaveform: View {
    @ObservedObject var controller: RecordingPlaybackController
    @ObservedObject var player: SeekableAudioPlayer
    let height: CGFloat

    @State private var scrubProgress: CGFloat = 0
    @State private var lastSeek: Date = .distantPast

    private var bars: [Float] { controller.waveform.isEmpty ? Array(repeating: 0.12, count: 70) : controller.waveform }
    private var progress: CGFloat { player.isScrubbing ? scrubProgress : CGFloat(player.progress) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if height > 40 {
                    barRow(color: WhispererColors.secondaryText(.dark).opacity(0.25), glow: false)
                        .mask(fade)
                    barRow(color: WhispererColors.accent, glow: true)
                        .mask(Rectangle().frame(width: geometry.size.width * progress).frame(maxWidth: .infinity, alignment: .leading))
                        .mask(fade)
                } else {
                    thinBars(progress: progress)
                }
                if height > 40 {
                    Circle().fill(Color.white).frame(width: 10, height: 10)
                        .shadow(color: WhispererColors.accent.opacity(0.5), radius: 4, y: 2)
                        .shadow(color: Color.white.opacity(0.3), radius: 2, y: 0)
                        .offset(x: geometry.size.width * progress - 5)
                } else {
                    Capsule().fill(Color.white).frame(width: 2, height: height * 0.8)
                        .offset(x: geometry.size.width * progress - 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard player.duration > 0 else { return }
                    let p = max(0, min(1, value.location.x / max(geometry.size.width, 1)))
                    scrubProgress = p
                    player.isScrubbing = true
                    if Date().timeIntervalSince(lastSeek) > 0.1 { lastSeek = Date(); controller.seek(to: Double(p) * player.duration) }
                }
                .onEnded { value in
                    guard player.duration > 0 else { return }
                    let p = max(0, min(1, value.location.x / max(geometry.size.width, 1)))
                    player.isScrubbing = false
                    controller.seek(to: Double(p) * player.duration)
                })
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(FileTranscriptClock.format(player.currentTime)) of \(FileTranscriptClock.format(player.duration))")
        .accessibilityAdjustableAction { direction in
            controller.seek(to: player.currentTime + (direction == .increment ? 15 : -15))
        }
    }

    /// The compact bar is long and short, so it draws thin fixed-width bars resampled from the same waveform
    /// instead of stretching 70 bars into fat blocks.
    private func thinBars(progress: CGFloat) -> some View {
        Canvas { context, size in
            let pitch: CGFloat = 5
            let count = max(10, Int(size.width / pitch))
            for i in 0..<count {
                let level = CGFloat(bars[min(bars.count - 1, i * bars.count / count)])
                let h = max(4, level * size.height)
                let x = CGFloat(i) * pitch
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: 3, height: h)
                let played = x / max(size.width, 1) <= progress
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                             with: .color(played ? WhispererColors.accent : WhispererColors.secondaryText(.dark).opacity(0.3)))
            }
        }
    }

    private func barRow(color: Color, glow: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<bars.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2).fill(color)
                    .frame(height: max(4, CGFloat(bars[index]) * height))
                    .shadow(color: glow ? WhispererColors.accent.opacity(0.4) : .clear, radius: glow ? 3 : 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var fade: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.15),
                               .init(color: .white, location: 0.85), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Controls

private struct PlayerPlayButton: View {
    @ObservedObject var player: SeekableAudioPlayer
    let size: CGFloat
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(WhispererColors.accent).frame(width: size, height: size)
                    .shadow(color: WhispererColors.accent.opacity(hovered ? 0.4 : 0.25), radius: hovered ? 10 : 6, y: hovered ? 3 : 2)
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.36, weight: .semibold)).foregroundColor(.white)
                    .offset(x: player.isPlaying ? 0 : 1)
            }
            .scaleEffect(hovered ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovered = inside } }
        .disabled(player.duration == 0)
        .help(player.isPlaying ? "Pause" : "Play")
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }
}

private struct PlayerTime: View {
    @ObservedObject var player: SeekableAudioPlayer
    let size: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Text(FileTranscriptClock.format(player.currentTime))
                .font(.system(size: size, weight: .semibold, design: .monospaced)).foregroundColor(WhispererColors.primaryText(.dark))
            Text("/").font(.system(size: size - 2)).foregroundColor(WhispererColors.secondaryText(.dark))
            Text(FileTranscriptClock.format(player.duration))
                .font(.system(size: size, weight: .medium, design: .monospaced)).foregroundColor(WhispererColors.secondaryText(.dark))
        }
        .lineLimit(1).fixedSize()
    }
}

private struct PlayerSpeed: View {
    @ObservedObject var player: SeekableAudioPlayer
    @State private var hovered = false

    private var tint: Color { player.playbackRate != 1.0 ? .orange : WhispererColors.secondaryText(.dark) }

    var body: some View {
        Menu {
            ForEach([Float(0.5), 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                Button { player.setRate(rate) } label: {
                    HStack {
                        Text(label(rate))
                        if player.playbackRate == rate { Spacer(); Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.15)).frame(width: 22, height: 22)
                    Image(systemName: "speedometer").font(.system(size: 10, weight: .semibold)).foregroundColor(tint)
                }
                Text(label(player.playbackRate)).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(tint)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundColor(tint.opacity(0.6))
            }
            .padding(.leading, 5).padding(.trailing, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(hovered ? 0.12 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(hovered ? 0.2 : 0.1), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovered = inside } }
        .help("Playback speed")
    }

    private func label(_ rate: Float) -> String {
        if rate == 1.0 { return "1x" }
        if rate == floor(rate) { return "\(Int(rate))x" }
        return "\(String(format: "%.2g", rate))x"
    }
}

#if DEBUG
/// How many player presentations are on screen right now, by style. The "exactly one player" rule is
/// asserted against this in tests.
@MainActor
enum RecordingPlayerProbe {
    static var live: [String: Int] = [:]
}
#endif
