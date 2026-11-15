//
//  LivePreviewWindowTests.swift
//  WhispererTests
//
//  The live preview must cost the same however long the live tail has grown, and the watchdog must notice a main
//  thread that is saturated rather than blocked. Both failed on 2026-11-15 and froze the app for fifty minutes.
//

import XCTest
@testable import whisperer

final class LivePreviewWindowTests: XCTestCase {

    private func text(words: Int) -> String {
        let sample = ["Привет", "как", "дела", "Мы", "сегодня", "обсуждаем", "Проект", "and", "the", "Meeting", "Review", "יש", "לנו", "תוכנית"]
        return (0..<words).map { i in sample[i % sample.count] + (i % 11 == 10 ? "." : "") }.joined(separator: " ")
    }

    func testTextWithinTheBudgetIsTransformedWhole() {
        let t = text(words: 40)
        XCTAssertLessThan(t.count, LivePreviewWindow.maxPolishedCharacters)
        XCTAssertEqual(LivePreviewWindow.apply(to: t) { $0.uppercased() }, t.uppercased())
        XCTAssertNil(LivePreviewWindow.split(t))
    }

    func testOnlyTheRecentWindowIsTransformedAndTheHeadIsUntouched() {
        let t = text(words: 2_000)
        var seen = 0
        let out = LivePreviewWindow.apply(to: t) { window in seen = window.count; return window.uppercased() }
        XCTAssertLessThanOrEqual(seen, LivePreviewWindow.maxPolishedCharacters)
        XCTAssertGreaterThan(seen, LivePreviewWindow.maxPolishedCharacters / 2, "the window should be close to the budget, not tiny")
        let (head, tail) = try! XCTUnwrap(LivePreviewWindow.split(t))
        XCTAssertEqual(out, String(head) + String(tail).uppercased())
        XCTAssertEqual(head + tail, Substring(t), "split must not lose or duplicate a character")
    }

    func testTheCutFallsOnWhitespaceAndPrefersASentenceStart() {
        for words in [300, 701, 1_500] {
            let t = text(words: words)
            let (head, tail) = try! XCTUnwrap(LivePreviewWindow.split(t))
            XCTAssertTrue(head.last?.isWhitespace == true, "the head ends at a whitespace boundary")
            XCTAssertFalse(tail.first?.isWhitespace ?? true, "the tail starts on a word")
        }
        // A sentence end inside the search slack wins over the first plain word boundary.
        let long = String(repeating: "слово ", count: 220) + "Конец предложения. Новое начало " + String(repeating: "слово ", count: 200)
        let (_, tail) = try! XCTUnwrap(LivePreviewWindow.split(long))
        XCTAssertFalse(tail.isEmpty)
    }

    func testAnEmptyTransformKeepsTheOriginal() {
        let t = text(words: 2_000)
        XCTAssertEqual(LivePreviewWindow.apply(to: t) { _ in "" }, t, "dropping speech is never acceptable")
    }

    func testRightToLeftAndCombiningTextSplitsOnGraphemeBoundaries() {
        let t = String(repeating: "שלום עולם e\u{301}cole ", count: 400)
        let (head, tail) = try! XCTUnwrap(LivePreviewWindow.split(t))
        XCTAssertEqual(String(head) + String(tail), t)
    }

    /// The regression that froze the app: polishing must not get slower as the tail grows.
    func testLivePolishCostIsBoundedNoMatterHowLongTheTailGrows() {
        let polisher = DeterministicPolisher.forTranscript(dictionaryEntries: [], formatsLists: false, terminatesUtteranceEnd: false, editor: nil)
        func polishMs(_ t: String) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = LivePreviewWindow.apply(to: t) { polisher.polish(text: $0).text }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        _ = polishMs(text(words: 100)) // warm the spell checker and tagger
        let short = (0..<3).map { _ in polishMs(text(words: 180)) }.min()!
        let huge = (0..<3).map { _ in polishMs(text(words: 40_000)) }.min()! // ~300,000 characters
        XCTAssertLessThan(huge, max(60, short * 8), "a 300,000-character tail must cost about what a long utterance costs (short=\(short) ms, huge=\(huge) ms)")
    }

    // MARK: - Chronic stalls

    func testASaturatedMainThreadIsNoticedEvenThoughNoSingleStallIsLong() {
        var tracker = ChronicStallTracker(window: .seconds(120), count: 4, dumpInterval: .seconds(900))
        let t0 = ContinuousClock.now
        XCTAssertFalse(tracker.note(at: t0))
        XCTAssertFalse(tracker.note(at: t0 + .seconds(30)))
        XCTAssertFalse(tracker.note(at: t0 + .seconds(60)))
        XCTAssertTrue(tracker.note(at: t0 + .seconds(90)), "four stalls inside two minutes is chronic")
        XCTAssertFalse(tracker.note(at: t0 + .seconds(120)), "no second dump inside the interval")
        XCTAssertFalse(tracker.note(at: t0 + .seconds(600)))
        XCTAssertTrue(tracker.note(at: t0 + .seconds(1_000)) || tracker.note(at: t0 + .seconds(1_010)) || tracker.note(at: t0 + .seconds(1_020)) || tracker.note(at: t0 + .seconds(1_030)),
                      "after the interval a new chronic run dumps again")
    }

    func testSparseStallsAreNotChronic() {
        var tracker = ChronicStallTracker(window: .seconds(120), count: 4, dumpInterval: .seconds(900))
        let t0 = ContinuousClock.now
        for i in 0..<10 { XCTAssertFalse(tracker.note(at: t0 + .seconds(Double(i) * 200))) }
    }

    func testBuildIdentityCarriesTheUUIDAndLoadAddress() {
        let note = BuildIdentity.symbolicationNote
        XCTAssertTrue(note.contains("uuid="), note)
        XCTAssertTrue(note.contains("load=0x") && !note.contains("load=0x0 ") && !note.hasSuffix("load=0x0"), note)
    }
}
