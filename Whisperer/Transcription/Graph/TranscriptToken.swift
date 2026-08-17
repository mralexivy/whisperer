//
//  TranscriptToken.swift
//  Whisperer
//
//  One addressable unit of a transcript, plus the optional ASR evidence attached to it.
//
//  Edits address `TokenID`, never a UTF-16 `NSRange`. This app's languages are Hebrew,
//  Russian and English, frequently mixed inside one utterance — exactly the case where
//  offset arithmetic fails silently rather than loudly. A token ID survives insertion,
//  deletion and reordering elsewhere in the transcript; an offset does not.
//

import Foundation

// MARK: - TokenID

/// Stable identity for a token within one graph. Monotonic per graph, never reused, so an
/// edit that references a deleted token can be detected rather than mis-applied to whichever
/// token happens to occupy that position now.
struct TokenID: Hashable, Sendable, Comparable, CustomStringConvertible {
    let value: Int

    init(_ value: Int) { self.value = value }

    static func < (lhs: TokenID, rhs: TokenID) -> Bool { lhs.value < rhs.value }
    var description: String { "t\(value)" }
}

// MARK: - Lifecycle

/// How settled a token is. Together with the protection mask this is what makes "zero
/// revisions to committed text" checkable rather than aspirational.
///
/// The promotion mechanism differs per backend and the graph does not care which supplied
/// it: `EagerStreamEngine`'s LocalAgreement-2 soft commit for word-level backends, or
/// monotonic RNNT prefix comparison for Nemotron. Both mean the same thing here.
enum TokenLifecycle: Int, Sendable, Comparable {
    /// Speculative — the ASR may still retract or rewrite this.
    case provisional = 0
    /// The ASR will not change this. Polishing may still edit it.
    case asrStable = 1
    /// The utterance ended; the authoritative polishing pass has run.
    case utteranceFinal = 2
    /// The user touched it. Nothing automatic may ever change it again.
    case userFinal = 3

    static func < (lhs: TokenLifecycle, rhs: TokenLifecycle) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Protection

/// Whether an automatic edit is allowed to touch this token.
///
/// A *mask*, deliberately, not a substitution. `TranscriptPreCleaner.protectTokens` rewrites
/// spans into `__URL_1__` sentinels, which has three defects this replaces: the sentinels are
/// out-of-vocabulary strings nothing constrains a model to return intact; the shipped prompt
/// contradicts the mechanism by showing raw `docker run --rm -it` examples; and all 13 of its
/// patterns are ASCII classes, so Hebrew and Russian transcripts get no protection at all.
/// A mask has none of those failure modes because the text is never altered to apply it.
enum TokenProtection: Int, Sendable, Comparable {
    /// Editable under the normal confidence gate.
    case ordinary = 0
    /// Suspected name, unknown foreign term, mixed-script token. Raises the required margin.
    case soft = 1
    /// URL, email, number, date, code identifier, acronym, user-dictionary or product name.
    /// An edit touching this is *rejected*, whatever its confidence.
    case hard = 2

    static func < (lhs: TokenProtection, rhs: TokenProtection) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Kind

/// What sort of text a token holds. Whitespace is a token rather than a property of its
/// neighbour so that rendering is a plain concatenation and therefore byte-exact by
/// construction — see `TokenGraph.render()`.
enum TokenKind: Sendable {
    case word
    case punctuation
    case whitespace
}

// MARK: - TranscriptToken

struct TranscriptToken: Sendable, Identifiable {
    let id: TokenID
    let kind: TokenKind

    /// Exactly what the ASR produced, never normalized. Retained permanently — every plan
    /// guarantee about recoverability rests on this field being untouched.
    let rawText: String

    var lifecycle: TokenLifecycle
    var protection: TokenProtection

    /// What polishing decided this token should read as. `nil` means KEEP.
    var normalizedText: String?

    // MARK: Optional ASR evidence
    //
    // All four are `nil` on Nemotron, FluidAudio and SpeechAnalyzer as wired. Code that
    // reads them must treat `nil` as "no extra reason to edit", never as "threshold not
    // met, so use a weaker one".

    let audioStart: TimeInterval?
    let audioEnd: TimeInterval?
    let asrProbability: Float?
    let asrTokens: [Int]?

    /// The text this token renders as right now.
    var effectiveText: String { normalizedText ?? rawText }

    var isWord: Bool { kind == .word }

    init(id: TokenID,
         kind: TokenKind,
         rawText: String,
         lifecycle: TokenLifecycle = .provisional,
         protection: TokenProtection = .ordinary,
         normalizedText: String? = nil,
         audioStart: TimeInterval? = nil,
         audioEnd: TimeInterval? = nil,
         asrProbability: Float? = nil,
         asrTokens: [Int]? = nil) {
        self.id = id
        self.kind = kind
        self.rawText = rawText
        self.lifecycle = lifecycle
        self.protection = protection
        self.normalizedText = normalizedText
        self.audioStart = audioStart
        self.audioEnd = audioEnd
        self.asrProbability = asrProbability
        self.asrTokens = asrTokens
    }
}
