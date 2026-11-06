//
//  MeetingReminderCard.swift
//  Whisperer
//
//  HUD cards for calendar-aware meetings: the reminder before a scheduled meeting, the
//  "call may have ended" question for a recording whose end signal was ambiguous, and a notice
//  when a recording the user asked for could not start. Same shell as MeetingNotificationCard.
//

import SwiftUI

struct MeetingReminderCard: View {
    let meeting: ScheduledMeeting
    @ObservedObject private var store = CalendarMeetingsStore.shared
    @ObservedObject private var coordinator = MeetingSessionCoordinator.shared
    @ObservedObject private var appState = AppState.shared
    @State private var appeared = false

    private var startsText: String {
        let minutes = Int((meeting.startAt.timeIntervalSinceNow / 60).rounded())
        if minutes <= 0 { return meeting.isLive(at: Date()) ? "Started at \(time)" : "Starting now" }
        return "Starts in \(minutes) min \u{00B7} \(time)"
    }

    private var time: String { meeting.startAt.formatted(date: .omitted, time: .shortened) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: meeting.joinURL != nil ? "video.fill" : "calendar")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text([meeting.provider?.displayName, startsText].compactMap { $0 }.joined(separator: " \u{00B7} "))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
                .lineLimit(1)
            }
            .frame(maxWidth: 260, alignment: .leading)

            Spacer(minLength: 12)

            actions

            Menu {
                Button("Snooze 5 minutes") { store.snoozeReminder() }
                Button("Dismiss") { store.dismissReminder() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(width: 22, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Button(action: { store.dismissReminder() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .modifier(HUDCardShell(appeared: appeared))
        .onAppear { withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { appeared = true } }
    }

    @ViewBuilder
    private var actions: some View {
        if coordinator.isRecordingReminderMeeting {
            HUDPillButton(title: "Open Recording", primary: true) { coordinator.openRecording() }
        } else if appState.isMeetingMode {
            // Another meeting is recording: switching is the user's call, never ours.
            HUDPillButton(title: "Stop & Record This", primary: false) { coordinator.stopCurrentAndRecord(meeting) }
                .help("Stop the meeting you are recording and record this one")
        } else if meeting.joinURL != nil {
            HUDPillButton(title: "Join & Record", primary: true) { coordinator.joinAndRecord(meeting) }
            HUDPillButton(title: "Join", primary: false) { coordinator.joinOnly(meeting) }
                .help("Open the meeting without recording")
            HUDPillButton(title: "Record", primary: false) { coordinator.record(meeting) }
        } else {
            // No link (in person, or several conflicting links): record only.
            HUDPillButton(title: "Record", primary: true) { coordinator.record(meeting) }
                .help(meeting.hasConflictingLinks ? "This event has several meeting links — join from Calendar" : "Start recording")
        }
    }
}

/// A recording started from a detected call whose end could not be confirmed.
struct MeetingEndPendingCard: View {
    @ObservedObject private var coordinator = MeetingSessionCoordinator.shared
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.down")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Call may have ended")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text("Still recording")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
            }
            Spacer(minLength: 12)
            HUDPillButton(title: "Stop", primary: true) { coordinator.confirmEnd() }
            HUDPillButton(title: "Keep Recording", primary: false) { coordinator.keepRecordingAfterAmbiguousEnd() }
        }
        .modifier(HUDCardShell(appeared: appeared))
        .onAppear { withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { appeared = true } }
    }
}

/// A start the user asked for failed. Says so, instead of a recording that is not there.
struct MeetingStartFailedCard: View {
    let message: String
    @ObservedObject private var coordinator = MeetingSessionCoordinator.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            Button(action: { coordinator.dismissStartFailure() }) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color(hex: "0C0C1A"))
            .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1).allowsHitTesting(false)))
        .fixedSize()
        .task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            coordinator.dismissStartFailure()
        }
    }
}

// MARK: - Shared pieces

/// The dark rounded shell every meeting HUD card uses.
struct HUDCardShell: ViewModifier {
    let appeared: Bool
    func body(content: Content) -> some View {
        content
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(hex: "0C0C1A"))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1)
                        .allowsHitTesting(false))
            )
            .fixedSize(horizontal: true, vertical: false)
            .scaleEffect(appeared ? 1 : 0.94)
            .offset(y: appeared ? 0 : 16)
            .opacity(appeared ? 1 : 0)
    }
}

struct HUDPillButton: View {
    let title: String
    let primary: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(primary ? Color(hex: "0C0C1A") : .white.opacity(0.85))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(primary ? Color.white.opacity(hovering ? 1 : 0.92) : Color.white.opacity(hovering ? 0.12 : 0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerOnHover()
    }
}
