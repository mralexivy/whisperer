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
        // Capitalized because `SentenceCaser` runs after the filler deletions — the opening word
        // of an utterance is a sentence opening whichever word survived the cleanup.
        XCTAssertEqual(result.text, "Hello world")
    }

    /// The bug the gate-simulated normalizer scratch exists to prevent: if the duplicate-word
    /// deletion is refused as a negation, the whitespace collapse that would have closed the gap
    /// must be refused with it, or the two words fuse.
    func testRefusedDeletionDoesNotFuseItsNeighbours() {
        let result = polisher.polish(text: "не не надо это делать")
        XCTAssertFalse(result.text.contains("нене"), result.text)
    }

    // MARK: - Phrase aliases are all-or-nothing

    /// The shipped-lexicon bug. `("no sequel", "NoSQL")` is a two-token phrase whose first token
    /// is in `ConfidenceGate.negations`, so the `.replace` was refused and both `.delete`s were
    /// accepted — the transcript came back as the single word `no`, with the user's second word
    /// gone and nothing in the log to say so.
    ///
    /// Before the fix this rendered `"no"`. The assertion is deliberately on the exact string:
    /// the whole point is that a refused phrase leaves the input *untouched*, not merely
    /// non-empty.
    func testNegationRefusalDropsTheWholePhraseRatherThanHalfOfIt() {
        let out = polisher.polish(text: "no sequel").text
        // Both words present, in order, and only the sentence-initial capital changed. Asserting
        // the exact string rather than `contains` is the point: "untouched" has to mean the tail
        // survived, not merely that the output is non-empty.
        XCTAssertEqual(out, "No sequel")
        XCTAssertNotEqual(out.lowercased(), "no",
                          "the alias engine deleted a word the gate would not let it replace")
    }

    /// The same shape, tripping a different guard. `numberViolation` refuses the `.delete` of a
    /// token carrying digits, so a phrase alias whose tail is a number used to apply its
    /// replacement and its whitespace deletion and leave the digits stranded — `the i 5 is here`
    /// became `the iPhone5 is here`.
    ///
    /// Driven through `AliasEngine` + `ConfidenceGate` directly rather than the polisher, because
    /// `ProtectionDetector` hard-protects anything containing a digit and would mask the guard
    /// this is about.
    func testNumberRefusalDropsTheWholePhraseRatherThanHalfOfIt() {
        let engine = AliasEngine(entries: [DictionaryEntry(incorrectForm: "i 5",
                                                           correctForm: "iPhone")],
                                 includeShippedLexicon: false)
        let gate = ConfidenceGate()
        var graph = TokenGraph.from(text: "the i 5 is here")
        let accepted = gate.apply(engine.proposals(for: graph, gate: gate), to: &graph)

        XCTAssertEqual(graph.render(), "the i 5 is here")
        XCTAssertTrue(accepted.isEmpty, "\(accepted.map(\.reason))")
    }

    /// The guard must not cost recall on phrases nothing objects to.
    func testOrdinaryPhraseAliasesStillApply() {
        XCTAssertEqual(polisher.polish(text: "ask chat gpt about git hub").text,
                       "Ask ChatGPT about GitHub")
    }

    // MARK: - TokenGraph index map

    /// `index(of:)` became a dictionary lookup. A stale map mis-targets an edit, which is worse
    /// than the O(n) scan it replaced, so this applies a large mixed batch — replace, delete,
    /// insert, interleaved — and compares against an independent list simulation. The expected
    /// output is exactly what the linear scan produced.
    func testLargeEditBatchTargetsTheSameTokensAsALinearScan() {
        let text = (0..<200).map { "w\($0)" }.joined(separator: " ")
        var graph = TokenGraph.from(text: text)
        let ids = graph.tokens.map(\.id)

        var referenceIDs: [TokenID?] = ids
        var referenceText: [String] = graph.tokens.map(\.effectiveText)

        for (offset, id) in ids.enumerated() {
            let operation: EditOperation
            switch offset % 4 {
            case 0:  operation = .replace("X\(offset)")
            case 1:  operation = .delete
            case 2:  operation = .insertAfter("!")
            default: continue
            }
            let edit = TranscriptEdit(target: id, operation: operation,
                                      source: .normalization, confidence: 1.0,
                                      reason: "batch \(offset)")
            XCTAssertTrue(graph.apply(edit), "edit \(offset) did not find its target")

            guard let position = referenceIDs.firstIndex(where: { $0 == id }) else {
                XCTFail("reference lost \(id)")
                continue
            }
            switch operation {
            case .replace(let replacement): referenceText[position] = replacement
            case .delete:
                referenceIDs.remove(at: position)
                referenceText.remove(at: position)
            case .insertAfter(let inserted):
                referenceIDs.insert(nil, at: position + 1)
                referenceText.insert(inserted, at: position + 1)
            case .keep: break
            }
        }

        XCTAssertEqual(graph.render(), referenceText.joined())
        for (position, token) in graph.tokens.enumerated() {
            XCTAssertEqual(graph.index(of: token.id), position,
                           "index map drifted at \(position)")
        }
    }

    // MARK: - rawRanges invalidation

    /// `rawRanges` is parallel to `tokens` **as built**. After a deletion the zip in
    /// `tokenIDs(overlappingRawRange:)` pairs token *i* with the span of token *i+k*, so it
    /// returned confidently wrong token IDs — which would have handed `ProtectionDetector` the
    /// wrong span to hard-protect. Before the fix this returned the whitespace token that had
    /// slid into `beta`'s slot; now the invariant is enforced rather than commented.
    func testRawRangeLookupIsRefusedOnceTheGraphHasBeenEdited() {
        var graph = TokenGraph.from(text: "alpha beta gamma")
        let beta = graph.rawTranscript.range(of: "beta")!
        let before = graph.tokenIDs(overlappingRawRange: beta)
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(graph.token(before[0])?.effectiveText, "beta")

        XCTAssertTrue(graph.apply(TranscriptEdit(target: graph.tokens[0].id,
                                                 operation: .delete,
                                                 source: .normalization, confidence: 1.0,
                                                 reason: "invalidate")))
        XCTAssertEqual(graph.tokenIDs(overlappingRawRange: beta), [],
                       "stale raw ranges must return nothing, not the wrong tokens")
    }

    // MARK: - ListFormatter offset basis

    /// `precedingWord` derived a `String.Index` from a Character distance and an `NSRange`
    /// length from the same number. They agree only when every grapheme is one UTF-16 unit —
    /// and pointed Hebrew is not: `בְּ` is one Character and three UTF-16 units. The search range
    /// was therefore truncated short of the marker, `matches.last` returned an *earlier*
    /// occurrence of the preceding word, and the shared-prefix grouping mis-sliced every item.
    ///
    /// Before the fix this produced `["שלב:", "1. לְעַדְכֵּן שלב", "2. לבדוק שלב", "3. לכתוב"]`
    /// — the marker word leaking into each item. The unpointed control below is what it should
    /// have been all along, and pointing the text must not change it.
    func testPointedHebrewMarkersAreClassifiedOnTheSameOffsetBasis() {
        let pointed = "שלב ראשית לְעַדְכֵּן שלב שנית לבדוק שלב שלישית לכתוב"
        let plain   = "שלב ראשית לעדכן שלב שנית לבדוק שלב שלישית לכתוב"

        XCTAssertEqual(ListFormatter.format(pointed).components(separatedBy: "\n"),
                       ["1. לְעַדְכֵּן", "2. לבדוק", "3. לכתוב"])
        XCTAssertEqual(ListFormatter.format(plain).components(separatedBy: "\n"),
                       ["1. לעדכן", "2. לבדוק", "3. לכתוב"])
    }

    /// Cyrillic is one UTF-16 unit per character, so this is a control rather than a repro: the
    /// Russian markers must keep formatting exactly as before the offset change.
    func testRussianMarkersAreUnaffectedByTheOffsetFix() {
        XCTAssertEqual(
            ListFormatter.format("во-первых, обновить базу. во-вторых, перезапустить сервис. "
                                 + "в-третьих, проверить логи").components(separatedBy: "\n"),
            ["1. Обновить базу", "2. Перезапустить сервис", "3. Проверить логи"])
        XCTAssertEqual(
            ListFormatter.format("номер один обновить базу. номер два перезапустить сервис")
                .components(separatedBy: "\n"),
            ["1. Обновить базу", "2. Перезапустить сервис"])
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
