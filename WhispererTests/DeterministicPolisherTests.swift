//
//  DeterministicPolisherTests.swift
//  WhispererTests
//
//  Two things are under test here, and the second one is the plan's Verification item 3:
//
//  1. The M2 pipeline composes — protect, alias, normalize, format, all gated — and its
//     `needsGenerativePass` predicate is the M2e short-circuit.
//  2. **Engine parity.** The same corpus polished twice, once through `from(words:)` with full
//     whisper.cpp evidence and once through `from(text:)` with none, must produce byte-identical
//     output. Any divergence means evidence leaked into a decision Nemotron cannot supply, and
//     the engine-independence claim the whole plan rests on would be false.
//

import XCTest
@testable import whisperer

final class DeterministicPolisherTests: XCTestCase {

    private let polisher = DeterministicPolisher()

    // MARK: - Pipeline

    func testWorkedExampleEndToEnd() {
        let input = "okay um first send the deployment to chat gpt second update postgress "
                  + "and then כאילו restart the service сегодня"
        let out = polisher.polish(text: input).text

        XCTAssertTrue(out.contains("ChatGPT"), out)
        XCTAssertTrue(out.contains("PostgreSQL"), out)
        XCTAssertFalse(out.contains("um "), out)
        XCTAssertFalse(out.contains("כאילו"), out)
        // The plan's correction of its own source document: no translation, in either direction.
        XCTAssertTrue(out.contains("сегодня"), out)
        XCTAssertFalse(out.contains("היום"), out)
    }

    func testProtectedSpansSurviveTheWholePipeline() {
        let input = "run docker run --rm -it and check https://example.com/a_b then call loadModel"
        XCTAssertEqual(polisher.polish(text: input).text, input)
    }

    /// The gap the shipped `protectTokens` leaves: all 13 of its patterns are ASCII classes, so a
    /// Latin identifier inside a Hebrew sentence is unprotected today.
    func testLatinIdentifierInsideHebrewIsProtected() {
        let input = "צריך להריץ את loadModel על ה-server"
        XCTAssertEqual(polisher.polish(text: input).text, input)
    }

    func testEditsAreReported() {
        let result = polisher.polish(text: "um um hello  world")
        XCTAssertFalse(result.appliedEdits.isEmpty)
        XCTAssertEqual(result.text, "hello world")
    }

    /// The bug the gate-simulated normalizer scratch exists to prevent: if the duplicate-word
    /// deletion is refused as a negation, the whitespace collapse that would have closed the gap
    /// must be refused with it, or the two words fuse.
    func testRefusedDeletionDoesNotFuseItsNeighbours() {
        let result = polisher.polish(text: "не не надо это делать")
        XCTAssertFalse(result.text.contains("нене"), result.text)
    }

    // MARK: - needsGenerativePass

    func testFinishedTextSkipsTheModel() {
        for text in ["Yes.", "Ship it.", "The build passed. Deploy it now.",
                     "צריך לבדוק את זה.", "Надо это проверить."] {
            XCTAssertFalse(DeterministicPolisher.needsGenerativePass(text), text)
        }
    }

    func testUnfinishedTextStillInvokesTheModel() {
        for text in ["yes",                                   // no capital, no stop
                     "The build passed",                      // no terminal punctuation
                     "ship it now.",                          // lowercase opener
                     "The build passed. deploy it now."] {    // lowercase second sentence
            XCTAssertTrue(DeterministicPolisher.needsGenerativePass(text), text)
        }
    }

    /// A capital and a full stop say nothing about the interior. One long breath with punctuation
    /// only at the two ends has not had its sentence boundaries restored.
    func testLongUnpunctuatedRunInvokesTheModel() {
        let breath = "So " + Array(repeating: "then we do the thing", count: 6).joined(separator: " ") + "."
        XCTAssertTrue(DeterministicPolisher.needsGenerativePass(breath))
    }

    /// Hebrew has no case, so the casing clauses must be vacuous rather than failing.
    func testCaselessScriptIsNotPenalisedForLackingCapitals() {
        XCTAssertFalse(DeterministicPolisher.needsGenerativePass("אני צריך לבדוק את זה. אחר כך נדבר."))
    }

    func testTextWithoutLettersNeedsNothing() {
        XCTAssertFalse(DeterministicPolisher.needsGenerativePass("..."))
        XCTAssertFalse(DeterministicPolisher.needsGenerativePass(""))
    }

    // MARK: - Engine parity (Verification item 3)

    /// Full whisper.cpp evidence, synthesised from the same text so the only difference between
    /// the two graphs is the evidence itself. Probabilities are deliberately hostile — alternating
    /// near-zero and near-one — so that any gate reading them would diverge loudly.
    private func words(for text: String) -> [WhisperStreamWord] {
        var words: [WhisperStreamWord] = []
        var start = 0.0
        for (offset, piece) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            let chunk = offset == 0 ? String(piece) : " " + piece
            guard !chunk.isEmpty else { continue }
            words.append(WhisperStreamWord(text: chunk,
                                           tokens: [offset],
                                           start: start,
                                           end: start + 0.3,
                                           probability: offset.isMultiple(of: 2) ? 0.02 : 0.98))
            start += 0.3
        }
        return words
    }

    func testBothBuildersAgreeOnTheWorkedExample() {
        let input = "okay um first send the deployment to chat gpt second update postgress "
                  + "and then כאילו restart the service сегодня"
        XCTAssertEqual(polisher.polish(words: words(for: input)).text,
                       polisher.polish(text: input).text)
    }

    /// The whole corpus, both builders. This is the test that answers "is this reliable no matter
    /// which ASR engine produced the text" for everything M2 does.
    func testBothBuildersAgreeOnTheWholeCorpus() throws {
        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 400)
        try XCTSkipIf(fixtures.isEmpty, "No transcriptions in the local history database")

        var divergences: [String] = []
        var changed = 0
        for fixture in fixtures {
            let bare = polisher.polish(text: fixture.transcript)
            let rich = polisher.polish(words: words(for: fixture.transcript))
            if bare.text != rich.text {
                divergences.append("[]: \(bare.text)\nfull: \(rich.text)")
            }
            if bare.needsGenerativePass == false { changed += 1 }
        }

        print("Polisher: \(fixtures.count) fixtures, "
            + "\(changed) already well-formed (LLM skipped), "
            + "\(divergences.count) builder divergences")
        XCTAssertEqual(divergences.count, 0, divergences.prefix(3).joined(separator: "\n---\n"))
    }
}
