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

        // …and none of it applies. The context names no language, so the (language, class) cell
        // is `unmeasured` and the confidence is capped at `uncertifiedCeiling` — below every
        // floor the gate can apply, including the cosmetic one this edit would otherwise get.
        XCTAssertLessThanOrEqual(edits[0].confidence,
                                 MMBERTEditingModel.Calibration.uncalibrated.uncertifiedCeiling)
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

    // MARK: - Risk-tiered floors

    private func graph(_ text: String, annotated: Bool = false) -> TokenGraph {
        var graph = TokenGraph.from(text: text)
        if annotated { ProtectionDetector.annotate(&graph) }
        return graph
    }

    /// A model-sourced edit against the named word, at the named confidence.
    private func modelEdit(_ word: String,
                           in graph: TokenGraph,
                           _ operation: EditOperation,
                           _ confidence: Float) -> TranscriptEdit {
        guard let id = graph.tokens.first(where: { $0.effectiveText == word })?.id else {
            fatalError("no token '\(word)'")
        }
        return TranscriptEdit(target: id, operation: operation, source: .editorModel,
                              confidence: confidence, reason: "test")
    }

    /// The whole point of the tiering, in one test: at the *same* confidence, an edit that can
    /// change what the sentence means is refused and an edit that cannot is applied.
    func testWordSubstitutionIsRefusedAtAConfidencePunctuationClears() {
        let gate = ConfidenceGate(language: .english)
        let g = graph("we ship tomorrow")

        let substitution = gate.judge(modelEdit("ship", in: g, .replace("skip"), 0.96), in: g)
        XCTAssertFalse(substitution.isAccepted,
                       "0.96 is nowhere near the 0.99 a word substitution needs")

        // en/punct `.`: P = 1.0000, 0 wrong out of 88, LCB95 0.9665 (CALIBRATION.md §2).
        XCTAssertEqual(gate.judge(modelEdit("tomorrow", in: g, .insertAfter("."), 0.96), in: g),
                       .accept)
    }

    /// A deny-list, not a threshold — so raising confidence cannot buy it.
    func testCommaSemicolonAndColonInsertionAreRefusedByConstruction() {
        let gate = ConfidenceGate(language: .english)
        let g = graph("we ship tomorrow")

        for mark in [",", ";", ":"] {
            let verdict = gate.judge(modelEdit("ship", in: g, .insertAfter(mark), 0.999), in: g)
            XCTAssertFalse(verdict.isAccepted, "'\(mark)' inserted at 0.999")
            if case .keep(let reason) = verdict {
                XCTAssertTrue(reason.contains("may never insert"), reason)
            }
        }
        // Not a blanket ban on insertion: the period is the class that measured 0/88 wrong.
        XCTAssertEqual(gate.judge(modelEdit("tomorrow", in: g, .insertAfter("."), 0.999), in: g),
                       .accept)
    }

    /// The tier of a `.replace` is computed from the text, never taken from the edit's `reason`.
    func testCaseTransformIsCosmeticAndALetterChangeIsNot() {
        XCTAssertEqual(ConfidenceGate.editClass(of: .replace("Deploy"), originalText: "deploy"),
                       .cosmetic)
        XCTAssertEqual(ConfidenceGate.editClass(of: .replace("GITHUB"), originalText: "github"),
                       .cosmetic)
        XCTAssertEqual(ConfidenceGate.editClass(of: .replace("destroy"), originalText: "deploy"),
                       .substitution)
        // One letter apart is still a different word.
        XCTAssertEqual(ConfidenceGate.editClass(of: .replace("Deployed"), originalText: "deploy"),
                       .substitution)

        let gate = ConfidenceGate(language: .english)
        let g = graph("deploy the service")
        // Casing is the cosmetic tier: 0.96 clears its gate. (What the *model* measures on real
        // ASR — en/case ALL P = 0.9149, LCB95 0.8517 — is why no cell is enabled to reach here.)
        XCTAssertEqual(gate.judge(modelEdit("deploy", in: g, .replace("Deploy"), 0.96), in: g),
                       .accept)
        XCTAssertFalse(gate.judge(modelEdit("deploy", in: g, .replace("Destroy"), 0.96),
                                  in: g).isAccepted)
    }

    /// Filler deletion sits between the two: bounded blast radius, but it does remove a token.
    func testFillerDeletionIsItsOwnTier() {
        let gate = ConfidenceGate(language: .english)
        let g = graph("um we ship tomorrow")

        XCTAssertEqual(ConfidenceGate.editClass(of: .delete, originalText: "um"), .fillerDeletion)
        XCTAssertEqual(ConfidenceGate.editClass(of: .delete, originalText: "tomorrow"),
                       .substitution)

        XCTAssertFalse(gate.judge(modelEdit("um", in: g, .delete, 0.96), in: g).isAccepted)
        XCTAssertEqual(gate.judge(modelEdit("um", in: g, .delete, 0.975), in: g), .accept)
        // Deleting a content word is a substitution however confident the model is at 0.975.
        XCTAssertFalse(gate.judge(modelEdit("tomorrow", in: g, .delete, 0.975), in: g).isAccepted)
    }

    /// Every relaxation is licensed by an English measurement, so it is available in English and
    /// nowhere else. `CALIBRATION.md` §5: he and ru "should be treated as unmeasured".
    func testUnmeasuredLanguagesGetNoRelaxation() {
        let english = graph("we ship tomorrow")
        for language: TranscriptionLanguage? in [nil, .hebrew, .russian, .german] {
            let gate = ConfidenceGate(language: language)
            XCTAssertFalse(gate.judge(modelEdit("tomorrow", in: english, .insertAfter("."), 0.96),
                                      in: english).isAccepted,
                           "cosmetic tier leaked into \(String(describing: language))")
        }
    }

    /// Nothing here may make a word substitution easier to apply than it was.
    func testSubstitutionFloorIsUnchangedByTheTiering() {
        for language: TranscriptionLanguage? in [nil, .english, .hebrew, .russian] {
            XCTAssertEqual(ConfidenceGate.floor(for: .editorModel,
                                                operation: .replace("destroy"),
                                                originalText: "deploy",
                                                language: language),
                           ConfidenceGate.floor(for: .editorModel))
        }
        // …and the other sources keep their source-level floor whatever the operation is.
        for source in [EditSource.alias, .filler, .normalization, .listFormatting, .llm] {
            for operation in [EditOperation.delete, .replace("X"), .insertAfter(".")] {
                XCTAssertEqual(ConfidenceGate.floor(for: source, operation: operation,
                                                    originalText: "um", language: .english),
                               ConfidenceGate.floor(for: source))
            }
        }
    }

    /// The tiering must not weaken protection: a hard span refuses every tier at full confidence.
    func testHardProtectionRefusesEveryTier() {
        let g = graph("email me at alex@example.com now", annotated: true)

        // The word tokenizer splits on `@` and `.`, so the address is five tokens — `alex`, `@`,
        // `example`, `.`, `com` — not one. That is the right shape: `ProtectionDetector` annotates
        // by *range*, so what has to hold is that every piece the span covers is hard, and that is
        // stronger than one fused token would be. A test asserting a single token would be
        // asserting the tokenizer's granularity rather than the protection guarantee.
        let pieces = ["alex", "@", "example", ".", "com"]
        for piece in pieces {
            XCTAssertEqual(g.tokens.first { $0.effectiveText == piece }?.protection, .hard,
                           "'\(piece)' is inside the address and must be hard-protected")
        }

        let gate = ConfidenceGate(language: .english)
        let operations: [EditOperation] = [.insertAfter("."),
                                           .replace("Alex"),
                                           .delete]
        for piece in pieces {
            for operation in operations {
                let verdict = gate.judge(modelEdit(piece, in: g, operation, 1.0), in: g)
                XCTAssertFalse(verdict.isAccepted, "hard span '\(piece)' edited by \(operation)")
                if case .keep(let reason) = verdict {
                    XCTAssertTrue(reason.contains("hard-protected"), reason)
                }
            }
        }
    }

    /// The relationship that makes "absence never means permitted" true.
    func testUncertifiedCeilingSitsBelowEveryFloor() {
        let ceiling = MMBERTEditingModel.Calibration.uncalibrated.uncertifiedCeiling
        let operations: [(EditOperation, String)] = [(.insertAfter("."), "tomorrow"),
                                                     (.replace("Ship"), "ship"),
                                                     (.delete, "um"),
                                                     (.replace("skip"), "ship")]
        for language in [TranscriptionLanguage.english, .hebrew, .russian] {
            for (operation, word) in operations {
                XCTAssertLessThan(ceiling,
                                  ConfidenceGate.floor(for: .editorModel, operation: operation,
                                                       originalText: word, language: language),
                                  "\(operation) on '\(word)' in \(language)")
            }
        }
    }

    // MARK: - Per-language, per-class calibration

    private static func table(_ json: String) throws -> MMBERTCalibrationTable {
        try MMBERTCalibrationTable.decode(from: Data(json.utf8))
    }

    private static func cellJSON(language: String,
                                 head: String,
                                 action: String,
                                 threshold: String,
                                 enabled: Bool) -> String {
        """
        "\(language)/\(head)/\(action)": {"language": "\(language)", "head": "\(head)",
          "action": "\(action)", "threshold": \(threshold), "precision": 1.0,
          "support": 88, "precision_lcb95": 0.9665, "enabled": \(enabled)}
        """
    }

    private static func calibration(_ table: MMBERTCalibrationTable)
        -> MMBERTEditingModel.Calibration {
        let base = MMBERTEditingModel.Calibration.uncalibrated
        return MMBERTEditingModel.Calibration(keepBias: base.keepBias,
                                              errorFloor: base.errorFloor,
                                              actionFloor: base.actionFloor,
                                              vetoCeiling: base.vetoCeiling,
                                              uncertifiedCeiling: base.uncertifiedCeiling,
                                              table: table)
    }

    /// A period proposal for the last word of each language's sample sentence.
    private func periodRuntime(_ words: [String]) -> ScriptedEditingRuntime {
        var scripted: [String: EditingTokenLogits] = [:]
        for word in words {
            scripted[word] = Self.logits([
                .error: EditingErrorLabel.incorrect.rawValue,
                .operation: EditingOperationLabel.insertAfter.rawValue,
                .punctuation: EditingPunctuationLabel.period.rawValue,
            ])
        }
        return ScriptedEditingRuntime(scripted: scripted)
    }

    private static let samples: [(TranscriptionLanguage, String, String)] = [
        (.english, "we ship tomorrow", "tomorrow"),
        (.hebrew, "אנחנו משיקים מחר", "מחר"),
        (.russian, "мы выпускаем завтра", "завтра"),
    ]

    /// A disabled cell produces **no proposal at all** — not a quiet one. An unmeasured class has
    /// to be unreachable, because "unlikely to apply" is a property of a number someone can
    /// change and "not proposed" is a property of the code.
    func testDisabledCellProducesZeroProposalsInEveryLanguage() async throws {
        let cells = Self.samples.map {
            Self.cellJSON(language: $0.0.rawValue, head: "punct", action: ".",
                          threshold: "0.995", enabled: false)
        }
        let table = try Self.table("{\"schema\": 2, \"cells\": {\(cells.joined(separator: ","))}}")
        let model = MMBERTEditingModel(runtime: periodRuntime(Self.samples.map(\.2)),
                                       calibration: Self.calibration(table))

        for (language, text, word) in Self.samples {
            let graph = TokenGraph.from(text: text)
            let edits = await model.propose(graph.tokens,
                                            context: EditContext(language: language))
            XCTAssertTrue(edits.isEmpty,
                          "\(language.rawValue) proposed \(edits.count) edits for '\(word)' from "
                            + "a disabled cell")
        }
    }

    /// …and an enabled cell reports a confidence that clears its tier's floor and applies.
    func testEnabledCellProducesAnApplyingProposal() async throws {
        let table = try Self.table("""
        {"schema": 2, "cells": {\(Self.cellJSON(language: "en", head: "punct", action: ".",
                                                threshold: "0.99", enabled: true))}}
        """)
        let model = MMBERTEditingModel(runtime: periodRuntime(["tomorrow"]),
                                       calibration: Self.calibration(table))
        var graph = TokenGraph.from(text: "we ship tomorrow")
        let edits = await model.propose(graph.tokens, context: EditContext(language: .english))

        XCTAssertEqual(edits.count, 1)
        XCTAssertGreaterThanOrEqual(edits[0].confidence,
                                    ConfidenceGate.floor(for: .editorModel,
                                                         operation: edits[0].operation,
                                                         originalText: "tomorrow",
                                                         language: .english))
        let accepted = ConfidenceGate(language: .english).apply(edits, to: &graph)
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(graph.render(), "we ship tomorrow.")

        // The same enabled cell says nothing about Hebrew, which stays unmeasured and capped.
        var hebrew = TokenGraph.from(text: "אנחנו משיקים מחר")
        let model2 = MMBERTEditingModel(runtime: periodRuntime(["מחר"]),
                                        calibration: Self.calibration(table))
        let hebrewEdits = await model2.propose(hebrew.tokens,
                                               context: EditContext(language: .hebrew))
        XCTAssertEqual(hebrewEdits.count, 1)
        XCTAssertTrue(ConfidenceGate(language: .hebrew).apply(hebrewEdits, to: &hebrew).isEmpty)
    }

    /// A missing cell keeps the current behaviour: the proposal exists so the benchmark can count
    /// it, and it cannot apply in any language.
    func testMissingCellProposesButCannotApply() async {
        let model = MMBERTEditingModel(runtime: periodRuntime(Self.samples.map(\.2)),
                                       calibration: Self.calibration(.empty))
        for (language, text, _) in Self.samples {
            var graph = TokenGraph.from(text: text)
            let edits = await model.propose(graph.tokens,
                                            context: EditContext(language: language))
            XCTAssertEqual(edits.count, 1, "\(language.rawValue)")
            XCTAssertLessThanOrEqual(
                edits[0].confidence,
                MMBERTEditingModel.Calibration.uncalibrated.uncertifiedCeiling)
            XCTAssertTrue(ConfidenceGate(language: language).apply(edits, to: &graph).isEmpty)
        }
    }

    /// The shipped file must decode under the schema this build reads, and the literal baked into
    /// the binary must never be more permissive than it.
    ///
    /// One-directional on purpose: a calibration run that *enables* a cell the literal still has
    /// disabled is a regeneration this test should not block, only a literal claiming more than
    /// the measurement is a failure.
    func testBakedTableIsNoLooserThanTheCalibrationFile() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/mmbert/thresholds-calibrated-wispr.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("thresholds-calibrated-wispr.json absent")
        }
        let measured = try MMBERTCalibrationTable.decode(from: Data(contentsOf: url))
        XCTAssertFalse(measured.cells.isEmpty, "the file decoded to nothing")

        for (key, baked) in MMBERTCalibrationTable.measured.cells where baked.enabled {
            guard let cell = measured.cells[key] else {
                return XCTFail("\(key) is enabled in the binary and absent from the file")
            }
            XCTAssertTrue(cell.enabled, "\(key) is enabled in the binary and disabled in the file")
            XCTAssertGreaterThanOrEqual(baked.threshold ?? 0, cell.threshold ?? 0,
                                        "\(key) is baked at a looser threshold than measured")
        }
    }

    /// An `enabled` cell with no operating point is a broken file, and a broken file must not
    /// open an edit class.
    func testEnabledCellWithoutAThresholdIsForbidden() throws {
        let table = try Self.table("""
        {"schema": 2, "cells": {\(Self.cellJSON(language: "en", head: "punct", action: ".",
                                                threshold: "null", enabled: true))}}
        """)
        XCTAssertEqual(table.verdict(language: "en", head: .punct, action: "."), .forbidden)
        XCTAssertEqual(table.verdict(language: "en", head: .punct, action: ","), .unmeasured)
        XCTAssertEqual(table.verdict(language: nil, head: .punct, action: "."), .unmeasured)
    }

    func testUnsupportedSchemaIsRejectedRatherThanPartiallyRead() {
        XCTAssertThrowsError(try Self.table("{\"schema\": 99, \"cells\": {}}"))
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
