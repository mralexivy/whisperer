//
//  MeetingPromptLedger.swift
//  Whisperer
//
//  The refire guard for meeting prompts — scoped to the call, not to the clock.
//

import Foundation

/// What audio-capture attribution knows about one app right now.
enum MeetingCaptureStatus: Equatable {
    /// The app is holding the microphone — whatever it is doing has not finished.
    ///
    /// `since` is when this unbroken run began and `precededByGap` is how long the app was off the
    /// microphone immediately before it (nil for its first observed run). Both are needed because
    /// "quiet right now" cannot describe a call that already ended: two meetings back to back are
    /// separated by seconds, so by the time anything asks, the provider is capturing again.
    case capturing(since: Date, precededByGap: TimeInterval?)
    /// The app's last unbroken capture run ended at this time.
    case ended(Date)
    /// The app has never been seen capturing, so the end of its call cannot be observed.
    case unobserved
}

/// Remembers which providers have already raised a meeting prompt, and releases that guard when
/// the call it belongs to ends.
///
/// The guard exists to stop one call prompting twice. It used to be written as a wall-clock
/// window — fire once, then reject that display name for thirty minutes — and nothing cleared the
/// entry when the user *accepted* the prompt or let it time out. Only the dismissal path cleared
/// it, and only when the hardware happened to go idle. So the second meeting of a morning was
/// dropped in silence: the guard is checked before any scoring or logging, on every path
/// (`score()` and all five fallback-poll branches alike), which is why detection looked like it
/// worked exactly once per provider per session.
///
/// A call end is observable: the provider stops holding the microphone, and `AudioProcessMonitor`
/// already tracks unbroken capture runs per app. So the guard is released by that event, and the
/// 30-minute window survives only as a ceiling for providers matched *without* attribution — a
/// virtual audio device, a frontmost native app — whose end genuinely cannot be seen.
struct MeetingPromptLedger {

    /// Ceiling for a provider whose call end cannot be observed.
    var refireInterval: TimeInterval = 30 * 60

    /// How long a provider must be off the microphone before its guard is released. Long enough to
    /// ride out a device switch or a reconnect mid-call, short enough that the next meeting in a
    /// back-to-back block still prompts.
    var callEndedGrace: TimeInterval = 20

    /// The same, for a provider the user dismissed. Muting yourself for a minute in a long call is
    /// ordinary, and it must not bring back a toast that was explicitly waved away — a dismissal is
    /// released only once the provider has been quiet long enough to be a different call.
    var dismissalGrace: TimeInterval = 120

    /// How long a provider must have been off the microphone *between two capture runs* for the
    /// second run to count as a different call.
    ///
    /// Much shorter than `callEndedGrace`, and deliberately so: a gap that has already closed is
    /// far better evidence than a gap still in progress. Leaving one call and joining the next
    /// takes seconds, while a device switch or a reconnect mid-call drops capture for well under
    /// one. This threshold also overrides a dismissal — waving away the toast answers the call it
    /// was raised for, not the next one.
    var newCallGap: TimeInterval = 5

    private struct Entry {
        let bundleID: String
        let firedAt: Date
        var dismissed: Bool
    }

    private var entries: [String: Entry] = [:]

    var dismissedCount: Int { entries.values.filter(\.dismissed).count }

    /// No outstanding guard — nothing is waiting for a call end to be observed.
    var isEmpty: Bool { entries.isEmpty }

    /// The app a prompt was attributed to, for logging why that name is still suppressed.
    func bundleID(for name: String) -> String? { entries[name]?.bundleID }

    // MARK: - Recording

    mutating func recordPrompt(name: String, bundleID: String, at now: Date = Date()) {
        entries[name] = Entry(bundleID: bundleID, firedAt: now, dismissed: false)
    }

    mutating func recordDismissal(name: String) {
        entries[name]?.dismissed = true
    }

    // MARK: - Querying

    /// True while `name` must not prompt again. Expires the entry once past `refireInterval`, so a
    /// provider whose call could never be attributed still recovers on its own.
    mutating func isSuppressed(_ name: String, now: Date = Date()) -> Bool {
        guard let entry = entries[name] else { return false }
        guard now.timeIntervalSince(entry.firedAt) < refireInterval else {
            // Expire the dismissal with the cooldown it is pinned to, or a name the user once
            // dismissed would survive for the rest of the app session.
            entries[name] = nil
            return false
        }
        return true
    }

    // MARK: - Releasing

    /// Releases every provider whose call has ended. Returns the released names for logging.
    ///
    /// Two shapes of "ended", because a call end is only sometimes still visible when this is
    /// asked:
    ///
    /// - **Quiet now.** The app stopped capturing and has stayed off the microphone past the grace
    ///   period. This is the case where nothing has started since.
    /// - **Quiet, then back.** The app is capturing again on a run that began after we prompted,
    ///   separated from the previous run by at least `newCallGap`. That gap *is* the end of the
    ///   first call, observed after the fact.
    ///
    /// The second case is not a refinement — it is the common one, and its absence is what made
    /// detection look like it worked once per session. Back-to-back meetings are seconds apart, so
    /// a poll fast enough to see the gap open sees it as a few seconds old and declines, and by
    /// the next poll the provider is capturing again and no path can release it at all.
    ///
    /// `status` is asked per entry rather than handed a set, so a provider that was never
    /// attributed (`.unobserved`) is held to the `refireInterval` ceiling instead of being
    /// released the instant it is absent from the capturing set.
    @discardableResult
    mutating func releaseEndedCalls(
        now: Date = Date(),
        status: (String) -> MeetingCaptureStatus
    ) -> [String] {
        var released: [String] = []
        for (name, entry) in entries {
            switch status(entry.bundleID) {
            case .ended(let endedAt):
                let grace = entry.dismissed ? dismissalGrace : callEndedGrace
                guard now.timeIntervalSince(endedAt) >= grace else { continue }

            case .capturing(let since, let precededByGap):
                // The run that was in progress when we prompted is the call we prompted for.
                guard since > entry.firedAt else { continue }
                guard let gap = precededByGap, gap >= newCallGap else { continue }

            case .unobserved:
                continue
            }
            entries[name] = nil
            released.append(name)
        }
        return released
    }

    /// Hardware went fully idle — no camera, nobody on the microphone.
    ///
    /// Only providers whose call end cannot be observed are released here. For anything that was
    /// attributed, hardware idle is too coarse to mean "the call ended": muting yourself with the
    /// camera off looks exactly the same, and releasing on it would raise a second toast for the
    /// meeting already in progress. Those wait for `releaseEndedCalls` and its grace period.
    ///
    /// Dismissals are kept regardless — wiping them on this signal is what once turned "Dismiss"
    /// into a 40-second snooze, because an unrelated camera blip counted as the call ending.
    @discardableResult
    mutating func releaseUnobservableCalls(status: (String) -> MeetingCaptureStatus) -> [String] {
        var released: [String] = []
        for (name, entry) in entries where !entry.dismissed {
            guard status(entry.bundleID) == .unobserved else { continue }
            entries[name] = nil
            released.append(name)
        }
        return released
    }

    /// The provider quit outright — nothing to wait for.
    mutating func release(_ name: String) {
        entries[name] = nil
    }
}
