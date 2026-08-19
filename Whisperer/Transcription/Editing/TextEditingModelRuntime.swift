//
//  TextEditingModelRuntime.swift
//  Whisperer
//
//  The deployment seam under `MMBERTEditingModel`: one encoder pass in, per-token head logits
//  out.
//
//  Separated from the model logic because the two have completely different failure modes and
//  completely different review criteria. The tagging policy — when a KEEP bias is enough, what
//  counts as a semantic-risk veto — is testable today against `StubEditingRuntime`. The
//  runtime is a Core ML / Core AI question that cannot be answered until weights exist, and
//  answering it early would mean shipping guesses about quantization as if they were decisions.
//
//  **Deployment shape, from the plan.** FP16, fixed sequence lengths 32 / 64 / 128, 8-bit
//  weight quantization. Palettization and W8A8 only after a profile says so, and `Linear` is
//  not to be rewritten as `Conv2d` before a profile says so either — that rewrite is folklore
//  that predates recent Core ML releases and it costs readability permanently.
//
//  **There is no Core ML implementation in this file, and that is deliberate.** The mmBERT
//  weights do not exist. A loader for a model that cannot be loaded is untestable code that
//  looks tested. `StubEditingRuntime` returns all-KEEP so that the policy above it is exercised
//  end to end and provably emits nothing.
//

import Foundation

// MARK: - Fixed shapes

/// The three compiled sequence lengths. Fixed shapes rather than a flexible input because a
/// flexible-shape Core ML model falls back to CPU on several macOS releases, and the whole
/// reason for a small discriminative tagger is that it must cost less than the 4B it replaces.
enum EditingSequenceShape: Int, Sendable, CaseIterable, Comparable {
    case short = 32
    case medium = 64
    case long = 128

    /// Smallest compiled shape that fits `count` tokens, or `nil` when the caller must split.
    /// Padding to the next shape up is cheaper than a second encoder pass, so the answer is
    /// always the smallest that fits and never the largest available.
    static func fitting(_ count: Int) -> EditingSequenceShape? {
        allCases.first { count <= $0.rawValue }
    }

    static func < (lhs: EditingSequenceShape, rhs: EditingSequenceShape) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Heads

/// One encoder pass, many small heads — the GECToR decomposition. Separate heads rather than
/// one flat label space because the thresholds are per-action: the plan ships punctuation
/// before casing before disfluency, each only once it measures ≥99% precision per language, and
/// a single softmax over a combined label set makes "ship punctuation only" unexpressible.
enum EditingHead: String, Sendable, CaseIterable {
    /// Is anything wrong with this token at all. The separate detection head is what lets the
    /// tagging heads stay sharp: without it, KEEP dominates training and every other class
    /// collapses.
    case error
    /// Which `EditOperation` shape applies.
    case operation
    /// Which mark to insert after the token.
    case punctuation
    /// Which case transform to apply to the token.
    case casing
    /// Whether the token is a disfluency to drop.
    case disfluency
    /// Line break / list item — structure the renderer, not the text, acts on.
    case structure
    /// Whether the edit would move the token into another language. A veto, never a proposal.
    case language
    /// Whether the edit changes meaning rather than form. Also a veto.
    case semanticRisk

    /// Number of logits this head emits per token. The runtime and the model must agree on
    /// this exactly; `StubEditingRuntime` is the executable statement of the contract.
    var labelCount: Int {
        switch self {
        case .error:        return EditingErrorLabel.allCases.count
        case .operation:    return EditingOperationLabel.allCases.count
        case .punctuation:  return EditingPunctuationLabel.allCases.count
        case .casing:       return EditingCasingLabel.allCases.count
        case .disfluency:   return EditingDisfluencyLabel.allCases.count
        case .structure:    return EditingStructureLabel.allCases.count
        case .language:     return EditingLanguageLabel.allCases.count
        case .semanticRisk: return EditingRiskLabel.allCases.count
        }
    }

    /// Index of the do-nothing label. Every head has one, and it is index 0 in every head — the
    /// invariant that makes an all-zero logit vector mean KEEP rather than mean nothing.
    var keepIndex: Int { 0 }
}

enum EditingErrorLabel: Int, Sendable, CaseIterable { case correct, incorrect }
enum EditingOperationLabel: Int, Sendable, CaseIterable { case keep, replace, delete, insertAfter }
enum EditingPunctuationLabel: Int, Sendable, CaseIterable {
    case none, period, comma, question, exclamation, colon, semicolon

    var mark: String? {
        switch self {
        case .none:        return nil
        case .period:      return "."
        case .comma:       return ","
        case .question:    return "?"
        case .exclamation: return "!"
        case .colon:       return ":"
        case .semicolon:   return ";"
        }
    }
}
enum EditingCasingLabel: Int, Sendable, CaseIterable { case keep, lower, capitalize, upper }
enum EditingDisfluencyLabel: Int, Sendable, CaseIterable { case keep, drop }
enum EditingStructureLabel: Int, Sendable, CaseIterable { case none, lineBreak, listItem }
enum EditingLanguageLabel: Int, Sendable, CaseIterable { case same, drifted }
enum EditingRiskLabel: Int, Sendable, CaseIterable { case safe, risky }

// MARK: - Output

/// Raw logits, not probabilities. The KEEP bias is a logit-space addition, so a runtime that
/// softmaxed first would make it unapplyable — and a calibrated probability is the model's job
/// anyway, not the runtime's.
struct EditingTokenLogits: Sendable {
    let logits: [EditingHead: [Float]]

    init(logits: [EditingHead: [Float]]) {
        self.logits = logits
    }

    /// All-zero logits: a uniform distribution over every head. The tagging heads' argmax is
    /// then index 0 — KEEP — under the ordering above, and the veto heads read as undecided,
    /// which also blocks. Neutral means "no edit" by both routes, which is the point.
    static let neutral = EditingTokenLogits(
        logits: Dictionary(uniqueKeysWithValues: EditingHead.allCases.map {
            ($0, [Float](repeating: 0, count: $0.labelCount))
        }))

    /// Logits for one head, or `nil` when the runtime did not emit that head or emitted the
    /// wrong width. A shape mismatch is silently treated as an absent head by every caller —
    /// a runtime and a policy that disagree about a label space must not produce edits.
    func values(for head: EditingHead) -> [Float]? {
        guard let values = logits[head], values.count == head.labelCount else { return nil }
        return values
    }
}

/// One encoder pass. `tokens` covers only the real inputs — padding positions are dropped here
/// rather than returned, because a padded position that reaches the tagging policy is a bug
/// that shows up as an edit against a token that does not exist.
struct EditingRuntimeOutput: Sendable {
    let shape: EditingSequenceShape
    let tokens: [EditingTokenLogits]
}

// MARK: - Errors

enum EditingRuntimeError: Error, LocalizedError {
    case notLoaded
    case sequenceTooLong(Int)
    case weightsUnavailable

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "Editing model runtime is not loaded"
        case .sequenceTooLong(let count):
            return "Sequence of \(count) tokens exceeds the longest compiled shape"
        case .weightsUnavailable:
            return "No editing model weights are available"
        }
    }
}

// MARK: - Runtime

protocol TextEditingModelRuntime: Sendable {
    var isLoaded: Bool { get }

    func load() async throws
    func unload() async

    /// Encode one batch of at most 128 token strings and return per-token head logits.
    ///
    /// The caller passes token *text*, not IDs: sub-word tokenization belongs to whichever
    /// runtime owns the vocabulary, and a token-ID contract here would leak that vocabulary
    /// into the policy above. Alignment back from sub-words to `TranscriptToken` is likewise
    /// the runtime's problem — it returns exactly one entry per input string.
    func encode(_ pieces: [String]) async throws -> EditingRuntimeOutput
}

// MARK: - Stub

/// Returns KEEP for every token of every head.
///
/// This exists so the policy in `MMBERTEditingModel` is executable and provably silent before
/// any weights exist. "Stub emits zero edits" is a real regression test: it fails the moment
/// the policy grows a path that proposes an edit without the model having asked for one.
struct StubEditingRuntime: TextEditingModelRuntime {

    /// Whether `load()` should fail, so callers' error paths are reachable in tests.
    let failsToLoad: Bool

    init(failsToLoad: Bool = false) {
        self.failsToLoad = failsToLoad
    }

    var isLoaded: Bool { !failsToLoad }

    func load() async throws {
        if failsToLoad { throw EditingRuntimeError.weightsUnavailable }
    }

    func unload() async {}

    func encode(_ pieces: [String]) async throws -> EditingRuntimeOutput {
        guard !failsToLoad else { throw EditingRuntimeError.notLoaded }
        guard let shape = EditingSequenceShape.fitting(pieces.count) else {
            throw EditingRuntimeError.sequenceTooLong(pieces.count)
        }
        return EditingRuntimeOutput(
            shape: shape,
            tokens: [EditingTokenLogits](repeating: .neutral, count: pieces.count))
    }
}
