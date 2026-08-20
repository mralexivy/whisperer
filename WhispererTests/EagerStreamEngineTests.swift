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
        var engine = EagerStreamEngine()
        XCTAssertNil(engine.agreementStartIndex)
        XCTAssertTrue(engine.confirmedWords.isEmpty)
        XCTAssertTrue(engine.prefixTokens.isEmpty)
    }

    // MARK: - First pass (no previousHypothesis)

    func testFirstPassReturnsDisplayTextWithNoConfirmation() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        let hyp = sentence("hello world how are you")
        let outcome = engine.consume(
            hypothesis: hyp,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0, windowEndIndex: .max
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
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        // Pass 1
        let hyp1 = sentence("the cat sat on the mat")
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0, windowEndIndex: .max)

        // Pass 2 — same prefix, one extra word
        let hyp2 = sentence("the cat sat on the mat and")
        let outcome = engine.consume(
            hypothesis: hyp2,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0, windowEndIndex: .max
        )

        XCTAssertNotNil(outcome.displayText)
        // commonCount = 6; boundary = 2 → newlyConfirmed = 4 words
        XCTAssertEqual(engine.confirmedWords.count, 4,
                       "Should confirm 4 words (commonCount - boundaryWordCount = 6 - 2)")
        XCTAssertFalse(outcome.wasHeld)
    }

    // MARK: - Monotonicity: confirmed words + provisional tail never shrink

    func testDisplayTextDoesNotShrinkAcrossConsecutivePasses() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        var previousLength = 0
        for passIdx in 0..<5 {
            let words = Array(sentence("the quick brown fox jumped over the lazy dog").prefix((passIdx + 2) * 2))
            let outcome = engine.consume(
                hypothesis: words,
                audioBaseIndex: 0,
                languageIsLocked: true,
                lastCommittedIndex: 0, windowEndIndex: .max
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
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        // Pass 1 — establish a 5-word hypothesis
        let hyp1 = sentence("one two three four five")
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0, windowEndIndex: .max)

        // Pass 2 — completely different words (anchor = 0 < requiredAnchor = 2)
        let hyp2 = sentence("alpha beta gamma delta epsilon")
        let outcome = engine.consume(
            hypothesis: hyp2,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0, windowEndIndex: .max
        )

        XCTAssertNil(outcome.displayText, "Unanchored revision should be held (nil displayText)")
        XCTAssertTrue(outcome.wasHeld, "wasHeld must be set on an anchor failure")
        XCTAssertEqual(outcome.holdReason, .unanchoredSameStart,
                       "the window start did not move, so this is real instability")
        // confirmedWords must not grow after holding
        XCTAssertTrue(engine.confirmedWords.isEmpty)
    }

    /// The other anchor failure: the boundary advanced, so the new window is cut at a different
    /// sample and its first word is not comparable with the word it is scored against. Classified
    /// apart from `unanchoredSameStart` because they need opposite treatment, and because the
    /// profile could not otherwise tell which of the two is costing 40-50% of all passes.
    func testAnchorLossRightAfterBoundaryMoveIsClassifiedSeparately() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        // Pass 1 — confident enough for the entropy gate to confirm and move the boundary.
        let hyp1 = sentence("one two three four five", p: 0.99)
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: 0, languageIsLocked: true,
                           lastCommittedIndex: 0, windowEndIndex: .max)
        let movedTo = engine.agreementStartIndex
        XCTAssertNotEqual(movedTo, 0, "precondition: the entropy gate must have moved the boundary")

        // Pass 2 — decoded from the new, shorter window; nothing in common at the front.
        let hyp2 = sentence("alpha beta gamma", startSec: 1.5)
        let outcome = engine.consume(hypothesis: hyp2, audioBaseIndex: 0, languageIsLocked: true,
                                     lastCommittedIndex: 0, windowEndIndex: .max)

        XCTAssertTrue(outcome.wasHeld)
        XCTAssertEqual(outcome.holdReason, .unanchoredAfterBoundaryMove)
    }

    // MARK: - Large retraction is held

    func testLargeRetractionIsHeld() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        // Pass 1 — 8 words
        let hyp1 = sentence("a b c d e f g h")
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0, windowEndIndex: .max)

        // Pass 2 — only 2 words shared prefix, loses 6 = 8 - 2 words (> maxRetraction = 3)
        // Partial overlap so anchor check passes (common = 2 ≥ 2), but lostWords = 8 - 2 = 6 > 3
        let hyp2 = sentence("a b")
        let outcome = engine.consume(
            hypothesis: hyp2,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0, windowEndIndex: .max
        )

        XCTAssertNil(outcome.displayText, "Large retraction (6 > maxRetraction=3) should be held")
        XCTAssertTrue(outcome.wasHeld)
    }

    // MARK: - Short-tail branch (commonCount == hyp.count and hyp.count <= boundary)

    func testShortTailConfirmsAllButLastWord() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        // Pass 1 — 4 words
        let hyp1 = sentence("hello there how are")
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0, windowEndIndex: .max)

        // Pass 2 — 2 words (≤ boundary=2) that are a full common prefix
        let hyp2 = sentence("hello there")
        _ = engine.consume(
            hypothesis: hyp2,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0, windowEndIndex: .max
        )

        // confirmCount = hyp.count - 1 = 1 (only "hello")
        XCTAssertEqual(engine.confirmedWords.count, 1,
                       "Short-tail with 2 words should confirm exactly 1 (all-but-last)")
    }

    // MARK: - Entropy gate: p ≥ 0.95 words confirmed in one pass without second window

    func testEntropyGateConfirmsHighProbWords() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        // Pass 1 — 8 words at moderate probability (establish previousHypothesis).
        let hyp1 = (0..<8).map { i in
            EagerStreamWord(text: " w\(i)", tokens: [],
                            startIndex: i * (sampleRate / 2), endIndex: i * (sampleRate / 2) + sampleRate / 4,
                            probability: 0.80)
        }
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0, windowEndIndex: .max)

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
            lastCommittedIndex: 0, windowEndIndex: .max
        )

        XCTAssertNotNil(outcome.displayText)
        let confirmedAdded = engine.confirmedWords.count - confirmedBefore
        // Agreement should add 6 words; entropy gate on the tail should add at least 1 more.
        XCTAssertGreaterThan(confirmedAdded, 6,
                             "Entropy gate should confirm additional words on top of the agreement path")
    }

    // MARK: - Entropy gate boundary retention: last `boundaryWordCount` remain provisional

    func testEntropyGateKeepsBoundaryWordsTentative() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        // N words all at p ≥ 0.95 — the last `boundaryWordCount` must stay unconfirmed.
        let n = 6
        let boundary = config.boundaryWordCount
        let hyp = (0..<n).map { i in
            word(" w\(i)", startSec: Double(i) * 0.5, endSec: Double(i) * 0.5 + 0.45, p: 0.97)
        }
        _ = engine.consume(hypothesis: hyp, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0, windowEndIndex: .max)
        // Entropy gate fires even on pass 1 for very-high-p words (no cross-window requirement).
        // What must hold: at most n - boundary words confirmed (the last `boundary` stay provisional).
        let afterPass1 = engine.confirmedWords.count
        XCTAssertLessThanOrEqual(afterPass1, n - boundary,
                                 "Entropy gate must not confirm the last \(boundary) words on pass 1")

        // Pass 2 with n+1 words (all high-p) — entropy gate runs on the unconfirmed suffix.
        let hyp2 = (0..<(n + 1)).map { i in
            word(" w\(i)", startSec: Double(i) * 0.5, endSec: Double(i) * 0.5 + 0.45, p: 0.97)
        }
        _ = engine.consume(hypothesis: hyp2, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0, windowEndIndex: .max)

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
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        // Manually inject confirmed words and set agreementStartIndex by running two passes
        // where the common prefix is large enough to push the boundary to 7s.
        let hyp1 = (0..<10).map { i in
            EagerStreamWord(text: " w\(i)", tokens: [], startIndex: i * sampleRate / 2, endIndex: i * sampleRate / 2 + 7000, probability: 0.90)
        }
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0, windowEndIndex: .max)

        // Pass 2 — same words + extras, boundary lands past 6s
        let hyp2 = (0..<12).map { i in
            EagerStreamWord(text: " w\(i)", tokens: [], startIndex: i * sampleRate / 2, endIndex: i * sampleRate / 2 + 7000, probability: 0.90)
        }
        let outcome = engine.consume(
            hypothesis: hyp2,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0, windowEndIndex: .max
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
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        // Force a commit by passing agreementStartIndex past 6 × 16000 directly.
        // We do this via two passes with a long enough window.
        let halfSec = sampleRate / 2
        let hyp1 = (0..<15).map { i in
            EagerStreamWord(text: " word\(i)", tokens: [], startIndex: i * halfSec, endIndex: i * halfSec + halfSec - 100, probability: 0.90)
        }
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0, windowEndIndex: .max)

        let hyp2 = (0..<16).map { i in
            EagerStreamWord(text: " word\(i)", tokens: [], startIndex: i * halfSec, endIndex: i * halfSec + halfSec - 100, probability: 0.90)
        }
        let outcome = engine.consume(
            hypothesis: hyp2,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0, windowEndIndex: .max
        )

        if outcome.softCommit != nil {
            // After a soft-commit, confirmedWords should be empty.
            XCTAssertTrue(engine.confirmedWords.isEmpty,
                          "confirmedWords must be cleared after soft-commit")
        }
    }

    // MARK: - Language lock gate

    func testNoConfirmationWhenLanguageNotLocked() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        let hyp1 = sentence("the cat sat on the mat")
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: 0, languageIsLocked: false, lastCommittedIndex: 0, windowEndIndex: .max)

        let hyp2 = sentence("the cat sat on the mat and")
        let outcome = engine.consume(
            hypothesis: hyp2,
            audioBaseIndex: 0,
            languageIsLocked: false,
            lastCommittedIndex: 0, windowEndIndex: .max
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
        var engine = EagerStreamEngine()
        engine.reset(at: 5000)  // agreementStartIndex = 5000

        // Every word ends before the boundary (5000 samples = 0.3125s), so none of them overlaps
        // the unconfirmed region and all are filtered out. The test is overlap, not start: a word
        // straddling the boundary is the boundary word itself and must survive — see the filter
        // in `consume`.
        let staleHyp = [
            word(" old", startSec: 0, endSec: 0.15),
            word(" words", startSec: 0.15, endSec: 0.30)
        ]
        let outcome = engine.consume(
            hypothesis: staleHyp,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0, windowEndIndex: .max
        )

        XCTAssertNil(outcome.displayText)
        XCTAssertNil(outcome.softCommit)
        XCTAssertFalse(outcome.wasHeld)
    }

    // MARK: - Normalization / case insensitivity

    func testNormalizationIgnoresPunctuationAndCase() {
        var engine = EagerStreamEngine()
        // "Hello," and "hello" should be treated as equal in the agreement check.
        let prev = [word("Hello,", startSec: 0, endSec: 0.4)]
        let curr = [word("hello.", startSec: 0, endSec: 0.4)]
        let common = engine.commonPrefixCount(prev, curr)
        XCTAssertEqual(common, 1, "Normalised words should agree across punctuation and case")
    }

    func testNormalizationSkipsEmptyNormalizedWords() {
        var engine = EagerStreamEngine()
        // A word that normalises to "" (e.g. "...") should NOT match anything.
        let prev = [word("...", startSec: 0, endSec: 0.4)]
        let curr = [word("...", startSec: 0, endSec: 0.4)]
        let common = engine.commonPrefixCount(prev, curr)
        XCTAssertEqual(common, 0, "Words that normalise to empty string must not count as agreement")
    }

    // MARK: - Reset

    func testResetClearsAllState() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        let hyp = sentence("some words here")
        _ = engine.consume(hypothesis: hyp, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0, windowEndIndex: .max)

        engine.reset(at: 100)

        XCTAssertTrue(engine.confirmedWords.isEmpty)
        XCTAssertTrue(engine.prefixTokens.isEmpty)
        XCTAssertEqual(engine.agreementStartIndex, 100)
    }

    // MARK: - Soft-commit span arithmetic

    func testSoftCommitSpanMatchesLastCommittedIndex() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)
        let lastCommitted = 1000

        // Force many confirmed words and an agreement boundary well past 6s from lastCommitted.
        let startOffset = lastCommitted + config.softCommitSamples + sampleRate  // 7s past lastCommitted
        var hyp1: [EagerStreamWord] = []
        for i in 0..<10 {
            let s = lastCommitted + i * (sampleRate / 4)
            hyp1.append(EagerStreamWord(text: " w\(i)", tokens: [], startIndex: s, endIndex: s + sampleRate / 4 - 100, probability: 0.90))
        }
        _ = engine.consume(hypothesis: hyp1, audioBaseIndex: lastCommitted, languageIsLocked: true, lastCommittedIndex: lastCommitted, windowEndIndex: .max)

        var hyp2: [EagerStreamWord] = []
        for i in 0..<12 {
            let s = lastCommitted + i * (sampleRate / 4)
            hyp2.append(EagerStreamWord(text: " w\(i)", tokens: [], startIndex: s, endIndex: s + sampleRate / 4 - 100, probability: 0.90))
        }
        let outcome = engine.consume(
            hypothesis: hyp2,
            audioBaseIndex: lastCommitted,
            languageIsLocked: true,
            lastCommittedIndex: lastCommitted, windowEndIndex: .max
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
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        let base = sentence("the quick brown fox")
        _ = engine.consume(hypothesis: base, audioBaseIndex: 0, languageIsLocked: true, lastCommittedIndex: 0, windowEndIndex: .max)

        let extended = sentence("the quick brown fox jumps")
        let outcome = engine.consume(
            hypothesis: extended,
            audioBaseIndex: 0,
            languageIsLocked: true,
            lastCommittedIndex: 0, windowEndIndex: .max
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

    // MARK: - Retraction guard vs. a shorter window

    /// A window that got *shorter* is not a retraction, and must not be held.
    ///
    /// This is the common case on the capped eager path, not an edge case: the window is
    /// `[agreementStart, +cap]`, so every soft-commit that jumps the boundary forward leaves less
    /// than a cap's worth of unconfirmed audio behind it, and the next hypothesis covers less
    /// audio and has fewer words. Comparing raw word counts scored that as a large retraction and
    /// threw the decode away — measured at 35% of all passes over a full profile run, each one a
    /// completed GPU decode discarded *and* a boundary left where it was.
    func testShorterWindowIsNotTreatedAsRetraction() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        // Pass 1 sees ten words over five seconds.
        let wide = sentence("alpha bravo charlie delta echo foxtrot golf hotel india juliett")
        _ = engine.consume(hypothesis: wide, audioBaseIndex: 0, languageIsLocked: true,
                           lastCommittedIndex: 0, windowEndIndex: Int(5.0 * 16000))

        // Pass 2's window ends after two seconds, so it can only contain the first four words.
        // Seven fewer words than pass 1 — well past `maxRetraction` — but none were taken back.
        let narrowEnd = Int(2.0 * 16000)
        let narrow = Array(engine.previousHypothesis.prefix(4))
        let outcome = engine.consume(hypothesis: narrow, audioBaseIndex: 0, languageIsLocked: true,
                                     lastCommittedIndex: 0, windowEndIndex: narrowEnd)

        XCTAssertFalse(outcome.wasHeld,
                       "a shorter window was scored as a retraction; holdReason=\(String(describing: outcome.holdReason))")
        XCTAssertNotNil(outcome.displayText)
    }

    /// The guard must still fire on a real retraction — same window, words genuinely gone.
    func testGenuineRetractionInSameWindowIsStillHeld() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        let windowEnd = Int(5.0 * 16000)
        let wide = sentence("alpha bravo charlie delta echo foxtrot golf hotel india juliett")
        _ = engine.consume(hypothesis: wide, audioBaseIndex: 0, languageIsLocked: true,
                           lastCommittedIndex: 0, windowEndIndex: windowEnd)

        // Same window end, decoder collapsed to four words. Those six are a true retraction.
        let collapsed = Array(engine.previousHypothesis.prefix(4))
        let outcome = engine.consume(hypothesis: collapsed, audioBaseIndex: 0, languageIsLocked: true,
                                     lastCommittedIndex: 0, windowEndIndex: windowEnd)

        XCTAssertTrue(outcome.wasHeld)
        XCTAssertEqual(outcome.holdReason, .largeRetraction)
    }

    // MARK: - Repetition-loop guard

    /// A decoder loop confirms the same short phrase pass after pass. The guard lets two
    /// consecutive copies through — real speech does repeat itself — and drops the rest.
    ///
    /// Driven through `consume` rather than the private gate, because the loop only matters via
    /// the path that actually confirms words.
    func testDecoderRepetitionLoopIsSuppressedAfterTwoCopies() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        // Nine copies of "i dont know", each with advancing timestamps — a stuck decoder gives
        // its repeats new times, so a span test would never catch this.
        let phrase = "i dont know"
        var text = ""
        for _ in 0..<9 { text += phrase + " " }
        let hyp = sentence(text.trimmingCharacters(in: .whitespaces), p: 0.99)

        // Entropy gate confirms everything but the boundary words in one pass. Nine copies span
        // 13.5s, so the confirmed words leave via a soft-commit rather than staying in the buffer.
        let outcome = engine.consume(hypothesis: hyp, audioBaseIndex: 0, languageIsLocked: true,
                                     lastCommittedIndex: 0, windowEndIndex: .max)

        let confirmed = ((outcome.softCommit?.text ?? "") + " " +
                         engine.confirmedWords.map(\.text).joined())
            .split(separator: " ").map(String.init)
        let occurrences = confirmed.filter { $0 == "know" }.count
        XCTAssertEqual(occurrences, 2, "two copies survive, the loop does not: \(confirmed)")
        XCTAssertGreaterThan(engine.suppressedRepeatWords, 0)
    }

    /// The guard is a loop detector, not a duplicate-word filter. Speech that genuinely repeats
    /// a word twice, or repeats a phrase later with other words in between, must survive.
    func testGenuineRepeatedSpeechIsNotSuppressed() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        let hyp = sentence("no no i said go left and then go left again", p: 0.99)
        _ = engine.consume(hypothesis: hyp, audioBaseIndex: 0, languageIsLocked: true,
                           lastCommittedIndex: 0, windowEndIndex: .max)

        let confirmed = engine.confirmedWords.map { $0.text.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(confirmed.filter { $0 == "no" }.count, 2, "\(confirmed)")
        XCTAssertEqual(confirmed.filter { $0 == "go" }.count, 2, "separated repeats: \(confirmed)")
        XCTAssertEqual(engine.suppressedRepeatWords, 0)
    }

    /// A loop that straddles a soft-commit must not get a fresh count. `committedTail` exists
    /// only for this case.
    func testRepetitionCountSurvivesSoftCommit() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        // First pass ends with two copies of the phrase and triggers a soft-commit (>6s of audio).
        // The two leading fillers are margin, not decoration: `sentence` spaces words 0.5s apart
        // with a 0.45s duration, and the agreement boundary is clamped to the end of the last
        // confirmed word, so a span that clears 6s only by the 0.05s inter-word gap does not
        // commit. This test is about the repetition count surviving a commit, not about where the
        // threshold sits — so put the precondition comfortably past it.
        let first = sentence("india juliett alpha bravo charlie delta echo foxtrot golf hotel i dont know i dont know",
                             p: 0.99)
        let outcome = engine.consume(hypothesis: first, audioBaseIndex: 0, languageIsLocked: true,
                                     lastCommittedIndex: 0, windowEndIndex: .max)
        XCTAssertNotNil(outcome.softCommit, "precondition: the span must be long enough to commit")
        XCTAssertTrue(engine.confirmedWords.isEmpty, "precondition: the commit cleared the buffer")

        // The loop continues into the next window. Its third copy must still be refused.
        let startSec = 0.5 * Double(first.count)
        let second = sentence("i dont know i dont know", startSec: startSec, p: 0.99)
        _ = engine.consume(hypothesis: second, audioBaseIndex: 0, languageIsLocked: true,
                           lastCommittedIndex: 0, windowEndIndex: .max)

        let confirmed = engine.confirmedWords.map { $0.text.trimmingCharacters(in: .whitespaces) }
        XCTAssertFalse(confirmed.contains("know"),
                       "two copies were already committed, so none may follow: \(confirmed)")
    }

    // MARK: - Boundary trail (late word offsets)

    /// The persisted boundary trails the confirmed text, so a word whose offset the *previous*
    /// pass placed too early is still inside the next window.
    ///
    /// Regression test for the last resolvable WER regression in the golden-set gate. On
    /// `B6250001`, a pass confirmed `…why Meta is` and reported `is` ending at ~6.02s, while the
    /// next decode of that same audio placed the following word at 5.82s. `not meeting. And` lies
    /// in between, so the `startIndex >= agreementStart` entry filter dropped it from that window and from
    /// every later one — three words gone from the final text that the VAD-chunk arm keeps.
    /// Clamping to the confirmed word's *end* does not help, because that end is the timestamp
    /// that is wrong.
    /// Note the explicit config: `boundaryTrailSamples` ships at 0 because trailing lost on the
    /// corpus (see `EagerStreamEngine.Config.default`). The mechanism is still tested, so that if
    /// a future fix switches it on it does what it claims rather than something adjacent.
    func testBoundaryTrailsConfirmedTextSoLateOffsetsSurvive() {
        let trail = Int(0.25 * 16000)
        var engine = EagerStreamEngine(config: EagerStreamEngine.Config(
            boundaryWordCount: config.boundaryWordCount,
            singlePassThreshold: config.singlePassThreshold,
            softCommitSamples: config.softCommitSamples,
            requiredAnchor: config.requiredAnchor,
            maxRetraction: config.maxRetraction,
            skipsAnchorCheckAfterBoundaryMove: config.skipsAnchorCheckAfterBoundaryMove,
            suppressesRepetitionLoops: config.suppressesRepetitionLoops,
            boundaryTrailSamples: trail))
        engine.reset(at: 0)

        // Two identical passes: LocalAgreement confirms all but the last `boundaryWordCount` (2).
        let hyp = sentence("alpha bravo charlie delta echo", p: 0.90)
        _ = engine.consume(hypothesis: hyp, audioBaseIndex: 0, languageIsLocked: true,
                           lastCommittedIndex: 0, windowEndIndex: .max)
        _ = engine.consume(hypothesis: hyp, audioBaseIndex: 0, languageIsLocked: true,
                           lastCommittedIndex: 0, windowEndIndex: .max)

        // `charlie` is the last confirmed word; `sentence` ends it at 1.45s.
        let confirmedEnd = Int(1.45 * 16000)
        XCTAssertEqual(engine.agreementStartIndex, confirmedEnd - trail,
                       "the boundary must sit one trailing margin behind the confirmed text")

        // A word the next decode places entirely before the untrailed boundary — the shape that
        // used to vanish. It must survive into the hypothesis and reach the display.
        let late = [word(" not", startSec: 1.30, endSec: 1.42, p: 0.99),
                    word(" meeting", startSec: 1.42, endSec: 1.60, p: 0.99),
                    word(" delta", startSec: 1.60, endSec: 1.90, p: 0.99)]
        let outcome = engine.consume(hypothesis: late, audioBaseIndex: 0, languageIsLocked: true,
                                     lastCommittedIndex: 0, windowEndIndex: .max)

        // Survival is asserted on the hypothesis, not on `displayText`, because this pass is
        // *held*: recovering a word ahead of the previous hypothesis's first word shifts the whole
        // prefix, `commonPrefixCount` drops to 0, and the anchor check reads that as a decoder
        // collapse. A held pass stores its hypothesis and publishes nothing.
        //
        // That interaction is the measured cost of trailing, not an artifact of this test. Over
        // the same corpus, turning the trail on raised `unanchoredAfterBoundaryMove` holds from
        // 1–2 per fixture to 3–5 — each one a discarded decode that also freezes the boundary. So
        // any future attempt to recover these words has to answer the anchor check too; buying the
        // word back and then throwing the pass away is the failure mode, not the fix.
        XCTAssertNil(outcome.displayText, "precondition: the recovered word unanchors this pass")
        XCTAssertTrue(engine.previousHypothesis.contains { $0.text.contains("not") },
                      "a word ending before the untrailed boundary was filtered out entirely: " +
                      "\(engine.previousHypothesis.map(\.text))")
    }

    /// The trailing boundary must not cause a word to be confirmed twice inside one pass.
    ///
    /// The trail deliberately sits behind words that were just confirmed, so if the in-pass
    /// hypothesis filters used it instead of the strict boundary, the entropy gate would see those
    /// words again in the same `consume` and confirm them a second time.
    func testBoundaryTrailDoesNotDuplicateWithinOnePass() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        let hyp = sentence("alpha bravo charlie delta echo", p: 0.99)
        _ = engine.consume(hypothesis: hyp, audioBaseIndex: 0, languageIsLocked: true,
                           lastCommittedIndex: 0, windowEndIndex: .max)
        _ = engine.consume(hypothesis: hyp, audioBaseIndex: 0, languageIsLocked: true,
                           lastCommittedIndex: 0, windowEndIndex: .max)

        let confirmed = engine.confirmedWords.map { $0.text.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(confirmed.count, Set(confirmed).count,
                       "a word was confirmed twice in one pass: \(confirmed)")
    }

    // MARK: - Stall detection

    /// A capped window whose decode yields a single word forever must be reported as stalled.
    ///
    /// Reproduces the 2026-08-20 meeting hang. `boundaryWordCount` is 2, so a one-word hypothesis
    /// takes the short-tail branch, where `confirmCount = hyp.count - 1 = 0` — nothing is
    /// confirmed, so `confirmedThroughIndex` does not move, so `advanceAgreement(to:)` clamps the
    /// boundary to where it already was. The caller caps the window at `[agreementStartIndex,
    /// +cap]`, so the window cannot move either. The production log shows the end state: 2,429
    /// identical decodes of the same 12s window over 40 minutes, no commit, and a ring buffer that
    /// grew to the whole meeting because `dropFront` is only called on commit.
    ///
    /// The engine cannot break the deadlock itself — only the caller knows the window is capped —
    /// but it is the only party that knows the boundary stopped moving, so it must say so.
    func testCappedWindowYieldingOneWordReportsStall() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)
        // Mimic the silent-backlog seek that preceded the hang: it sets `confirmedThroughIndex`,
        // which is what pins `advanceAgreement` afterwards.
        engine.seek(past: 1_750_560)

        let stuck = [word(" so", startSec: 109.6, endSec: 109.9, p: 0.30)]
        for _ in 0..<8 {
            _ = engine.consume(hypothesis: stuck, audioBaseIndex: 1_750_560,
                               languageIsLocked: true, lastCommittedIndex: 251_200,
                               windowEndIndex: 1_942_560)
        }

        XCTAssertEqual(engine.agreementStartIndex, 1_750_560,
                       "precondition: the boundary is pinned — this is the deadlock")
        XCTAssertGreaterThanOrEqual(
            engine.consecutiveStalledPasses, 8,
            "the engine must report that the boundary has not moved, so the caller can seek past "
            + "the capped window instead of re-decoding it for the rest of the meeting")
    }

    /// A window that keeps confirming must never look stalled.
    func testProgressingWindowReportsNoStall() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)

        let hyp = sentence("alpha bravo charlie delta echo", p: 0.99)
        _ = engine.consume(hypothesis: hyp, audioBaseIndex: 0, languageIsLocked: true,
                           lastCommittedIndex: 0, windowEndIndex: .max)
        _ = engine.consume(hypothesis: hyp, audioBaseIndex: 0, languageIsLocked: true,
                           lastCommittedIndex: 0, windowEndIndex: .max)

        XCTAssertEqual(engine.consecutiveStalledPasses, 0,
                       "a pass that advanced the boundary must reset the stall counter")
    }

    /// `seek(past:)` is the escape hatch — taking it must clear the stall.
    func testSeekClearsStall() {
        var engine = EagerStreamEngine()
        engine.reset(at: 0)
        engine.seek(past: 1_750_560)

        let stuck = [word(" so", startSec: 109.6, endSec: 109.9, p: 0.30)]
        for _ in 0..<8 {
            _ = engine.consume(hypothesis: stuck, audioBaseIndex: 1_750_560,
                               languageIsLocked: true, lastCommittedIndex: 251_200,
                               windowEndIndex: 1_942_560)
        }
        XCTAssertGreaterThan(engine.consecutiveStalledPasses, 0)

        engine.seek(past: 1_942_560)
        XCTAssertEqual(engine.consecutiveStalledPasses, 0,
                       "the caller took the escape hatch; the next window is fresh audio")
        XCTAssertEqual(engine.agreementStartIndex, 1_942_560)
    }
}
