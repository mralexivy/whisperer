//
//  MeetingLiveBadge.swift
//  Whisperer
//
//  The LIVE pill on the meeting surfaces (live window, Meeting Studio). One view so the
//  surfaces cannot drift: it was copied by hand between two of them.
//
//  It also says when the meeting is *not* capturing — paused by the user, or paused while the
//  user dictates on top of it (`AppState.beginMeetingInterlude`). A red LIVE over a paused
//  capture is exactly the "is it still recording?" doubt this exists to remove.
//

import SwiftUI

struct MeetingLiveBadge: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject private var appState = AppState.shared

    private static let amber = Color(red: 0.961, green: 0.620, blue: 0.043)

    private var label: String {
        if session.isPausedForDictation { return "PAUSED \u{00B7} DICTATING" }
        if appState.isPaused { return "PAUSED" }
        return "LIVE"
    }

    private var color: Color {
        session.isPausedForDictation || appState.isPaused ? Self.amber : .red
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .contentTransition(.opacity)
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
        .animation(.easeInOut(duration: 0.2), value: label)
        .help(session.isPausedForDictation
              ? "The meeting is paused while you dictate, and resumes when you release the shortcut."
              : appState.isPaused ? "The meeting is paused." : "Recording")
        .accessibilityLabel(label.capitalized)
    }
}
