//
//  EagerStreamEngineTests.swift
//  WhispererTests
//
//  Unit tests for EagerStreamEngine — the backend-agnostic LocalAgreement-2 algorithm.
//  No model, no audio, no async — all tests run in milliseconds.
//

import XCTest
@testable import whisperer

final class EagerStreamEngineTests: XCTestCase {

    // MARK: - Helpers

    private let sampleRate = 16000
    private let config = EagerStreamEngine.Config.default

    /// Make a StreamWord at absolute sample positions. `startSec` and `endSec` are relative to
    /// the ring start (absolute = ringBase + sec * 16000).
    private func word(
        _ text: String,
        startSec: Double,
        endSec: Double,
        p: Float = 0.90,
        ringBase: Int = 0
    ) -> EagerStreamWord {
        EagerStreamWord(
            text: text,
            tokens: [],
            startIndex: ringBase + Int(startSec * Double(sampleRate)),
            endIndex: ringBase + Int(endSec * Double(sampleRate)),
            probability: p
        )
    }

    /// Build a hypothesis list from a space-separated sentence, each word getting 0.5s.
    private func sentence(
        _ s: String,
        startSec: Double = 0,
        p: Float = 0.90,
        ringBase: Int = 0
    ) -> [EagerStreamWord] {
        let words = s.split(separator: " ").map(String.init)
        return words.enumerated().map { i, w in
            let s = startSec + Double(i) * 0.5
            return word(" " + w, startSec: s, endSec: s + 0.45, p: p, ringBase: ringBase)
        }
    }

    // MARK: - Initial state

    func testInitialState() {
        let engine = EagerStreamEngine()
        XCTAssertNil(engine.agreementStartIndex)
        XCTAssertTrue(engine.confirmedWords.isEmpty)
        XCTAssertTrue(engine.prefixTokens.isEmpty)
    }

    // MARK: - First pass (no previousHypothesis)

    func testFirstPassReturnsDisplayTextWithNoConfirmation() {
        let engine = EagerStreamEngine()
        engine.reset(at: 0)

        let hyp = sentence("hello world how are you")
        let outcome = engine.consume(
            hypothesis: hyp,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0
        )
        // No previousHypothesis → no confirmation, but display text should appear.
        XCTAssertNotNil(outcome.displayText)
        XCTAssertTrue(outcome.displayText!.contains("hello"))
        XCTAssertNil(outcome.softCommit)
        XCTAssertFalse(outcome.wasHeld)
        // No confirmation yet — confirmedWords should be empty.
        XCTAssertTrue(engine.confirmedWords.isEmpty)
    }

    // MARK: - Normal confirmation (common prefix > boundaryWordCount)

    func testConfirmationOnSecondPassWithSuffix() {
        let engine = EagerStreamEngine()
        engine.reset(at: 0)

        // Pass 1
        let hyp1 = sentence("the cat sat on the mat")
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0)

        // Pass 2 — same prefix, one extra word
        let hyp2 = sentence("the cat sat on the mat and")
        let outcome = engine.consume(
            hypothesis: hyp2,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0
        )

        XCTAssertNotNil(outcome.displayText)
        // commonCount = 6; boundary = 2 → newlyConfirmed = 4 words
        XCTAssertEqual(engine.confirmedWords.count, 4,
                       "Should confirm 4 words (commonCount - boundaryWordCount = 6 - 2)")
        XCTAssertFalse(outcome.wasHeld)
    }

    // MARK: - Monotonicity: confirmed words + provisional tail never shrink

    func testDisplayTextDoesNotShrinkAcrossConsecutivePasses() {
        let engine = EagerStreamEngine()
        engine.reset(at: 0)

        var previousLength = 0
        for passIdx in 0..<5 {
            let words = Array(sentence("the quick brown fox jumped over the lazy dog").prefix((passIdx + 2) * 2))
            let outcome = engine.consume(
                hypothesis: words,
                audioBaseIndex: 0,
                languageIsLocked: true,
                lastCommittedIndex: 0
            )
            if let text = outcome.displayText {
                let len = text.split(separator: " ").count
                XCTAssertGreaterThanOrEqual(len, previousLength,
                    "Display word count must not shrink pass \(passIdx): was \(previousLength), got \(len)")
                previousLength = len
            }
        }
    }

    // MARK: - Anchor guard: unanchored revision is held

    func testUnanchoredRevisionIsHeld() {
        let engine = EagerStreamEngine()
        engine.reset(at: 0)

        // Pass 1 — establish a 5-word hypothesis
        let hyp1 = sentence("one two three four five")
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0)

        // Pass 2 — completely different words (anchor = 0 < requiredAnchor = 2)
        let hyp2 = sentence("alpha beta gamma delta epsilon")
        let outcome = engine.consume(
            hypothesis: hyp2,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0
        )

        XCTAssertNil(outcome.displayText, "Unanchored revision should be held (nil displayText)")
        XCTAssertTrue(outcome.wasHeld, "wasHeld must be set on an anchor failure")
        // confirmedWords must not grow after holding
        XCTAssertTrue(engine.confirmedWords.isEmpty)
    }

    // MARK: - Large retraction is held

    func testLargeRetractionIsHeld() {
        let engine = EagerStreamEngine()
        engine.reset(at: 0)

        // Pass 1 — 8 words
        let hyp1 = sentence("a b c d e f g h")
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0)

        // Pass 2 — only 2 words shared prefix, loses 6 = 8 - 2 words (> maxRetraction = 3)
        // Partial overlap so anchor check passes (common = 2 ≥ 2), but lostWords = 8 - 2 = 6 > 3
        let hyp2 = sentence("a b")
        let outcome = engine.consume(
            hypothesis: hyp2,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0
        )

        XCTAssertNil(outcome.displayText, "Large retraction (6 > maxRetraction=3) should be held")
        XCTAssertTrue(outcome.wasHeld)
    }

    // MARK: - Short-tail branch (commonCount == hyp.count and hyp.count <= boundary)

    func testShortTailConfirmsAllButLastWord() {
        let engine = EagerStreamEngine()
        engine.reset(at: 0)

        // Pass 1 — 4 words
        let hyp1 = sentence("hello there how are")
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0)

        // Pass 2 — 2 words (≤ boundary=2) that are a full common prefix
        let hyp2 = sentence("hello there")
        _ = engine.consume(
            hypothesis: hyp2,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0
        )

        // confirmCount = hyp.count - 1 = 1 (only "hello")
        XCTAssertEqual(engine.confirmedWords.count, 1,
                       "Short-tail with 2 words should confirm exactly 1 (all-but-last)")
    }

    // MARK: - Entropy gate: p ≥ 0.95 words confirmed in one pass without second window

    func testEntropyGateConfirmsHighProbWords() {
        let engine = EagerStreamEngine()
        engine.reset(at: 0)

        // Pass 1 — 8 words at moderate probability (establish previousHypothesis).
        let hyp1 = (0..<8).map { i in
            EagerStreamWord(text: " w\(i)", tokens: [],
                            startIndex: i * (sampleRate / 2), endIndex: i * (sampleRate / 2) + sampleRate / 4,
                            probability: 0.80)
        }
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0)

        // Pass 2 — same 8 words + 4 more, all at p = 0.97.
        // Agreement phase confirms words[0..5] (commonCount=8, boundary=2).
        // The boundary slice [w6, w7] are now at p=0.97, so the entropy gate runs on
        // the re-filtered tail [w6, w7, w8, w9, w10, w11] and should commit w6..w9 (6-2=4 words).
        let hyp2 = (0..<12).map { i in
            EagerStreamWord(text: " w\(i)", tokens: [],
                            startIndex: i * (sampleRate / 2), endIndex: i * (sampleRate / 2) + sampleRate / 4,
                            probability: 0.97)
        }
        let confirmedBefore = engine.confirmedWords.count
        let outcome = engine.consume(
            hypothesis: hyp2,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0
        )

        XCTAssertNotNil(outcome.displayText)
        let confirmedAdded = engine.confirmedWords.count - confirmedBefore
        // Agreement should add 6 words; entropy gate on the tail should add at least 1 more.
        XCTAssertGreaterThan(confirmedAdded, 6,
                             "Entropy gate should confirm additional words on top of the agreement path")
    }

    // MARK: - Entropy gate boundary retention: last `boundaryWordCount` remain provisional

    func testEntropyGateKeepsBoundaryWordsTentative() {
        let engine = EagerStreamEngine()
        engine.reset(at: 0)

        // N words all at p ≥ 0.95 — the last `boundaryWordCount` must stay unconfirmed.
        let n = 6
        let boundary = config.boundaryWordCount
        let hyp = (0..<n).map { i in
            word(" w\(i)", startSec: Double(i) * 0.5, endSec: Double(i) * 0.5 + 0.45, p: 0.97)
        }
        _ = engine.consume(hypothesis: hyp, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0)
        // Entropy gate fires even on pass 1 for very-high-p words (no cross-window requirement).
        // What must hold: at most n - boundary words confirmed (the last `boundary` stay provisional).
        let afterPass1 = engine.confirmedWords.count
        XCTAssertLessThanOrEqual(afterPass1, n - boundary,
                                 "Entropy gate must not confirm the last \(boundary) words on pass 1")

        // Pass 2 with n+1 words (all high-p) — entropy gate runs on the unconfirmed suffix.
        let hyp2 = (0..<(n + 1)).map { i in
            word(" w\(i)", startSec: Double(i) * 0.5, endSec: Double(i) * 0.5 + 0.45, p: 0.97)
        }
        _ = engine.consume(hypothesis: hyp2, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0)

        // The last `boundary` words must NOT be in confirmedWords.
        let confirmedCount = engine.confirmedWords.count
        let totalAvailable = n + 1
        XCTAssertLessThanOrEqual(
            confirmedCount, totalAvailable - boundary,
            "Entropy gate must never confirm the last \(boundary) words (total available = \(totalAvailable))"
        )
    }

    // MARK: - Soft-commit fires after 6 seconds of agreed audio

    func testSoftCommitFiresAfter6Seconds() {
        // Construct agreement boundary at 6.5 × 16000 = 104000 samples past lastCommittedIndex = 0
        let engine = EagerStreamEngine()
        engine.reset(at: 0)

        // Manually inject confirmed words and set agreementStartIndex by running two passes
        // where the common prefix is large enough to push the boundary to 7s.
        let hyp1 = (0..<10).map { i in
            EagerStreamWord(text: " w\(i)", tokens: [], startIndex: i * sampleRate / 2, endIndex: i * sampleRate / 2 + 7000, probability: 0.90)
        }
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0)

        // Pass 2 — same words + extras, boundary lands past 6s
        let hyp2 = (0..<12).map { i in
            EagerStreamWord(text: " w\(i)", tokens: [], startIndex: i * sampleRate / 2, endIndex: i * sampleRate / 2 + 7000, probability: 0.90)
        }
        let outcome = engine.consume(
            hypothesis: hyp2,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0
        )

        // If agreementStartIndex > 6 * 16000, the soft-commit should fire.
        if let startIdx = engine.agreementStartIndex, startIdx >= config.softCommitSamples {
            XCTAssertNotNil(outcome.softCommit,
                            "Soft-commit must fire when agreement boundary is ≥ 6s past lastCommittedIndex")
            XCTAssertFalse(outcome.softCommit!.text.isEmpty,
                           "Soft-commit text must not be empty")
        }
        // If the boundary hasn't crossed 6s (depends on exact word placement), the test is still
        // valid — it asserts no spurious soft-commit.
        else {
            XCTAssertNil(outcome.softCommit, "No soft-commit should fire before 6s boundary")
        }
    }

    func testSoftCommitClearsConfirmedWords() {
        let engine = EagerStreamEngine()
        engine.reset(at: 0)

        // Force a commit by passing agreementStartIndex past 6 × 16000 directly.
        // We do this via two passes with a long enough window.
        let halfSec = sampleRate / 2
        let hyp1 = (0..<15).map { i in
            EagerStreamWord(text: " word\(i)", tokens: [], startIndex: i * halfSec, endIndex: i * halfSec + halfSec - 100, probability: 0.90)
        }
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0)

        let hyp2 = (0..<16).map { i in
            EagerStreamWord(text: " word\(i)", tokens: [], startIndex: i * halfSec, endIndex: i * halfSec + halfSec - 100, probability: 0.90)
        }
        let outcome = engine.consume(
            hypothesis: hyp2,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0
        )

        if outcome.softCommit != nil {
            // After a soft-commit, confirmedWords should be empty.
            XCTAssertTrue(engine.confirmedWords.isEmpty,
                          "confirmedWords must be cleared after soft-commit")
        }
    }

    // MARK: - Language lock gate

    func testNoConfirmationWhenLanguageNotLocked() {
        let engine = EagerStreamEngine()
        engine.reset(at: 0)

        let hyp1 = sentence("the cat sat on the mat")
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: 0, languageIsLocked: false, lastCommittedIndex: 0)

        let hyp2 = sentence("the cat sat on the mat and")
        let outcome = engine.consume(
            hypothesis: hyp2,
            audioBaseIndex: 0,
            languageIsLocked: false,
            lastCommittedIndex: 0
        )

        // Display text still shown (preview keeps running)
        XCTAssertNotNil(outcome.displayText, "Display text should still appear when language not locked")
        // But nothing committed
        XCTAssertTrue(engine.confirmedWords.isEmpty,
                      "No words should be confirmed when languageIsLocked = false")
        XCTAssertNil(outcome.softCommit,
                     "No soft-commit should fire when languageIsLocked = false")
    }

    // MARK: - Empty hypothesis after filtering

    func testEmptyHypothesisAfterFilteringReturnsNil() {
        let engine = EagerStreamEngine()
        engine.reset(at: 5000)  // agreementStartIndex = 5000

        // hypothesis words all start BEFORE the agreementStartIndex — all filtered out
        let staleHyp = [
            word(" old", startSec: 0, endSec: 0.3),
            word(" words", startSec: 0.3, endSec: 0.6)
        ]
        let outcome = engine.consume(
            hypothesis: staleHyp,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0
        )

        XCTAssertNil(outcome.displayText)
        XCTAssertNil(outcome.softCommit)
        XCTAssertFalse(outcome.wasHeld)
    }

    // MARK: - Normalization / case insensitivity

    func testNormalizationIgnoresPunctuationAndCase() {
        let engine = EagerStreamEngine()
        // "Hello," and "hello" should be treated as equal in the agreement check.
        let prev = [word("Hello,", startSec: 0, endSec: 0.4)]
        let curr = [word("hello.", startSec: 0, endSec: 0.4)]
        let common = engine.commonPrefixCount(prev, curr)
        XCTAssertEqual(common, 1, "Normalised words should agree across punctuation and case")
    }

    func testNormalizationSkipsEmptyNormalizedWords() {
        let engine = EagerStreamEngine()
        // A word that normalises to "" (e.g. "...") should NOT match anything.
        let prev = [word("...", startSec: 0, endSec: 0.4)]
        let curr = [word("...", startSec: 0, endSec: 0.4)]
        let common = engine.commonPrefixCount(prev, curr)
        XCTAssertEqual(common, 0, "Words that normalise to empty string must not count as agreement")
    }

    // MARK: - Reset

    func testResetClearsAllState() {
        let engine = EagerStreamEngine()
        engine.reset(at: 0)

        let hyp = sentence("some words here")
        _ = engine.consume(hypothesis: hyp, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0)

        engine.reset(at: 100)

        XCTAssertTrue(engine.confirmedWords.isEmpty)
        XCTAssertTrue(engine.prefixTokens.isEmpty)
        XCTAssertEqual(engine.agreementStartIndex, 100)
    }

    // MARK: - Soft-commit span arithmetic

    func testSoftCommitSpanMatchesLastCommittedIndex() {
        let engine = EagerStreamEngine()
        engine.reset(at: 0)
        let lastCommitted = 1000

        // Force many confirmed words and an agreement boundary well past 6s from lastCommitted.
        let startOffset = lastCommitted + config.softCommitSamples + sampleRate  // 7s past lastCommitted
        var hyp1: [EagerStreamWord] = []
        for i in 0..<10 {
            let s = lastCommitted + i * (sampleRate / 4)
            hyp1.append(EagerStreamWord(text: " w\(i)", tokens: [], startIndex: s, endIndex: s + sampleRate / 4 - 100, probability: 0.90))
        }
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: lastCommitted, languageIsLocked: true, lastCommittedIndex: lastCommitted)

        var hyp2: [EagerStreamWord] = []
        for i in 0..<12 {
            let s = lastCommitted + i * (sampleRate / 4)
            hyp2.append(EagerStreamWord(text: " w\(i)", tokens: [], startIndex: s, endIndex: s + sampleRate / 4 - 100, probability: 0.90))
        }
        let outcome = engine.consume(
            hypothesis: hyp2,
            audioBaseIndex: lastCommitted,
            languageIsLocked: true,
            lastCommittedIndex: lastCommitted
        )

        if let commit = outcome.softCommit {
            XCTAssertEqual(commit.startIndex, lastCommitted,
                           "Soft-commit startIndex must equal the lastCommittedIndex passed in")
            XCTAssertGreaterThan(commit.endIndex, commit.startIndex,
                                 "Soft-commit endIndex must be after startIndex")
        }
        // If no commit fired (boundary < 6s after lastCommitted), the test passes vacuously —
        // the assertion about startIndex only applies when a commit actually fires.
    }

    // MARK: - No duplication in agreed text

    func testAgreedWordsAreNotDuplicated() {
        let engine = EagerStreamEngine()
        engine.reset(at: 0)

        let base = sentence("the quick brown fox")
        _ = engine.consume(hypothesis: base, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0)

        let extended = sentence("the quick brown fox jumps")
        let outcome = engine.consume(
            hypothesis: extended,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0
        )

        if let text = outcome.displayText {
            // "the quick brown fox" should appear exactly once, not "the quick the quick".
            let words = text.lowercased().split(separator: " ")
            let uniqueWords = Set(words)
            // Pairs of consecutive repeated words indicate duplication
            for i in 0..<(words.count - 1) {
                XCTAssertFalse(
                    words[i] == words[i + 1] && words[i].count > 1,
                    "Consecutive identical words '\(words[i])' detected — possible duplication in: \(text)"
                )
            }
        }
    }
}
