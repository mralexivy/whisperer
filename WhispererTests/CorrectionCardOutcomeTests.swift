//
//  CorrectionCardOutcomeTests.swift
//  WhispererTests
//
//  The two outcomes the correction card can produce, asserted end to end against the real
//  promotion gates and the real correction engine — the last two steps of the plan's manual list.
//
//  Uses temp-file stores throughout. A test suite must never touch the user's dictionary.
//

import XCTest
@testable import whisperer

final class CorrectionCardOutcomeTests: XCTestCase {
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` synthesizes an isolated `deinit` on
    /// `CorrectionEngine`, and deallocating one inside a synchronous test method aborts the test
    /// host. Engines built here are kept alive for the process instead. See CLAUDE.md.
    private static var retainedEngines: [CorrectionEngine] = []

    private func engine(with entries: [DictionaryEntry]) -> CorrectionEngine {
        let engine = CorrectionEngine(entries: entries)
        Self.retainedEngines.append(engine)
        return engine
    }

    private func temporaryStoreURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
    }

    /// The card fixes a word → it is learned → the user hits Undo on the toast → dictating the
    /// same sentence again must not relearn it. Mirrors what `CorrectionLearningService.undo`
    /// does, against a throwaway tombstone file.
    func testUndoingALearnedWordStopsItBeingLearnedAgain() async throws {
        let tombstones = CorrectionTombstoneStore(fileURL: temporaryStoreURL("tombstones.json"))
        defer { Task { await tombstones.removeAll() } }

        let tokens = CorrectionPromptTokenizer.tokenize("we can glyn a lot from these numbers")
        let index = try XCTUnwrap(tokens.first { $0.text == "glyn" }?.index)
        let edited = try XCTUnwrap(CorrectionPromptTokenizer.replacing(
            tokenAt: index, with: "Glean", in: tokens))
        let candidate = try XCTUnwrap(CorrectionLearningCandidateExtractor.extract(
            from: CorrectionPromptTokenizer.text(of: tokens), edited: edited).first)

        // First correction: learned outright.
        var known = await tombstones.all()
        XCTAssertEqual(CorrectionPromotion.evaluate(observed: candidate.observed,
                                                    corrected: candidate.corrected,
                                                    tombstones: known), .automatic)

        // Undo tombstones the *observed* form.
        let entry = DictionaryEntry(incorrectForm: "glyn", correctForm: "Glean",
                                    observedSource: "glyn")
        await tombstones.add(try XCTUnwrap(entry.observedSource))

        // Same dictation again: not learned, and not even offered.
        known = await tombstones.all()
        let second = CorrectionPromotion.evaluate(observed: candidate.observed,
                                                  corrected: candidate.corrected,
                                                  tombstones: known)
        guard case .rejected = second else {
            return XCTFail("a word the user undid came back as \(second)")
        }

        // And a near-miss spelling of the same mishearing is blocked too — tombstones key on the
        // observed form, not the pair.
        let variant = CorrectionPromotion.evaluate(observed: "glyn", corrected: "Gleen",
                                                   tombstones: known)
        guard case .rejected = variant else {
            return XCTFail("re-offering the same mishearing with a different fix is the same annoyance")
        }
    }

    /// "Always fix" is the card's answer when the gates refuse a pair the user stated outright.
    /// It must enter as a *hand-authored* entry — the user authored it — which is what admits it to
    /// the fuzzy indexes and lets it rewrite a valid English word.
    func testAlwaysFixEntersAsAHandAuthoredEntryAndActuallyFires() throws {
        let pair = ("report", "readout")

        // Precondition: the gates do refuse it, so this path is the only way it can be learned.
        XCTAssertEqual(
            CorrectionPromotion.evaluate(observed: pair.0, corrected: pair.1, tombstones: []),
            .suggestion,
            "if the gates started auto-learning this, the Always fix branch is no longer under test"
        )

        // Exactly what `CorrectionPopoverCard.alwaysFix` constructs.
        let entry = DictionaryEntry(incorrectForm: pair.0, correctForm: pair.1,
                                    category: "Learned",
                                    notes: "Added from a correction you made")
        XCTAssertFalse(entry.isAutoLearned,
                       "an entry the user confirmed by hand must not carry auto-learned provenance")
        XCTAssertNil(entry.observedSource)

        // A hand-authored entry rewrites a valid English word; an auto-learned one never would.
        let byHand = engine(with: [entry])
        XCTAssertEqual(byHand.applyCorrections("the report says the numbers are late").text,
                       "the readout says the numbers are late")

        let autoLearned = DictionaryEntry(incorrectForm: pair.0, correctForm: pair.1,
                                          observedSource: pair.0)
        let byInference = engine(with: [autoLearned])
        XCTAssertEqual(byInference.applyCorrections("the report says the numbers are late").text,
                       "the report says the numbers are late",
                       "provenance is what keeps an inferred entry from rewriting real English")
    }
}
