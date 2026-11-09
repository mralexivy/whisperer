//
//  CalendarMeetingsStore.swift
//  Whisperer
//
//  Upcoming meetings from the user's Google and Microsoft calendars, kept current, and the
//  reminder that fires shortly before each one. Independent of call detection: everything here works with detection
//  off, and detection works with this never connected.
//
//  Local only. Event titles, links and attendees never leave the Mac and are never logged.
//

import AppKit
import Combine
import Foundation

/// What the user did with one meeting occurrence. Persisted, so a restart neither repeats a
/// reminder nor forgets a dismissal.
nonisolated enum OccurrenceDecision: Codable, Equatable, Sendable {
    case reminded
    case dismissed
    case snoozed(until: Date)
    /// Joined without recording — the detected-call prompt is held back for this meeting.
    case joinedOnly
    case recording
}

@MainActor
final class CalendarMeetingsStore: ObservableObject {
    static let shared = CalendarMeetingsStore()

    // MARK: Settings

    enum Keys {
        static let enabledCalendars = "calendar.enabledCalendarIDs"
        static let reminderLead = "calendar.reminderLeadMinutes"
        static let showNextMeeting = "calendar.showNextMeetingInMenuBar"
        static let includeUnlinkedSolo = "calendar.includeUnlinkedSolo"
        static let decisions = "calendar.occurrenceDecisions"
        static let accounts = "calendar.accounts"
    }

    /// Lead times offered in Settings. nil = reminders off.
    static let leadChoices: [Int?] = [nil, 0, 1, 2, 5]
    static let defaultLead = 2

    @Published private(set) var calendars: [CalendarSummary] = []
    /// nil = every calendar.
    @Published private(set) var enabledCalendarIDs: Set<String>?
    @Published var reminderLeadMinutes: Int? {
        didSet { persistLead(); scheduleNextReminder() }
    }
    @Published var showNextMeetingInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showNextMeetingInMenuBar, forKey: Keys.showNextMeeting) }
    }
    @Published var includeUnlinkedSolo: Bool {
        didSet {
            UserDefaults.standard.set(includeUnlinkedSolo, forKey: Keys.includeUnlinkedSolo)
            Task { await refresh(reason: "solo-events setting") }
        }
    }

    /// Signed-in Google / Microsoft accounts — the calendar sources.
    @Published private(set) var accounts: [CalendarAccount] = []
    /// Accounts whose access was revoked or expired — they need "Sign in again".
    @Published private(set) var accountsNeedingReconnect: Set<String> = []
    @Published private(set) var signingIn: CalendarAccountProvider?
    @Published private(set) var signInError: String?

    /// At least one account is signed in.
    var hasAnySource: Bool { !accounts.isEmpty }

    /// Meetings from now−30 min to now+7 days, in start order.
    @Published private(set) var upcoming: [ScheduledMeeting] = []
    /// The reminder on screen, if any.
    @Published private(set) var activeReminder: ScheduledMeeting? {
        didSet { if oldValue?.id != activeReminder?.id { NotificationCenter.default.post(name: NSNotification.Name("AppStateChanged"), object: nil) } }
    }
    @Published private(set) var lastRefresh: Date?

    var nextMeeting: ScheduledMeeting? {
        let now = Date()
        return upcoming.filter { $0.endAt > now && decisions[$0.id] != .dismissed }.preferredFirst
    }

    /// Last good events per account, kept through a network failure so reminders survive it.
    private var remoteCache: [String: (calendars: [CalendarSummary], events: [CalendarEventSnapshot])] = [:]
    /// Injected in tests; real accounts use the provider's REST API.
    var makeRemoteSource: (CalendarAccount) -> RemoteCalendarSource = { account in
        switch account.provider {
        case .google: return GoogleCalendarSource(account: account)
        case .microsoft: return MicrosoftCalendarSource(account: account)
        }
    }
    private var decisions: [String: OccurrenceDecision] = [:]
    private var reminderTask: Task<Void, Never>?
    private var reconcileTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    init() {
        let defaults = UserDefaults.standard
        enabledCalendarIDs = (defaults.array(forKey: Keys.enabledCalendars) as? [String]).map(Set.init)
        if defaults.object(forKey: Keys.reminderLead) == nil {
            reminderLeadMinutes = Self.defaultLead
        } else {
            let stored = defaults.integer(forKey: Keys.reminderLead)
            reminderLeadMinutes = stored < 0 ? nil : stored
        }
        showNextMeetingInMenuBar = defaults.object(forKey: Keys.showNextMeeting) as? Bool ?? true
        includeUnlinkedSolo = defaults.bool(forKey: Keys.includeUnlinkedSolo)
        decisions = Self.loadDecisions()
        if let data = defaults.data(forKey: Keys.accounts),
           let saved = try? JSONDecoder().decode([CalendarAccount].self, from: data) {
            accounts = saved
        }
    }

    // MARK: - Lifecycle

    /// Starts keeping meetings current. Cheap and idempotent; does nothing until connected.
    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh(reason: "wake") }
        })
        for name in [NSNotification.Name.NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh(reason: "clock or time zone") }
            })
        }
        // Provider APIs push no change events to a desktop app, so changes are picked up by this
        // reconciliation (and on wake); reminders themselves fire at their exact time.
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(reason: "periodic") }
        }
        Task { await refresh(reason: "launch") }
    }

    // MARK: - Google / Microsoft accounts

    /// "Sign in with Google / Microsoft": the provider's own sign-in sheet, read-only access.
    func signIn(_ provider: CalendarAccountProvider) async {
        signInError = nil
        signingIn = provider
        defer { signingIn = nil }
        do {
            let (account, _) = try await CalendarOAuthClient.shared.signIn(provider)
            if !accounts.contains(account) { accounts.append(account) }
            accountsNeedingReconnect.remove(account.id)
            saveAccounts()
            Logger.info("Calendar: \(provider.rawValue) account connected", subsystem: .app)
            start()
            await refresh(reason: "account connected")
        } catch CalendarAccountError.cancelled {
            Logger.info("Calendar: \(provider.rawValue) sign-in cancelled", subsystem: .app)
        } catch {
            signInError = error.localizedDescription
            Logger.warning("Calendar: \(provider.rawValue) sign-in failed — \(error.localizedDescription)", subsystem: .app)
        }
    }

    /// Signs the account out of Whisperer: tokens deleted, its cached events and calendars gone.
    func removeAccount(_ account: CalendarAccount) {
        CalendarOAuthClient.shared.forget(account)
        accounts.removeAll { $0 == account }
        accountsNeedingReconnect.remove(account.id)
        remoteCache[account.id] = nil
        saveAccounts()
        Task { await refresh(reason: "account removed") }
    }

    func dismissSignInError() { signInError = nil }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Keys.accounts)
        }
    }

    func setCalendar(_ id: String, enabled: Bool) {
        var ids = enabledCalendarIDs ?? Set(calendars.map(\.id))
        if enabled { ids.insert(id) } else { ids.remove(id) }
        enabledCalendarIDs = ids
        UserDefaults.standard.set(Array(ids), forKey: Keys.enabledCalendars)
        Task { await refresh(reason: "calendar selection") }
    }

    func isCalendarEnabled(_ id: String) -> Bool { enabledCalendarIDs?.contains(id) ?? true }

    // MARK: - Refresh

    func refresh(reason: String) async {
        guard !accounts.isEmpty else {
            upcoming = []
            calendars = []
            activeReminder = nil
            return
        }
        let now = Date()
        let start = now.addingTimeInterval(-30 * 60)
        let end = now.addingTimeInterval(7 * 86_400)

        var allCalendars: [CalendarSummary] = []
        var snapshots: [CalendarEventSnapshot] = []
        for account in accounts {
            let (calendars, events) = await fetchRemote(account, from: start, to: end)
            allCalendars += calendars
            snapshots += events
        }
        calendars = allCalendars

        // The same event reached through two accounts (an invite on both a Google and an Outlook
        // calendar) has one occurrence ID — its iCalendar UID plus start — so it appears once.
        var seen = Set<String>()
        upcoming = snapshots
            .compactMap { MeetingEventClassifier.meeting(from: $0, includeUnlinkedSolo: includeUnlinkedSolo) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.startAt < $1.startAt }
        lastRefresh = now
        pruneDecisions(now: now)
        // A reminder on screen for an event that moved, was cancelled or declined goes away.
        if let shown = activeReminder, !upcoming.contains(where: { $0.id == shown.id }) {
            activeReminder = nil
        } else if let shown = activeReminder, let fresh = upcoming.first(where: { $0.id == shown.id }) {
            activeReminder = fresh
        }
        scheduleNextReminder()
        Logger.debug("Calendar: \(upcoming.count) meeting(s) from \(accounts.count) account(s) after \(reason)", subsystem: .app)
    }

    /// One account's calendars and events. On a network failure the last good copy is used, so
    /// a flaky connection does not drop reminders; a revoked grant flags the account instead.
    private func fetchRemote(_ account: CalendarAccount, from start: Date, to end: Date)
        async -> (calendars: [CalendarSummary], events: [CalendarEventSnapshot]) {
        let source = makeRemoteSource(account)
        do {
            let calendars = try await source.calendars()
            let selected = calendars.map(\.id).filter { isCalendarEnabled($0) }.compactMap(account.localCalendarID)
            let events = try await source.events(from: start, to: end, calendarIDs: selected)
            remoteCache[account.id] = (calendars, events)
            accountsNeedingReconnect.remove(account.id)
            return (calendars, events)
        } catch CalendarAccountError.needsReconnect {
            accountsNeedingReconnect.insert(account.id)
            Logger.warning("Calendar: \(account.provider.rawValue) account needs signing in again", subsystem: .app)
            return remoteCache[account.id] ?? ([], [])
        } catch {
            Logger.warning("Calendar: \(account.provider.rawValue) refresh failed — \(error.localizedDescription); keeping last copy", subsystem: .app)
            return remoteCache[account.id] ?? ([], [])
        }
    }

    // MARK: - Reminders

    /// When `meeting`'s reminder is due, or nil when it should not remind.
    func reminderDate(for meeting: ScheduledMeeting, now: Date = Date()) -> Date? {
        guard let lead = reminderLeadMinutes else { return nil }
        // Overlapped by a meeting the user accepted: that one reminds, this one stays quiet.
        guard upcoming.filter({ decisions[$0.id] != .dismissed }).outranking(meeting) == nil else { return nil }
        switch decisions[meeting.id] {
        case .dismissed, .reminded, .joinedOnly, .recording:
            return nil
        case .snoozed(let until):
            return until < meeting.endAt ? until : nil
        case nil:
            let due = meeting.startAt.addingTimeInterval(TimeInterval(-lead * 60))
            // Missed (app was closed, Mac asleep): still worth a reminder in the meeting's first
            // ten minutes — later than that it is noise about a meeting already under way.
            return now < min(meeting.endAt, meeting.startAt.addingTimeInterval(600)) ? due : nil
        }
    }

    private func scheduleNextReminder() {
        reminderTask?.cancel()
        let now = Date()
        let due = upcoming.compactMap { m in reminderDate(for: m, now: now).map { (m, $0) } }
            .min { $0.1 < $1.1 }
        guard let (meeting, date) = due else { return }
        let delay = max(0, date.timeIntervalSince(now))
        reminderTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.fireReminder(meeting) }
        }
    }

    private func fireReminder(_ meeting: ScheduledMeeting) {
        // Re-read: the event may have changed while we slept.
        guard let current = upcoming.first(where: { $0.id == meeting.id }),
              reminderDate(for: current) != nil, current.endAt > Date() else {
            scheduleNextReminder()
            return
        }
        record(.reminded, for: current.id)
        if MeetingSessionCoordinator.shared.presentReminder(current) {
            activeReminder = current
            Logger.info("Calendar: reminder shown (\(current.provider?.rawValue ?? "no link"))", subsystem: .app)
        }
        scheduleNextReminder()
    }

    // MARK: - Reminder actions

    func dismissReminder() {
        guard let m = activeReminder else { return }
        record(.dismissed, for: m.id)
        activeReminder = nil
    }

    /// Snoozes for 5 minutes, never past the meeting's end.
    func snoozeReminder(minutes: Double = 5) {
        guard let m = activeReminder else { return }
        let until = min(Date().addingTimeInterval(minutes * 60), m.endAt.addingTimeInterval(-60))
        guard until > Date() else { dismissReminder(); return }
        record(.snoozed(until: until), for: m.id)
        activeReminder = nil
        scheduleNextReminder()
    }

    func markJoinedOnly(_ meeting: ScheduledMeeting) {
        record(.joinedOnly, for: meeting.id)
        if activeReminder?.id == meeting.id { activeReminder = nil }
    }

    func markRecording(_ meeting: ScheduledMeeting) {
        record(.recording, for: meeting.id)
        if activeReminder?.id == meeting.id { activeReminder = nil }
    }

    func decision(for id: String) -> OccurrenceDecision? { decisions[id] }

    func clearActiveReminder() { activeReminder = nil }

    /// A calendar meeting on now (or starting within `slack`) on `provider`, for naming a detected
    /// call. Display only: a match never raises a call's confidence.
    func meeting(matching provider: ConferenceProvider?, at now: Date = Date(),
                 slack: TimeInterval = 15 * 60) -> ScheduledMeeting? {
        let window = upcoming.filter { $0.startAt.addingTimeInterval(-slack) <= now && now < $0.endAt }
            .sorted { $0.commitmentRank > $1.commitmentRank }
        if let provider, let exact = window.first(where: { $0.provider == provider }) { return exact }
        // A single unlinked meeting on now is probably this one; two is a guess, so no title.
        let unlinked = window.filter { $0.provider == nil }
        return provider == nil && unlinked.count == 1 ? unlinked.first : nil
    }

    // MARK: - Persistence

    private func record(_ decision: OccurrenceDecision, for id: String) {
        decisions[id] = decision
        Self.saveDecisions(decisions)
    }

    /// Decisions for occurrences that ended more than a day ago are dropped. IDs carry the start
    /// time, so they can be aged without the event.
    private func pruneDecisions(now: Date) {
        let cutoff = now.addingTimeInterval(-86_400).timeIntervalSince1970
        let before = decisions.count
        decisions = decisions.filter { key, _ in
            guard let stamp = key.split(separator: "@").last.flatMap({ Double($0) }) else { return true }
            return stamp > cutoff
        }
        if decisions.count != before { Self.saveDecisions(decisions) }
    }

    private func persistLead() {
        UserDefaults.standard.set(reminderLeadMinutes ?? -1, forKey: Keys.reminderLead)
    }

    private static func loadDecisions() -> [String: OccurrenceDecision] {
        guard let data = UserDefaults.standard.data(forKey: Keys.decisions),
              let decoded = try? JSONDecoder().decode([String: OccurrenceDecision].self, from: data) else { return [:] }
        return decoded
    }

    private static func saveDecisions(_ decisions: [String: OccurrenceDecision]) {
        if let data = try? JSONEncoder().encode(decisions) {
            UserDefaults.standard.set(data, forKey: Keys.decisions)
        }
    }
}
