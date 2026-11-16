import XCTest
import SwiftUI
import AppKit
@testable import whisperer

/// Opt-in: renders the unified workspace on the real library (`TEST_RUNNER_RECORDINGS_DIR=<folder>`).
@MainActor
final class RecordingsWorkspaceSnapshotTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    private func pump(_ seconds: Double, until condition: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    }

    func testRenderWorkspace() throws {
        guard let dir = ProcessInfo.processInfo.environment["RECORDINGS_DIR"] else { throw XCTSkip("set TEST_RUNNER_RECORDINGS_DIR") }
        let model = RecordingsWorkspaceModel.shared
        let host = NSHostingView(rootView: RecordingsWorkspaceView().frame(width: 1320, height: 820))
        host.frame = NSRect(x: 0, y: 0, width: 1320, height: 820)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        Self.keepAlive += [window, host]
        pump(6) { !model.items.isEmpty }

        func shot(_ name: String, kind: RecordingKind?, wait: Double = 4) throws {
            if let kind, let item = model.items.first(where: { $0.kind == kind }) { model.open(item.id) }
            pump(wait)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        try shot("1-first", kind: nil)
        try shot("2-dictation", kind: .dictation)
        try shot("3-meeting", kind: .meeting, wait: 6)
        try shot("4-file", kind: .file)
        UserDefaults.standard.set(false, forKey: "recordings.sidebarVisible")
        try shot("5-compact", kind: .dictation, wait: 3)
        UserDefaults.standard.removeObject(forKey: "recordings.sidebarVisible")
        print("RECORDINGS items=\(model.items.count) selected=\(String(describing: model.selectedID?.key))")
    }
}

/// Opt-in renders of the "+" menu and of a meeting that is being recorded (`TEST_RUNNER_RECORDINGS_DIR=<folder>`).
@MainActor
final class RecordingsNewAndLiveSnapshotTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    private func render<V: View>(_ view: V, size: CGSize, to path: String, wait: Double = 2) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderFront(nil)
        Self.keepAlive += [window, host]
        let end = Date().addingTimeInterval(wait)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    func testRenderMenuAndLiveMeeting() throws {
        guard let dir = ProcessInfo.processInfo.environment["RECORDINGS_DIR"] else { throw XCTSkip("set TEST_RUNNER_RECORDINGS_DIR") }
        let session = MeetingSession()
        Self.keepAlive.append(session)
        try render(NewRecordingMenu(model: RecordingsWorkspaceModel.shared, session: session, dismiss: {})
            .padding(20).background(WhispererColors.background(.dark)), size: CGSize(width: 380, height: 280), to: "\(dir)/6-new-menu.png")

        var meeting = MeetingRecord(id: UUID(), title: "Note Nov 16, 2026 6:02 PM", language: "en", modelUsed: "Nemotron Multilingual")
        meeting.isInProgress = true
        session.isRecording = true
        session.meetingID = meeting.id
        session.elapsedSeconds = 84
        session.segments = [
            MeetingSegment(timestamp: 0, endTimestamp: 6, text: "Okay, let's start with the roadmap for next quarter.", speakerName: "Alex", speakerIndex: 0),
            MeetingSegment(timestamp: 7, endTimestamp: 14, text: "Sounds good. I have three things I want to cover today.", speakerName: "Maya", speakerIndex: 1),
        ]
        let document = TranscriptDocument(meeting: meeting)
        try render(RecordingsWorkspaceView(fixture: RecordingsWorkspaceFixture(document: document, record: meeting), session: session),
                   size: CGSize(width: 1320, height: 820), to: "\(dir)/7-live-meeting.png", wait: 3)
        session.isRecording = false
    }
}
