//
//  SilentMeetingCard.swift
//  Whisperer
//
//  HUD card for a meeting that is not hearing anything. Two cases, never confused:
//
//  - **Started by mistake** (nothing transcribed, no notes): a visible 30 s countdown, then the
//    empty meeting is discarded. Keep recording / Discard now. Any sound restarts the countdown;
//    only words or a note end it.
//  - **Went quiet** (real content, then minutes of silence): never discarded. Pause / Keep going
//    / Stop, and the copy says the meeting is saved.
//
//  Same shell as MeetingNotificationCard. See `MeetingSilencePolicy.swift` for the rules.
//

import SwiftUI

struct SilentMeetingCard: View {
    @ObservedObject var watcher: MeetingSilenceWatcher

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private static let accent = Color(hex: "5B6CF7")
    private static let warn = Color(hex: "FF5555")

    var body: some View {
        Group {
            switch watcher.prompt {
            case .startedByMistake(let secondsLeft, let micSilent):
                mistakeCard(secondsLeft: secondsLeft, micSilent: micSilent)
            case .wentQuiet(let minutes):
                quietCard(minutes: minutes)
            case .none:
                EmptyView()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(hex: "0C0C1A"))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                        .allowsHitTesting(false)
                )
        )
        .fixedSize(horizontal: true, vertical: false)
        .scaleEffect(appeared ? 1.0 : 0.94)
        .offset(y: appeared ? 0 : 16)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.78).delay(0.03)) {
                appeared = true
            }
        }
    }

    // MARK: - Started by mistake

    private func mistakeCard(secondsLeft: Int, micSilent: Bool) -> some View {
        let urgent = secondsLeft <= 10
        return HStack(spacing: 12) {
            Image(systemName: micSilent ? "mic.slash" : "waveform.slash")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 5) {
                Text(micSilent ? "No sound from your microphone" : "Nothing heard yet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Text("Started by mistake? Discarding in \(Self.clock(secondsLeft))")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(urgent ? Self.warn.opacity(0.9) : .white.opacity(0.5))
                    .contentTransition(.numericText(countsDown: true))

                // Drains over the countdown; a sound refills it.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.1))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(urgent ? Self.warn : Self.accent)
                            .frame(width: geo.size.width * Double(secondsLeft) / MeetingQuietTracker.discardCountdown)
                            .animation(reduceMotion ? nil : .linear(duration: 1), value: secondsLeft)
                    }
                }
                .frame(width: 190, height: 3)
            }

            Spacer(minLength: 12)

            CardButton(title: "Keep recording", isPrimary: true) { watcher.keep() }
                .help("Keep this meeting — it will not be discarded")
            CardButton(title: "Discard", isPrimary: false, tint: Self.warn) {
                AppState.shared.discardEmptyMeeting(reason: "user pressed Discard")
            }
            .help("Stop and delete this empty meeting")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nothing heard yet. Discarding in \(secondsLeft) seconds.")
    }

    // MARK: - Went quiet

    private func quietCard(minutes: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text("Quiet for \(minutes) min")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text("Your meeting is saved. Pause it while it's quiet?")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer(minLength: 12)

            CardButton(title: "Pause", systemImage: "pause.fill", isPrimary: true) {
                if !AppState.shared.isPaused { AppState.shared.togglePause() }
            }
            .help("Pause recording; resume any time")
            CardButton(title: "Keep going", isPrimary: false) { watcher.dismiss() }
                .help("Keep recording and ask again in 10 minutes")
            CardButton(title: "Stop", isPrimary: false) { AppState.shared.stopActiveRecording() }
                .help("Stop and save the meeting")
        }
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "0:%02d", max(0, seconds))
    }
}

/// The card's buttons. Primary is a white pill, secondary a subtle one.
private struct CardButton: View {
    let title: String
    var systemImage: String? = nil
    let isPrimary: Bool
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
                }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(isPrimary ? Color(hex: "0C0C1A") : (tint ?? .white.opacity(0.85)))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isPrimary
                          ? Color.white.opacity(hovering ? 1.0 : 0.92)
                          : Color.white.opacity(hovering ? 0.12 : 0.07))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerOnHover()
    }
}

/// After an empty meeting was discarded: says so, so a meeting never just vanishes.
struct EmptyMeetingDiscardedCard: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
            Text("Empty meeting discarded — nothing was said")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule().fill(Color(hex: "0C0C1A"))
                .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1).allowsHitTesting(false))
        )
        .fixedSize()
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: - Preview

#Preview {
    let watcher = MeetingSilenceWatcher()
    return ZStack {
        Color.black
        SilentMeetingCard(watcher: watcher)
            .padding(40)
    }
    .onAppear {
        Task { @MainActor in
            watcher.start(vad: nil)
        }
    }
}
