//
//  RecordingPlayerView.swift
//  Whisperer
//
//  The two faces of the one playback session: a full card pinned above the sidebar tabs, and a compact
//  bar pinned under the reader when the sidebar is hidden. Both read `RecordingPlaybackController`;
//  neither owns audio.
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

    private static let speeds: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]
    private let accent = WhispererColors.accent

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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).foregroundColor(accent)
                Text("AUDIO RECORDING")
                    .font(.system(size: 10, weight: .bold)).tracking(1.0)
                    .foregroundColor(Color.white.opacity(0.55))
                Spacer()
            }
            waveform(height: 48)
            HStack(spacing: 12) {
                playButton(size: 42)
                timeLabel
                Spacer()
                speedMenu
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
        .overlay { if player.isLoading { ProgressView().controlSize(.small) } }
    }

    // MARK: Compact

    private var compactPlayer: some View {
        HStack(spacing: 12) {
            playButton(size: 30)
            timeLabel.frame(minWidth: 84, alignment: .leading)
            waveform(height: 24)
            speedMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: "14142B"))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    // MARK: Parts

    private func playButton(size: CGFloat) -> some View {
        Button(action: controller.togglePlay) {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(accent))
        }
        .buttonStyle(.plain)
        .help(player.isPlaying ? "Pause" : "Play")
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        .uiTestFrame("recordings.player.play.\(style == .full ? "full" : "compact")")
    }

    private var timeLabel: some View {
        HStack(spacing: 4) {
            Text(FileTranscriptClock.format(player.currentTime)).foregroundColor(.white)
            Text("/ \(FileTranscriptClock.format(player.duration))").foregroundColor(Color.white.opacity(0.45))
        }
        .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
    }

    private var speedMenu: some View {
        Menu {
            ForEach(Self.speeds, id: \.self) { rate in
                Button { player.setRate(rate) } label: {
                    Text(rate == player.playbackRate ? "\(label(rate))  ✓" : label(rate))
                }
            }
        } label: {
            Text(label(player.playbackRate))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(player.playbackRate == 1 ? Color.white.opacity(0.6) : .orange)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.06)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Playback speed")
    }

    private func label(_ rate: Float) -> String { rate == rate.rounded() ? "\(Int(rate))x" : String(format: "%gx", rate) }

    private func waveform(height: CGFloat) -> some View {
        GeometryReader { geo in
            let bars = controller.waveform
            ZStack(alignment: .leading) {
                Canvas { context, size in
                    let count = max(bars.count, 1)
                    let barWidth = max(1.5, size.width / CGFloat(count) - 1.5)
                    for (index, level) in (bars.isEmpty ? Array(repeating: Float(0.15), count: 60) : bars).enumerated() {
                        let x = CGFloat(index) / CGFloat(bars.isEmpty ? 60 : count) * size.width
                        let h = max(2, CGFloat(level) * size.height)
                        let played = Double(x / max(size.width, 1)) <= player.progress
                        let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                        context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                     with: .color(played ? accent : Color.white.opacity(0.22)))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    player.isScrubbing = true
                    player.currentTime = Double(min(max(value.location.x / max(geo.size.width, 1), 0), 1)) * player.duration
                }
                .onEnded { value in
                    let fraction = Double(min(max(value.location.x / max(geo.size.width, 1), 0), 1))
                    player.isScrubbing = false
                    controller.seek(to: fraction * player.duration)
                })
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(FileTranscriptClock.format(player.currentTime)) of \(FileTranscriptClock.format(player.duration))")
        .accessibilityAdjustableAction { direction in
            controller.seek(to: player.currentTime + (direction == .increment ? 15 : -15))
        }
        .uiTestFrame("recordings.player.scrub.\(style == .full ? "full" : "compact")")
    }

    private func unavailable(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.slash").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.4))
            Text(message).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.5))
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.03)))
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
