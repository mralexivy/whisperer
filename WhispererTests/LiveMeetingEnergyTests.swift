//
//  LiveMeetingEnergyTests.swift
//  WhispererTests
//
//  A live meeting transcribes with Apple's on-device models, so the only thing the app itself should cost while
//  it listens is showing the words. This drives the real live meeting window with a realistic speech stream —
//  2.6 words/s, the newest words revised every 300 ms, settled batches every ~2 s, twenty minutes already
//  transcribed, 119 cards above — in real time, and measures the process's CPU time. CPU time is the energy
//  proxy: the idle window is measured first and subtracted, so the number is what the live text costs.
//

import AppKit
import SwiftUI
import XCTest
@testable import whisperer

@MainActor
final class LiveMeetingEnergyTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    // MARK: - Measuring

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }

    /// The test host is the whole app: for a while after launch it loads models, starts servers and warms caches.
    /// Measuring through that measures the app's startup, not the live window — wait until a few seconds in a row
    /// are quiet.
    private func awaitQuietHost(maxSeconds: Double = 90) {
        var quiet = 0
        let started = Date()
        while quiet < 3, Date().timeIntervalSince(started) < maxSeconds {
            let c0 = cpuSeconds(), w0 = Date()
            run(seconds: 2, interval: 0.5) { _ in }
            let percent = (cpuSeconds() - c0) / Date().timeIntervalSince(w0) * 100
            quiet = percent < 3 ? quiet + 1 : 0
        }
    }

    /// Runs the main run loop for `seconds`, calling `step(elapsed)` every `interval`, sleeping in between
    /// (a busy pump would measure the test, not the app).
    private func run(seconds: Double, interval: Double = 0.05, step: (Double) -> Void) {
        let start = Date()
        var next = start
        while true {
            let now = Date()
            let elapsed = now.timeIntervalSince(start)
            if elapsed >= seconds { break }
            if now >= next {
                step(elapsed)
                next = next.addingTimeInterval(interval)
            }
            RunLoop.current.run(mode: .default, before: min(next, start.addingTimeInterval(seconds)))
        }
    }

    // MARK: - Speech stream

    private static let corpus = ("Привет как дела Мы сегодня обсуждаем проект и следующий шаг по бюджету на ноябрь "
        + "so the next thing on the list is the quarterly plan and how we split it between the teams "
        + "и еще нужно поговорить про релиз потому что клиенты ждут обновление уже две недели").split(separator: " ").map(String.init)

    /// What Apple dictation does: settled words never change, the newest few are revised in place.
    private struct Speaker {
        var spoken: [String] = []       // every word so far (the accumulated text Apple reports)
        var settled = 0                 // how many of them are final
        var clock = 0.0                 // audio seconds
        var settledTimed: [TimedWord] = []
        private var cursor = 0

        mutating func say(words n: Int) {
            for _ in 0..<n {
                spoken.append(LiveMeetingEnergyTests.corpus[cursor % LiveMeetingEnergyTests.corpus.count] + (cursor % 13 == 12 ? "." : ""))
                cursor += 1
            }
        }

        /// The newest words as Apple would currently hear them: the last one flickers between two spellings.
        func volatileWords(revision: Int) -> [String] {
            var tail = Array(spoken[settled...])
            if let last = tail.last, revision % 2 == 1 { tail[tail.count - 1] = last.lowercased() + "т" }
            return tail
        }

        /// Settles all but the newest `keep` words and returns them with audio times.
        mutating func settle(keep: Int) -> [TimedWord] {
            let upTo = max(settled, spoken.count - keep)
            let words = spoken[settled..<upTo].map { w -> TimedWord in
                defer { clock += 0.38 }
                return TimedWord(text: w, start: clock, end: clock + 0.3)
            }
            settled = upTo
            return Array(words)
        }
    }

    // MARK: - Scenario

    private struct Result { var cpuPercent: Double; var wallSeconds: Double; var active = 0.0; var idle = 0.0 }

    /// Main-thread seconds spent inside each part of the driver, so the remainder is rendering and the run loop.
    private var spent: [String: Double] = [:]
    private func timed<T>(_ name: String, _ body: () -> T) -> T {
        let t = CACurrentMediaTime()
        defer { spent[name, default: 0] += CACurrentMediaTime() - t }
        return body()
    }

    /// `longMeeting`: twenty minutes already transcribed (3,000 words in Apple's accumulated text, 119 cards).
    private func liveMeetingCPU(seconds: Double, longMeeting: Bool, driver: (_ session: MeetingSession, _ speaker: inout Speaker, _ elapsed: Double, _ tick: Int) -> Void) -> Result {
        let id = UUID()
        var record = MeetingRecord(id: id, title: "Weekly", language: "ru", modelUsed: "apple")
        record.isInProgress = true
        let session = MeetingSession()
        session.meetingID = id
        session.isRecording = true
        session.coordinatorOwnsTail = true
        let segments: [MeetingSegment] = longMeeting ? (0..<119).map { i in
            MeetingSegment(timestamp: Double(i) * 10, endTimestamp: Double(i) * 10 + 9,
                           text: "Мы обсуждаем бюджет на ноябрь и следующий шаг, пункт \(i). The next item is the quarterly plan.",
                           speakerName: i % 2 == 0 ? "Alex" : "Keren", speakerIndex: i % 2) } : []
        let view = MeetingLiveTranscriptView(session: session, meeting: record, segments: segments)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 420, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [session, hosting, window]
        awaitQuietHost()
        run(seconds: 1.0) { _ in } // settle layout

        var speaker = Speaker()
        if longMeeting { speaker.say(words: 3_000); speaker.settled = 3_000 }

        // Idle first: the hosted window with nothing happening.
        let idleStart = cpuSeconds(), idleWall = Date()
        run(seconds: 3, interval: 0.5) { _ in }
        let idle = (cpuSeconds() - idleStart) / Date().timeIntervalSince(idleWall)

        // Warm up with the same stream first: the first text layout in a process pays for font fallback and glyph
        // caches once. That is a start-up cost, not what a running meeting costs, and it made the first scenario in a
        // process look worse than the same scenario later.
        var tick = 0
        run(seconds: 8, interval: 0.1) { elapsed in
            if tick % 4 == 0 { speaker.say(words: 1) }
            if tick % 10 == 0 { speaker.say(words: 1) }
            driver(session, &speaker, elapsed, tick)
            tick += 1
        }
        spent = [:]
        // A profiler script can wait for this file to sample exactly the active phase.
        try? "\(getpid())".write(toFile: NSTemporaryDirectory() + "live-energy-active.marker", atomically: true, encoding: .utf8)
        let cpu0 = cpuSeconds(), wall0 = Date()
        run(seconds: seconds, interval: 0.1) { elapsed in
            // 2.6 words per second → 0.26 per tick; speak in whole words.
            if tick % 4 == 0 { speaker.say(words: 1) }       // ~2.5/s
            if tick % 10 == 0 { speaker.say(words: 1) }      // top up to ~2.6/s
            driver(session, &speaker, elapsed, tick)
            tick += 1
        }
        let wall = Date().timeIntervalSince(wall0)
        let active = (cpuSeconds() - cpu0) / wall
        window.orderOut(nil)
        return Result(cpuPercent: max(0, active - idle) * 100, wallSeconds: wall, active: active * 100, idle: idle * 100)
    }

    /// The path AppState runs today for Apple dictation in a meeting, for every volatile update and settled batch.
    private func currentAppStateDriver(_ session: MeetingSession, _ speaker: inout Speaker, _ elapsed: Double, _ tick: Int, pending: inout String, settledCount: inout Int, tracker: inout VolatileTailTracker) {
        if tick % 3 == 0 { // a volatile update every 300 ms
            let volatile: String = timed("1 tail computation") {
                let tail = speaker.spoken.joined(separator: " ")
                settledCount = speaker.settled
                return tracker.tail(of: tail, settled: settledCount)
            }
            timed("2 livePreviewText setter") { session.livePreviewText = SystemLivePreviewBridge.join(pending, volatile) }
        }
        if tick % 22 == 0, tick > 0 { // a settled batch about every 2.2 s
            let words = speaker.settle(keep: 3)
            if !words.isEmpty { timed("3 onAttributedWords") { session.onAttributedWords(words, speakerIndex: 0) } }
        }
    }

    private func report(_ name: String, _ r: Result) {
        print(String(format: "LIVE_ENERGY %@: %.1f%% of a core above idle (active %.1f%%, idle %.1f%%) over %.0fs", name, r.cpuPercent, r.active, r.idle, r.wallSeconds))
        for (k, v) in spent.sorted(by: { $0.key < $1.key }) { print(String(format: "LIVE_ENERGY   %@: %.1f%% of a core", k, v / r.wallSeconds * 100)) }
        spent = [:]
    }

    func testLiveMeetingCPUOverTwentyMinutesIn() {
        var pending = "", settledCount = 0, tracker = VolatileTailTracker()
        let r = liveMeetingCPU(seconds: 30, longMeeting: true) { session, speaker, elapsed, tick in
            self.currentAppStateDriver(session, &speaker, elapsed, tick, pending: &pending, settledCount: &settledCount, tracker: &tracker)
        }
        report("long-meeting", r)
        // 2026-11-15 baseline in this scenario: 29.4%. Debug builds run ~3-4x slower than Release, so this is generous.
        XCTAssertLessThan(r.cpuPercent, 8, "a live meeting twenty minutes in must cost almost nothing above idle")
    }

    /// The live window with a recording in progress and nothing being said. It should cost nothing: any CPU here is
    /// an animation, timer or re-render that runs for as long as the meeting does.
    func testAnIdleLiveWindowCostsNothing() {
        // Control: the test host is the whole app (health monitor, servers, model preloading), so measure it with no
        // window first and report the window's cost above that.
        awaitQuietHost()
        let c0 = cpuSeconds(), cw0 = Date()
        run(seconds: 8, interval: 0.5) { _ in }
        let control = (cpuSeconds() - c0) / Date().timeIntervalSince(cw0) * 100
        let id = UUID()
        var record = MeetingRecord(id: id, title: "Weekly", language: "ru", modelUsed: "apple")
        record.isInProgress = true
        let session = MeetingSession()
        session.meetingID = id
        session.isRecording = true
        let segments: [MeetingSegment] = (0..<119).map { i in
            MeetingSegment(timestamp: Double(i) * 10, endTimestamp: Double(i) * 10 + 9,
                           text: "Мы обсуждаем бюджет на ноябрь и следующий шаг, пункт \(i). The next item is the quarterly plan.",
                           speakerName: i % 2 == 0 ? "Alex" : "Keren", speakerIndex: i % 2) }
        let hosting = NSHostingView(rootView: MeetingLiveTranscriptView(session: session, meeting: record, segments: segments))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 420, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [session, hosting, window]
        run(seconds: 3.0, interval: 0.5) { _ in } // let layout and any one-off work finish
        let cpu0 = cpuSeconds(), wall0 = Date()
        run(seconds: 10, interval: 0.5) { _ in }
        let percent = (cpuSeconds() - cpu0) / Date().timeIntervalSince(wall0) * 100
        print(String(format: "LIVE_ENERGY idle live window: %.1f%% of a core (control without the window: %.1f%%) => window costs %.1f%%", percent, control, percent - control))
        XCTAssertLessThan(percent - control, 2, "an idle live window must not animate or poll")
        window.close()
    }

    func testLiveMeetingCPUAtTheStart() {
        var pending = "", settledCount = 0, tracker = VolatileTailTracker()
        let r = liveMeetingCPU(seconds: 30, longMeeting: false) { session, speaker, elapsed, tick in
            self.currentAppStateDriver(session, &speaker, elapsed, tick, pending: &pending, settledCount: &settledCount, tracker: &tracker)
        }
        report("fresh-meeting", r)
        XCTAssertLessThan(r.cpuPercent, 8)
    }
}
