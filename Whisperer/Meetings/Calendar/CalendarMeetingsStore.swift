//
//  CalendarMeetingsStore.swift
//  Whisperer
//
//  Upcoming meetings from the calendars on this Mac, kept current, and the reminder that fires
//  shortly before each one. Independent of call detection: everything here works with detection
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
        static let connected = "calendar.connected"
        static let enabledCalendars = "calendar.enabledCalendarIDs"
        static let reminderLead = "calendar.reminderLeadMinutes"
        static let showNextMeeting = "calendar.showNextMeetingInMenuBar"
        static let includeUnlinkedSolo = "calendar.includeUnlinkedSolo"
        static let decisions = "calendar.occurrenceDecisions"
    }

    /// Lead times offered in Settings. nil = reminders off.
    static let leadChoices: [Int?] = [nil, 0, 1, 2, 5]
    static let defaultLead = 2

    /// The user pressed Connect. Distinct from the OS grant: disconnecting stops reminders and
    /// clears our cache without touching the system permission (only the user can revoke that).
    @Published private(set) var isConnected: Bool
    @Published private(set) var access: CalendarAccess
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

    /// Meetings from now−30 min to now+7 days, in start order.
    @Published private(set) var upcoming: [ScheduledMeeting] = []
    /// The reminder on screen, if any.
    @Published private(set) var activeReminder: ScheduledMeeting? {
        didSet { if oldValue?.id != activeReminder?.id { NotificationCenter.default.post(name: NSNotification.Name("AppStateChanged"), object: nil) } }
    }
    @Published private(set) var lastRefresh: Date?

    var nextMeeting: ScheduledMeeting? {
        let now = Date()
        return upcoming.first { $0.endAt > now && decisions[$0.id] != .dismissed }
    }

    private let provider: CalendarMeetingProvider
    private var decisions: [String: OccurrenceDecision] = [:]
    private var reminderTask: Task<Void, Never>?
    private var reconcileTimer: Timer?
    private var changeTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    init(provider: CalendarMeetingProvider = EventKitCalendarProvider.shared) {
        self.provider = provider
        let defaults = UserDefaults.standard
        isConnected = defaults.bool(forKey: Keys.connected)
        access = provider.accessStatus()
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
        changeTask = Task { [weak self, provider] in
            for await _ in provider.observeChanges() {
                await self?.refresh(reason: "calendar changed")
            }
        }
        // Reconciliation for anything the notifications miss; reminders themselves are exact.
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(reason: "periodic") }
        }
        Task { await refresh(reason: "launch") }
    }

    // MARK: - Connect / disconnect

    /// Asks macOS for Calendar access (once — macOS itself never asks twice) and connects.
    @discardableResult
    func connect() async -> Bool {
        access = provider.accessStatus()
        if access == .notDetermined {
            do {
                _ = try await provider.requestReadAccess()
            } catch {
                Logger.warning("Calendar: access request failed — \(error.localizedDescription)", subsystem: .app)
            }
            access = provider.accessStatus()
        }
        guard access == .granted else {
            Logger.info("Calendar: access \(access) — connection not made", subsystem: .app)
            return false
        }
        isConnected = true
        UserDefaults.standard.set(true, forKey: Keys.connected)
        Logger.info("Calendar: connected", subsystem: .app)
        start()
        await refresh(reason: "connected")
        return true
    }

    /// Stops reminders and clears cached event data. Recordings are untouched, and the macOS
    /// permission stays as the user left it.
    func disconnect() {
        isConnected = false
        UserDefaults.standard.set(false, forKey: Keys.connected)
        upcoming = []
        calendars = []
        activeReminder = nil
        reminderTask?.cancel()
        decisions = [:]
        Self.saveDecisions(decisions)
        Logger.info("Calendar: disconnected — cached events cleared", subsystem: .app)
    }

    func setCalendar(_ id: String, enabled: Bool) {
        var ids = enabledCalendarIDs ?? Set(calendars.map(\.id))
        if enabled { ids.insert(id) } else { ids.remove(id) }
        enabledCalendarIDs = ids
        UserDefaults.standard.set(Array(ids), forKey: Keys.enabledCalendars)
        Task { await refresh(reason: "calendar selection") }
    }

    func isCalendarEnabled(_ id: String) -> Bool { enabledCalendarIDs?.contains(id) ?? true }

    func openCalendarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Refresh

    func refresh(reason: String) async {
        access = provider.accessStatus()
        guard isConnected, access == .granted else {
            if isConnected, access != .granted {
                // Revoked in System Settings: stop quietly, keep the connect intent so a re-grant
                // resumes without another click.
                upcoming = []
                activeReminder = nil
            }
            return
        }
        calendars = provider.calendars()
        let now = Date()
        let snapshots = await provider.events(from: now.addingTimeInterval(-30 * 60),
                                              to: now.addingTimeInterval(7 * 86_400),
                                              calendarIDs: enabledCalendarIDs)
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
        Logger.debug("Calendar: \(upcoming.count) meeting(s) after \(reason)", subsystem: .app)
    }

    // MARK: - Reminders

    /// When `meeting`'s reminder is due, or nil when it should not remind.
    func reminderDate(for meeting: ScheduledMeeting, now: Date = Date()) -> Date? {
        guard let lead = reminderLeadMinutes else { return nil }
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
