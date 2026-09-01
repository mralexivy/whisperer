//
//  AutoLearnedEntryTests.swift
//  WhispererTests
//
//  Provenance safety for auto-learned dictionary entries.
//
//  An auto-learned entry is promoted from a single observed mishearing, so it is only
//  trustworthy for the exact string that was observed. Two properties keep it from doing
//  damage the way a hand-authored entry never could:
//
//    1. It is excluded from the SymSpell and PhoneticMatcher indexes, so it cannot pull in
//       neighbours of the observed form.
//    2. It is held to the same valid-English spell gate as a built-in entry, so a learned
//       pair like `backend → firebase` can never rewrite an ordinary English word.
//
//  Confirming an entry clears `observedSource`, at which point it behaves as a normal
//  user-authored entry.
//

import XCTest
@testable import whisperer

final class AutoLearnedEntryTests: XCTestCase {

    /// See CorrectionEngineTests.liveEngines — an isolated deinit aborts the test host.
    private static var liveEngines: [CorrectionEngine] = []

    private func makeEngine(_ entries: [DictionaryEntry]) -> CorrectionEngine {
        let engine = CorrectionEngine(entries: entries)
        Self.liveEngines.append(engine)
        return engine
    }

    private func autoLearned(_ observed: String, _ corrected: String) -> DictionaryEntry {
        DictionaryEntry(
            incorrectForm: observed,
            correctForm: corrected,
            category: "Learned",
            observedSource: observed
        )
    }

    // MARK: - Provenance

    func testObservedSourceMarksTheEntryAutoLearned() {
        XCTAssertTrue(autoLearned("glyn", "Glean").isAutoLearned)
        XCTAssertFalse(DictionaryEntry(incorrectForm: "glyn", correctForm: "Glean").isAutoLearned)
    }

    // MARK: - Exact match still works

    func testAutoLearnedEntryStillCorrectsTheExactObservedForm() {
        let engine = makeEngine([autoLearned("glyn", "Glean")])
        XCTAssertEqual(
            engine.applyCorrections("open glyn and show the dashboard").text,
            "open Glean and show the dashboard"
        )
    }

    // MARK: - Excluded from the fuzzy indexes

    func testAutoLearnedEntryIsAbsentFromTheFuzzyIndexes() {
        // `glynn` is not the observed form and is not valid English, so with fuzzy matching on it
        // would reach an indexed entry by edit distance or soundex. An auto-learned entry must not
        // be reachable that way.
        let learned = makeEngine([autoLearned("glyn", "Glean")])
        XCTAssertEqual(learned.applyCorrections("open glynn now").text, "open glynn now")

        // Control: the identical pair authored by hand *is* indexed, so the neighbour is reached.
        // This is what proves the previous assertion is testing the index split and not simply
        // an entry too short or too obscure for the matchers.
        let authored = makeEngine([DictionaryEntry(incorrectForm: "glyn", correctForm: "Glean")])
        XCTAssertEqual(authored.applyCorrections("open glynn now").text, "open Glean now")
    }

    // MARK: - The spell gate

    func testAutoLearnedEntryNeverRewritesAValidEnglishWord() {
        // The destructive case measured on the Wispr corpus: `backend → firebase`, observed once,
        // would otherwise rewrite all 87 dictations containing "backend".
        let engine = makeEngine([autoLearned("backend", "Firebase")])
        XCTAssertEqual(
            engine.applyCorrections("the backend is deployed").text,
            "the backend is deployed"
        )
    }

    func testHandAuthoredEntryStillRewritesAValidEnglishWord() {
        // Unchanged behaviour for entries the user typed in themselves: they always fire.
        let engine = makeEngine([DictionaryEntry(incorrectForm: "backend", correctForm: "Firebase")])
        XCTAssertEqual(
            engine.applyCorrections("the backend is deployed").text,
            "the Firebase is deployed"
        )
    }

    func testConfirmingAnAutoLearnedEntryRestoresFullBehaviour() {
        let confirmed = DictionaryEntry(
            incorrectForm: "backend",
            correctForm: "Firebase",
            category: "Learned",
            observedSource: nil
        )
        XCTAssertFalse(confirmed.isAutoLearned)
        let engine = makeEngine([confirmed])
        XCTAssertEqual(
            engine.applyCorrections("the backend is deployed").text,
            "the Firebase is deployed"
        )
    }
}
