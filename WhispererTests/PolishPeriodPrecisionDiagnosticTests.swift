//
//  PolishPeriodPrecisionDiagnosticTests.swift
//  WhispererTests
//
//  Why verdict rule 5 fails, in the only form that can settle it: the individual false positives.
//
//  `PolishVerdictTests` scores period insertion at 0.8646 (83/96) against `goldenTranscript` and
//  the rule needs 0.99, so rule 5 fails and the flag cannot default to on. But the same insertions
//  score boundary precision 0.9938 against the authored gold, and two references disagreeing by
//  that much is a claim about the references at least as much as about the pipeline. The scorer's
//  proxy is crude by construction — it asks *"does this word end a sentence everywhere it appears
//  in the whole-file decode?"*, which is a question about a word rather than about this position,
//  and `endsASentence` returns `nil` (unscoreable) only when the reference's occurrences disagree
//  with each other, never when the reference simply has no view of this utterance's ending.
//
//  So this dumps the 13 disagreements with enough context for a person to classify each one. It
//  asserts nothing about them. Whether they are real over-insertions or artefacts of the proxy is
//  a judgement, and a test that made that judgement for the reader would be the test choosing the
//  verdict — which is the thing this whole benchmark exists not to do.
//

import XCTest
@testable import whisperer

final class PolishPeriodPrecisionDiagnosticTests: XCTestCase {

    private static let terminators: Set<String> = [".", "!", "?", "…"]

    func testPeriodInsertionFalsePositives() throws {
        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 400)
        try XCTSkipIf(fixtures.isEmpty, "No transcriptions in the local history database")
        try XCTSkipIf(GoldenSet.isEmpty, "golden set failed to load")

        let polisher = DeterministicPolisher()
        var falsePositives = 0
        var truePositives = 0

        print("""

        ── Period-insertion disagreements with goldenTranscript ──────────────────
        Each row: the word the period was inserted after, the tail of the polished output, and
        every occurrence of that word in the whole-file decode with the character that follows it.
        """)

        for fixture in fixtures {
            guard let golden = GoldenSet.reference(for: fixture.id), !golden.isEmpty else { continue }
            let result = polisher.polish(text: fixture.transcript)
            let goldenWords = golden.split(whereSeparator: \.isWhitespace).map(String.init)

            for applied in result.graph.appliedEdits {
                guard case .insertAfter(let mark) = applied.edit.operation,
                      Self.terminators.contains(mark) else { continue }
                let word = applied.previousText
                guard let verdict = Self.endsASentence(word, in: goldenWords) else { continue }
                guard !verdict else { truePositives += 1; continue }
                falsePositives += 1

                let occurrences = goldenWords
                    .filter { Self.strip($0).lowercased() == Self.strip(word).lowercased() }
                    .prefix(6)
                    .joined(separator: " | ")
                print("""

                FP  after \"\(word)\"  source=\(applied.edit.source)  \
                confidence=\(String(format: "%.3f", applied.edit.confidence))
                    polished tail: …\(Self.tail(of: result.text))
                    reference occurrences: \(occurrences)
                """)
            }
        }

        print("""

        \(truePositives) agreed · \(falsePositives) disagreed — the 13 that cost rule 5 its 0.99.
        ──────────────────────────────────────────────────────────────────────────

        """)
        XCTAssertGreaterThan(truePositives + falsePositives, 0,
                             "no scoreable period insertions — the diagnostic measured nothing")
    }

    /// The positions the **position-aligned** ruler rejects, which is a different and much shorter
    /// list than the proxy's.
    ///
    /// Rule 5 at B6 fails four cells, and three of them fail by a handful of edits: en · authored
    /// 0.9844 (2 wrong of 128), he · authored 0.9375 (3 of 48), ru · authored 0.9730 (1 of 37).
    /// Six insertions stand between those three cells and the 0.99 bar. Whether they are one
    /// closable phenomenon or six unrelated ones is not something a precision figure can say, so
    /// this prints them with their reference context and classifies nothing.
    ///
    /// Scored against the **authored gold**, not the whole-file decode: the fourth failing cell
    /// (en · decode 0.8496) sits on the utterance-final position that neither reference can judge —
    /// the decode omits a final period on 18% of utterances where the gold supplies one, 51 cases
    /// to 5 in one direction. Listing its 17 disagreements would be listing that disagreement.
    func testPositionAlignedRejections() throws {
        // Iterates the authored cases and polishes `entry.input`, which is what rule 5's authored
        // cell does (`PolishVerdictTests:735-741`) — not the history fixture with the same id. The
        // first version of this test walked the fixtures instead and printed zero rejections while
        // the verdict was reporting six: same corpus by name, different input text, so a diagnostic
        // that looked like an all-clear was examining edits the rule never scored.
        let cases = AuthoredGold.punctuationCases()
        try XCTSkipIf(cases.isEmpty, "authored gold failed to load")

        for (label, polisher) in Self.configurations { try report(label, polisher, cases) }
    }

    /// The bench's configuration and the shipping one, side by side.
    ///
    /// `DeterministicPolisher()` defaults to `formatsLists: true` and `splitsParagraphs: true`
    /// (`DeterministicPolisher.swift:72,75`). Dictation calls
    /// `forTranscript(dictionaryEntries:formatsLists: false, …)` from `AppState.swift:2000`, with
    /// paragraphs following a flag that is off. Every rule scored through the bare initialiser has
    /// therefore been scoring enumeration reflow that dictation does not run — which is not a
    /// hypothetical: two of rule 5's six authored-gold rejections are `ListFormatter` treating
    /// "screenshot 13 / screenshot 14" as an enumeration.
    private static var configurations: [(String, DeterministicPolisher)] {
        [("bench default (formatsLists: true, paragraphs: true)", DeterministicPolisher()),
         ("shipping dictation (formatsLists: false, paragraphs: false)",
          DeterministicPolisher.forTranscript(dictionaryEntries: [],
                                              formatsLists: false,
                                              splitsParagraphs: false))]
    }

    private func report(_ label: String,
                        _ polisher: DeterministicPolisher,
                        _ cases: [AuthoredGold.Case]) throws {
        var byScript: [String: Int] = [:]

        print("""

        ── Position-aligned rejections against the authored gold — \(label) ──
        Each row is one inserted terminator the gold does not have at that position, shown in the
        gold's own words with ⟦.⟧ where the pass put it.
        """)

        // Same attribution as `testDecodeRejectionsSplitByPosition`, for the same reason: a
        // rejection at the utterance end and a rejection elsewhere are different defects with
        // different fixes, and the reference position alone cannot tell them apart.
        let withoutEndRule = DeterministicPolisher.forTranscript(dictionaryEntries: [],
                                                                 formatsLists: false,
                                                                 terminatesUtteranceEnd: false,
                                                                 splitsParagraphs: false)

        for entry in cases {
            let polished = polisher.polish(text: entry.input).text
            let disagreements = BoundaryScorer.insertionDisagreements(
                reference: entry.gold, input: entry.input, hypothesis: polished)
            guard !disagreements.isEmpty else { continue }

            let remaining = Set(BoundaryScorer.insertionDisagreements(
                reference: entry.gold, input: entry.input,
                hypothesis: withoutEndRule.polish(text: entry.input).text).map(\.0))
            let referenceWordCount = BoundaryScorer.words(entry.gold).count

            byScript[entry.language, default: 0] += disagreements.count
            for (position, window) in disagreements {
                print("  \(remaining.contains(position) ? "SURVIVES" : "END-RULE")  "
                      + "\(entry.language)  \(String(entry.id.prefix(8)).lowercased())  "
                      + "@\(position)/\(referenceWordCount)  \(window)")
            }
        }

        let total = byScript.values.reduce(0, +)
        print("""

        \(total) rejected position(s): \
        \(byScript.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
        ──────────────────────────────────────────────────────────────────────────

        """)
    }

    /// The same position-aligned rejections against the **whole-file decode**, split by whether the
    /// rejected position is the last word of the reference.
    ///
    /// This is the cell that gates rule 5 for English (0.8522, 98/115) and the one §3b argues is
    /// unjudgeable: the decode omits a final period on 18% of utterances the authored gold
    /// terminates, 51 cases to 5 in one direction. But "the reference is biased at the final
    /// position" is a claim about the *final* position, and it says nothing about a period inserted
    /// in the middle of an utterance. Those, if any exist, are real over-insertions that both
    /// references would reject and that no amount of arguing about references excuses.
    ///
    /// So the split is the whole point of this table — but the reference's word count is the wrong
    /// axis to split on, and the first version of this test split on it and got a misleading answer.
    /// The stored transcript and the whole-file decode are two different decodes of the same audio
    /// and they end at different words: when the stored transcript stops at the reference's word 32
    /// of 48, the utterance-final period projects onto reference position 32 and *looks* interior.
    /// Ten of twenty-four rows were labelled INTERIOR that way, several of them at `n-1`, which is
    /// not a plausible place for a pipeline to insert a period.
    ///
    /// The axis that answers it is the polisher's own: `terminatesUtteranceEnd`. Turn the end rule
    /// off and re-score. Whatever survives is by construction an insertion made somewhere other
    /// than the utterance end, and is a real over-insertion no reference argument excuses.
    func testDecodeRejectionsSplitByPosition() throws {
        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 400)
        try XCTSkipIf(fixtures.isEmpty, "No transcriptions in the local history database")
        try XCTSkipIf(GoldenSet.isEmpty, "golden set failed to load")

        let shipping = DeterministicPolisher.forTranscript(dictionaryEntries: [],
                                                           formatsLists: false,
                                                           splitsParagraphs: false)
        let withoutEndRule = DeterministicPolisher.forTranscript(dictionaryEntries: [],
                                                                 formatsLists: false,
                                                                 terminatesUtteranceEnd: false,
                                                                 splitsParagraphs: false)
        var shippingRejections = 0
        var survivors: [String] = []

        print("""

        ── Decode-reference rejections, attributed to the rule that made them ────
        Each row is one inserted terminator the whole-file decode does not have at that position.
        SURVIVES = still rejected with SentenceTerminator's end-of-utterance rule switched off, so
        some other rule put it there. END-RULE = disappears without it, and is therefore the
        utterance-final period the decode systematically omits (51 cases to 5 — see §3b).
        """)

        for fixture in fixtures {
            guard let golden = GoldenSet.reference(for: fixture.id), !golden.isEmpty else { continue }
            let script = PolishBenchmarkTests.detectedLanguage(of: fixture.transcript)
            guard script == PolishBenchmarkTests.detectedLanguage(of: golden) else { continue }

            let referenceWordCount = BoundaryScorer.words(golden).count
            let rejections = BoundaryScorer.insertionDisagreements(
                reference: golden, input: fixture.transcript,
                hypothesis: shipping.polish(text: fixture.transcript).text)
            guard !rejections.isEmpty else { continue }

            let remaining = Set(BoundaryScorer.insertionDisagreements(
                reference: golden, input: fixture.transcript,
                hypothesis: withoutEndRule.polish(text: fixture.transcript).text).map(\.0))

            for (position, window) in rejections {
                shippingRejections += 1
                let survives = remaining.contains(position)
                if survives { survivors.append("\(script) \(fixture.id.prefix(8)) @\(position)") }
                print("  \(survives ? "SURVIVES" : "END-RULE")  \(script)  "
                      + "\(String(fixture.id.prefix(8)).lowercased())  "
                      + "@\(position)/\(referenceWordCount)  \(window)")
            }
        }

        print("""

        \(shippingRejections) rejected · \(shippingRejections - survivors.count) attributable to the \
        end-of-utterance rule · \(survivors.count) from another rule
        ──────────────────────────────────────────────────────────────────────────

        """)

        // Not a bar on the cell — the cell's precision is argued about elsewhere. This asserts the
        // narrower thing the table establishes: every decode-reference rejection comes from the one
        // rule whose position that reference cannot judge. A survivor is a defect somewhere else in
        // the pass, and it must be named rather than absorbed into the reference argument.
        XCTAssertEqual(survivors, [],
                       "over-insertion(s) not attributable to the end-of-utterance rule")
    }

    private static func tail(of text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.suffix(12).joined(separator: " ")
    }

    /// The same proxy `PolishVerdictTests` scores rule 5 with, duplicated deliberately: this file
    /// exists to examine that proxy's verdicts, so importing a changed version later and silently
    /// examining a different question is the failure mode to avoid.
    private static func endsASentence(_ word: String, in reference: [String]) -> Bool? {
        let needle = strip(word)
        guard !needle.isEmpty else { return nil }
        var verdicts: Set<Bool> = []
        for candidate in reference where strip(candidate) == needle {
            verdicts.insert(candidate.last.map { terminators.contains(String($0)) } ?? false)
        }
        return verdicts.count == 1 ? verdicts.first : nil
    }

    private static func strip(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }
}
