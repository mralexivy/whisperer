//
//  ASRCapabilities.swift
//  Whisperer
//
//  What per-token evidence a transcription backend can supply.
//
//  The shared `TranscriptionBackend` protocol carries only `String`, and Nemotron does not
//  even sit behind that protocol — it is fed samples and returns one `String` for the whole
//  session. So polishing that depends on word timings or acoustic probabilities is polishing
//  that only works on whisper.cpp. This type makes that dependency explicit instead of
//  implicit, and the contract below makes the absence of evidence safe rather than silently
//  degrading.
//
//  **The contract: every gate must define its behaviour at `[]`, and that behaviour is the
//  conservative one — KEEP.** Absent evidence never loosens a threshold. It only removes an
//  *extra* reason to edit. A token with no `asrProbability` is judged by the text thresholds
//  alone and can never be edited on weaker grounds than a token that has evidence.
//

import Foundation

struct ASRCapabilities: OptionSet, Sendable, Hashable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    /// Audio start/end per word.
    static let wordSpans      = ASRCapabilities(rawValue: 1 << 0)
    /// Per-word probability from the decoder.
    static let wordConfidence = ASRCapabilities(rawValue: 1 << 1)
    /// ASR sub-word token IDs.
    static let subwordTokens  = ASRCapabilities(rawValue: 1 << 2)
    /// The backend can re-run a span of audio on demand.
    static let reDecode       = ASRCapabilities(rawValue: 1 << 3)
    /// Per-segment no-speech probability — the hallucination signal.
    static let noSpeechProb   = ASRCapabilities(rawValue: 1 << 4)

    /// Nemotron, FluidAudio, SpeechAnalyzer as wired today. Also meetings, which run on
    /// Nemotron — so this is not an edge case, it is half the product.
    static let none: ASRCapabilities = []

    /// whisper.cpp: word spans, probabilities, token IDs, re-decode, and no-speech.
    static let whisperCpp: ASRCapabilities = [.wordSpans, .wordConfidence, .subwordTokens,
                                              .reDecode, .noSpeechProb]

    /// WhisperKit: word-level evidence, but no re-decode or no-speech hook wired.
    static let whisperKit: ASRCapabilities = [.wordSpans, .wordConfidence, .subwordTokens]

    /// Short label for benchmark tables, which report every quality column twice — once at
    /// full evidence and once at `[]`. The `[]` column is the engine-independence metric.
    var tierLabel: String {
        if isEmpty { return "none" }
        if self == .whisperCpp { return "full" }
        if self == .whisperKit { return "words" }
        return "0x\(String(rawValue, radix: 16))"
    }
}
