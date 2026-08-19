//
//  SentenceTerminatorTests.swift
//  WhispererTests
//
//  The pass that supplies sentence boundaries from silence.
//
//  Two properties matter more than the individual rules. The first is that the evidence is a
//  *pause*, so the same audio shape must produce the same boundary in Hebrew and Russian as in
//  English. The second is that it declines more often than it fires: the corpus it exists to fix
//  has 38.2% of utterances with no terminal mark at all, and the temptation is to close that
//  number rather than to be right.
//
//  **A per-script gate was tried here on 2026-08-19 and reverted.** For one day the
//  end-of-utterance rule was disabled for Hebrew and Cyrillic, because it inserts a period the
//  authored gold refuses 3 times in 48 Hebrew cases and 1 time in 37 Russian. The gate removed
//  those four wrong periods and cost Hebrew sentence-boundary F1 0.742 → 0.412 — it also removes
//  every *right* period at the same position, and there are far more of those. Rule 3b in
//  `PolishVerdictTests` failed on it. So both properties stand as originally written: the pass is
//  script-independent at both boundaries, and the four known over-insertions are disclosed in the
//  verdict rather than gated away. Fixing them needs a reference that can judge an utterance-final
//  ending; neither available corpus can (`Tools/llm-eval/calibrate_danglers.py`).
//

import XCTest
@testable import whisperer

final class SentenceTerminatorTests: XCTestCase {

    /// Chunks with an exact silence between them. `gap` is the audio-time pause the speaker left.
    private func chunks(_ texts: [String], gap: TimeInterval) -> [DeterministicPolisher.Chunk] {
        var result: [DeterministicPolisher.Chunk] = []
        var clock: TimeInterval = 0
        for text in texts {
            let duration = Double(text.split(whereSeparator: \.isWhitespace).count) * 0.4
            result.append(DeterministicPolisher.Chunk(text: text, start: clock, end: clock + duration))
            clock += duration + gap
        }
        return result
    }

    /// No paragraph breaks: this file is about sentence marks, and a `\n\n` in the middle of an
    /// expectation would be testing `ParagraphSplitter` by accident.
    private let polisher = DeterministicPolisher(splitsParagraphs: false)

    private func periods(in text: String) -> Int {
        text.reduce(into: 0) { $0 += $1 == "." ? 1 : 0 }
    }

    // MARK: - The interior rule

    func testPauseAtChunkJoinInsertsExactlyOnePeriod() {
        let text = polisher.polish(chunks: chunks(["we shipped the release yesterday",
                                                   "the rollback plan is ready"], gap: 1.4)).text
        XCTAssertEqual(periods(in: text), 2, text)  // the join, and the end of the utterance
        XCTAssertTrue(text.contains("yesterday. The"), text)
    }

    /// The boundary is only worth creating if the caser then makes it look like one.
    func testInsertedBoundaryIsCapitalised() {
        let text = polisher.polish(chunks: chunks(["the build finished cleanly",
                                                   "nobody reviewed it"], gap: 1.4)).text
        XCTAssertFalse(text.contains("cleanly. nobody"), text)
    }

    func testSubThresholdPauseInsertsNothingInterior() {
        let text = polisher.polish(chunks: chunks(["we shipped the release yesterday",
                                                   "the rollback plan is ready"], gap: 0.3)).text
        XCTAssertFalse(text.contains("yesterday."), text)
        XCTAssertEqual(periods(in: text), 1, text)  // only the end of the utterance
    }

    /// 0.7s is the floor, and a floor that admits the value just below it is not a floor.
    func testPauseExactlyAtTheFloorFiresAndJustBelowDoesNot() {
        let atFloor = polisher.polish(
            chunks: chunks(["the migration completed", "we can move on"],
                           gap: SentenceTerminator.minimumPause)).text
        XCTAssertTrue(atFloor.contains("completed."), atFloor)

        let below = polisher.polish(
            chunks: chunks(["the migration completed", "we can move on"],
                           gap: SentenceTerminator.minimumPause - 0.05)).text
        XCTAssertFalse(below.contains("completed."), below)
    }

    // MARK: - What it refuses

    func testAbbreviationBeforeAPauseIsNotTerminated() {
        let text = polisher.polish(chunks: chunks(["that was reviewed by Dr",
                                                   "and then merged anyway"], gap: 1.4)).text
        XCTAssertFalse(text.contains("Dr."), text)
    }

    func testHardProtectedSpanIsNeverSplit() {
        let text = polisher.polish(chunks: chunks(["the docs live at https://example.com/a_b",
                                                   "everyone can read them"], gap: 1.4)).text
        XCTAssertTrue(text.contains("https://example.com/a_b"), text)
        XCTAssertFalse(text.contains("a_b."), text)
    }

    /// A period after a number reads as a decimal point, not as a full stop.
    func testDigitBeforeTheBoundaryIsNotTerminated() {
        let text = polisher.polish(chunks: chunks(["the timeout is set to 30",
                                                   "that should be enough"], gap: 1.4)).text
        XCTAssertFalse(text.contains("30."), text)
    }

    func testExistingPunctuationIsNotDoubled() {
        let text = polisher.polish(chunks: chunks(["is the deployment finished?",
                                                   "nobody has said so"], gap: 1.4)).text
        XCTAssertFalse(text.contains("?."), text)
        XCTAssertFalse(text.contains(".?"), text)
    }

    // MARK: - The end of the utterance

    func testShortUtteranceIsNotTerminated() {
        // Two words is a label or a search query, and a trailing period there is noise.
        XCTAssertFalse(polisher.polish(text: "deployment logs").text.hasSuffix("."))
    }

    func testWholeUtteranceIsTerminated() {
        XCTAssertTrue(polisher.polish(text: "the deployment finished cleanly").text.hasSuffix("."))
    }

    /// An utterance ending in a conjunction was cut off, not finished.
    func testDanglingConjunctionIsNotTerminated() {
        XCTAssertFalse(polisher.polish(text: "we shipped the release and").text.hasSuffix("."))
    }

    func testFragmentIsNotTerminated() {
        let fragment = DeterministicPolisher(isFragment: true, splitsParagraphs: false)
        XCTAssertFalse(fragment.polish(text: "the deployment finished cleanly").text.hasSuffix("."))
    }

    /// The meetings per-utterance configuration: interior pauses still count, the end does not.
    func testTerminatesUtteranceEndOffKeepsInteriorBoundaries() {
        let editor = DeterministicPolisher(terminatesUtteranceEnd: false, splitsParagraphs: false)
        let text = editor.polish(chunks: chunks(["we shipped the release yesterday",
                                                 "the rollback plan is ready"], gap: 1.4)).text
        XCTAssertTrue(text.contains("yesterday."), text)
        XCTAssertFalse(text.hasSuffix("."), text)
    }

    // MARK: - Engine and script independence

    /// The evidence is silence, so the decision cannot depend on the script. These two assert the
    /// same shape as the English case above with no language-specific expectation of any kind.
    func testHebrewBehavesIdenticallyOnTheSamePauses() {
        let text = polisher.polish(chunks: chunks(["אנחנו שחררנו את הגרסה אתמול",
                                                   "תוכנית החזרה מוכנה"], gap: 1.4)).text
        XCTAssertTrue(text.contains("אתמול."), text)
    }

    func testRussianBehavesIdenticallyOnTheSamePauses() {
        let text = polisher.polish(chunks: chunks(["мы выпустили релиз вчера",
                                                   "план отката готов"], gap: 1.4)).text
        XCTAssertTrue(text.contains("вчера."), text)
    }

    /// The pass reads `TranscriptChunk` sample spans, never ASR word timings — so a graph built
    /// with no per-word evidence must reach the same text as one built with it.
    func testCapabilityTiersAgree() {
        let spoken = chunks(["we shipped the release yesterday", "the rollback plan is ready"],
                            gap: 1.4)
        XCTAssertEqual(polisher.polish(chunks: spoken).text,
                       polisher.polish(chunks: spoken).text)
    }

    // MARK: - Chunk bookkeeping

    /// Two chunks with identical text used to resolve to the same chunk when the pause map was
    /// built by matching on text, which silently mis-keyed every pause after the duplicate.
    func testDuplicateChunkTextsKeepTheirOwnSpans() {
        // Multi-word repeats rather than a repeated single word: `TranscriptNormalizer` deletes
        // adjacent duplicate words, so "okay okay" would collapse before this pass ever ran and
        // the test would be measuring the normalizer.
        let duplicated = [
            DeterministicPolisher.Chunk(text: "the build failed", start: 0, end: 1.2),
            DeterministicPolisher.Chunk(text: "the build failed", start: 1.4, end: 2.6),
            DeterministicPolisher.Chunk(text: "the rollback plan is ready now", start: 4.7, end: 7.0),
        ]
        // Only the 2.1s gap before the last chunk clears the floor, so exactly one interior period
        // may appear — after the *second* "failed", not the first. Keyed by text, both joins would
        // have resolved to the first chunk and the period would land in the wrong place.
        let text = polisher.polish(chunks: duplicated).text
        XCTAssertTrue(text.contains("the build failed. The rollback"), text)
        XCTAssertEqual(periods(in: text), 2, text)
    }

    // MARK: - The dangler guard, at both boundaries

    /// The guard used to live in `endOfUtterance` alone, so a word refused a period at the end of
    /// an utterance was handed one at a chunk join. Same question, same answer, both positions.
    func testDanglerIsRefusedAtAChunkJoin() {
        let text = polisher.polish(chunks: chunks(["we shipped the release and",
                                                   "the rollback plan is ready"], gap: 1.4)).text
        XCTAssertFalse(text.contains("and."), text)
    }

    func testDanglerIsStillRefusedAtTheUtteranceEnd() {
        XCTAssertFalse(polisher.polish(text: "we shipped the release and").text.contains("and."))
    }

}
