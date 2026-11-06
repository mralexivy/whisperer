//
//  ScheduledMeeting.swift
//  Whisperer
//
//  The calendar side of meetings: a normalized occurrence, and the pure rules that decide which
//  calendar events are meetings worth a recording reminder.
//
//  Pure and nonisolated on purpose — provider responses are converted to `CalendarEventSnapshot`
//  at the source boundary, so every rule here is unit-testable without a network.
//
//  A calendar entry means a meeting *may* happen. It is never evidence that one *is* happening,
//  so nothing here can start a recording on its own (see `MeetingSessionCoordinator`).
//

import Foundation

/// Where an event came from: the account it was read from, signed in directly.
enum CalendarSource: String, Codable, Sendable {
    case google
    case microsoft
}

enum MeetingRSVP: String, Codable, Sendable {
    case accepted, tentative, declined, pending, unknown
}

enum MeetingKind: String, Codable, Sendable {
    case online, inPerson, unknown
}

/// Someone on the invite. Read from the calendar so a recording knows who was in the room:
/// the user's own name for their voice, and the names to offer for everyone else's.
struct MeetingParticipant: Codable, Sendable, Equatable, Hashable {
    var name: String?
    var email: String
    /// The signed-in user.
    var isSelf: Bool
    var isOrganizer: Bool
    var response: MeetingRSVP

    /// What to call them: the invite's display name, else "Me" for the user (Google never names
    /// the signed-in attendee, and "ialex.ivy" → "Ialex Ivy" reads as someone else), else a
    /// readable form of the address ("dana.levi@x.com" → "Dana Levi").
    var displayName: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, !name.contains("@") {
            return name
        }
        if isSelf { return "Me" }
        let local = email.split(separator: "@").first.map(String.init) ?? email
        return local.split(whereSeparator: { ".-_+".contains($0) })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

extension Array where Element == MeetingParticipant {
    /// People other than the user who did not decline — the voices a recording may hear.
    var expectedOthers: [MeetingParticipant] {
        filter { !$0.isSelf && $0.response != .declined }
    }
}

/// Conferencing providers whose join links Whisperer recognizes. Only these hosts are offered
/// as "Join" — an arbitrary link in an event's notes is never opened.
enum ConferenceProvider: String, Codable, Sendable, CaseIterable {
    case zoom, googleMeet, teams, webex, slack, whereby, around, chime

    var displayName: String {
        switch self {
        case .zoom: return "Zoom"
        case .googleMeet: return "Google Meet"
        case .teams: return "Microsoft Teams"
        case .webex: return "Webex"
        case .slack: return "Slack"
        case .whereby: return "Whereby"
        case .around: return "Around"
        case .chime: return "Amazon Chime"
        }
    }

    /// Recognizes a provider from a URL host. Suffix-matched on a label boundary so
    /// `evilzoom.us` is not `zoom.us`.
    static func from(host rawHost: String) -> ConferenceProvider? {
        let host = rawHost.lowercased()
        func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if matches("zoom.us") || matches("zoomgov.com") { return .zoom }
        if host == "meet.google.com" { return .googleMeet }
        if host == "teams.microsoft.com" || host == "teams.live.com" { return .teams }
        if matches("webex.com") { return .webex }
        if host == "app.slack.com" { return .slack }
        if matches("whereby.com") { return .whereby }
        if host == "around.co" { return .around }
        if host == "chime.aws" { return .chime }
        return nil
    }
}

/// What the classifier needs from a calendar event, normalized from the provider's API response.
struct CalendarEventSnapshot: Sendable, Equatable {
    var source: CalendarSource = .google
    var eventIdentifier: String
    var externalIdentifier: String?
    var calendarID: String
    var title: String
    var startAt: Date
    var endAt: Date
    var isAllDay: Bool
    var isCanceled: Bool
    var url: URL?
    var location: String?
    var notes: String?
    /// nil when the event has no attendee list (a personal time block, usually).
    var attendeeCount: Int?
    var currentUserRSVP: MeetingRSVP
    /// True when the user is the organizer and the only attendee, or has no attendees at all.
    var isSoloEvent: Bool
    /// Human attendees (rooms and resources dropped), organizer included.
    var participants: [MeetingParticipant] = []
}

struct ScheduledMeeting: Identifiable, Equatable, Sendable {
    /// Stable per occurrence: survives resyncs that change `eventIdentifier`, and differs
    /// between occurrences of a recurring event.
    let id: String
    let calendarID: String
    let source: CalendarSource
    let title: String
    let startAt: Date
    let endAt: Date
    let joinURL: URL?
    let provider: ConferenceProvider?
    /// More than one join link that disagree — never auto-join; the user picks.
    let hasConflictingLinks: Bool
    let hasOtherParticipants: Bool?
    let response: MeetingRSVP
    let kind: MeetingKind
    var participants: [MeetingParticipant] = []

    func isLive(at now: Date) -> Bool { startAt <= now && now < endAt }
}

/// Decides which events are meetings and normalizes them. Pure.
nonisolated enum MeetingEventClassifier {

    /// Events longer than this are not meetings (conference days, out-of-office blocks).
    static let maxMeetingDuration: TimeInterval = 6 * 3600

    /// Normalizes `event`, or returns nil when it should never produce a recording reminder.
    ///
    /// - `includeUnlinkedSolo`: the user opted in to reminders for title-only events with no
    ///   attendees and no link (rule 4). Off by default.
    static func meeting(from event: CalendarEventSnapshot, includeUnlinkedSolo: Bool = false) -> ScheduledMeeting? {
        // Rule 1: cancelled, declined, all-day, implausible length.
        guard !event.isCanceled, event.currentUserRSVP != .declined, !event.isAllDay else { return nil }
        let duration = event.endAt.timeIntervalSince(event.startAt)
        guard duration > 0, duration <= maxMeetingDuration else { return nil }

        let links = joinLinks(in: event)
        let distinct = Array(Set(links.map(\.url)))
        let primary = links.first
        let hasOthers: Bool? = event.attendeeCount.map { _ in !event.isSoloEvent }

        // Rule 2: a recognized conference link always qualifies, 1:1s included.
        // Rule 3: attendees and a plausible duration qualify without a link (record, no join).
        // Rule 4: a solo, unlinked block qualifies only when the user asked for those.
        if primary == nil {
            let hasAttendees = (event.attendeeCount ?? 0) > 0 && !event.isSoloEvent
            guard hasAttendees || includeUnlinkedSolo else { return nil }
        }

        let kind: MeetingKind
        if primary != nil {
            kind = .online
        } else if let location = event.location, !location.trimmingCharacters(in: .whitespaces).isEmpty {
            kind = .inPerson
        } else {
            kind = .unknown
        }

        return ScheduledMeeting(
            id: occurrenceID(for: event),
            calendarID: event.calendarID,
            source: event.source,
            title: displayTitle(event.title),
            startAt: event.startAt,
            endAt: event.endAt,
            joinURL: distinct.count > 1 ? nil : primary?.url,
            provider: primary?.provider,
            hasConflictingLinks: distinct.count > 1,
            hasOtherParticipants: hasOthers,
            response: event.currentUserRSVP,
            kind: kind,
            participants: event.participants
        )
    }

    /// Stable occurrence identity: the calendar's own UID when it has one (it survives the
    /// event-identifier churn a resync causes), plus the occurrence start, so each instance of a
    /// recurring event is distinct.
    static func occurrenceID(for event: CalendarEventSnapshot) -> String {
        let base = event.externalIdentifier ?? event.eventIdentifier
        return "\(base)@\(Int(event.startAt.timeIntervalSince1970))"
    }

    static func displayTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled meeting" : trimmed
    }

    // MARK: - Join links

    struct JoinLink: Equatable, Sendable {
        let url: URL
        let provider: ConferenceProvider
    }

    /// Recognized conference links, structured field first, then location, then notes.
    static func joinLinks(in event: CalendarEventSnapshot) -> [JoinLink] {
        var found: [JoinLink] = []
        if let url = event.url, let link = validated(url) { found.append(link) }
        for text in [event.location, event.notes].compactMap({ $0 }) {
            for url in urls(in: text) {
                if let link = validated(url), !found.contains(link) { found.append(link) }
            }
        }
        // The same meeting is often linked twice with different query strings (pwd, tracking).
        var seen = Set<String>()
        return found.filter { seen.insert(normalizedKey($0.url)).inserted }
    }

    /// An allowlisted https conference link, stripped to what it needs. Anything else — other
    /// schemes, other hosts, redirectors — is not offered as Join.
    static func validated(_ url: URL) -> JoinLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host, let provider = ConferenceProvider.from(host: host) else { return nil }
        return JoinLink(url: url, provider: provider)
    }

    /// Host + path, lowercased: two links to one meeting compare equal.
    static func normalizedKey(_ url: URL) -> String {
        "\(url.host?.lowercased() ?? "")\(url.path.lowercased())"
    }

    private static let linkDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func urls(in text: String) -> [URL] {
        guard let detector = linkDetector else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap(\.url)
    }
}
