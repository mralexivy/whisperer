//
//  EditingModelTests.swift
//  WhispererTests
//
//  The editing seam behind the gate: a tagger with no weights must be silent, a tagger with
//  weights must still be refused until it is calibrated, and a generative model must not be
//  able to launder a bad edit through the diff.
//

import XCTest
@testable import whisperer

final class EditingModelTests: XCTestCase {

    // MARK: - Scripted runtime

    /// A runtime that returns whatever the test says, for the tokens the test names.
    ///
    /// Exists so the "stub emits nothing" test cannot pass vacuously: the same policy, handed
    /// a confident detection and a confident operation, does emit an edit.
    private struct ScriptedEditingRuntime: TextEditingModelRuntime {
        /// Token text → the logits to return for it. Anything unnamed gets neutral logits.
        let scripted: [String: EditingTokenLogits]

        var isLoaded: Bool { true }
        func load() async throws {}
        func unload() async {}

        func encode(_ pieces: [String]) async throws -> EditingRuntimeOutput {
            guard let shape = EditingSequenceShape.fitting(pieces.count) else {
                throw EditingRuntimeError.sequenceTooLong(pieces.count)
            }
            return EditingRuntimeOutput(shape: shape,
                                        tokens: pieces.map { scripted[$0] ?? .neutral })
        }
    }

    /// Logits that make the named label overwhelmingly likely in each named head, and the
    /// index-0 label overwhelmingly likely everywhere else.
    ///
    /// Unnamed heads are pinned to index 0 rather than left flat because the veto heads treat
    /// a flat distribution as "undecided about risk", which blocks — correct in production,
    /// useless in a test that wants to reach the code after the vetoes.
    private static func logits(_ decisions: [EditingHead: Int],
                               raw: [EditingHead: [Float]] = [:]) -> EditingTokenLogits {
        var table: [EditingHead: [Float]] = [:]
        for head in EditingHead.allCases {
            if let explicit = raw[head] {
                table[head] = explicit
                continue
            }
            var values = [Float](repeating: 0, count: head.labelCount)
            values[decisions[head] ?? 0] = 12  // ~1.0 after softmax against zeros
            table[head] = values
        }
        return EditingTokenLogits(logits: table)
    }

    // MARK: - Stub runtime

    func testStubRuntimeEmitsNoEdits() async {
        let graph = TokenGraph.from(text: "so um we should ship this tomorrow")
        let model = MMBERTEditingModel(runtime: StubEditingRuntime())
        let edits = await model.propose(graph.tokens, context: EditContext())
        XCTAssertTrue(edits.isEmpty, "an all-KEEP runtime must propose nothing")
    }

    func testStubRuntimeEmitsNoEditsInEveryScript() async {
        let model = MMBERTEditingModel(runtime: StubEditingRuntime())
        for text in ["ship it tomorrow",
                     "אני חושב שזה עובד",
                     "мы используем Redis для очереди",
                     "בוא נריץ docker run и посмотрим the logs"] {
            let graph = TokenGraph.from(text: text)
            let edits = await model.propose(graph.tokens, context: EditContext())
            XCTAssertTrue(edits.isEmpty, "unexpected edits for \(text)")
        }
    }

    func testUnloadedRuntimeProposesNothing() async {
        let model = MMBERTEditingModel(runtime: StubEditingRuntime(failsToLoad: true))
        let graph = TokenGraph.from(text: "ship it tomorrow")
        let edits = await model.propose(graph.tokens, context: EditContext())
        XCTAssertTrue(edits.isEmpty)
    }

    // MARK: - Tagging policy

    func testConfidentRuntimeProposesAnEditButTheGateRefusesIt() async {
        let graph = TokenGraph.from(text: "we ship tomorrow")
        let runtime = ScriptedEditingRuntime(scripted: [
            "tomorrow": Self.logits([
                .error: EditingErrorLabel.incorrect.rawValue,
                .operation: EditingOperationLabel.insertAfter.rawValue,
                .punctuation: EditingPunctuationLabel.period.rawValue,
            ]),
        ])
        let model = MMBERTEditingModel(runtime: runtime)
        let edits = await model.propose(graph.tokens, context: EditContext())

        XCTAssertEqual(edits.count, 1, "the policy must be capable of proposing")
        XCTAssertEqual(edits[0].source, .editorModel)
        XCTAssertEqual(graph.token(edits[0].target)?.effectiveText, "tomorrow")
        if case .insertAfter(let text) = edits[0].operation {
            XCTAssertEqual(text, ".")
        } else {
            XCTFail("expected an insertAfter, got \(edits[0].operation)")
        }

        // …and none of it applies, because nothing has been calibrated yet. This is the
        // designed M2/M3 state: a model-sourced edit auto-applies only at ≥99% measured
        // precision, and `maximumConfidence` sits below the floor until that exists.
        XCTAssertLessThan(edits[0].confidence, ConfidenceGate.floor(for: .editorModel))
        var working = graph
        let accepted = ConfidenceGate().apply(edits, to: &working)
        XCTAssertTrue(accepted.isEmpty)
        XCTAssertEqual(working.render(), "we ship tomorrow")
    }

    func testKeepBiasSuppressesAMarginalProposal() async {
        // The operation head prefers `insertAfter`, but only by one logit. A plain argmax would
        // take it; the explicit KEEP bias is what does not.
        var marginal = [Float](repeating: 0, count: EditingHead.operation.labelCount)
        marginal[EditingOperationLabel.insertAfter.rawValue] = 1.0

        let runtime = ScriptedEditingRuntime(scripted: [
            "tomorrow": Self.logits([
                .error: EditingErrorLabel.incorrect.rawValue,
                .punctuation: EditingPunctuationLabel.period.rawValue,
            ], raw: [.operation: marginal]),
        ])
        let model = MMBERTEditingModel(runtime: runtime)
        let graph = TokenGraph.from(text: "we ship tomorrow")
        let edits = await model.propose(graph.tokens, context: EditContext())
        XCTAssertTrue(edits.isEmpty)
    }

    func testSemanticRiskVetoesAnOtherwiseConfidentEdit() async {
        let graph = TokenGraph.from(text: "we ship tomorrow")
        let runtime = ScriptedEditingRuntime(scripted: [
            "tomorrow": Self.logits([
                .error: EditingErrorLabel.incorrect.rawValue,
                .operation: EditingOperationLabel.insertAfter.rawValue,
                .punctuation: EditingPunctuationLabel.period.rawValue,
                .semanticRisk: EditingRiskLabel.risky.rawValue,
            ]),
        ])
        let model = MMBERTEditingModel(runtime: runtime)
        let edits = await model.propose(graph.tokens, context: EditContext())
        XCTAssertTrue(edits.isEmpty, "a risky edit is refused whatever else it scored")
    }

    /// Hebrew has no case, so the casing head's transform is the identity there and the policy
    /// drops the proposal rather than emitting a replace that changes nothing.
    func testCaselessScriptProducesNoRecasing() async {
        let graph = TokenGraph.from(text: "אני חושב שזה עובד")
        let runtime = ScriptedEditingRuntime(scripted: [
            "אני": Self.logits([
                .error: EditingErrorLabel.incorrect.rawValue,
                .operation: EditingOperationLabel.replace.rawValue,
                .casing: EditingCasingLabel.capitalize.rawValue,
            ]),
        ])
        let model = MMBERTEditingModel(runtime: runtime)
        let edits = await model.propose(graph.tokens, context: EditContext())
        XCTAssertTrue(edits.isEmpty)
    }

    // MARK: - Fixed shapes

    func testSequenceShapesAreTheCompiledOnes() {
        XCTAssertEqual(EditingSequenceShape.fitting(1), .short)
        XCTAssertEqual(EditingSequenceShape.fitting(32), .short)
        XCTAssertEqual(EditingSequenceShape.fitting(33), .medium)
        XCTAssertEqual(EditingSequenceShape.fitting(128), .long)
        XCTAssertNil(EditingSequenceShape.fitting(129))
    }

    func testEveryHeadKeepsAtIndexZero() {
        // The neutral-logits contract: all-zero logits must mean KEEP in every head, which is
        // only true while every head's do-nothing label is index 0.
        XCTAssertEqual(EditingErrorLabel.correct.rawValue, 0)
        XCTAssertEqual(EditingOperationLabel.keep.rawValue, 0)
        XCTAssertEqual(EditingPunctuationLabel.none.rawValue, 0)
        XCTAssertEqual(EditingCasingLabel.keep.rawValue, 0)
        XCTAssertEqual(EditingDisfluencyLabel.keep.rawValue, 0)
        XCTAssertEqual(EditingStructureLabel.none.rawValue, 0)
        XCTAssertEqual(EditingLanguageLabel.same.rawValue, 0)
        XCTAssertEqual(EditingRiskLabel.safe.rawValue, 0)
        for head in EditingHead.allCases {
            XCTAssertEqual(EditingTokenLogits.neutral.values(for: head)?.count, head.labelCount)
        }
    }

    // MARK: - LLM edits through the gate

    func testGateRefusesLLMEditsThatMangleAHardSpan() {
        var graph = TokenGraph.from(text: "email me at alex@example.com tomorrow")
        ProtectionDetector.annotate(&graph)

        let edits = TranscriptDiff.edits(from: graph,
                                         to: "Email me at alex@example.org tomorrow.",
                                         source: .llm,
                                         confidence: 1.0)
        XCTAssertFalse(edits.isEmpty, "the diff must actually see the mangling")

        var working = graph
        ConfidenceGate().apply(edits, to: &working)
        XCTAssertTrue(working.render().contains("alex@example.com"),
                      "a hard-protected address must survive an LLM rewrite of it")
    }

    func testGateRefusesLLMEditsBelowTheFloor() {
        let graph = TokenGraph.from(text: "we ship tomorrow")
        let edits = TranscriptDiff.edits(from: graph,
                                         to: "We ship tomorrow.",
                                         source: .llm,
                                         confidence: LLMEditingModel.unclaimedConfidence)
        XCTAssertFalse(edits.isEmpty)

        var working = graph
        let accepted = ConfidenceGate().apply(edits, to: &working)
        XCTAssertTrue(accepted.isEmpty)
        XCTAssertEqual(working.render(), "we ship tomorrow")
    }

    func testUnclaimedConfidenceStaysBelowTheLLMFloor() {
        // If this ever passes by accident, LLM edits start auto-applying with no calibration
        // behind them. It is the tripwire on the number, not a restatement of it.
        XCTAssertLessThan(LLMEditingModel.unclaimedConfidence, ConfidenceGate.floor(for: .llm))
    }

    // MARK: - Prompt fidelity

    func testCorrectPromptIsCarriedThroughUnmodified() {
        let config = LLMEditingModel.PromptConfig.correct
        guard let mode = AIMode.builtInDefault(for: AIMode.correctModeId) else {
            return XCTFail("Correct mode missing")
        }

        // Every line of the mode's own prompt above the envelope has to survive the split. The
        // prompt's worked examples alone are worth 0.11 balanced score on the gold corpus, and
        // a split that quietly ate the tail of it would be invisible in behaviour and expensive
        // in quality — so this compares against the mode rather than against a copy of its text.
        let body = mode.prompt.components(separatedBy: "[INPUT]").first ?? ""
        for line in body.split(whereSeparator: \.isNewline) where !line.isEmpty {
            XCTAssertTrue(config.systemPrompt.contains(line), "prompt lost: \(line)")
        }
        XCTAssertTrue(config.systemPrompt.contains("before:"), "the worked examples are the gain")
        XCTAssertFalse(config.systemPrompt.contains("{transcript}"))
        // The envelope belongs in the user message, so no line may *be* a tag. The tags are
        // still named in prose — the prompt's first sentence says the text arrives between them,
        // which is how the model knows where to look, and the appended sentence tells it not to
        // echo them. Counting occurrences would conflate those with the envelope; what matters
        // is that nothing is left for the model to fill in.
        XCTAssertTrue(config.systemPrompt.hasSuffix(
            "Do not include [INPUT] or [/INPUT] in your response."))
        for line in config.systemPrompt.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            XCTAssertNotEqual(trimmed, "[INPUT]", "the envelope survived the split")
            XCTAssertNotEqual(trimmed, "[/INPUT]", "the envelope survived the split")
        }
        XCTAssertEqual(config.temperature, mode.temperature)
        XCTAssertEqual(config.topP, mode.topP)
        XCTAssertEqual(config.maxTokensCap, mode.maxTokensCap)
    }

    func testStructuralTagsAreStrippedBeforeDiffing() {
        XCTAssertEqual(LLMEditingModel.stripStructuralTags("[INPUT]\nShip it.\n[/INPUT]"),
                       "Ship it.")
        XCTAssertEqual(LLMEditingModel.stripStructuralTags("Ship it.\n[/INPUT"), "Ship it.")
    }
}
