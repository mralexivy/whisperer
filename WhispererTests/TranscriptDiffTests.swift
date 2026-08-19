//
//  TranscriptDiffTests.swift
//  WhispererTests
//
//  The diff is the load-bearing piece of the editing seam: everything a generative model
//  proposes reaches the gate through it. These tests pin the two properties the rest of the
//  design assumes — applying the diff reproduces the model's output exactly, and an unchanged
//  token produces no edit at all.
//

import XCTest
@testable import whisperer

final class TranscriptDiffTests: XCTestCase {

    // MARK: - Helpers

    private func diff(_ original: String, _ revised: String) -> [TranscriptEdit] {
        TranscriptDiff.edits(from: TokenGraph.from(text: original),
                             to: revised,
                             source: .llm,
                             confidence: 1.0)
    }

    /// Apply every emitted edit to the graph the diff was taken from and return the render.
    /// The gate is bypassed on purpose — this measures the diff, not the policy.
    @discardableResult
    private func roundTrip(_ original: String,
                           _ revised: String,
                           file: StaticString = #filePath,
                           line: UInt = #line) -> [TranscriptEdit] {
        let graph = TokenGraph.from(text: original)
        let edits = TranscriptDiff.edits(from: graph, to: revised, source: .llm, confidence: 1.0)
        var working = graph
        for edit in edits {
            XCTAssertTrue(working.apply(edit),
                          "edit failed to apply: \(edit.reason)", file: file, line: line)
        }
        XCTAssertEqual(working.render(), revised, file: file, line: line)
        return edits
    }

    private func targets(_ edits: [TranscriptEdit], in graph: TokenGraph) -> [String] {
        edits.compactMap { graph.token($0.target)?.effectiveText }
    }

    // MARK: - Round trips

    func testEnglishCorrectionRoundTrips() {
        let edits = roundTrip("so i think we should um ship this tomorrow",
                              "So I think we should ship this tomorrow.")
        XCTAssertFalse(edits.isEmpty)
    }

    func testHebrewCorrectionRoundTrips() {
        roundTrip("אני רואה שעדיין יש תקורות, עדיין יש תקורות, והמודל לא מושלם",
                  "אני רואה שעדיין יש תקורות, והמודל לא מושלם.")
    }

    func testRussianCorrectionRoundTrips() {
        roundTrip("мы используем редис для очереди но он иногда падает",
                  "Мы используем Redis для очереди, но он иногда падает.")
    }

    /// The case the whole design exists for: three scripts and a code token in one utterance,
    /// where UTF-16 offsets, grapheme counts and visual order all disagree.
    func testMixedScriptRoundTrips() {
        roundTrip("בוא נריץ את docker run בבוקר и потом посмотрим the logs",
                  "בוא נריץ את docker run בבוקר, и потом посмотрим the logs.")
    }

    func testLongFormMultilingualRoundTrips() {
        roundTrip("""
                  ok so um the deployment failed again \
                  אני חושב שזה בגלל הקונפיגורציה \
                  и нам нужно проверить логи
                  """,
                  """
                  OK, so the deployment failed again. \
                  אני חושב שזה בגלל הקונפיגורציה, \
                  и нам нужно проверить логи.
                  """)
    }

    // MARK: - Edges

    func testNoChangeEmitsNoEdits() {
        let text = "The deployment finished at 3 PM."
        XCTAssertTrue(diff(text, text).isEmpty)
    }

    func testUnchangedTokensAreNeverTargeted() {
        let original = "we should ship the planer to production tomorrow"
        let graph = TokenGraph.from(text: original)
        let edits = TranscriptDiff.edits(from: graph,
                                         to: "we should ship the planner to production tomorrow",
                                         source: .llm,
                                         confidence: 1.0)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(targets(edits, in: graph), ["planer"])
        if case .replace(let text) = edits[0].operation {
            XCTAssertEqual(text, "planner")
        } else {
            XCTFail("expected a replace, got \(edits[0].operation)")
        }
    }

    func testSubstitutionDeletionAndInsertionMapToTheRightOperations() {
        let original = "we we ship tomorrow"
        let graph = TokenGraph.from(text: original)
        let edits = TranscriptDiff.edits(from: graph, to: "We ship tomorrow.",
                                         source: .llm, confidence: 1.0)

        XCTAssertTrue(edits.contains { if case .delete = $0.operation { return true }; return false },
                      "the duplicated word should be a delete")
        XCTAssertTrue(edits.contains { if case .replace = $0.operation { return true }; return false },
                      "the recased word should be a replace")
        XCTAssertTrue(edits.contains {
            if case .insertAfter(let text) = $0.operation { return text == "." }
            return false
        }, "the added terminator should be an insertAfter on the last surviving token")

        var working = graph
        for edit in edits { XCTAssertTrue(working.apply(edit), edit.reason) }
        XCTAssertEqual(working.render(), "We ship tomorrow.")
    }

    func testInsertionAtTheEndAnchorsToTheLastToken() {
        let graph = TokenGraph.from(text: "ship it")
        let edits = TranscriptDiff.edits(from: graph, to: "ship it now",
                                         source: .llm, confidence: 1.0)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(targets(edits, in: graph), ["it"])
        if case .insertAfter(let text) = edits[0].operation {
            XCTAssertEqual(text, " now")
        } else {
            XCTFail("expected an insertAfter, got \(edits[0].operation)")
        }
        roundTrip("ship it", "ship it now")
    }

    /// There is no `insertBefore` — an insertion ahead of every surviving token has no token to
    /// address, so it folds into the first survivor. The render still has to be exact.
    func testInsertionAtTheStartFoldsIntoTheFirstSurvivor() {
        let edits = roundTrip("world", "hello world")
        XCTAssertEqual(edits.count, 1)
        if case .replace(let text) = edits[0].operation {
            XCTAssertEqual(text, "hello world")
        } else {
            XCTFail("expected a replace carrying the prefix, got \(edits[0].operation)")
        }
    }

    func testInsertionAtTheStartOfRTLTextFoldsIntoTheFirstSurvivor() {
        roundTrip("עובד", "זה עובד היום.")
    }

    func testPurePunctuationChange() {
        let graph = TokenGraph.from(text: "yes. but not today")
        let edits = TranscriptDiff.edits(from: graph, to: "yes, but not today",
                                         source: .llm, confidence: 1.0)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(targets(edits, in: graph), ["."])
        roundTrip("yes. but not today", "yes, but not today")
    }

    func testPunctuationOnlyInsertionInHebrew() {
        roundTrip("אני חושב שזה עובד", "אני חושב שזה עובד.")
    }

    func testWholeInputReplaced() {
        roundTrip("foo", "bar baz")
    }

    /// Canonical equivalence, not code units. A revision that differs only in Unicode
    /// composition is not a revision — the exact class of false diff that an offset-based
    /// implementation cannot avoid.
    func testDecomposedFormIsNotADifference() {
        let original = "мы пьём кофе"
        let decomposed = original.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(original.unicodeScalars), Array(decomposed.unicodeScalars),
                          "the fixture must actually differ at the scalar level")
        XCTAssertTrue(diff(original, decomposed).isEmpty)
    }

    func testEmptyModelOutputIsRefused() {
        XCTAssertTrue(diff("we should ship tomorrow", "").isEmpty)
        XCTAssertTrue(diff("we should ship tomorrow", "   \n ").isEmpty)
    }

    func testEmptyOriginalProducesNothing() {
        XCTAssertTrue(diff("", "hello").isEmpty)
    }

    // MARK: - Source and confidence pass-through

    func testEditsCarryTheRequestedSourceAndConfidence() {
        let edits = TranscriptDiff.edits(from: TokenGraph.from(text: "ship it"),
                                         to: "Ship it.",
                                         source: .editorModel,
                                         confidence: 0.42)
        XCTAssertFalse(edits.isEmpty)
        XCTAssertTrue(edits.allSatisfy { $0.source == .editorModel })
        XCTAssertTrue(edits.allSatisfy { $0.confidence == 0.42 })
    }
}
