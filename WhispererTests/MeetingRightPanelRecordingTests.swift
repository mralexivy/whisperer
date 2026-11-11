//
//  MeetingRightPanelRecordingTests.swift
//  WhispererTests
//
//  While one meeting records, any other meeting opened in the workspace shows its own player
//  and Ask AI; the recording state belongs to the meeting being recorded (2026-11-10).
//  Opt-in snapshots: TEST_RUNNER_RIGHT_PANEL_SNAPSHOT=<dir>.
//

import AppKit
import SwiftUI
import XCTest
@testable import whisperer

@MainActor
final class MeetingRightPanelRecordingTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private func snapshot(_ view: AnyView, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["RIGHT_PANEL_SNAPSHOT"] else { throw XCTSkip("set TEST_RUNNER_RIGHT_PANEL_SNAPSHOT") }
        let hosting = NSHostingView(rootView: view.frame(width: 420, height: 700))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 420, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [hosting, window]
        let until = Date().addingTimeInterval(1.0)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    func testRecordingStateOnlyOnTheRecordingMeeting() throws {
        let session = MeetingSession()
        session.isRecording = true
        session.meetingID = UUID()
        let player = SeekableAudioPlayer()
        Self.keepAlive += [session, player]
        let past = MeetingRecord(id: UUID(), title: "Yesterday", language: "en", modelUsed: "v3")
        let recording = MeetingRecord(id: session.meetingID!, title: "Now", language: "en", modelUsed: "v3")
        try snapshot(AnyView(MeetingRightPanel(meeting: past, session: session, player: player)), "panel-other-meeting")
        try snapshot(AnyView(MeetingRightPanel(meeting: recording, session: session, player: player)), "panel-recording-meeting")
    }
}
