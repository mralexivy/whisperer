//
//  MeetingSeriesListSnapshotTests.swift
//  WhispererTests
//
//  Opt-in look at the Notes list grouped into series: TEST_RUNNER_SERIES_SNAPSHOT=<dir>.
//

import XCTest
import SwiftUI
@testable import whisperer

@MainActor
final class MeetingSeriesListSnapshotTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    func testSeriesListSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["SERIES_SNAPSHOT"] else { throw XCTSkip("set TEST_RUNNER_SERIES_SNAPSHOT") }
        let day = 86_400.0
        let now = Date()
        var items: [MeetingListItem] = []
        for w in 0..<6 { items.append(MeetingListItem(id: UUID(), title: "Alex / Keren - Weekly", language: "he", createdAt: now - Double(w) * 7 * day, duration: 1_800 + Double(w) * 60)) }
        for d in 0..<4 { items.append(MeetingListItem(id: UUID(), title: "Platform stand-up", language: "en", createdAt: now - Double(d) * day - 3_600, duration: 900)) }
        items.append(MeetingListItem(id: UUID(), title: "Interview: Staff Engineer", language: "en", createdAt: now - 2 * day, duration: 3_900))
        items.append(MeetingListItem(id: UUID(), title: "Unscheduled Zoom meeting · 11:24", language: "en", createdAt: now - 3 * day, duration: 600))
        let manager = MeetingManager.shared
        let saved = manager.meetings
        let savedMore = manager.hasMorePages
        defer { manager.meetings = saved; manager.hasMorePages = savedMore }
        manager.meetings = items.sorted { $0.createdAt > $1.createdAt }
        manager.hasMorePages = false
        UserDefaults.standard.set(true, forKey: "meetingListGroupsSeries")
        defer { UserDefaults.standard.removeObject(forKey: "meetingListGroupsSeries") }

        let session = MeetingSession()
        var selected: UUID? = items[1].id
        let view = MeetingListPanel(session: session, selectedMeetingID: Binding(get: { selected }, set: { selected = $0 }))
            .environment(\.colorScheme, .dark)
            .frame(width: 300, height: 640)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 300, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [hosting, window, session]
        let until = Date().addingTimeInterval(1.5)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("series-list.png"))
        }
    }
}
