//
//  MeetingLiveRealAudioTests.swift
//  WhispererTests
//
//  The whole live-paragraph path on the user's real saved meetings: the recording is played at 1x
//  into Apple dictation (`SystemLivePreviewBridge`), its settled timed words go to a
//  `MeetingSession` exactly as `AppState` wires them, and the cards that come out are compared with
//  what the meeting has saved. Opt-in — it runs in real time on real audio.
//
//    TEST_RUNNER_MEETING_LIVE=1   [TEST_RUNNER_MEETING_LIVE_MAX_SECONDS=200]
//

import XCTest
@testable import whisperer

@available(macOS 26.0, *)
@MainActor
final class MeetingLiveRealAudioTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    func testLiveCardsOnRealMeetings() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MEETING_LIVE"] != nil else { throw XCTSkip("set TEST_RUNNER_MEETING_LIVE=1") }
        let maxSeconds = Double(env["MEETING_LIVE_MAX_SECONDS"] ?? "200") ?? 200

        let meetings = HistoryTestLoader.loadMeetingFixtures(maxCount: 50).filter { fixture in
            fixture.audioURL != nil && TranscriptionLanguage(rawValue: fixture.language).map { $0 != .auto } == true
        }
        try XCTSkipIf(meetings.isEmpty, "no saved meetings with audio")

        var rows: [String] = []
        for meeting in meetings {
            let language = TranscriptionLanguage(rawValue: meeting.language) ?? .english
            var samples = try loadAudioSamples(from: meeting.audioURL!)
            samples = Array(samples.prefix(Int(maxSeconds * 16_000)))
            let seconds = Double(samples.count) / 16_000

            let session = MeetingSession()
            Self.keepAlive.append(session)
            session.meetingID = UUID()
            session.isRecording = true
            defer { MeetingPendingStore.clear(meetingID: session.meetingID!) }

            let bridge = SystemLivePreviewBridge(preferredLanguages: [language])
            Self.keepAlive.append(bridge)
            let words = WordBox()
            await bridge.setTimedWordsCallback { new in
                words.add(new)
                Task { @MainActor in session.onAttributedWords(new, speakerIndex: 0) }
            }
            await bridge.beginSession(language: language)

            let began = Date()
            var offset = 0
            while offset < samples.count {
                let end = min(offset + 1_600, samples.count)
                await bridge.feed(samples: Array(samples[offset..<end]))
                offset = end
                let due = Double(offset) / 16_000 - Date().timeIntervalSince(began)
                if due > 0 { try await Task.sleep(nanoseconds: UInt64(due * 1e9)) }
            }
            let sessionText = await bridge.endSession()
            try await Task.sleep(nanoseconds: 300_000_000)   // the last callbacks hop to the main actor

            // What the live window would show: committed cards, then the open paragraph.
            var live = session.segments
            if !session.currentSegmentText.isEmpty {
                live.append(MeetingSegment(timestamp: session.currentSegmentStartTimestamp,
                                           endTimestamp: seconds, text: session.currentSegmentText))
            }
            let liveWords = live.flatMap { $0.text.split(separator: " ") }.count
            let timed = words.all
            let timedWordsCount = timed.count
            let saved = meeting.segments.map(\.text).joined(separator: " ")
            let savedWordsCount = saved.split(separator: " ").count
            let afterPass = FinalParagraphPass.apply(live)

            func layout(_ cards: [MeetingSegment]) -> String {
                let sizes = cards.map { FinalParagraphPass.wordCount($0.text) }
                return "\(cards.count) cards, words/card \(sizes)"
            }
            rows.append("""
                [MeetingLive] \(meeting.id.prefix(6)) \(meeting.language) \(Int(seconds))s: \
                Apple words \(sessionText.split(separator: " ").count), timed \(timedWordsCount), in cards \(liveWords), \
                saved transcript \(savedWordsCount)
                [MeetingLive]    live:      \(layout(live))
                [MeetingLive]    saved:     \(layout(meeting.segments))
                [MeetingLive]    after pass \(layout(afterPass))
                """)
            // The session's per-utterance editor may drop a filler or a stutter ("the the"), so the cards
            // can hold slightly fewer words than arrived — never more than a few percent fewer.
            XCTAssertGreaterThanOrEqual(liveWords, timedWordsCount - max(4, timedWordsCount / 25),
                                        "timed words must reach a card (\(meeting.id.prefix(6)))")
            XCTAssertLessThanOrEqual(liveWords, timedWordsCount)
            XCTAssertLessThanOrEqual(abs(timedWordsCount - sessionText.split(separator: " ").count),
                                     max(3, sessionText.split(separator: " ").count / 20))
            var previous = -1.0
            for word in timed {
                guard let start = word.start else { continue }
                XCTAssertGreaterThanOrEqual(start, previous)
                previous = start
            }
        }
        print(rows.joined(separator: "\n"))
    }
}

private final class WordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var words: [TimedWord] = []
    func add(_ new: [TimedWord]) { lock.lock(); words += new; lock.unlock() }
    var all: [TimedWord] { lock.lock(); defer { lock.unlock() }; return words }
}
