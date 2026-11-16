//
//  NewRecordingMenu.swift
//  Whisperer
//
//  The "+" in the Recordings header: one place to start anything new. A meeting or call records the mic and
//  the call audio; a dictation starts hands-free; a file opens the import flow, which returns to the new
//  recording when it is done. Each row says what it does and, when it cannot start now, why.
//

import SwiftUI

/// Starts the things the "+" offers. Kept out of the view so the rules are in one place.
@MainActor
enum RecordingStarter {
    /// Why a new meeting cannot start right now, or nil.
    static func meetingBlocker(session: MeetingSession) -> String? {
        if session.isRecording { return "A meeting is already being recorded." }
        if AppState.shared.pendingMeetingStarts > 0 { return "A meeting is starting…" }
        if AppState.shared.state.isRecording { return "Finish the dictation first." }
        return nil
    }

    static func dictationBlocker(session: MeetingSession) -> String? {
        if session.isRecording || AppState.shared.pendingMeetingStarts > 0 { return "A meeting is being recorded." }
        if AppState.shared.state.isRecording { return "A dictation is already running." }
        if AppState.shared.state != .idle { return "Whisperer is busy — try again in a moment." }
        return nil
    }

    static func defaultMeetingTitle(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy h:mm a"
        return "Note \(f.string(from: now))"
    }

    /// The meeting appears in the list at once (its row is created when it starts) and opens in the reader.
    static func startMeeting(session: MeetingSession) {
        guard meetingBlocker(session: session) == nil else { return }
        Task { await session.startRecording(title: defaultMeetingTitle(), surface: .workspace) }
    }

    /// Hands-free, like the Island's dictate button: no key is held, so the dictation HUD's stop button ends it.
    static func startDictation(session: MeetingSession) {
        guard dictationBlocker(session: session) == nil else { return }
        let appState = AppState.shared
        appState.startRecording()
        if appState.state.isRecording { appState.isHandsFreeRecording = true }
    }
}

struct NewRecordingButton: View {
    @ObservedObject var model: RecordingsWorkspaceModel
    @ObservedObject var session: MeetingSession
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(WhispererColors.accentGradient))
                .shadow(color: WhispererColors.accent.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .help("New recording")
        .accessibilityLabel("New recording")
        .uiTestFrame("recordings.new")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            NewRecordingMenu(model: model, session: session, dismiss: { open = false })
        }
    }
}

/// The choices behind the "+": a meeting or call, a dictation, a file.
struct NewRecordingMenu: View {
    @ObservedObject var model: RecordingsWorkspaceModel
    @ObservedObject var session: MeetingSession
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NEW").font(.system(size: 10, weight: .bold)).tracking(1.0)
                .foregroundColor(Color.white.opacity(0.35)).padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            row(icon: "video", tint: Color(hex: "06B6D4"), title: "Meeting or call",
                subtitle: "Records your mic and the call, with speakers.",
                blocker: RecordingStarter.meetingBlocker(session: session), id: "meeting") {
                dismiss()
                RecordingStarter.startMeeting(session: session)
            }
            row(icon: "mic", tint: WhispererColors.accent, title: "Dictation",
                subtitle: "Speak hands-free; the text is saved here.",
                blocker: RecordingStarter.dictationBlocker(session: session), id: "dictation") {
                dismiss()
                RecordingStarter.startDictation(session: session)
            }
            row(icon: "doc.text", tint: Color(hex: "F59E0B"), title: "Audio or video file",
                subtitle: "Transcribe a recording from your Mac.",
                blocker: nil, id: "file") {
                dismiss()
                model.isImporting = true
            }
        }
        .padding(6)
        .frame(width: 320)
        .background(WhispererColors.cardBackground(.dark))
        .environment(\.colorScheme, .dark)
    }

    private func row(icon: String, tint: Color, title: String, subtitle: String, blocker: String?, id: String,
                     action: @escaping () -> Void) -> some View {
        NewRecordingRow(icon: icon, tint: tint, title: title, subtitle: blocker ?? subtitle, blocked: blocker != nil, action: action)
            .uiTestFrame("recordings.new.\(id)")
    }
}

private struct NewRecordingRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let blocked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14, weight: .regular)).foregroundColor(tint)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(tint.opacity(0.3), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundColor(.white)
                    Text(subtitle).font(.system(size: 12)).foregroundColor(blocked ? Color.orange.opacity(0.9) : Color.white.opacity(0.5))
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(WhispererColors.elevatedBackground(.dark).opacity(hovering && !blocked ? 0.8 : 0)))
            .opacity(blocked ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .onHover { hovering = $0 }
    }
}
