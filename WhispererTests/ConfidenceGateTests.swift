//
//  ConfidenceGateTests.swift
//  WhispererTests
//

import XCTest
@testable import whisperer

final class ConfidenceGateTests: XCTestCase {

    private let gate = ConfidenceGate()

    private func graph(_ text: String, annotated: Bool = false) -> TokenGraph {
        var graph = TokenGraph.from(text: text)
        if annotated { ProtectionDetector.annotate(&graph) }
        return graph
    }

    private func id(_ word: String, in graph: TokenGraph) -> TokenID {
        graph.tokens.first { $0.effectiveText == word }!.id
    }

    private func edit(_ word: String, in graph: TokenGraph, _ operation: EditOperation,
                      source: EditSource, confidence: Float = 1.0) -> TranscriptEdit {
        TranscriptEdit(target: id(word, in: graph), operation: operation,
                       source: source, confidence: confidence, reason: "test")
    }

    private func reason(_ verdict: ConfidenceGate.Verdict) -> String {
        if case .keep(let reason) = verdict { return reason }
        return ""
    }

    // MARK: - Confidence floors

    func testConfidenceFloorIsPerSource() {
        let g = graph("deploy the service")
        // A learned alias at 0.80 clears the alias floor…
        XCTAssertEqual(gate.judge(edit("deploy", in: g, .replace("Deploy"),
                                       source: .alias, confidence: 0.80), in: g), .accept)
        // …but the same number from a model does not come close to the model floor.
        XCTAssertFalse(gate.judge(edit("deploy", in: g, .replace("Deploy"),
                                       source: .editorModel, confidence: 0.80), in: g).isAccepted)
    }

    func testModelEditsDoNotAutoApplyBelowNinetyNine() {
        let g = graph("deploy the service")
        for confidence in [Float(0.90), 0.95, 0.98] {
            XCTAssertFalse(gate.judge(edit("deploy", in: g, .replace("Deploy"),
                                           source: .editorModel, confidence: confidence),
                                      in: g).isAccepted,
                           "model edit at \(confidence) should not auto-apply")
        }
        XCTAssertEqual(gate.judge(edit("deploy", in: g, .replace("Deploy"),
                                       source: .editorModel, confidence: 0.99), in: g), .accept)
    }

    // MARK: - Stated vs inferred

    /// Soft protection is the "this might be a name or a foreign term" signal. A model must not
    /// resolve it; an explicit table may.
    func testSoftProtectionStopsInferredEditsOnly() {
        let g = graph("restart the service сегодня", annotated: true)
        XCTAssertEqual(g.token(id("сегодня", in: g))?.protection, .soft)

        let inferred = gate.judge(edit("сегодня", in: g, .delete,
                                       source: .editorModel, confidence: 1.0), in: g)
        XCTAssertFalse(inferred.isAccepted)
        XCTAssertTrue(reason(inferred).contains("soft-protected"), reason(inferred))

        XCTAssertEqual(gate.judge(edit("сегодня", in: g, .delete,
                                       source: .filler, confidence: 1.0), in: g), .accept)
    }

    /// The worked example's own rule, made mechanical: `сегодня` may not become `היום`.
    func testInferredScriptChangeIsRefused() {
        let g = graph("restart the service сегодня")
        let verdict = gate.judge(edit("сегодня", in: g, .replace("היום"),
                                      source: .editorModel, confidence: 1.0), in: g)
        XCTAssertFalse(verdict.isAccepted)
        XCTAssertTrue(reason(verdict).contains("script"), reason(verdict))
    }

    /// …but a dictionary entry the user typed is a transliteration they asked for.
    func testStatedScriptChangeIsAllowed() {
        let g = graph("מריצים קוברנטיס בענן")
        XCTAssertEqual(gate.judge(edit("קוברנטיס", in: g, .replace("Kubernetes"),
                                       source: .alias, confidence: 1.0), in: g), .accept)
    }

    func testCasingIsNotAScriptChange() {
        let g = graph("deploy the service")
        XCTAssertEqual(gate.judge(edit("deploy", in: g, .replace("Deploy"),
                                       source: .editorModel, confidence: 1.0), in: g), .accept)
    }

    // MARK: - Negation

    /// The catastrophic edit: it inverts the meaning while looking like a clean-up.
    func testNegationIsNeverDeletedByAnySource() {
        for (text, word) in [("do not deploy this", "not"),
                             ("אל תפרוס את זה", "אל"),
                             ("не надо это делать", "не")] {
            let g = graph(text)
            for source in [EditSource.alias, .filler, .normalization, .editorModel, .llm] {
                let verdict = gate.judge(edit(word, in: g, .delete, source: source,
                                              confidence: 1.0), in: g)
                XCTAssertFalse(verdict.isAccepted, "\(source) deleted \(word)")
                XCTAssertTrue(reason(verdict).contains("negation"), reason(verdict))
            }
        }
    }

    func testNegationMayBeRespelledButNotRemoved() {
        let g = graph("dont deploy this")
        XCTAssertEqual(gate.judge(edit("dont", in: g, .replace("don't"),
                                       source: .alias, confidence: 1.0), in: g), .accept)
        XCTAssertFalse(gate.judge(edit("dont", in: g, .replace("do"),
                                       source: .alias, confidence: 1.0), in: g).isAccepted)
    }

    func testNegationIsNotInserted() {
        let g = graph("deploy this")
        XCTAssertFalse(gate.judge(edit("deploy", in: g, .insertAfter("not"),
                                       source: .editorModel, confidence: 1.0), in: g).isAccepted)
    }

    // MARK: - Numbers

    func testDigitsSurviveEveryEdit() {
        let g = graph("scale to 42 replicas")
        XCTAssertFalse(gate.judge(edit("42", in: g, .delete,
                                       source: .normalization, confidence: 1.0), in: g).isAccepted)
        XCTAssertFalse(gate.judge(edit("42", in: g, .replace("forty two"),
                                       source: .alias, confidence: 1.0), in: g).isAccepted)
        // Reformatting around the digits is fine — the digits themselves are unchanged.
        XCTAssertEqual(gate.judge(edit("42", in: g, .replace("42x"),
                                       source: .alias, confidence: 1.0), in: g), .accept)
    }

    // MARK: - Structural invariants

    func testHardProtectionAndUserFinalAreRefused() {
        var g = graph("call loadModel now", annotated: true)
        XCTAssertFalse(gate.judge(edit("loadModel", in: g, .replace("load model"),
                                       source: .alias, confidence: 1.0), in: g).isAccepted)

        g.promote([id("now", in: g)], to: .userFinal)
        XCTAssertFalse(gate.judge(edit("now", in: g, .delete,
                                       source: .filler, confidence: 1.0), in: g).isAccepted)
    }

    func testStaleTargetIsKeptRatherThanCrashing() {
        var g = graph("um hello")
        let target = id("um", in: g)
        let removal = TranscriptEdit(target: target, operation: .delete, source: .filler,
                                     confidence: 1.0, reason: "test")
        XCTAssertTrue(g.apply(removal))
        XCTAssertFalse(gate.judge(removal, in: g).isAccepted)
    }

    // MARK: - Application

    func testApplyReturnsOnlyWhatSurvived() {
        var g = graph("um do not deploy this")
        let proposals = [
            edit("um", in: g, .delete, source: .filler, confidence: 1.0),
            edit("not", in: g, .delete, source: .filler, confidence: 1.0),
        ]
        let accepted = gate.apply(proposals, to: &g)
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(g.render(), " do not deploy this")
    }

    // MARK: - Engine independence

    /// The gate must be blind to ASR evidence, or the `ASRCapabilities = []` column stops
    /// matching the full-evidence one and the whole engine-independence claim goes with it.
    func testVerdictsAreIdenticalWithAndWithoutEvidence() {
        let words = [
            WhisperStreamWord(text: "um", tokens: [1], start: 0, end: 0.2, probability: 0.05),
            WhisperStreamWord(text: " deploy", tokens: [2], start: 0.2, end: 0.6, probability: 0.99),
            WhisperStreamWord(text: " now", tokens: [3], start: 0.6, end: 0.9, probability: 0.10),
        ]
        let rich = TokenGraph.from(words: words)
        let bare = TokenGraph.from(text: "um deploy now")
        XCTAssertEqual(rich.capabilities, .whisperCpp)
        XCTAssertEqual(bare.capabilities, [])

        for word in ["um", "deploy", "now"] {
            for source in [EditSource.filler, .alias, .editorModel] {
                for confidence in [Float(0.5), 0.8, 0.95, 1.0] {
                    let operations: [EditOperation] = [.delete, .replace("X"), .insertAfter(".")]
                    for operation in operations {
                        let a = gate.judge(edit(word, in: rich, operation, source: source,
                                                confidence: confidence), in: rich)
                        let b = gate.judge(edit(word, in: bare, operation, source: source,
                                                confidence: confidence), in: bare)
                        XCTAssertEqual(a, b, "\(word)/\(source)/\(confidence) diverged on evidence")
                    }
                }
            }
        }
    }
}
