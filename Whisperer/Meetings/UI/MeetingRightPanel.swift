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
    @ObservedObject var player: MeetingAudioPlayer

    var body: some View {
        ZStack {
            if session.isRecording {
                RecordingInProgressView(session: session)
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    MeetingPlayerCard(meeting: meeting, session: session, player: player)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)

                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)

                    MeetingAssistantPanel(meeting: meeting, session: session)
                }
                .transition(.opacity)
            }
        }
        .background(Color(hex: "0A0A18"))
        .animation(.easeInOut(duration: 0.45), value: session.isRecording)
    }
}

// MARK: - Recording in-progress state

private struct RecordingInProgressView: View {
    @ObservedObject var session: MeetingSession
    @State private var pulse = false
    @State private var dotBright = false

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            sonarIcon

            VStack(spacing: 16) {
                liveBadge

                Text(session.elapsedDisplay)
                    .font(.system(size: 52, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundColor(.white)
                    .contentTransition(.numericText())

                Text("Player and AI ready when recording ends")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.white.opacity(0.25))
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "0A0A18"))
        .onAppear {
            pulse = true
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                dotBright = true
            }
        }
    }

    // MARK: - Sonar icon

    private var sonarIcon: some View {
        ZStack {
            // Three expanding sonar rings
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(hex: "5B6CF7").opacity(0.55),
                                Color(hex: "8B5CF6").opacity(0.25)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: 86, height: 86)
                    .scaleEffect(pulse ? 3.0 : 1.0)
                    .opacity(pulse ? 0 : 0.75)
                    .animation(
                        .easeOut(duration: 2.5)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.82),
                        value: pulse
                    )
            }

            // Center gradient circle
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "5B6CF7"), Color(hex: "8B5CF6")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 74, height: 74)
                    .shadow(color: Color(hex: "5B6CF7").opacity(0.55), radius: 24, y: 6)

                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .frame(width: 230, height: 230)
    }

    // MARK: - Live badge

    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
                .opacity(dotBright ? 1.0 : 0.2)

            Text("RECORDING LIVE")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.9)
                .foregroundColor(Color.red.opacity(0.9))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.red.opacity(0.08))
        .overlay(Capsule().stroke(Color.red.opacity(0.22), lineWidth: 1))
        .clipShape(Capsule())
    }
}
