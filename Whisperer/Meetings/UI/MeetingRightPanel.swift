//
//  MeetingRightPanel.swift
//  Whisperer
//
//  Right column: audio player card + assistant panel.
//  Shows an animated recording state while a session is active.
//

import SwiftUI

struct MeetingRightPanel: View {
    let meeting: MeetingRecord?
    @ObservedObject var session: MeetingSession
    @ObservedObject var player: SeekableAudioPlayer
    var onSpeakerRenamed: ((Int, String) -> Void)?

    /// The recording state belongs to the meeting being recorded. Shown for whatever meeting
    /// was open, it hid the player and Ask AI of every past meeting for the length of a call.
    private var isShowingTheRecording: Bool {
        session.isRecording && session.meetingID != nil && session.meetingID == meeting?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            // The meeting being recorded: a compact recording strip, then Ask AI over what has
            // been said so far. Any other meeting: its player, then Ask AI — a recording running
            // elsewhere never takes its place.
            if isShowingTheRecording {
                RecordingStrip(session: session)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .transition(.opacity)
            } else {
                MeetingPlayerCard(meeting: meeting, session: session, player: player)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .transition(.opacity)
            }

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            MeetingAssistantPanel(meeting: meeting,
                                 session: session,
                                 onSpeakerRenamed: onSpeakerRenamed)
        }
        .background(Color(hex: "0A0A18"))
        .animation(.easeInOut(duration: 0.3), value: isShowingTheRecording)
    }
}

// MARK: - Recording strip

/// The recording, small: state, elapsed time, pause and mute. Sits where the player will be
/// once the meeting ends.
private struct RecordingStrip: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject private var appState = AppState.shared

    private var isPausedCapture: Bool { session.isPausedForDictation || appState.isPaused }
    private var badgeColor: Color { isPausedCapture ? Color(red: 0.961, green: 0.620, blue: 0.043) : .red }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(badgeColor).frame(width: 6, height: 6)
                    Text(session.isPausedForDictation ? "PAUSED \u{00B7} DICTATING"
                         : appState.isPaused ? "PAUSED" : "RECORDING")
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(badgeColor.opacity(0.9))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(badgeColor.opacity(0.08)))
                .overlay(Capsule().stroke(badgeColor.opacity(0.22), lineWidth: 1))

                Text(session.elapsedDisplay)
                    .font(.system(size: 20, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundColor(.white)
                    .contentTransition(.numericText())

                Spacer(minLength: 4)

                MeetingCaptureControls(size: 28)
            }

            Text(appState.isMicMuted ? "Your microphone is muted. The call is still recorded."
                 : "Ask about what has been said so far. The player appears when the meeting ends.")
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)

            if let note = session.callAudioNote {
                Label(note, systemImage: "speaker.wave.2")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .accessibilityIdentifier("meetingCallAudioNote")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(WhispererColors.cardBackground(.dark)))
    }
}

/// Pause / resume and microphone mute for the meeting being recorded. Usable from the first
/// second — e.g. muted while waiting for the others to join. Shared by the workspace and the
/// floating live window.
struct MeetingCaptureControls: View {
    var size: CGFloat = 26
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        HStack(spacing: 6) {
            control(systemName: appState.isMicMuted ? "mic.slash.fill" : "mic.fill",
                    active: appState.isMicMuted,
                    tint: Color(red: 0.937, green: 0.267, blue: 0.267),
                    help: appState.isMicMuted ? "Unmute microphone" : "Mute microphone",
                    id: "meetingMuteButton") { appState.toggleMicMute() }
            control(systemName: appState.isPaused ? "play.fill" : "pause.fill",
                    active: appState.isPaused,
                    tint: Color(red: 0.961, green: 0.620, blue: 0.043),
                    help: appState.isPaused ? "Resume recording" : "Pause recording",
                    id: "meetingPauseButton") { appState.togglePause() }
        }
    }

    private func control(systemName: String, active: Bool, tint: Color, help: String,
                         id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(active ? tint : .white.opacity(0.7))
                .frame(width: size, height: size)
                .background(Circle().fill(active ? tint.opacity(0.16) : Color.white.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(id)
    }
}
