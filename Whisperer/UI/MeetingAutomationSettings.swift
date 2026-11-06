//
//  MeetingAutomationSettings.swift
//  Whisperer
//
//  Settings rows for calendar reminders and automatic recording of detected calls. Hosted in
//  the Settings tab's Calendar and Meeting Detection cards; same row style as their neighbours.
//

import SwiftUI

// MARK: - Calendar

struct CalendarSettingsRows: View {
    @ObservedObject private var store = CalendarMeetingsStore.shared
    @State private var connecting = false
    @State private var showCalendars = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            connectionRow
            ForEach(CalendarAccountProvider.allCases, id: \.self) { provider in
                divider
                accountRows(provider)
            }
            if let error = store.signInError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.system(size: 10))
                    Text(error).font(.system(size: 11)).foregroundColor(.orange)
                    Spacer()
                    Button(action: { store.dismissSignInError() }) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundColor(MBColors.textTertiary)
                    }.buttonStyle(.plain)
                }
            }

            if store.hasAnySource {
                divider
                if store.calendars.isEmpty {
                    noCalendarsRow
                } else {
                    calendarsRow
                }
                divider
                reminderRow
                divider
                toggleRow("Show next meeting in the menu bar",
                          subtitle: "On the Status tab",
                          isOn: $store.showNextMeetingInMenuBar)
                divider
                toggleRow("Remind for events with no attendees",
                          subtitle: "Off: only meetings with a link or other people remind you",
                          isOn: $store.includeUnlinkedSolo)
            }

            Text("Event details stay on this Mac. Whisperer only reads your calendars — it never changes them.")
                .font(.system(size: 10.5))
                .foregroundColor(MBColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var divider: some View {
        Divider().background(MBColors.border).padding(.vertical, 2)
    }

    /// Sign in with Google / Microsoft directly — for calendars not added to macOS.
    @ViewBuilder
    private func accountRows(_ provider: CalendarAccountProvider) -> some View {
        let signedIn = store.accounts.filter { $0.provider == provider }
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(MBColors.textPrimary)
                Text(signedIn.isEmpty
                     ? (provider.isConfigured ? "Sign in to read your \(provider.shortName) calendars directly" : "\(provider.shortName) sign-in isn't set up in this build")
                     : "Read-only access · tokens kept in your Keychain")
                    .font(.system(size: 11))
                    .foregroundColor(MBColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if store.signingIn == provider {
                ProgressView().controlSize(.small)
            } else {
                smallButton(signedIn.isEmpty ? "Sign In" : "Add Account", subtle: !signedIn.isEmpty) {
                    Task { await store.signIn(provider) }
                }
                .disabled(!provider.isConfigured || store.signingIn != nil)
                .opacity(provider.isConfigured ? 1 : 0.45)
                .uiTestFrame("settings.calendar.signIn.\(provider.rawValue)")
            }
        }
        ForEach(signedIn) { account in
            HStack(spacing: 8) {
                Image(systemName: store.accountsNeedingReconnect.contains(account.id) ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(store.accountsNeedingReconnect.contains(account.id) ? .orange : .green)
                Text(account.email)
                    .font(.system(size: 12))
                    .foregroundColor(MBColors.textPrimary)
                    .lineLimit(1)
                Spacer()
                if store.accountsNeedingReconnect.contains(account.id) {
                    smallButton("Sign In Again") { Task { await store.signIn(provider) } }
                }
                smallButton("Remove", subtle: true) { store.removeAccount(account) }
            }
            .padding(.leading, 4)
        }
    }

    @ViewBuilder
    private var connectionRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("macOS Calendars")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(MBColors.textPrimary)
                Text(connectionSubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(store.access == .denied || store.access == .restricted ? .orange : MBColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            connectionButton
        }
    }

    private var connectionSubtitle: String {
        switch (store.isConnected, store.access) {
        case (_, .denied):
            return "Calendar access is off for Whisperer. Turn it on in System Settings → Privacy & Security → Calendars."
        case (_, .restricted):
            return "Calendar access is restricted on this Mac."
        case (true, .granted):
            if let next = store.nextMeeting {
                return "Next: \(next.title) · \(next.startAt.formatted(date: .abbreviated, time: .shortened))"
            }
            return "Connected — no upcoming meetings this week"
        default:
            return "Calendars already on this Mac — iCloud, and any account added in System Settings → Internet Accounts."
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        switch (store.isConnected, store.access) {
        case (_, .denied), (_, .restricted):
            smallButton("Open Settings") { store.openPrivacySettings() }
        case (true, .granted):
            smallButton("Disconnect", subtle: true) { store.disconnect() }
        default:
            if connecting {
                ProgressView().controlSize(.small)
            } else {
                smallButton("Connect") {
                    connecting = true
                    Task {
                        await store.connect()
                        connecting = false
                    }
                }
                .uiTestFrame("settings.calendar.connect")
            }
        }
    }

    private var noCalendarsRow: some View {
        HStack {
            Text("No calendars on this Mac yet. Add Google, Outlook or another account in System Settings → Internet Accounts.")
                .font(.system(size: 11))
                .foregroundColor(MBColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            smallButton("Open", subtle: true) { store.openCalendarSettings() }
        }
    }

    private var calendarsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showCalendars.toggle() } }) {
                HStack {
                    Text("Calendars")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(MBColors.textPrimary)
                    Spacer()
                    let on = store.calendars.filter { store.isCalendarEnabled($0.id) }.count
                    Text("\(on) of \(store.calendars.count)")
                        .font(.system(size: 11))
                        .foregroundColor(MBColors.textSecondary)
                    Image(systemName: showCalendars ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(MBColors.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerOnHover()

            if showCalendars {
                ForEach(store.calendars) { calendar in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(red: calendar.color[0], green: calendar.color[1], blue: calendar.color[2]))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(calendar.title)
                                .font(.system(size: 12))
                                .foregroundColor(MBColors.textPrimary)
                            if !calendar.sourceTitle.isEmpty {
                                Text(calendar.sourceTitle)
                                    .font(.system(size: 10))
                                    .foregroundColor(MBColors.textTertiary)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { store.isCalendarEnabled(calendar.id) },
                            set: { store.setCalendar(calendar.id, enabled: $0) }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .tint(MBColors.accent)
                            .labelsHidden()
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private var reminderRow: some View {
        HStack {
            Text("Remind me before meetings")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(MBColors.textPrimary)
            Spacer()
            Picker("", selection: $store.reminderLeadMinutes) {
                ForEach(CalendarMeetingsStore.leadChoices, id: \.self) { choice in
                    Text(Self.leadLabel(choice)).tag(choice)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    static func leadLabel(_ minutes: Int?) -> String {
        switch minutes {
        case nil: return "Off"
        case 0: return "At start"
        case let m?: return "\(m) min before"
        }
    }
}

// MARK: - Automatic recording

struct AutoRecordSettingsRows: View {
    @ObservedObject private var coordinator = MeetingSessionCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatically record detected meetings")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(MBColors.textPrimary)
                    Text("Zoom, Teams and Webex calls, after a countdown you can cancel. Other calls still ask first. Let participants know when you record them.")
                        .font(.system(size: 11))
                        .foregroundColor(MBColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { coordinator.autoRecordEnabled },
                                         set: { coordinator.autoRecordEnabled = $0 }))
                    .toggleStyle(.switch)
                    .tint(MBColors.accent)
                    .labelsHidden()
                    .uiTestFrame("settings.autoRecord")
            }

            if coordinator.autoRecordEnabled {
                HStack {
                    Text("Countdown before recording")
                        .font(.system(size: 12))
                        .foregroundColor(MBColors.textSecondary)
                    Spacer()
                    Stepper(value: Binding(get: { coordinator.countdownSeconds },
                                           set: { coordinator.countdownSeconds = $0 }),
                            in: MeetingSessionCoordinator.countdownRange, step: 5) {
                        Text("\(coordinator.countdownSeconds) s")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundColor(MBColors.textPrimary)
                    }
                    .fixedSize()
                }
                .transition(.opacity)
            }

            Divider().background(MBColors.border).padding(.vertical, 2)

            toggleRow("Stop recording when the call ends",
                      subtitle: "For recordings started from a detected call. If the end is unclear, Whisperer asks.",
                      isOn: Binding(get: { coordinator.autoStopWhenCallEnds },
                                    set: { coordinator.autoStopWhenCallEnds = $0 }))

            if !coordinator.excludedBundleIDs.isEmpty {
                Divider().background(MBColors.border).padding(.vertical, 2)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Apps you asked not to prompt for")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(MBColors.textPrimary)
                        Text(coordinator.excludedBundleIDs.map(Self.appName).sorted().joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundColor(MBColors.textSecondary)
                    }
                    Spacer()
                    smallButton("Reset", subtle: true) { coordinator.excludedBundleIDs = [] }
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: coordinator.autoRecordEnabled)
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - Shared row pieces

private func toggleRow(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
    HStack {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(MBColors.textPrimary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(MBColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        Toggle("", isOn: isOn)
            .toggleStyle(.switch)
            .tint(MBColors.accent)
            .labelsHidden()
    }
}

private func smallButton(_ title: String, subtle: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(subtle ? MBColors.textSecondary : .white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(subtle ? Color.white.opacity(0.07) : MBColors.accent))
    }
    .buttonStyle(.plain)
    .pointerOnHover()
}

// MARK: - Menu bar: next meeting

/// The next calendar meeting on the Status tab, with Record when it is on now.
struct NextMeetingRow: View {
    @ObservedObject private var store = CalendarMeetingsStore.shared
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        if store.hasAnySource, store.showNextMeetingInMenuBar, let next = store.nextMeeting {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: next.joinURL != nil ? "video.fill" : "calendar")
                        .font(.system(size: 15))
                        .foregroundColor(.orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(next.isLive(at: Date()) ? "Meeting now" : "Next meeting")
                        .font(.caption)
                        .foregroundColor(MBColors.textTertiary)
                    Text(next.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(MBColors.textPrimary)
                        .lineLimit(1)
                    Text(Self.when(next))
                        .font(.system(size: 11))
                        .foregroundColor(MBColors.textSecondary)
                }
                Spacer()
                if !appState.isMeetingMode, next.startAt.timeIntervalSinceNow < 15 * 60 {
                    if next.joinURL != nil {
                        smallButton("Join & Record") { MeetingSessionCoordinator.shared.joinAndRecord(next) }
                    } else {
                        smallButton("Record") { MeetingSessionCoordinator.shared.record(next) }
                    }
                }
            }
            .padding(12)
            .background(MBColors.cardSurface)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(MBColors.border, lineWidth: 1).allowsHitTesting(false))
        }
    }

    static func when(_ meeting: ScheduledMeeting) -> String {
        let time = meeting.startAt.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(meeting.startAt) {
            let minutes = Int(meeting.startAt.timeIntervalSinceNow / 60)
            if minutes > 0 && minutes < 60 { return "In \(minutes) min · \(time)" }
            return "Today · \(time)"
        }
        if Calendar.current.isDateInTomorrow(meeting.startAt) { return "Tomorrow · \(time)" }
        return meeting.startAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
