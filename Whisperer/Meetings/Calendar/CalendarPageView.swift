//
//  CalendarPageView.swift
//  Whisperer
//
//  The "Calendar" workspace page — connect Google Calendar or Outlook so Whisperer knows your
//  meetings: a reminder before each one, Join & Record in one click, and recordings titled from
//  the invite.
//
//  Structure (same patterns as the LLM and MCP pages):
//   1. Hero — what this does in one sentence and the current state (connected accounts).
//   2. Connect — one list of the two providers. Picking one unfolds the steps in place with ONE
//      primary button; connected accounts sit under their provider with Remove / Sign in again.
//   3. Once connected: upcoming meetings, which calendars count, reminders, automatic recording.
//
//  The menu bar Settings tab keeps a compact copy of the same controls (CalendarSettingsRows);
//  both read and write `CalendarMeetingsStore`, so they can never disagree.
//

import AppKit
import SwiftUI

struct CalendarPageView: View {
    let colorScheme: ColorScheme

    @ObservedObject private var store: CalendarMeetingsStore
    @ObservedObject private var coordinator = MeetingSessionCoordinator.shared
    @ObservedObject private var appState = AppState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let testScope: String

    init(colorScheme: ColorScheme, store: CalendarMeetingsStore = .shared, testScope: String = "") {
        self.colorScheme = colorScheme
        self.testScope = testScope
        _store = ObservedObject(wrappedValue: store)
    }

    /// The provider whose connect steps are unfolded.
    @State private var expanded: CalendarAccountProvider?
    @State private var appeared = false
    @State private var refreshing = false

    private var spring: Animation? {
        reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.84)
    }

    private var connected: Bool { store.hasAnySource }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                connectSection
                if connected {
                    upcomingSection
                    calendarsSection
                }
                remindersSection
                recordingSection
                footer
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WhispererColors.background(colorScheme))
        .environment(\.uiTestScope, testScope)
        .animation(spring, value: connected)
        .animation(spring, value: expanded)
        .animation(spring, value: store.accounts)
        .onAppear {
            // Nothing connected yet: open the first provider's steps so the page leads somewhere.
            if !connected && expanded == nil { expanded = .google }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) { appeared = true }
        }
        .onChange(of: store.accounts) { _, accounts in
            // A sign-in just finished — fold its steps away; the account row is the confirmation.
            if let p = expanded, accounts.contains(where: { $0.provider == p }) { expanded = nil }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(connected
                          ? AnyShapeStyle(LinearGradient(colors: [Color(hex: "F97316"), Color(hex: "EC4899")],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(Color.white.opacity(0.06)))
                    .frame(width: 52, height: 52)
                    .shadow(color: Color(hex: "F97316").opacity(connected ? 0.4 : 0), radius: 14, y: 3)
                Image(systemName: "calendar")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(connected ? .white : Color(hex: "F97316"))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Calendar")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Connect your calendar and Whisperer reminds you before each meeting, joins and records in one click, and names the recording after the invite.")
                    .font(.system(size: 13.5))
                    .foregroundColor(.white.opacity(0.55))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            statusChip
        }
        .padding(24)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(WhispererColors.cardBackground(colorScheme))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(RadialGradient(colors: [Color(hex: "F97316").opacity(connected ? 0.16 : 0.05), .clear],
                                         center: .topLeading, startRadius: 0, endRadius: 520))
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Color.white.opacity(0.07), lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
    }

    private var statusChip: some View {
        let needsAttention = !store.accountsNeedingReconnect.isEmpty
        let color: Color = needsAttention ? MCPPalette.warning : (connected ? MCPPalette.success : .white.opacity(0.35))
        let text: String = {
            if needsAttention { return "Sign in again" }
            switch store.accounts.count {
            case 0: return "Not connected"
            case 1: return "Connected"
            case let n: return "\(n) accounts"
            }
        }()
        return HStack(spacing: 6) {
            MCPPulsingDot(color: color, active: connected && !needsAttention, size: 7)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(connected ? color : .white.opacity(0.55))
                .lineLimit(1)
        }
        .padding(.leading, 8).padding(.trailing, 12)
        .frame(height: 30)
        .background(Capsule().fill(color.opacity(connected ? 0.12 : 0.06)))
        .fixedSize()
    }

    // MARK: - Connect

    private var connectSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(connected ? "Accounts" : "Connect a calendar",
                         subtitle: connected ? "Add another account any time — events from all of them are merged."
                                             : "Pick where your meetings live. Access is read-only.")
            VStack(spacing: 10) {
                ForEach(CalendarAccountProvider.allCases, id: \.self) { provider in
                    providerCard(provider)
                }
            }
            if let error = store.signInError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(MCPPalette.warning)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(MCPPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { store.dismissSignInError() } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(MCPPalette.warning.opacity(0.08)))
                .transition(.opacity)
            }
        }
    }

    private func providerCard(_ provider: CalendarAccountProvider) -> some View {
        let accounts = store.accounts.filter { $0.provider == provider }
        let isOpen = expanded == provider
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(spring) { expanded = isOpen ? nil : provider }
            } label: {
                HStack(spacing: 14) {
                    CalendarBrandMark(provider: provider, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text(providerSubtitle(provider, accounts: accounts))
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if !accounts.isEmpty {
                        MCPChip(icon: "checkmark", text: "Connected", color: MCPPalette.success)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.35))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerOnHover()
            .uiTestFrame("calendar.provider.\(provider.rawValue)")

            if !accounts.isEmpty {
                VStack(spacing: 0) {
                    ForEach(accounts) { account in
                        Divider().background(Color.white.opacity(0.06))
                        accountRow(account)
                    }
                }
                .padding(.horizontal, 16)
            }

            if isOpen {
                Divider().background(Color.white.opacity(0.06)).padding(.horizontal, 16)
                connectSteps(provider, hasAccount: !accounts.isEmpty)
                    .padding(16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isOpen ? Color.white.opacity(0.045) : WhispererColors.cardBackground(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isOpen ? provider.brandColor.opacity(0.35) : Color.white.opacity(0.07), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func providerSubtitle(_ provider: CalendarAccountProvider, accounts: [CalendarAccount]) -> String {
        if accounts.isEmpty {
            return provider == .google ? "Gmail and Google Workspace calendars"
                                       : "Outlook.com, Microsoft 365 and Exchange Online"
        }
        // The account rows below name each email; the subtitle only counts them.
        return accounts.count == 1 ? "1 account · read-only" : "\(accounts.count) accounts · read-only"
    }

    private func accountRow(_ account: CalendarAccount) -> some View {
        let stale = store.accountsNeedingReconnect.contains(account.id)
        let calendarCount = store.calendars.filter { $0.id.hasPrefix(account.id + "|") }.count
        return HStack(spacing: 10) {
            Image(systemName: stale ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(stale ? MCPPalette.warning : MCPPalette.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(stale ? "Access expired — sign in again to keep reminders coming"
                           : "\(calendarCount) calendar\(calendarCount == 1 ? "" : "s") · read-only")
                    .font(.system(size: 11))
                    .foregroundColor(stale ? MCPPalette.warning.opacity(0.9) : .white.opacity(0.4))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if stale {
                pillButton("Sign in again", prominent: true) { Task { await store.signIn(account.provider) } }
                    .disabled(store.signingIn != nil)
            }
            pillButton("Remove", prominent: false) { store.removeAccount(account) }
                .uiTestFrame("calendar.remove.\(account.id)")
        }
        .padding(.vertical, 11)
    }

    private func connectSteps(_ provider: CalendarAccountProvider, hasAccount: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                step(1, "A \(provider.shortName) sign-in window opens — your password goes to \(provider == .google ? "Google" : "Microsoft"), never to Whisperer.")
                step(2, "Allow read-only access to your calendars. Whisperer can't change or delete events.")
                step(3, "Your upcoming meetings appear here, and reminders start right away.")
            }
            HStack(spacing: 10) {
                if store.signingIn == provider {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for \(provider.shortName)…")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .frame(height: 34)
                } else {
                    Button {
                        Task { await store.signIn(provider) }
                    } label: {
                        HStack(spacing: 8) {
                            CalendarBrandMark(provider: provider, size: 16, onDark: false)
                            Text(hasAccount ? "Add another \(provider.shortName) account"
                                            : "Continue with \(provider == .google ? "Google" : "Microsoft")")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(Capsule().fill(LinearGradient(colors: [WhispererColors.accentBlue, WhispererColors.accentPurple],
                                                                  startPoint: .leading, endPoint: .trailing)))
                        .shadow(color: WhispererColors.accentBlue.opacity(0.3), radius: 8, y: 2)
                    }
                    .buttonStyle(.plain)
                    .pointerOnHover()
                    .disabled(!provider.isConfigured || store.signingIn != nil)
                    .opacity(provider.isConfigured ? 1 : 0.4)
                    .uiTestFrame("calendar.signIn.\(provider.rawValue)")
                }
                Spacer()
            }
            if !provider.isConfigured {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 11))
                        .foregroundColor(MCPPalette.warning)
                    Text("\(provider.shortName) sign-in isn't set up in this build yet: it needs an OAuth client ID in Info.plist (\(provider.clientIDKey)).")
                        .font(.system(size: 11.5))
                        .foregroundColor(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(WhispererColors.accentBlue)
                .frame(width: 20, height: 20)
                .background(Circle().fill(WhispererColors.accentBlue.opacity(0.15)))
            Text(text)
                .font(.system(size: 12.5))
                .foregroundColor(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Upcoming

    private var upcomingMeetings: [ScheduledMeeting] {
        let now = Date()
        return store.upcoming.filter { $0.endAt > now }.prefix(6).map { $0 }
    }

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Coming up", subtitle: refreshedText)
                Spacer()
                Button {
                    refreshing = true
                    Task {
                        await store.refresh(reason: "workspace")
                        refreshing = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .rotationEffect(.degrees(refreshing && !reduceMotion ? 360 : 0))
                        .animation(refreshing && !reduceMotion
                                   ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                                   value: refreshing)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Refresh now")
                .disabled(refreshing)
            }
            card {
                if upcomingMeetings.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "sun.max")
                            .foregroundColor(Color(hex: "FBBF24"))
                        Text("No meetings in the next 7 days on the calendars you chose.")
                            .font(.system(size: 12.5))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(upcomingMeetings.enumerated()), id: \.element.id) { index, meeting in
                            if index > 0 { Divider().background(Color.white.opacity(0.06)) }
                            meetingRow(meeting)
                        }
                    }
                }
            }
        }
    }

    private var refreshedText: String {
        guard let last = store.lastRefresh else { return "Your next 7 days" }
        return "Your next 7 days · updated \(last.formatted(date: .omitted, time: .shortened))"
    }

    private func meetingRow(_ meeting: ScheduledMeeting) -> some View {
        let now = Date()
        let live = meeting.isLive(at: now)
        let soon = meeting.startAt.timeIntervalSince(now) < 15 * 60
        let calendar = store.calendars.first { $0.id == meeting.calendarID }
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(calendar.map { Color(red: $0.color[0], green: $0.color[1], blue: $0.color[2]) } ?? WhispererColors.accentBlue)
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if live {
                        Text("NOW")
                            .font(.system(size: 9.5, weight: .bold))
                            .tracking(0.6)
                            .foregroundColor(Color(hex: "EF4444"))
                    }
                    Text(timeRange(meeting))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundColor(.white.opacity(0.5))
                    if let provider = meeting.provider {
                        Text("·").foregroundColor(.white.opacity(0.25))
                        Image(systemName: "video.fill").font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.4))
                        Text(provider.displayName)
                            .font(.system(size: 11.5))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if (live || soon) && !appState.isMeetingMode {
                if meeting.joinURL != nil {
                    pillButton("Join & Record", prominent: true) { coordinator.joinAndRecord(meeting) }
                } else {
                    pillButton("Record", prominent: true) { coordinator.record(meeting) }
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func timeRange(_ meeting: ScheduledMeeting) -> String {
        let start = meeting.startAt.formatted(date: .omitted, time: .shortened)
        let end = meeting.endAt.formatted(date: .omitted, time: .shortened)
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(meeting.startAt) { day = "Today" }
        else if cal.isDateInTomorrow(meeting.startAt) { day = "Tomorrow" }
        else { day = meeting.startAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
        return "\(day) · \(start)–\(end)"
    }

    // MARK: - Calendars

    private var calendarsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Calendars", subtitle: "Only meetings on the calendars you keep on remind you.")
            card {
                if store.calendars.isEmpty {
                    Text("No calendars found in the connected accounts yet.")
                        .font(.system(size: 12.5))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                            let calendars = store.calendars.filter { $0.id.hasPrefix(account.id + "|") }
                            if !calendars.isEmpty {
                                if index > 0 { Divider().background(Color.white.opacity(0.06)).padding(.vertical, 6) }
                                HStack(spacing: 8) {
                                    CalendarBrandMark(provider: account.provider, size: 14)
                                    Text(account.email)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.45))
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 6)
                                ForEach(calendars) { calendar in
                                    calendarRow(calendar)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func calendarRow(_ calendar: CalendarSummary) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(red: calendar.color[0], green: calendar.color[1], blue: calendar.color[2]))
                .frame(width: 9, height: 9)
            Text(calendar.title)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer()
            Toggle("", isOn: Binding(get: { store.isCalendarEnabled(calendar.id) },
                                     set: { store.setCalendar(calendar.id, enabled: $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(WhispererColors.accent)
                .labelsHidden()
        }
        .padding(.vertical, 6)
    }

    // MARK: - Reminders & recording

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Reminders", subtitle: connected ? nil : "Used once a calendar is connected.")
            card {
                VStack(spacing: 0) {
                    settingRow("Remind me before meetings",
                               subtitle: "A card with Join & Record, Record or Dismiss") {
                        Picker("", selection: $store.reminderLeadMinutes) {
                            ForEach(CalendarMeetingsStore.leadChoices, id: \.self) { choice in
                                Text(CalendarSettingsRows.leadLabel(choice)).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    rowDivider
                    settingRow("Show next meeting in the menu bar", subtitle: "On the Status tab") {
                        switchToggle($store.showNextMeetingInMenuBar)
                    }
                    rowDivider
                    settingRow("Remind for events with no attendees",
                               subtitle: "Off: only meetings with a link or other people remind you") {
                        switchToggle($store.includeUnlinkedSolo)
                    }
                }
                .disabled(!connected)
                .opacity(connected ? 1 : 0.5)
            }
        }
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Automatic recording", subtitle: "For calls Whisperer detects, with or without a calendar.")
            card {
                AutoRecordSettingsRows()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill").font(.system(size: 11))
            Text("Read-only. Events come straight from Google or Microsoft, sign-in tokens stay in your Keychain, and nothing is sent anywhere else.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(.white.opacity(0.35))
        .padding(.top, 4)
    }

    // MARK: - Pieces

    private func sectionTitle(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(WhispererColors.cardBackground(colorScheme)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    private func settingRow<Control: View>(_ title: String, subtitle: String,
                                           @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 10)
    }

    private var rowDivider: some View {
        Divider().background(Color.white.opacity(0.06))
    }

    private func switchToggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .toggleStyle(.switch)
            .tint(WhispererColors.accent)
            .labelsHidden()
    }

    private func pillButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(prominent ? .white : .white.opacity(0.65))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(prominent
                    ? AnyShapeStyle(LinearGradient(colors: [WhispererColors.accentBlue, WhispererColors.accentPurple],
                                                   startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(Color.white.opacity(0.07))))
        }
        .buttonStyle(.plain)
        .pointerOnHover()
    }
}

// MARK: - Meeting Notes strip

/// Under the Notes search field: the next meeting once a calendar is connected, otherwise a
/// one-line invitation to connect one (dismissible). Both open the Calendar page.
struct MeetingListCalendarStrip: View {
    @ObservedObject private var store = CalendarMeetingsStore.shared
    @AppStorage("meetings.calendarPromptDismissed") private var promptDismissed = false
    @State private var hovering = false

    var body: some View {
        if store.hasAnySource {
            if let next = store.nextMeeting {
                strip(icon: next.joinURL != nil ? "video.fill" : "calendar",
                      title: next.title,
                      subtitle: (next.isLive(at: Date()) ? "Now · " : "") + NextMeetingRow.when(next),
                      dismissible: false)
            }
        } else if !promptDismissed {
            strip(icon: "calendar.badge.plus",
                  title: "Connect your calendar",
                  subtitle: "Reminders and one-click Join & Record",
                  dismissible: true)
        }
    }

    private func strip(icon: String, title: String, subtitle: String, dismissible: Bool) -> some View {
        Button {
            NotificationCenter.default.post(name: .switchToCalendarTab, object: nil)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "F97316"))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color(hex: "F97316").opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if dismissible {
                    Button { withAnimation(.easeOut(duration: 0.2)) { promptDismissed = true } } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(.white.opacity(0.35))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(hovering ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "F97316").opacity(0.18), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.opacity)
    }
}

// MARK: - Provider marks

extension CalendarAccountProvider {
    var brandColor: Color { self == .google ? Color(hex: "4285F4") : Color(hex: "0078D4") }
}

/// The provider's mark, drawn rather than bundled: Google's four-colour G, and for Microsoft
/// the installed Outlook icon when there is one, otherwise the four-square logo.
struct CalendarBrandMark: View {
    let provider: CalendarAccountProvider
    var size: CGFloat = 20
    /// On the page's dark surface the mark sits on a white tile, as the vendors require.
    var onDark: Bool = true

    var body: some View {
        Group {
            if provider == .microsoft, onDark, let outlook = AppIconCache.image(for: "com.microsoft.Outlook") {
                Image(nsImage: outlook)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    if onDark {
                        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                            .fill(Color.white)
                    }
                    Group {
                        if provider == .google { GoogleG() } else { MicrosoftSquares() }
                    }
                    .padding(onDark ? size * 0.2 : 0)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider.displayName)
    }
}

private struct GoogleG: View {
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let line = side * 0.2
            ZStack {
                // Arcs clockwise from 3 o'clock; the gap at the upper right is the G's mouth.
                arc(0.0, 0.14, Color(hex: "4285F4"), line)
                arc(0.14, 0.39, Color(hex: "34A853"), line)
                arc(0.39, 0.60, Color(hex: "FBBC05"), line)
                arc(0.60, 0.875, Color(hex: "EA4335"), line)
                Rectangle()
                    .fill(Color(hex: "4285F4"))
                    .frame(width: side * 0.46, height: line)
                    .offset(x: side * 0.2)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func arc(_ from: CGFloat, _ to: CGFloat, _ color: Color, _ line: CGFloat) -> some View {
        Circle()
            .trim(from: from, to: to)
            .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .butt))
            .padding(line / 2)
    }
}

private struct MicrosoftSquares: View {
    var body: some View {
        GeometryReader { geo in
            let gap = geo.size.width * 0.06
            let cell = (geo.size.width - gap) / 2
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    Rectangle().fill(Color(hex: "F25022")).frame(width: cell, height: cell)
                    Rectangle().fill(Color(hex: "7FBA00")).frame(width: cell, height: cell)
                }
                HStack(spacing: gap) {
                    Rectangle().fill(Color(hex: "00A4EF")).frame(width: cell, height: cell)
                    Rectangle().fill(Color(hex: "FFB900")).frame(width: cell, height: cell)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
