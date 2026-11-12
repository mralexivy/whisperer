//
//  AppleTimedWordsIntegrationTests.swift
//  WhispererTests
//
//  Real Apple dictation, real audio, 1x: do the settled timed words land on the audio clock, and
//  do the paragraph breaks fall on the pauses that were put there? Opt-in (needs the dictation
//  assets, runs in real time).
//
//    TEST_RUNNER_TIMED_WORDS_WAV=<16 kHz wav>  TEST_RUNNER_TIMED_WORDS_TRUTH=<json [{after_s, gap_s}]>
//

import XCTest
@testable import whisperer

@available(macOS 26.0, *)
@MainActor
final class AppleTimedWordsIntegrationTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    func testSettledWordsKeepAudioTimeAndBreaksFallOnPauses() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let wav = env["TIMED_WORDS_WAV"], let truthPath = env["TIMED_WORDS_TRUTH"] else {
            throw XCTSkip("set TEST_RUNNER_TIMED_WORDS_WAV and TEST_RUNNER_TIMED_WORDS_TRUTH")
        }
        let samples = try loadAudioSamples(from: URL(fileURLWithPath: wav))
        struct Pause: Decodable { let after_s: Double; let gap_s: Double }
        let truth = try JSONDecoder().decode([Pause].self, from: Data(contentsOf: URL(fileURLWithPath: truthPath)))

        let bridge = SystemLivePreviewBridge(preferredLanguages: [.english])
        Self.keepAlive.append(bridge)
        let collected = TimedCollector()
        await bridge.setTimedWordsCallback { collected.add($0) }
        await bridge.beginSession(language: .english)

        let began = Date()
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 1_600, samples.count)
            await bridge.feed(samples: Array(samples[offset..<end]))
            offset = end
            let due = Double(offset) / 16_000 - Date().timeIntervalSince(began)
            if due > 0 { try await Task.sleep(nanoseconds: UInt64(due * 1e9)) }
        }
        let finalText = await bridge.endSession()

        let words = collected.all
        let spoken = finalText.split(separator: " ").count
        print("[TimedWords] \(words.count) timed words vs \(spoken) words in the session text")
        XCTAssertLessThanOrEqual(abs(words.count - spoken), max(3, spoken / 33), "timed words must carry the whole transcript")
        // Strictly increasing starts, inside the recording.
        var previous = -1.0
        for word in words {
            let start = try XCTUnwrap(word.start)
            XCTAssertGreaterThanOrEqual(start, previous)
            previous = max(previous, start)
        }
        XCTAssertLessThanOrEqual(previous, Double(samples.count) / 16_000 + 1)

        for (a, b) in zip(words, words.dropFirst()) {
            if let end = a.end, let start = b.start, start - end >= 1.2 {
                print(String(format: "[TimedWords] gap %.1fs after '%@' at %.1fs", start - end, a.text, end))
            }
        }
        var segmenter = LiveParagraphSegmenter()
        var breakTimes: [Double] = []
        for word in words where segmenter.breaksBefore(word) { breakTimes.append(word.start ?? 0) }
        print("[TimedWords] \(words.count) words, breaks at \(breakTimes.map { String(format: "%.1f", $0) })")
        // Every long pause (>= 3 s) must have a break right after it; none may be missing.
        for pause in truth where pause.gap_s >= 3 {
            XCTAssertTrue(breakTimes.contains { $0 >= pause.after_s && $0 <= pause.after_s + pause.gap_s + 2.5 },
                          "no break after the \(pause.gap_s) s pause at \(pause.after_s) s")
        }
        // No break inside short pauses.
        for pause in truth where pause.gap_s < 1 {
            XCTAssertFalse(breakTimes.contains { $0 >= pause.after_s && $0 <= pause.after_s + pause.gap_s + 1 },
                           "break inside the \(pause.gap_s) s pause at \(pause.after_s) s")
        }
    }
}

private final class TimedCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var words: [TimedWord] = []
    func add(_ new: [TimedWord]) { lock.lock(); words += new; lock.unlock() }
    var all: [TimedWord] { lock.lock(); defer { lock.unlock() }; return words }
}
