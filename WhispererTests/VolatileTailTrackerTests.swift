//
//  VolatileTailTrackerTests.swift
//  WhispererTests
//
//  The tracker must give exactly what splitting the whole text gives — on every input a live meeting can produce
//  (growth, revision of the newest words, restarts, shrinking, odd spacing, Unicode) — while doing a fixed amount of
//  work per update.
//

import XCTest
@testable import whisperer

final class VolatileTailTrackerTests: XCTestCase {

    private func reference(_ text: String, settled: Int) -> String {
        SystemLivePreviewBridge.words(text).dropFirst(settled).joined(separator: " ")
    }

    func testMatchesTheFullSplitOnGrowingAndRevisedText() {
        var tracker = VolatileTailTracker()
        var words: [String] = []
        var settled = 0
        var rng = SystemRandomNumberGenerator()
        for step in 0..<2_000 {
            words.append(["привет", "hello", "שלום", "мир.", "e\u{301}cole", "x"].randomElement(using: &rng)!)
            if step % 7 == 0, settled < words.count - 2 { settled += Int.random(in: 1...2, using: &rng) }
            if step % 5 == 0, let last = words.last { words[words.count - 1] = last + "т" } // the newest word flickers
            let text = words.joined(separator: " ")
            XCTAssertEqual(tracker.tail(of: text, settled: min(settled, words.count)), reference(text, settled: min(settled, words.count)), "step \(step)")
        }
    }

    func testAnUnchangedPrefixIsRecognisedAndAChangedOneIsNot() {
        var tracker = VolatileTailTracker()
        let a = "one two three four five six seven"
        XCTAssertEqual(tracker.tail(of: a, settled: 3), "four five six seven")
        // The settled words change underneath (a restart carried different text): the cached position must not be trusted.
        let b = "alpha beta gamma delta epsilon"
        XCTAssertEqual(tracker.tail(of: b, settled: 3), reference(b, settled: 3))
        // Settled count going backwards (a new meeting) starts over.
        XCTAssertEqual(tracker.tail(of: a, settled: 1), reference(a, settled: 1))
    }

    func testFewerWordsThanSettledYieldsNothing() {
        var tracker = VolatileTailTracker()
        XCTAssertEqual(tracker.tail(of: "one two", settled: 5), "")
        XCTAssertEqual(tracker.tail(of: "", settled: 0), "")
        XCTAssertEqual(tracker.tail(of: "one two three", settled: 3), "")
    }

    func testOddSpacingIsCollapsedLikeTheSplit() {
        var tracker = VolatileTailTracker()
        let text = "  one   two  three    four   five  "
        for settled in 0...6 {
            XCTAssertEqual(tracker.tail(of: text, settled: settled), reference(text, settled: settled), "settled \(settled)")
            tracker.reset()
        }
    }

    func testNewTextAfterAShrinkIsHandled() {
        var tracker = VolatileTailTracker()
        _ = tracker.tail(of: (0..<50).map(String.init).joined(separator: " "), settled: 40)
        let shorter = (0..<30).map(String.init).joined(separator: " ")
        XCTAssertEqual(tracker.tail(of: shorter, settled: 25), reference(shorter, settled: 25))
    }

    /// The point of the tracker: the cost of an update does not depend on how long the transcript is.
    func testCostDoesNotGrowWithTheTranscript() {
        func millis(words: Int) -> Double {
            var tracker = VolatileTailTracker()
            var text = (0..<words).map { "слово\($0 % 97)" }.joined(separator: " ")
            _ = tracker.tail(of: text, settled: words - 5)
            let start = DispatchTime.now().uptimeNanoseconds
            for i in 0..<200 {
                text += " ещё\(i)"
                _ = tracker.tail(of: text, settled: words - 5 + i / 20)
            }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        _ = millis(words: 100)
        let small = (0..<3).map { _ in millis(words: 200) }.min()!
        let huge = (0..<3).map { _ in millis(words: 60_000) }.min()!
        // Appending a word to a 60,000-word String is itself O(n) in this harness (copy), so allow for that and
        // check the scan is not what dominates: the full split of 60,000 words takes far longer than this bound.
        XCTAssertLessThan(huge, max(250, small * 150), "small=\(small) ms, huge=\(huge) ms")
    }
}
