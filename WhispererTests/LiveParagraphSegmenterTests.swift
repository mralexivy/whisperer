//
//  LiveParagraphSegmenterTests.swift
//  WhispererTests
//
//  The edge-case table of docs/exec-plans/live-transcript-paragraphs.md §E, on synthetic word
//  streams: speech at 2.5 words/s with chosen pauses.
//

import XCTest
@testable import whisperer

final class LiveParagraphSegmenterTests: XCTestCase {

    /// `script` is a list of (word, pauseBeforeSeconds). Returns the indices where a paragraph starts.
    private func breaks(_ script: [(String, Double)], timed: Bool = true) -> [Int] {
        var segmenter = LiveParagraphSegmenter()
        var clock = 0.0
        var result: [Int] = []
        for (index, item) in script.enumerated() {
            clock += item.1
            let word = TimedWord(text: item.0, start: timed ? clock : nil, end: timed ? clock + 0.4 : nil)
            clock += 0.4
            if segmenter.breaksBefore(word), index > 0 { result.append(index) }
        }
        return result
    }

    private func run(_ count: Int, pause: Double = 0.05, endingWith final: String = "word") -> [(String, Double)] {
        (0..<count).map { ($0 == count - 1 ? final : "word", pause) }
    }

    func testContinuousSpeechNeverBreaks() {
        XCTAssertEqual(breaks(run(80)), [])
    }

    func testLongPauseBreaksAfterTwelveWords() {
        let script = run(14) + [("next", 6.0)] + run(5)
        XCTAssertEqual(breaks(script), [14])
    }

    func testLongPauseDoesNotBreakFragment() {
        XCTAssertEqual(breaks(run(8) + [("next", 6.0)] + run(8)), [])
    }

    func testThreeSecondPauseNeedsTwentyFiveWords() {
        XCTAssertEqual(breaks(run(20) + [("next", 3.5)] + run(5)), [])
        XCTAssertEqual(breaks(run(30) + [("next", 3.5)] + run(5)), [30])
    }

    func testShortPauseBreaksOnlyPastNinetyWords() {
        XCTAssertEqual(breaks(run(40, endingWith: "done.") + [("next", 1.0)] + run(5)), [])
        XCTAssertEqual(breaks(run(70, endingWith: "done.") + [("next", 1.0)] + run(5)), [70])
    }

    func testContinuationWordHoldsThePause() {
        // "and" + 3.5 s pause at 30 words: 4 + 0 − 2 < 3, stays open.
        XCTAssertEqual(breaks(run(29) + [("and", 0.05), ("then", 3.5)] + run(5)), [])
        // The same pause after a non-continuation word breaks.
        XCTAssertEqual(breaks(run(30) + [("then", 3.5)] + run(5)), [30])
    }

    func testHebrewContinuationHoldsThePause() {
        XCTAssertEqual(breaks(run(29) + [("כי", 0.05), ("אז", 3.5)] + run(5)), [])
    }

    func testWrongPeriodAloneNeverBreaksUnderSixtyWords() {
        XCTAssertEqual(breaks(run(40, endingWith: "wrong.") + [("next", 0.1)] + run(5)), [])
    }

    func testNoTimingNoBreakUnderNinetyWords() {
        XCTAssertEqual(breaks(run(85, endingWith: "end.") + run(5), timed: false), [])
    }

    func testNoTimingBreaksAtSentenceEndFromNinetyWords() {
        let result = breaks(run(95, endingWith: "end.") + run(5), timed: false)
        XCTAssertEqual(result, [95])
    }

    func testNoTimingNoPunctuationIsForcedAtOneFortyAndNeverFragments() {
        let result = breaks(run(300, endingWith: "word"), timed: false)
        XCTAssertFalse(result.isEmpty)
        var previous = 0
        for index in result {
            XCTAssertGreaterThanOrEqual(index - previous, 90)
            previous = index
        }
        XCTAssertLessThanOrEqual(result[0], 150)
    }

    func testNoBreakInsideANumber() {
        var script = run(139, endingWith: "version")
        script.append(("3", 0)); script.append(("5", 0)); script += run(5)
        let result = breaks(script, timed: false)
        XCTAssertFalse(result.contains(140), "never between 3 and 5")
    }

    func testSentenceEndDetectionIgnoresVersionsAndDecimals() {
        XCTAssertFalse(LiveParagraphSegmenter.endsSentence("v1.2"))
        XCTAssertFalse(LiveParagraphSegmenter.endsSentence("3.5"))
        XCTAssertTrue(LiveParagraphSegmenter.endsSentence("done."))
        XCTAssertTrue(LiveParagraphSegmenter.endsSentence("really?"))
    }

    func testTurnChangeResetsTheParagraph() {
        var segmenter = LiveParagraphSegmenter()
        for i in 0..<30 { _ = segmenter.breaksBefore(TimedWord(text: "w", start: Double(i), end: Double(i) + 0.4)) }
        segmenter.startTurn()
        XCTAssertEqual(segmenter.wordCount, 0)
    }

    func testCostPerWordIsTiny() {
        var segmenter = LiveParagraphSegmenter()
        let started = Date()
        for i in 0..<200_000 { _ = segmenter.breaksBefore(TimedWord(text: "w", start: Double(i) * 0.4, end: Double(i) * 0.4 + 0.3)) }
        let perWordMs = Date().timeIntervalSince(started) * 1000 / 200_000
        XCTAssertLessThan(perWordMs, 0.05)
    }
}
