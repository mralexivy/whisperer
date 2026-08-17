//
//  MMBERTEditingModel.swift
//  Whisperer
//
//  GECToR-style token-level edit tagging: one encoder pass, one edit per token at most.
//
//  A discriminative tagger instead of a generative model for the reason the whole plan exists
//  — it *cannot* rewrite, reorder, translate or invent. Its entire output vocabulary is
//  "which of these operations applies to this token", so the catastrophic failure of a 4B
//  correction pass (fluent, confident, and about a different sentence) is not in its range.
//
//  Three things here are load-bearing and are not stylistic choices:
//
//  1. **A separate error-detection head, consulted first.** In a corrected-transcript corpus
//     the overwhelming majority of tokens are KEEP, so a single tagging head trained on that
//     distribution learns to say KEEP and nothing else. Detection first, tagging second, is
//     what keeps the tagging heads sharp.
//  2. **An explicit KEEP bias, added in logit space.** Precision is the only metric that
//     matters here — a missed correction costs nothing the user notices, a wrong one costs the
//     user's own words — so the decision threshold is deliberately not the argmax.
//  3. **The vetoes are vetoes.** Language drift and semantic risk cannot be traded against a
//     high operation score. `ConfidenceGate` enforces the script rule again independently;
//     doing it in both places means neither is the single point of failure.
//
//  **No weights exist.** Against `StubEditingRuntime` this type emits exactly zero edits, and
//  that is a test. When weights do exist, every threshold below is a calibration slot to be
//  measured per language per action at `ASRCapabilities = []` — not tuned until the output
//  looks nice.
//

import Foundation

struct MMBERTEditingModel: EditingModel {

    // MARK: - Calibration

    /// Thresholds, all of them calibration slots. The defaults are chosen so that an
    /// uncalibrated deployment is silent rather than enthusiastic.
    struct Calibration: Sendable {
        /// Added to the KEEP logit of the operation head before softmax. Two logits is roughly
        /// "the model must be about 7× more confident in the edit than in leaving it alone".
        let keepBias: Float
        /// Minimum P(incorrect) from the detection head.
        let errorFloor: Float
        /// Minimum probability for the chosen operation, and for the action head that supplies
        /// its content.
        let actionFloor: Float
        /// Maximum tolerated P(drifted) / P(risky). Above this the edit is dropped whatever it
        /// scored elsewhere.
        let vetoCeiling: Float
        /// Cap on the confidence reported to the gate.
        ///
        /// Below `ConfidenceGate.floor(for: .editorModel)` on purpose: until per-language,
        /// per-action precision has actually been measured at ≥99%, a model-sourced edit must
        /// not auto-apply. Raising this is the final step of calibration, not a shortcut past
        /// it, and until then this type produces candidates for the benchmark to count.
        let maximumConfidence: Float

        static let uncalibrated = Calibration(keepBias: 2.0,
                                              errorFloor: 0.90,
                                              actionFloor: 0.95,
                                              vetoCeiling: 0.10,
                                              maximumConfidence: 0.98)
    }

    // MARK: - State

    let runtime: any TextEditingModelRuntime
    let calibration: Calibration

    init(runtime: any TextEditingModelRuntime,
         calibration: Calibration = .uncalibrated) {
        self.runtime = runtime
        self.calibration = calibration
    }

    // MARK: - EditingModel

    func propose(_ tokens: [TranscriptToken], context: EditContext) async -> [TranscriptEdit] {
        guard runtime.isLoaded else { return [] }

        // Whitespace never reaches the encoder: a sub-word vocabulary has no representation for
        // it, and every operation the heads can express targets a word or a mark. Deleting a
        // disfluency therefore leaves two adjacent whitespace tokens, which `TranscriptNormalizer`
        // collapses later in the pipeline — the tagger does not try to do that job itself.
        let candidates = tokens.filter { $0.kind != .whitespace }
        guard !candidates.isEmpty else { return [] }

        var edits: [TranscriptEdit] = []
        let window = EditingSequenceShape.long.rawValue
        var start = 0

        while start < candidates.count {
            let slice = Array(candidates[start..<min(start + window, candidates.count)])
            do {
                let output = try await runtime.encode(slice.map(\.effectiveText))
                guard output.tokens.count == slice.count else {
                    // A runtime that returns a different number of positions than it was given
                    // has lost the alignment, and an edit applied to the wrong token is worse
                    // than no edit. Abandon the whole pass rather than the current window.
                    Logger.error("Editing runtime returned \(output.tokens.count) positions for "
                                 + "\(slice.count) tokens", subsystem: .transcription)
                    return []
                }
                for (token, logits) in zip(slice, output.tokens) {
                    if let edit = proposal(for: token, logits: logits) { edits.append(edit) }
                }
            } catch {
                Logger.warning("Editing runtime failed: \(error.localizedDescription)",
                               subsystem: .transcription)
                return edits
            }
            start += window
        }

        if !edits.isEmpty {
            Logger.debug("Editor model: \(edits.count) candidate edits over "
                         + "\(candidates.count) tokens (\(context.capabilities.tierLabel) tier)",
                         subsystem: .transcription)
        }
        return edits
    }

    // MARK: - Tagging policy

    private func proposal(for token: TranscriptToken,
                          logits: EditingTokenLogits) -> TranscriptEdit? {
        guard let errorLogits = logits.values(for: .error),
              let operationLogits = logits.values(for: .operation) else { return nil }

        let errorProbability = Self.softmax(errorLogits)[EditingErrorLabel.incorrect.rawValue]
        guard errorProbability >= calibration.errorFloor else { return nil }

        var biased = operationLogits
        biased[EditingOperationLabel.keep.rawValue] += calibration.keepBias
        let operationProbabilities = Self.softmax(biased)
        guard let choice = Self.argmax(operationProbabilities),
              choice != EditingOperationLabel.keep.rawValue,
              operationProbabilities[choice] >= calibration.actionFloor,
              let label = EditingOperationLabel(rawValue: choice) else { return nil }

        if vetoed(logits, head: .language, label: EditingLanguageLabel.drifted.rawValue) { return nil }
        if vetoed(logits, head: .semanticRisk, label: EditingRiskLabel.risky.rawValue) { return nil }

        guard let action = self.action(for: label, token: token, logits: logits) else { return nil }

        let confidence = min(calibration.maximumConfidence,
                             errorProbability * operationProbabilities[choice] * action.probability)

        return TranscriptEdit(target: token.id,
                              operation: action.operation,
                              source: .editorModel,
                              confidence: confidence,
                              reason: "editor model: \(action.description)")
    }

    private struct Action {
        let operation: EditOperation
        let probability: Float
        let description: String
    }

    /// Turn an operation label into the operation's actual content, from the head that owns it.
    ///
    /// The operation head says *that* something changes; it never says *what to*. Splitting it
    /// this way is what makes "punctuation is shipped, casing is not yet" expressible as a
    /// threshold on one head rather than as a retrained model.
    private func action(for label: EditingOperationLabel,
                        token: TranscriptToken,
                        logits: EditingTokenLogits) -> Action? {
        switch label {
        case .keep:
            return nil

        case .delete:
            // A delete is only ever a disfluency here. Deleting a token for an unstated reason
            // is the edit class that silently drops content, so the disfluency head has to
            // assert it independently.
            guard let head = logits.values(for: .disfluency) else { return nil }
            let probabilities = Self.softmax(head)
            let drop = probabilities[EditingDisfluencyLabel.drop.rawValue]
            guard drop >= calibration.actionFloor else { return nil }
            return Action(operation: .delete,
                          probability: drop,
                          description: "drop disfluency '\(token.effectiveText)'")

        case .insertAfter:
            guard let head = logits.values(for: .punctuation) else { return nil }
            let probabilities = Self.softmax(head)
            guard let index = Self.argmax(probabilities),
                  probabilities[index] >= calibration.actionFloor,
                  let mark = EditingPunctuationLabel(rawValue: index)?.mark else { return nil }
            return Action(operation: .insertAfter(mark),
                          probability: probabilities[index],
                          description: "insert '\(mark)' after '\(token.effectiveText)'")

        case .replace:
            // The only replacement a tagger without an output vocabulary can make is a case
            // transform. In a caseless script the transform is the identity, so Hebrew falls
            // out as "no edit" here rather than needing a language check.
            guard let head = logits.values(for: .casing) else { return nil }
            let probabilities = Self.softmax(head)
            guard let index = Self.argmax(probabilities),
                  index != EditingCasingLabel.keep.rawValue,
                  probabilities[index] >= calibration.actionFloor,
                  let casing = EditingCasingLabel(rawValue: index) else { return nil }
            let text = Self.applyCasing(casing, to: token.effectiveText)
            guard text != token.effectiveText else { return nil }
            return Action(operation: .replace(text),
                          probability: probabilities[index],
                          description: "recase '\(token.effectiveText)' → '\(text)'")
        }
    }

    /// A veto head is read against a ceiling, not an argmax, so an *undecided* head blocks: a
    /// flat distribution puts 0.5 on "risky", which is far above the ceiling. That asymmetry is
    /// intentional — "the model has no opinion about whether this changes the meaning" is not a
    /// licence to change it. A head the runtime does not emit at all cannot veto, because that
    /// is a contract mismatch rather than a model opinion, and it is already caught by the
    /// width check in `EditingTokenLogits.values(for:)` failing the heads that do propose.
    private func vetoed(_ logits: EditingTokenLogits, head: EditingHead, label: Int) -> Bool {
        guard let values = logits.values(for: head) else { return false }
        return Self.softmax(values)[label] > calibration.vetoCeiling
    }

    // MARK: - Transforms

    /// `capitalize` upper-cases the first character and leaves the rest alone, rather than
    /// using `capitalized`, which lower-cases the remainder and would turn `API` into `Api` and
    /// `GitHub` into `Github` — silent damage to exactly the terms this app is dictated at.
    private static func applyCasing(_ casing: EditingCasingLabel, to text: String) -> String {
        switch casing {
        case .keep:
            return text
        case .lower:
            return text.lowercased()
        case .upper:
            return text.uppercased()
        case .capitalize:
            guard let first = text.first else { return text }
            return String(first).uppercased() + text.dropFirst()
        }
    }

    // MARK: - Numerics

    /// Max-subtracted softmax. The runtime returns logits from an FP16 graph, where an
    /// un-shifted exponential overflows well inside the range the model actually produces.
    static func softmax(_ logits: [Float]) -> [Float] {
        guard let maximum = logits.max() else { return [] }
        let exponentials = logits.map { expf($0 - maximum) }
        let total = exponentials.reduce(0, +)
        guard total > 0 else {
            return [Float](repeating: 1 / Float(max(1, logits.count)), count: logits.count)
        }
        return exponentials.map { $0 / total }
    }

    /// Index of the largest value, ties going to the lowest index — which is the KEEP label in
    /// every head, so a perfectly undecided model does nothing.
    static func argmax(_ values: [Float]) -> Int? {
        guard !values.isEmpty else { return nil }
        var best = 0
        for index in 1..<values.count where values[index] > values[best] { best = index }
        return best
    }
}
