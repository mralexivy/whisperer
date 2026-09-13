//
//  SilentMeetingCard.swift
//  Whisperer
//
//  HUD toast that appears during a meeting when no speech has been detected.
//  Visually mirrors MeetingNotificationCard — same shell, same spring animations.
//

import SwiftUI

struct SilentMeetingCard: View {
    @ObservedObject var watcher: MeetingSilenceWatcher

    @State private var appeared = false
    @State private var stopHovering = false
    @State private var dismissHovering = false

    private var isConfident: Bool { watcher.stage == .confident }

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: "mic.slash")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 22)

            // Text + progress bar
            VStack(alignment: .leading, spacing: 5) {
                Text(isConfident ? "No speech detected" : "No speech yet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Text("Started by mistake?")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.1))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isConfident ? Color(hex: "FF5555") : Color(hex: "5B6CF7"))
                            .frame(width: geo.size.width * MeetingSilencePolicy.progress(elapsed: elapsedSecondsApprox))
                            .animation(.linear(duration: 1), value: elapsedSecondsApprox)
                    }
                }
                .frame(height: 3)
            }

            Spacer(minLength: 12)

            stopButton
            dismissButton
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
                )
        )
        .fixedSize(horizontal: true, vertical: false)
        .scaleEffect(appeared ? 1.0 : 0.94)
        .offset(y: appeared ? 0 : 16)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78).delay(0.03)) {
                appeared = true
            }
        }
    }

    // MARK: - Approximate elapsed for progress animation

    /// Approximate elapsed from watcher stage. We don't hold a reference to MeetingSession here;
    /// progress is derived from time elapsed since the warn threshold, republished at ~1 Hz by the
    /// watcher's tick. We drive it via a local timer instead of the session clock so the bar
    /// animates smoothly without creating a circular dependency.
    @State private var elapsedSecondsApprox: Double = MeetingSilencePolicy.warnAfter
    @State private var tickTimer: Timer? = nil

    // MARK: - Buttons

    private var stopButton: some View {
        Button {
            AppState.shared.stopActiveRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Stop")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundColor(isConfident ? Color(hex: "0C0C1A") : .white.opacity(0.85))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isConfident
                          ? Color.white.opacity(stopHovering ? 1.0 : 0.92)
                          : Color.white.opacity(stopHovering ? 0.12 : 0.07))
            )
        }
        .buttonStyle(.plain)
        .onHover { stopHovering = $0 }
        .animation(.easeInOut(duration: 0.25), value: isConfident)
    }

    private var dismissButton: some View {
        Button {
            watcher.dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(dismissHovering ? 0.7 : 0.3))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { dismissHovering = $0 }
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
