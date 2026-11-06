//
//  EventKitCalendarProvider.swift
//  Whisperer
//
//  Reads upcoming events from the calendars already on this Mac (iCloud, and any Google,
//  Exchange or CalDAV account added in System Settings → Internet Accounts) through EventKit.
//  No provider login, no network of our own: EventKit reads the local Calendar store.
//
//  Read-only by contract. macOS only offers "full access" for reading events — write-only cannot
//  enumerate them — but nothing here ever saves, edits or deletes an event.
//

import AppKit
import EventKit
import Foundation

/// A calendar the user can switch on or off in Settings.
struct CalendarSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let sourceTitle: String
    /// sRGB components of the calendar's colour, for the selection list.
    let color: [Double]
}

enum CalendarAccess: Equatable, Sendable {
    case notDetermined, granted, denied, restricted
}

protocol CalendarMeetingProvider: Sendable {
    func accessStatus() -> CalendarAccess
    func requestReadAccess() async throws -> Bool
    func calendars() -> [CalendarSummary]
    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) async -> [CalendarEventSnapshot]
    func observeChanges() -> AsyncStream<Void>
}

nonisolated final class EventKitCalendarProvider: CalendarMeetingProvider, @unchecked Sendable {
    /// One store per process: EventKit objects are tied to the store that fetched them, and each
    /// store is a separate connection to the Calendar daemon.
    static let shared = EventKitCalendarProvider()

    private let store = EKEventStore()
    /// `events(matching:)` is synchronous and can take a moment on large calendars.
    private let queue = DispatchQueue(label: "com.ivy.whisperer.calendar", qos: .utility)

    func accessStatus() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        // Write-only cannot list events, so for us it is as good as denied.
        case .denied, .writeOnly: return .denied
        @unknown default: return .denied
        }
    }

    func requestReadAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    func calendars() -> [CalendarSummary] {
        guard accessStatus() == .granted else { return [] }
        return store.calendars(for: .event)
            .map { calendar in
                let rgb = calendar.color?.usingColorSpace(.sRGB)
                return CalendarSummary(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    sourceTitle: calendar.source?.title ?? "",
                    color: [Double(rgb?.redComponent ?? 0.5), Double(rgb?.greenComponent ?? 0.5),
                            Double(rgb?.blueComponent ?? 0.5)]
                )
            }
            .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
    }

    /// Events in `[start, end)` from `calendarIDs` (nil = all), as snapshots. Fetched off the
    /// main thread; the `EKEvent` objects never leave this function.
    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) async -> [CalendarEventSnapshot] {
        guard accessStatus() == .granted else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async { [store] in
                var calendars: [EKCalendar]? = nil
                if let calendarIDs {
                    calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
                    // An empty selection means "none", not "all" — nil would search everything.
                    if calendars?.isEmpty == true { continuation.resume(returning: []); return }
                }
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
                let snapshots = store.events(matching: predicate).map(Self.snapshot)
                continuation.resume(returning: snapshots)
            }
        }
    }

    /// Fires whenever the Calendar store changes (sync, edit, account added). Fetched events go
    /// stale then; callers refetch.
    func observeChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let token = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: store, queue: nil
            ) { _ in continuation.yield(()) }
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(token) }
        }
    }

    // MARK: - Snapshot

    static func snapshot(_ event: EKEvent) -> CalendarEventSnapshot {
        let attendees = event.attendees ?? []
        let me = attendees.first(where: \.isCurrentUser)
        let others = attendees.filter { !$0.isCurrentUser }
        return CalendarEventSnapshot(
            eventIdentifier: event.eventIdentifier ?? UUID().uuidString,
            externalIdentifier: event.calendarItemExternalIdentifier,
            calendarID: event.calendar?.calendarIdentifier ?? "",
            title: event.title ?? "",
            startAt: event.startDate,
            endAt: event.endDate,
            isAllDay: event.isAllDay,
            isCanceled: event.status == .canceled,
            url: event.url,
            location: event.location,
            notes: event.notes,
            attendeeCount: event.hasAttendees ? attendees.count : nil,
            currentUserRSVP: rsvp(me?.participantStatus),
            isSoloEvent: !event.hasAttendees || others.isEmpty
        )
    }

    private static func rsvp(_ status: EKParticipantStatus?) -> MeetingRSVP {
        switch status {
        case .accepted: return .accepted
        case .tentative: return .tentative
        case .declined: return .declined
        case .pending: return .pending
        default: return .unknown
        }
    }
}
