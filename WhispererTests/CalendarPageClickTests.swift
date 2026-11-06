//
//  CalendarPageClickTests.swift
//  WhispererTests
//
//  Click-level tests of the workspace Calendar page, same harness as LLMPageClickTests: the
//  real page in a real window, clicked with synthesized mouse events.
//

import AppKit
import SwiftUI
import XCTest
@testable import whisperer

private struct FakeCalendarSource: RemoteCalendarSource {
    let account: CalendarAccount
    func calendars() async throws -> [CalendarSummary] {
        [CalendarSummary(id: account.namespaced("work"), title: "Work", sourceTitle: account.email, color: [0.26, 0.52, 0.96]),
         CalendarSummary(id: account.namespaced("home"), title: "Family", sourceTitle: account.email, color: [0.2, 0.66, 0.33])]
    }
    func events(from start: Date, to end: Date, calendarIDs: [String]) async throws -> [CalendarEventSnapshot] {
        let begin = Date().addingTimeInterval(8 * 60)
        return [CalendarEventSnapshot(eventIdentifier: "E1", externalIdentifier: "E1",
                                      calendarID: account.namespaced("work"), title: "Design review",
                                      startAt: begin, endAt: begin.addingTimeInterval(1800),
                                      isAllDay: false, isCanceled: false, url: URL(string: "https://zoom.us/j/123"),
                                      location: nil, notes: nil, attendeeCount: 5, currentUserRSVP: .accepted,
                                      isSoloEvent: false)]
    }
}

@MainActor
final class CalendarPageClickTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []
    private var saved: [String: Any] = [:]
    private let keys = [CalendarMeetingsStore.Keys.accounts, CalendarMeetingsStore.Keys.enabledCalendars,
                        CalendarMeetingsStore.Keys.reminderLead, CalendarMeetingsStore.Keys.decisions]
    private var window: NSWindow!
    private var scope = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDownWithError() throws {
        window?.orderOut(nil)
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try super.tearDownWithError()
    }

    private func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    private func host(_ store: CalendarMeetingsStore, width: CGFloat = 900) {
        scope = "calendar-\(UUID().uuidString)"
        let hosting = NSHostingView(rootView: CalendarPageView(colorScheme: .dark, store: store, testScope: scope))
        let rect = CGRect(x: 40, y: 40, width: width, height: 1800)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        window.setFrame(rect, display: true)
        self.window = window
        Self.keepAlive += [store, hosting, window]
        pump(0.8)
    }

    private func frame(_ id: String) -> CGRect? {
        UITestFrames.frames[UITestFrames.key(scope: scope, id: id)]
    }

    private func click(_ id: String, x: CGFloat = 0.5, file: StaticString = #filePath, line: UInt = #line) throws {
        pump(0.4)
        let f = try XCTUnwrap(frame(id), "no frame for \(id)", file: file, line: line)
        let height = window.contentView?.bounds.height ?? 0
        let point = NSPoint(x: f.minX + f.width * x, y: height - f.midY)
        for (type, hold) in [(NSEvent.EventType.mouseMoved, 0.15), (.leftMouseDown, 0.2), (.leftMouseUp, 0.05)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            pump(hold)
        }
        pump(0.6)
    }

    /// Writes what the page looks like, for reviewing layout by eye (CALENDAR_PAGE_SNAPSHOT_DIR).
    private func snapshot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CALENDAR_PAGE_SNAPSHOT_DIR"],
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func connectedStore() async -> CalendarMeetingsStore {
        let account = CalendarAccount(provider: .google, email: "dana@example.com")
        UserDefaults.standard.set(try? JSONEncoder().encode([account]), forKey: CalendarMeetingsStore.Keys.accounts)
        let store = CalendarMeetingsStore()
        Self.keepAlive.append(store)
        store.makeRemoteSource = { FakeCalendarSource(account: $0) }
        await store.refresh(reason: "test")
        return store
    }

    // MARK: - Tests

    func testNotConnected_LeadsWithGoogleStepsAndOutlookUnfoldsInPlace() throws {
        let store = CalendarMeetingsStore()
        host(store)
        snapshot("calendar-empty")
        XCTAssertNotNil(frame("calendar.signIn.google"), "Google's connect steps are open on arrival")
        XCTAssertNil(frame("calendar.signIn.microsoft"))

        try click("calendar.provider.microsoft", x: 0.3)
        XCTAssertNotNil(frame("calendar.signIn.microsoft"), "picking Outlook unfolds its steps")
        snapshot("calendar-outlook-open")
    }

    func testConnected_ShowsAccountAndRemoveDisconnects() async throws {
        let store = await connectedStore()
        XCTAssertEqual(store.calendars.count, 2)
        host(store)
        snapshot("calendar-connected")
        let account = try XCTUnwrap(store.accounts.first)
        XCTAssertNil(frame("calendar.signIn.google"), "a connected provider's steps start folded")

        try click("calendar.remove.\(account.id)")
        XCTAssertTrue(store.accounts.isEmpty, "Remove disconnects the account")
        XCTAssertFalse(store.hasAnySource)
    }
}
