//
//  RecordingsWorkspacePlayerTests.swift
//  WhispererTests
//
//  The persistent player across the whole workspace, driven with real mouse clicks: for every kind and
//  every Transcript/Overview × sidebar-tab combination there is exactly one visible player, it stays
//  inside the window, and one playback session carries through every click without a reset. Then the
//  same with the sidebar hidden, focus mode and a short window.
//

import AVFoundation
import SwiftUI
import XCTest
@testable import whisperer

@MainActor
final class RecordingsWorkspacePlayerTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    private var window: NSWindow!
    private var scope = ""
    private var playback: RecordingPlaybackController!

    override func setUp() async throws {
        scope = "player-\(UUID().uuidString)"
        RecordingPlayerProbe.live = [:]
        UserDefaults.standard.set(true, forKey: "recordings.sidebarVisible")
        RecordingsWorkspaceModel.shared.focusMode = false
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        UserDefaults.standard.removeObject(forKey: "recordings.sidebarVisible")
        RecordingsWorkspaceModel.shared.focusMode = false
    }

    // MARK: Fixtures

    private func wav() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("player-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000 * 30)!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = sin(Float(i) * 0.04) * 0.3 }
        try file.write(from: buffer)
        return url
    }

    private let text = (0..<40).map { "This is sentence number \($0) of the recording." }.joined(separator: " ")

    private func fixture(_ kind: RecordingKind, audio: URL) -> RecordingsWorkspaceFixture {
        switch kind {
        case .meeting:
            var meeting = MeetingRecord(id: UUID(), title: "Weekly sync", language: "en", modelUsed: "m")
            meeting.isInProgress = false
            meeting.duration = 30
            meeting.segments = (0..<6).map {
                MeetingSegment(timestamp: Double($0) * 5, endTimestamp: Double($0) * 5 + 4, text: "Segment \($0) of the weekly sync, said at length.",
                               speakerName: $0 % 2 == 0 ? "Alex" : "Maya", speakerIndex: $0 % 2)
            }
            var document = TranscriptDocument(meeting: meeting)
            document.audioURL = audio
            document.audioIsMissing = false
            document.audioFileName = audio.lastPathComponent
            return RecordingsWorkspaceFixture(document: document, record: meeting)
        case .dictation, .file:
            let record = TranscriptionRecord(transcription: text, audioFileURL: audio.lastPathComponent, duration: 30, language: "en", modelUsed: "m",
                                             targetAppName: kind == .file ? "File Import" : "Cursor", sourceKind: kind == .file ? "file" : nil,
                                             sourceFileName: kind == .file ? "interview.m4a" : nil)
            var document = TranscriptDocument(transcription: record)
            document.audioURL = audio
            document.audioIsMissing = false
            return RecordingsWorkspaceFixture(document: document, record: document.asMeetingRecord())
        }
    }

    private func open(_ fixture: RecordingsWorkspaceFixture, size: CGSize = CGSize(width: 1320, height: 820)) throws {
        playback = RecordingPlaybackController()
        Self.keepAlive.append(playback)
        let view = RecordingsWorkspaceView(fixture: fixture, playback: playback, testScope: scope).frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderFront(nil)
        Self.keepAlive += [window, host]
        pump(1.2)
        snapshot("opened")
        // start real playback so a reset would be visible
        playback.seek(to: 3)
        playback.togglePlay()
        pump(0.8)
    }

    private func snapshot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["PLAYER_PNG_DIR"], let host = window.contentView,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(self.name.split(separator: " ").last.map(String.init)?.replacingOccurrences(of: "]", with: "") ?? "x")-\(name).png"))
    }

    // MARK: Driving

    private func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    private func frame(_ id: String) -> CGRect? { UITestFrames.frames[UITestFrames.key(scope: scope, id: id)] }

    private func click(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        pump(0.3)
        guard let f = frame(id) else { XCTFail("no frame for \(id)", file: file, line: line); return }
        let height = window.contentView?.bounds.height ?? 0
        let point = NSPoint(x: f.midX, y: height - f.midY)
        for (type, hold) in [(NSEvent.EventType.mouseMoved, 0.1), (.leftMouseDown, 0.12), (.leftMouseUp, 0.05)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            pump(hold)
        }
        pump(0.4)
    }

    /// Exactly one player is on screen and fully inside the window.
    private func assertOnePlayer(expecting style: String, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let live = Dictionary(uniqueKeysWithValues: RecordingPlayerProbe.live.filter { $0.key.hasPrefix(scope + "|") && $0.value != 0 }
            .map { (String($0.key.dropFirst(scope.count + 1)), $0.value) })
        XCTAssertEqual(live, [style: 1], "\(context): expected exactly one \(style) player, have \(live)", file: file, line: line)
        guard let f = frame("recordings.player.play.\(style)") else { return }
        XCTAssertLessThanOrEqual(f.maxY, window.contentView!.bounds.height + 1, "\(context): player below the window", file: file, line: line)
        XCTAssertGreaterThanOrEqual(f.minY, 0, "\(context): player above the window", file: file, line: line)
    }

    private func assertSameSession(since previous: Double, _ context: String, file: StaticString = #filePath, line: UInt = #line) -> Double {
        XCTAssertNotNil(playback.player.loadedURL, "\(context): audio unloaded", file: file, line: line)
        XCTAssertTrue(playback.player.isPlaying, "\(context): playback stopped", file: file, line: line)
        XCTAssertGreaterThanOrEqual(playback.player.currentTime, previous - 0.05, "\(context): position went backwards (reset)", file: file, line: line)
        return playback.player.currentTime
    }

    // MARK: The 14 combinations

    private func runCombinations(kind: RecordingKind, sidebarTabs: [String]) throws {
        let audio = try wav()
        try open(fixture(kind, audio: audio))
        let loaded = playback.player.loadedURL
        XCTAssertNotNil(loaded)
        var position = playback.player.currentTime
        XCTAssertGreaterThan(position, 2.5)

        for detailTab in ["transcript", "overview"] {
            try click("recordings.tab.\(detailTab)")
            for sidebarTab in sidebarTabs {
                if sidebarTabs.count > 1 { try click("recordings.sidebar.tab.\(sidebarTab)") }  // a lone tab has no strip
                let context = "\(kind) \(detailTab) × \(sidebarTab)"
                assertOnePlayer(expecting: "full", context)
                position = assertSameSession(since: position, context)
                XCTAssertEqual(playback.player.loadedURL, loaded, "\(context): another audio file was loaded")
            }
        }
    }

    func testMeetingAllSixCombinationsKeepOneFullPlayerAndOneSession() throws {
        try runCombinations(kind: .meeting, sidebarTabs: ["askai", "notes", "people"])
    }

    func testFileAllFourCombinationsKeepOneFullPlayerAndOneSession() throws {
        try runCombinations(kind: .file, sidebarTabs: ["askai", "notes"])
    }

    func testDictationAllFourCombinationsKeepOneFullPlayerAndOneSession() throws {
        try runCombinations(kind: .dictation, sidebarTabs: ["details"])
    }

    // MARK: Layout changes

    func testHidingTheSidebarSwapsToTheCompactPlayerWithoutResettingPlayback() throws {
        let audio = try wav()
        try open(fixture(.dictation, audio: audio))
        assertOnePlayer(expecting: "full", "sidebar visible")
        var position = playback.player.currentTime

        try click("recordings.sidebar.toggle")
        pump(0.6)
        assertOnePlayer(expecting: "compact", "sidebar hidden")
        position = assertSameSession(since: position, "sidebar hidden")

        try click("recordings.tab.overview")
        assertOnePlayer(expecting: "compact", "overview, sidebar hidden")
        position = assertSameSession(since: position, "overview, sidebar hidden")

        try click("recordings.sidebar.toggle")
        pump(0.6)
        assertOnePlayer(expecting: "full", "sidebar shown again")
        _ = assertSameSession(since: position, "sidebar shown again")
    }

    func testFocusModeShowsTheCompactPlayerAndLeavingItRestoresTheSidebarPlayer() throws {
        let audio = try wav()
        try open(fixture(.meeting, audio: audio))
        var position = playback.player.currentTime

        try click("recordings.focus.toggle")
        pump(0.6)
        assertOnePlayer(expecting: "compact", "focus mode")
        position = assertSameSession(since: position, "focus mode")

        try click("recordings.focus.toggle")
        pump(0.6)
        assertOnePlayer(expecting: "full", "focus mode left")
        _ = assertSameSession(since: position, "focus mode left")
    }

    func testANarrowWindowFallsBackToTheCompactPlayer() throws {
        let audio = try wav()
        try open(fixture(.file, audio: audio), size: CGSize(width: 900, height: 700))
        assertOnePlayer(expecting: "compact", "narrow window")
        _ = assertSameSession(since: 0, "narrow window")
    }

    func testAShortWindowKeepsThePlayerOnScreen() throws {
        let audio = try wav()
        try open(fixture(.dictation, audio: audio), size: CGSize(width: 1320, height: 520))
        assertOnePlayer(expecting: "full", "short window, sidebar")
        UserDefaults.standard.set(false, forKey: "recordings.sidebarVisible")
        pump(1.6)
        assertOnePlayer(expecting: "compact", "short window, compact")
    }

    func testLayoutRules() {
        XCTAssertTrue(RecordingsWorkspaceLayout(total: 1320, sidebarWidth: 340, wantsSidebar: true, focus: false, hasDocument: true).showsSidebar)
        XCTAssertFalse(RecordingsWorkspaceLayout(total: 900, sidebarWidth: 340, wantsSidebar: true, focus: false, hasDocument: true).showsSidebar)
        let focus = RecordingsWorkspaceLayout(total: 1320, sidebarWidth: 340, wantsSidebar: true, focus: true, hasDocument: true)
        XCTAssertFalse(focus.showsSidebar)
        XCTAssertFalse(focus.showsList)
        XCTAssertFalse(RecordingsWorkspaceLayout(total: 1320, sidebarWidth: 340, wantsSidebar: false, focus: false, hasDocument: true).showsSidebar)
        XCTAssertFalse(RecordingsWorkspaceLayout(total: 1320, sidebarWidth: 340, wantsSidebar: true, focus: false, hasDocument: false).showsSidebar)
    }
}
