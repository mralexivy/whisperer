//
//  EditingModel.swift
//  Whisperer
//
//  The seam every *model* proposal enters through.
//
//  `AliasEngine` and `TranscriptNormalizer` already return `[TranscriptEdit]`; this protocol
//  says that a model must too. A generative model does not naturally speak in edits — it
//  returns prose — so `LLMEditingModel` diffs its prose back into token-addressed edits
//  before returning. That conversion is the whole point: it turns "accept or reject the
//  model's rewrite" into "judge each of the model's forty changes", which is the only shape
//  the confidence gate can act on.
//
//  Two conformances are planned, and only one of them is the destination:
//
//  - `LLMEditingModel` — scaffolding. The existing 4B behind the unmodified Correct prompt,
//    diffed. Retired at the end of M4.
//  - `MMBERTEditingModel` — a GECToR-style token tagger, one encoder pass and many small
//    heads. Live, but only for the language × head × action cells a calibration run has
//    measured and cleared. A certified proposal carries the measured precision that certified
//    it (`TranscriptEdit.certifiedPrecisionLCB`) and is judged against the tier gates in
//    `ConfidenceGate.precisionGate(for:)`; an uncertified one is capped below every floor and
//    so can propose but never apply.
//
//  Nothing here reads audio or a `TokenGraph`. A model sees tokens and surrounding text, and
//  the gate — not the model — decides what happens, so a model that is confidently wrong
//  costs a rejected edit rather than a corrupted transcript.
//

import Foundation

// MARK: - Context

/// Everything a model is allowed to condition on beyond the tokens themselves.
///
/// `capabilities` is carried even though no conformance reads it yet. It is what lets the
/// benchmark report every quality number twice — once at full whisper.cpp evidence and once
/// at `[]` — and a model that quietly behaves differently between the two columns is a model
/// that will regress meetings, which run on Nemotron and therefore always at `[]`.
struct EditContext: Sendable {

    /// Which pass is asking. A live pass sees a fragment that may begin or end mid-sentence,
    /// so terminal punctuation and sentence-initial casing are not yet decidable; the
    /// authoritative pass runs at the utterance endpoint and sees the whole thing.
    enum Pass: Sendable {
        case live
        case authoritative
    }

    /// `nil` when routing has not decided yet. Never defaulted to English — a model that
    /// assumes English on a Hebrew utterance is exactly the drift the gate exists to stop.
    let language: TranscriptionLanguage?

    let capabilities: ASRCapabilities
    let pass: Pass

    /// Text before and after the tokens being judged, when the caller has it. Used for
    /// conditioning only; a model may not propose edits outside `tokens`, and it structurally
    /// cannot, because an edit addresses a `TokenID` it was handed.
    let precedingText: String
    let followingText: String

    init(language: TranscriptionLanguage? = nil,
         capabilities: ASRCapabilities = [],
         pass: Pass = .authoritative,
         precedingText: String = "",
         followingText: String = "") {
        self.language = language
        self.capabilities = capabilities
        self.pass = pass
        self.precedingText = precedingText
        self.followingText = followingText
    }
}

// MARK: - Protocol

/// `nonisolated` is load-bearing, not tidiness — but it is only half of what this pass needs, and
/// the earlier version of this comment was wrong to stop here.
///
/// **Why it is necessary.** The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so
/// without `nonisolated` this protocol — and therefore every witness, however the conformer is
/// declared — is `@MainActor`, and `await editor.propose(...)` is an explicit hop *onto* the thread
/// that draws the HUD. That is not a theoretical cost: the first inference specializes the
/// MPSGraph, which measured as a 2.0 s main-thread stall between `rec.stop` and the paste, caught
/// by `HealthManager`'s watchdog with `MPSGraphExecutable specializedModuleWithDevice` on top of
/// the stack.
///
/// **Why it is not sufficient.** The project also sets `SWIFT_APPROACHABLE_CONCURRENCY = YES`.
/// Under SE-0461 an unannotated `nonisolated async` requirement is `nonisolated(nonsending)`: it
/// has no executor of its own and runs on the **caller's**. Removing the `@MainActor` annotation
/// therefore removed the hop onto the main actor without adding a hop off it. Every caller of the
/// polish pipeline is a method on `@MainActor AppState`, so `propose`, `MMBERTCoreMLRuntime.encode`
/// and the synchronous `predict` inside its batching loop all still ran on thread 0. A dictation on
/// 2026-10-07 20:48:34 froze the UI for 4.6 s, with `semaphore_wait_trap →
/// MpsGraphInferenceOperation::ExecuteSync → MLE5ExecutionStream executeForInputFeatures:` captured
/// on the main thread.
///
/// **What actually achieves the hop.** `@concurrent` on the caller, not an annotation here. A
/// `@concurrent` function is required to run on the global concurrent executor, and a
/// `nonisolated(nonsending)` callee invoked from inside it inherits *that* isolation instead of the
/// original caller's. `DeterministicPolisher`'s three async `polish` entry points carry the
/// attribute and a `Thread.isMainThread` tripwire; `ModelWorkQueue.offCallerExecutor` does the same
/// for background model work and documents the stack dumps that established the technique.
///
/// A conformer must therefore **not** assume it is off the main thread by virtue of this protocol
/// being `nonisolated`. It is off the main thread because its caller forced it there.
nonisolated protocol EditingModel: Sendable {
    /// Propose edits against the tokens as given.
    ///
    /// Returning `[]` is always a valid answer and is the required answer under uncertainty —
    /// the conservative direction here is a missed correction, never a speculative one. An
    /// implementation must not mutate anything: the caller owns the graph, judges the
    /// proposals through `ConfidenceGate`, and applies only what survives.
    func propose(_ tokens: [TranscriptToken], context: EditContext) async -> [TranscriptEdit]
}
