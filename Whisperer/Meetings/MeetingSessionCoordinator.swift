//
//  MeetingSessionCoordinator.swift
//  Whisperer
//
//  One owner for "a meeting is about to start / has started / has ended", fed by two independent
//  sources — calendar reminders (`CalendarMeetingsStore`) and live call detection
//  (`MeetingDetector`) — so they never raise conflicting prompts or start two recordings.
//
//  Calendar presence means a meeting *may* happen; detection means one *appears to be*
//  happening. Only detection at `MeetingCallConfidence.confirmed`, with the user's explicit
//  opt-in, may start a recording without a click — after a visible, cancellable countdown and a
//  re-check of the evidence the instant before it starts. No capture logic lives here: recording
//  goes through `MeetingSession`, with all of its permission checks and file lifecycle.
//

import AppKit
import Combine
import Foundation

@MainActor
final class MeetingSessionCoordinator: ObservableObject {
    static let shared = MeetingSessionCoordinator()

    // MARK: Settings

    enum Keys {
        static let autoRecord = "meeting.autoRecordDetected"
        static let countdown = "meeting.autoRecordCountdownSeconds"
        static let autoStop = "meeting.autoStopWhenCallEnds"
        static let maxHours = "meeting.autoRecordMaxHours"
        static let excludedApps = "meeting.excludedBundleIDs"
    }

    static let countdownRange = 5...30
    static let defaultCountdown = 10
    static let defaultMaxHours = 3.0

    /// Off by default, and only ever switched on by the user.
    var autoRecordEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.autoRecord) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.autoRecord); objectWillChange.send() }
    }
    var countdownSeconds: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Keys.countdown)
            return v == 0 ? Self.defaultCountdown : min(max(v, Self.countdownRange.lowerBound), Self.countdownRange.upperBound)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.countdown); objectWillChange.send() }
    }
    var autoStopWhenCallEnds: Bool {
        get { UserDefaults.standard.object(forKey: Keys.autoStop) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.autoStop); objectWillChange.send() }
    }
    var maxAutoRecordingHours: Double {
        get { (UserDefaults.standard.object(forKey: Keys.maxHours) as? Double) ?? Self.defaultMaxHours }
        set { UserDefaults.standard.set(newValue, forKey: Keys.maxHours); objectWillChange.send() }
    }
    var excludedBundleIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Keys.excludedApps) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Keys.excludedApps); objectWillChange.send() }
    }

    // MARK: Published state (drives the HUD cards)

    /// The detected-call card's title: the calendar event's when one matches, else the app's.
    @Published private(set) var detectedTitle: String?
    /// Seconds left before an automatic start; nil when the card is a plain prompt.
    @Published private(set) var countdownSecondsLeft: Int?
    /// A detection-started recording whose call may have ended (an ambiguous end signal).
    @Published private(set) var endPendingPrompt = false {
        didSet { if oldValue != endPendingPrompt { NotificationCenter.default.post(name: NSNotification.Name("AppStateChanged"), object: nil) } }
    }
    /// A start the user asked for failed — never pretend a recording is running.
    @Published private(set) var startFailure: String? {
        didSet { if oldValue != startFailure { NotificationCenter.default.post(name: NSNotification.Name("AppStateChanged"), object: nil) } }
    }

    // MARK: Private state

    private enum Origin { case detectedPrompt, detectedAuto, reminder, manual }

    /// The recording this coordinator started and is watching, if any.
    private struct Tracked {
        let session: MeetingSession
        let origin: Origin
        let bundleID: String?
        let signals: MeetingCallSignals?
        let startedAt: Date
        var occurrenceID: String?
    }

    private var tracked: Tracked?
    private var startInFlight = false
    private var countdownTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var currentDetection: MeetingDetector.DetectedMeetingApp?
    private var matchedMeeting: ScheduledMeeting?

    private init() {}

    // MARK: - Detection

    /// Called for every detection before its card shows. Returns false to swallow it.
    func shouldPresentDetection(_ app: MeetingDetector.DetectedMeetingApp) -> Bool {
        if excludedBundleIDs.contains(app.bundleID) {
            Logger.info("Meetings: detection in an excluded app — not prompting", subsystem: .app)
            MeetingDetector.shared.onUserDismissed()
            return false
        }
        guard !isBusyRecording else { return false }

        let calendar = CalendarMeetingsStore.shared
        let match = calendar.meeting(matching: app.provider)
        // "Join only" means the user chose not to record this one.
        if let match, calendar.decision(for: match.id) == .joinedOnly {
            Logger.info("Meetings: detected call matches a join-only meeting — not prompting", subsystem: .app)
            MeetingDetector.shared.onUserDismissed()
            return false
        }
        // One card per meeting: a reminder already on screen for this call gives way to the
        // detection, which carries the stronger signal and the same title.
        if let shown = calendar.activeReminder, shown.id == match?.id || shown.provider == app.provider {
            calendar.clearActiveReminder()
        }

        currentDetection = app
        matchedMeeting = match
        detectedTitle = match?.title
        countdownSecondsLeft = nil
        startFailure = nil

        Logger.info("Meetings: detection \(MeetingCallPolicy.explain(app.signals)) calendarMatch=\(match != nil)", subsystem: .app)
        if autoRecordEnabled, app.confidence == .confirmed {
            beginCountdown(for: app)
        }
        return true
    }

    /// "Start recording" on the detected-call card (also "Start now" during a countdown).
    func startFromDetection(_ app: MeetingDetector.DetectedMeetingApp) {
        let auto = countdownSecondsLeft != nil
        cancelCountdownTask()
        Task { await start(title: title(for: app), origin: auto ? .detectedAuto : .detectedPrompt,
                           bundleID: app.bundleID, appName: app.name, signals: app.signals,
                           occurrence: matchedMeeting) }
        AppState.shared.dismissMeetingNotification()
    }

    /// "Not now" / the card's close button / "Cancel for this call". Suppressed for this call.
    func dismissDetection() {
        cancelCountdownTask()
        AppState.shared.dismissMeetingNotification()
        MeetingDetector.shared.onUserDismissed()
        clearDetection()
    }

    /// "Don't ask for this app".
    func excludeDetectedApp() {
        if let id = currentDetection?.bundleID { excludedBundleIDs.insert(id) }
        dismissDetection()
    }

    /// "Turn off auto-record" from the countdown: the card stays, as a plain prompt.
    func disableAutoRecordFromCountdown() {
        autoRecordEnabled = false
        cancelCountdownTask()
        Logger.info("Meetings: auto-record turned off from the countdown", subsystem: .app)
    }

    /// The detection card went away by itself (timed out).
    func detectionCardClosed() {
        cancelCountdownTask()
        clearDetection()
    }

    private func clearDetection() {
        currentDetection = nil
        matchedMeeting = nil
        detectedTitle = nil
        countdownSecondsLeft = nil
    }

    private func beginCountdown(for app: MeetingDetector.DetectedMeetingApp) {
        cancelCountdownTask()
        let total = countdownSeconds
        countdownSecondsLeft = total
        Logger.info("Meetings: auto-record countdown \(total)s", subsystem: .app)
        countdownTask = Task { [weak self] in
            for left in stride(from: total - 1, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                // Evidence must hold the whole way. Losing it dearms the start — the card stays
                // as a plain prompt, so the user can still start by hand.
                guard MeetingDetector.shared.liveness(bundleID: app.bundleID) == .live else {
                    Logger.info("Meetings: call evidence lost during the countdown — not starting", subsystem: .app)
                    self.countdownSecondsLeft = nil
                    return
                }
                self.countdownSecondsLeft = left
            }
            guard let self, !Task.isCancelled, self.countdownSecondsLeft == 0 else { return }
            // Final check, the instant before starting.
            guard self.autoRecordEnabled, MeetingDetector.shared.liveness(bundleID: app.bundleID) == .live else {
                self.countdownSecondsLeft = nil
                return
            }
            self.startFromDetection(app)
        }
    }

    private func cancelCountdownTask() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownSecondsLeft = nil
    }

    // MARK: - Reminders

    /// Called when a calendar reminder is due. Returns false when it should not show.
    func presentReminder(_ meeting: ScheduledMeeting) -> Bool {
        // Already recording this meeting: the reminder has nothing to add.
        if tracked?.occurrenceID == meeting.id, AppState.shared.isMeetingMode { return false }
        // A detected-call card is already up for it.
        if AppState.shared.showMeetingDetectedToast,
           currentDetection?.provider == meeting.provider || matchedMeeting?.id == meeting.id {
            return false
        }
        return true
    }

    /// Whether a meeting is being recorded now — the reminder offers "Open recording" or an
    /// explicit switch instead of a second start.
    var isBusyRecording: Bool {
        AppState.shared.isMeetingMode || AppState.shared.pendingMeetingStarts > 0 || startInFlight
    }

    var isRecordingReminderMeeting: Bool {
        guard let id = CalendarMeetingsStore.shared.activeReminder?.id else { return false }
        return tracked?.occurrenceID == id && AppState.shared.isMeetingMode
    }

    func joinAndRecord(_ meeting: ScheduledMeeting) {
        guard let url = meeting.joinURL else { return }
        NSWorkspace.shared.open(url)
        CalendarMeetingsStore.shared.markRecording(meeting)
        Task { await start(title: meeting.title, origin: .reminder, bundleID: nil, appName: meeting.provider?.displayName,
                           signals: nil, occurrence: meeting) }
    }

    func joinOnly(_ meeting: ScheduledMeeting) {
        guard let url = meeting.joinURL else { return }
        NSWorkspace.shared.open(url)
        CalendarMeetingsStore.shared.markJoinedOnly(meeting)
    }

    func record(_ meeting: ScheduledMeeting) {
        CalendarMeetingsStore.shared.markRecording(meeting)
        Task { await start(title: meeting.title, origin: .reminder, bundleID: nil, appName: nil,
                           signals: nil, occurrence: meeting) }
    }

    /// The user explicitly chose to end the current meeting and record the reminded one.
    func stopCurrentAndRecord(_ meeting: ScheduledMeeting) {
        Task {
            await AppState.shared.activeMeetingSession?.stopRecording()
            // The stop drains its tail before the recorder is free; start only once it is.
            let deadline = Date().addingTimeInterval(30)
            while (AppState.shared.isMeetingMode || AppState.shared.state != .idle), Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            record(meeting)
        }
    }

    func openRecording() {
        HistoryWindowManager.shared.showWindowAndDismissMenu()
        CalendarMeetingsStore.shared.clearActiveReminder()
    }

    // MARK: - Starting (exactly once)

    private func start(title: String, origin: Origin, bundleID: String?, appName: String?,
                       signals: MeetingCallSignals?, occurrence: ScheduledMeeting?) async {
        // Exactly-once: the idle → starting transition happens here, before any await.
        guard !startInFlight, !AppState.shared.isMeetingMode, AppState.shared.pendingMeetingStarts == 0 else {
            Logger.info("Meetings: start ignored — a meeting is already recording or starting", subsystem: .app)
            return
        }
        startInFlight = true
        defer { startInFlight = false }
        startFailure = nil

        let session = MeetingSession()
        await session.startRecording(title: title, surface: .floatingWindow,
                                     sourceBundleID: bundleID, sourceAppName: appName)

        // Never imply a recording that did not start.
        guard session.isRecording, AppState.shared.activeMeetingSession === session else {
            startFailure = "The meeting recording couldn't start."
            Logger.warning("Meetings: start failed (origin \(origin))", subsystem: .app)
            return
        }
        tracked = Tracked(session: session, origin: origin, bundleID: bundleID, signals: signals,
                          startedAt: Date(), occurrenceID: occurrence?.id)
        if let occurrence, !occurrence.participants.isEmpty, let meetingID = session.meetingID {
            await MeetingManager.shared.updateParticipants(meetingID: meetingID, participants: occurrence.participants)
        }
        Logger.info("Meetings: recording started (origin \(origin), calendar=\(occurrence != nil))", subsystem: .app)
        clearDetection()
        startMonitoring()
    }

    /// Name for a detected call: the calendar event's title when one matches, else
    /// "Unscheduled Zoom meeting · 11:24" — never an invented title. The AI may refine the
    /// generated name later; it never renames a calendar title (`isAutoGeneratedTitle`).
    func title(for app: MeetingDetector.DetectedMeetingApp) -> String {
        if let match = matchedMeeting ?? CalendarMeetingsStore.shared.meeting(matching: app.provider) {
            return match.title
        }
        return Self.defaultTitle(appName: app.name, at: Date())
    }

    nonisolated static func defaultTitle(appName: String, at date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let name = appName.hasPrefix("Meeting in ") ? "call in \(appName.dropFirst("Meeting in ".count))" : "\(appName) meeting"
        return "Unscheduled \(name) · \(time)"
    }

    // MARK: - Watching a recording we started

    /// Debounce before a definitive call end stops the recording (mute, device handoffs and
    /// reconnects drop the signal for less than this).
    static let definitiveEndDebounce: TimeInterval = 10
    /// An ambiguous end (a browser call going quiet) only ever asks, and not before this.
    static let ambiguousEndAfter: TimeInterval = 30

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if !self.tick() { return }
            }
        }
    }

    /// One monitoring step. Returns false once there is nothing left to watch.
    private func tick() -> Bool {
        guard let t = tracked else { return false }
        guard t.session.isRecording, AppState.shared.activeMeetingSession === t.session else {
            // Stopped by the user, the silence card or anything else.
            tracked = nil
            endPendingPrompt = false
            return false
        }
        let auto = t.origin == .detectedAuto
        // Bounded length, for recordings nobody started by hand.
        if auto, Date().timeIntervalSince(t.startedAt) >= maxAutoRecordingHours * 3600 {
            Logger.info("Meetings: automatic recording reached its \(maxAutoRecordingHours)h limit — stopping", subsystem: .app)
            stop(t, reason: "maximum length")
            return false
        }
        guard autoStopWhenCallEnds, t.origin == .detectedAuto || t.origin == .detectedPrompt,
              let bundleID = t.bundleID else { return true }

        let definitive = t.signals.map { $0.source == .nativeApp && MeetingCallPolicy.confidence($0) == .confirmed } ?? false
        switch MeetingDetector.shared.liveness(bundleID: bundleID) {
        case .live, .unknown:
            if endPendingPrompt { endPendingPrompt = false }
        case .appQuit:
            stop(t, reason: "the call app quit")
            return false
        case .ended(let since):
            let quiet = Date().timeIntervalSince(since)
            if definitive, quiet >= Self.definitiveEndDebounce {
                stop(t, reason: "the call ended")
                return false
            }
            if !definitive, quiet >= Self.ambiguousEndAfter, !endPendingPrompt {
                endPendingPrompt = true
                Logger.info("Meetings: call may have ended — asking", subsystem: .app)
            }
        }
        return true
    }

    private func stop(_ t: Tracked, reason: String) {
        Logger.info("Meetings: stopping the recording — \(reason)", subsystem: .app)
        endPendingPrompt = false
        tracked = nil
        Task { await t.session.stopRecording() }
    }

    /// "Stop" on the may-have-ended card.
    func confirmEnd() {
        guard let t = tracked else { endPendingPrompt = false; return }
        stop(t, reason: "the user confirmed the call ended")
    }

    /// "Keep recording" on the may-have-ended card: don't ask again for this recording.
    func keepRecordingAfterAmbiguousEnd() {
        endPendingPrompt = false
        if var t = tracked {
            t = Tracked(session: t.session, origin: .manual, bundleID: t.bundleID, signals: t.signals,
                        startedAt: t.startedAt, occurrenceID: t.occurrenceID)
            tracked = t
        }
    }

    func dismissStartFailure() { startFailure = nil }
}
