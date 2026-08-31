//
//  TranscriptEdit.swift
//  Whisperer
//
//  A single proposed modification, addressed to a token.
//
//  Nothing rewrites a transcript wholesale. Every change is one of these, carries where it
//  came from and how sure it is, and is judged individually by the confidence gate. That is
//  what makes "the model cannot bypass policy" enforceable: a model that returns prose gets
//  diffed into edits and each one faces the same gate as a dictionary lookup.
//

import Foundation

// MARK: - Operation

enum EditOperation: Sendable, Equatable {
    /// Explicitly do nothing. Always available, and the answer whenever the gate is unsure.
    case keep
    /// Replace the token's text.
    case replace(String)
    /// Remove the token (fillers, duplicated words).
    case delete
    /// Insert new text immediately after the target token (sentence punctuation).
    case insertAfter(String)

    var isNoOp: Bool { self == .keep }
}

// MARK: - Source

/// Where an edit came from. Thresholds are calibrated per source — a trie hit on the user's
/// own dictionary is not the same kind of evidence as a tagger's softmax, and averaging them
/// into one number loses exactly the distinction the gate needs.
enum EditSource: String, Sendable {
    case alias           // DictionaryManager / shipped lexicon trie
    case normalization   // whitespace, duplicate punctuation, adjacent-word dedupe
    case filler          // disfluency removal
    case listFormatting  // ListFormatter
    case acousticBoundary // SentenceTerminator — a pause measured by our own VAD, not by the ASR
    case editorModel     // the discriminative tagger (mmBERT, once trained)
    case llm             // the generative fallback, diffed back into edits
}

// MARK: - Edit

struct TranscriptEdit: Sendable {
    let target: TokenID
    let operation: EditOperation
    let source: EditSource

    /// Calibrated per language × edit type × source × model version × capability tier. Raw
    /// softmax is not comparable across any of those axes, so this must be a calibrated
    /// number and not a bare model output.
    let confidence: Float

    /// Human-readable justification, carried into the edit log so a bad edit can be traced
    /// to the rule that produced it rather than guessed at from the diff.
    let reason: String

    /// The Clopper-Pearson 95% lower bound on the *measured precision* of the calibration cell
    /// this edit came from, or `nil` when no cell certifies it.
    ///
    /// Carried separately from `confidence` because they are different quantities and the gate
    /// must not compare them. `confidence` is a softmax product from one forward pass — how sure
    /// the model is about *this* token. This is a frequentist bound over hundreds of held-out
    /// proposals — how often the model is *right* when it says this, in this language, for this
    /// edit class. Only the second is a precision claim, and precision is the thing the gate's
    /// floors were always trying to approximate.
    ///
    /// Without this the certified cells are unreachable in practice. `MMBERTEditingModel` reports
    /// `confidence` as the product of three probabilities, so clearing the 0.95 cosmetic floor
    /// needs each of them above ~0.983; a cell calibrated to operate at 0.30 therefore proposes
    /// constantly and applies never. The calibration run already enforced the operating point that
    /// buys its measured precision — re-judging that decision against an uncalibrated softmax
    /// threshold discards the measurement and keeps the guess.
    let certifiedPrecisionLCB: Float?

    init(target: TokenID,
         operation: EditOperation,
         source: EditSource,
         confidence: Float,
         reason: String,
         certifiedPrecisionLCB: Float? = nil) {
        self.target = target
        self.operation = operation
        self.source = source
        self.confidence = confidence
        self.reason = reason
        self.certifiedPrecisionLCB = certifiedPrecisionLCB
    }
}

// MARK: - Applied record

/// One edit that actually survived the gate, plus what it replaced. Appended to the graph's
/// log so the raw ASR output is always reconstructible and undo is per-edit rather than
/// all-or-nothing.
struct AppliedEdit: Sendable {
    let edit: TranscriptEdit
    let previousText: String
}
