//
//  TranscriptRepetitionTests.swift
//  WhispererTests
//
//  Unit tests for TranscriptRepetition — the text-level decoder-loop detector.
//  No model, no audio, no async — all tests run in milliseconds.
//

import XCTest
@testable import whisperer

final class TranscriptRepetitionTests: XCTestCase {

    // MARK: - Helpers

    private func containsLoop(_ text: String) -> Bool {
        TranscriptRepetition.containsLoop(words: text.lowercased().split(separator: " "))
    }

    /// The exact string that reached the clipboard on 2026-08-20 at 15:44.
    ///
    /// From `whisperer-2026-08-20.log`, the `+13.496` eager pass:
    /// `display: this language accordingly also in live the right of the right of ...`
    private static let realSpiral =
        "this language accordingly also in live "
        + String(repeating: "the right of ", count: 34)

    // MARK: - The regression

    func testRealWorldSpiralIsDetected() {
        XCTAssertTrue(containsLoop(Self.realSpiral))
    }

    /// The specific reason the old check missed it: the loop did not start at word 0, and the
    /// old code only ever tested phrases built from `words.prefix(phraseLen)`.
    func testLoopIsDetectedRegardlessOfPosition() {
        let spiral = String(repeating: "the right of ", count: 10)
        let carrier = "so what i wanted to say about the transcript"

        XCTAssertTrue(containsLoop(spiral + carrier), "loop at the start")
        XCTAssertTrue(containsLoop(carrier + " " + spiral + carrier), "loop in the middle")
        XCTAssertTrue(containsLoop(carrier + " " + spiral), "loop at the end")
    }

    // MARK: - Real speech must survive

    /// Actual transcripts from the same recording session as the spiral. These are the strings
    /// the detector sees on every normal pass; a false positive here silently deletes real speech.
    func testRealTranscriptsFromTheSameSessionAreClean() {
        let transcripts = [
            "want you to debug something For me, Sometimes in meeting when we speak,",
            "the stand like which language the whole meeting is reliably and not and fix transcript based on",
            "language that used for this meeting and then we can use",
            "this language accordingly also in live",
            "like segments will have the chance to improve it and my expectation that in final pass",
        ]
        for transcript in transcripts {
            XCTAssertFalse(containsLoop(transcript), "false positive on: \(transcript)")
        }
    }

    /// People repeat themselves. The detector must be looser than a stutter.
    func testGenuineRepetitionInSpeechIsNotALoop() {
        XCTAssertFalse(containsLoop("no no i really don't think so"))
        XCTAssertFalse(containsLoop("thank you very very much for all of this"))
        XCTAssertFalse(containsLoop("i mean i mean it was fine in the end"))
    }

    /// A phrase that recurs later in a long dictation is not a stuck decoder — only back-to-back
    /// copies are. This is why the implementation counts consecutive runs, not total occurrences.
    func testNonAdjacentRecurrenceIsNotALoop() {
        let text = "we should ship the fix today and then once we ship the fix today "
            + "we can look at the language routing and after that we ship the fix today"
        XCTAssertFalse(containsLoop(text))
    }

    // MARK: - Threshold

    func testTwoConsecutiveCopiesPassAndThreeAreRejected() {
        let phrase = "the right of "
        XCTAssertFalse(containsLoop(String(repeating: phrase, count: 2)), "2 copies is speech")
        XCTAssertTrue(containsLoop(String(repeating: phrase, count: 3)), "3 copies is a loop")
    }

    /// Eight words of a three-word phrase is 2⅔ copies. The run arithmetic must not round it up.
    func testPartialThirdCopyDoesNotFire() {
        XCTAssertFalse(containsLoop("the right of the right of the right"))
        XCTAssertTrue(containsLoop("the right of the right of the right of"))
    }

    func testLongerPhrasesAreDetected() {
        // Six words is the longest phrase length considered.
        let phrase = "and then we can look at "
        XCTAssertTrue(containsLoop(String(repeating: phrase, count: 3)))
    }

    /// Seven-word phrases sit above `maximumPhraseLength`. Documented as a known bound rather
    /// than a bug: loops are short by nature, and every extra length costs another pass.
    func testPhrasesLongerThanTheCeilingAreNotDetected() {
        let phrase = "and then we can look at the "
        XCTAssertFalse(containsLoop(String(repeating: phrase, count: 3)))
    }

    // MARK: - Degenerate input

    func testShortAndEmptyInputIsClean() {
        XCTAssertFalse(containsLoop(""))
        XCTAssertFalse(containsLoop("hello"))
        XCTAssertFalse(containsLoop("the right of the right"))
    }

    // MARK: - Words-per-second gate

    /// The rate that let the spiral through the stop-time reuse path: the pass recorded 108 words
    /// spanning 6.1s. Its `avgLogProb` was -0.17, comfortably inside the -0.65 confidence gate,
    /// which is why rate rather than confidence is the test that catches it.
    func testSpiralRateExceedsThePlausibilityCeiling() {
        let wordsPerSecond = 108.0 / 6.1
        XCTAssertGreaterThan(wordsPerSecond, StreamingTranscriber.maximumPlausibleWordsPerSecond)
    }

    /// Fast human speech must clear the ceiling with room to spare.
    func testFastHumanSpeechRateIsAccepted() {
        let fastSpeaker = 4.0
        XCTAssertLessThanOrEqual(fastSpeaker, StreamingTranscriber.maximumPlausibleWordsPerSecond)
        // A short burst of a few words in under a second is common at a pass boundary.
        XCTAssertLessThanOrEqual(5.0 / 0.7, StreamingTranscriber.maximumPlausibleWordsPerSecond)
    }

    // MARK: - Character-level spirals

    /// The three payloads are verbatim from `whisperer-2026-09-15.log`: the displayed eager text,
    /// the poisoned initial prompt fed into the next refine window, and a two-character cycle
    /// standing in for the general case the single-character one is an instance of.

    func testRealHebrewSpiralCollapsesAndKeepsThePrecedingWords() {
        let payload = "להיות בעיני פוזיטי א" + String(repeating: "ה", count: 90)
        XCTAssertTrue(TranscriptRepetition.containsCharacterLoop(in: payload))
        XCTAssertEqual(TranscriptRepetition.collapsingDegenerateRuns(in: payload),
                       "להיות בעיני פוזיטי אה")
    }

    func testPoisonedInitialPromptCollapsesToOneCharacter() {
        let prompt = String(repeating: "ה", count: 100)
        XCTAssertTrue(TranscriptRepetition.containsCharacterLoop(in: prompt))
        XCTAssertEqual(TranscriptRepetition.collapsingDegenerateRuns(in: prompt), "ה")
    }

    func testTwoCharacterCycleCollapsesToItsUnit() {
        let cycle = String(repeating: "אה", count: 20)
        XCTAssertTrue(TranscriptRepetition.containsCharacterLoop(in: cycle))
        XCTAssertEqual(TranscriptRepetition.collapsingDegenerateRuns(in: cycle), "אה")
    }

    /// Everything a real transcript, a real log line or this app's own prompts contain that
    /// *looks* like a run. Each must come back byte-identical — a false positive here deletes
    /// speech, which is worse than the bug this guards against.
    func testBenignRepetitionIsReturnedUnchanged() {
        let benign = [
            "aaaah",
            "hmmmm",
            "ווווואו",
            "שששש",
            "נכון נכון נכון",
            String(repeating: "…", count: 20),
            String(repeating: "-", count: 20),
            String(repeating: "!", count: 20),
            "0000000",
            "אני חושב שזה רעיון טוב אבל צריך לבדוק את זה קודם",
            "I think we should ship this on Monday and revisit the numbers next week",
        ]
        for text in benign {
            XCTAssertFalse(TranscriptRepetition.containsCharacterLoop(in: text),
                           "false positive on \"\(text.prefix(30))\"")
            XCTAssertEqual(TranscriptRepetition.collapsingDegenerateRuns(in: text), text)
        }
    }

    /// The invariant the whole fix rests on: whatever goes in, what comes out has no spiral in
    /// it, and running the collapse again changes nothing. Without this a caller could sanitize
    /// and still hand a wall downstream.
    func testCollapseIsIdempotentAndLeavesNoSpiral() {
        let inputs = [
            "להיות בעיני פוזיטי א" + String(repeating: "ה", count: 90),
            String(repeating: "ה", count: 100),
            String(repeating: "אה", count: 20),
            // Two walls with prose between them, and a cycle that collapses into its neighbour.
            String(repeating: "x", count: 40) + " ok " + String(repeating: "yz", count: 30),
            String(repeating: "ab", count: 12) + String(repeating: "ba", count: 12),
        ]
        for input in inputs {
            let once = TranscriptRepetition.collapsingDegenerateRuns(in: input)
            XCTAssertFalse(TranscriptRepetition.containsCharacterLoop(in: once),
                           "spiral survived the collapse of \"\(input.prefix(30))\"")
            XCTAssertEqual(TranscriptRepetition.collapsingDegenerateRuns(in: once), once)
        }
    }
}
