//
//  WorkspaceSnapshotTests.swift
//  WhispererTests
//
//  Opt-in look at every Workspace page at the smallest window the app allows (1060 x 660, minus
//  the 220 pt sidebar and the title bar): TEST_RUNNER_WORKSPACE_SNAPSHOT=<dir>. Written for App
//  Review's Guideline 4 rejection ("windows that cut off text", 14" MacBook Pro, 2026-11-23).
//

import XCTest
import SwiftUI
@testable import whisperer

@MainActor
final class WorkspaceSnapshotTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    private func snapshot<V: View>(_ name: String, size: CGSize, dir: String, @ViewBuilder _ content: () -> V) throws {
        let view = content()
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 40, y: 40), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [hosting, window]
        let until = Date().addingTimeInterval(1.5)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func testWorkspacePagesAtMinimumWindow() throws {
        guard let dir = ProcessInfo.processInfo.environment["WORKSPACE_SNAPSHOT"] else {
            throw XCTSkip("set TEST_RUNNER_WORKSPACE_SNAPSHOT=<dir>")
        }
        let content = CGSize(width: 840, height: 620)
        try snapshot("ws-recordings", size: content, dir: dir) { RecordingsWorkspaceView() }
        try snapshot("ws-calendar", size: content, dir: dir) { CalendarPageView(colorScheme: .dark) }
        try snapshot("ws-statistics", size: content, dir: dir) { StatisticsView() }
        try snapshot("ws-dictionary", size: content, dir: dir) { DictionaryView() }
        try snapshot("ws-aimodes", size: content, dir: dir) { AIModesView() }
        try snapshot("ws-llm", size: content, dir: dir) { LLMPageView(colorScheme: .dark) }
        try snapshot("ws-mcp", size: content, dir: dir) { MCPConnectPageView(colorScheme: .dark) }
        try snapshot("ws-settings", size: content, dir: dir) { HistorySettingsView() }
        try snapshot("ws-setup", size: content, dir: dir) { SetupChecklistView() }
        try snapshot("ws-feedback", size: content, dir: dir) { FeedbackView() }
        // The meeting prep screen: its download button now names the size ("Download about 3.9 GB").
        try snapshot("ws-meetingprep", size: content, dir: dir) { MeetingPrepView(continueAnyway: .constant(false)) }
        // The menu bar popover is a fixed 360 x 580.
        try snapshot("menubar", size: CGSize(width: 360, height: 580), dir: dir) { MenuBarView() }
    }
}
