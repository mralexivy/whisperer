//
//  SentenceCaser.swift
//  Whisperer
//
//  A capital after a full stop. Nothing else.
//
//  This is the one casing decision that is not a judgement call: a sentence opens with a capital,
//  and raising the first letter of a word cannot change what the word means. Everything harder —
//  proper nouns mid-sentence, `i` → `I`, restoring the case of a mangled acronym — is left where
//  it is, because those *can* change meaning and none of them is decidable from position alone.
//
//  **Never `String.capitalized`.** It lower-cases the remainder, so `API` becomes `Api` and
//  `loadModel` becomes `Loadmodel`. `MMBERTEditingModel.applyCasing` documents the same trap and
//  takes the same route: uppercase the first character, concatenate the rest untouched.
//
//  Four things are refused outright rather than scored:
//
//  - a token with any uppercase letter already anywhere in it — `iPhone`, `eBay`, `camelCase`;
//  - a hard-protected token — URLs, paths, identifiers, acronyms, digits, dictionary terms;
//  - a first character whose uppercase form is not one character — `ß` → `SS` would grow the word;
//  - a caseless script — Hebrew, Arabic, CJK have no uppercase, so the edit is a no-op and is not
//    proposed at all rather than proposed and discarded.
//

import Foundation

enum SentenceCaser {

    /// Capitalization edits for every sentence opening in `graph`.
    ///
    /// - Parameter capitalizesFirstWord: whether the transcript's own first word is treated as a
    ///   sentence opening. False for a mid-stream fragment, whose first word is wherever the VAD
    ///   happened to cut and may be the middle of a sentence the previous chunk started. This is
    ///   the same rule the fragment-mode LLM instruction states in prose.
    static func proposals(for graph: TokenGraph,
                          capitalizesFirstWord: Bool = true) -> [TranscriptEdit] {
        var edits: [TranscriptEdit] = []

        for opening in SentenceStructure.openings(in: graph) {
            if !opening.isTerminated && !capitalizesFirstWord { continue }

            let token = graph.tokens[opening.wordIndex]
            guard token.protection != .hard, token.lifecycle != .userFinal else { continue }
            guard let capitalized = Self.capitalizingFirstLetter(token.effectiveText) else { continue }

            edits.append(TranscriptEdit(
                target: token.id,
                operation: .replace(capitalized),
                source: .normalization,
                // Not 1.0: the boundary is inferred from punctuation the ASR supplied, and the ASR
                // is occasionally wrong about a period. Comfortably above the 0.90 normalization
                // floor, so it applies — the number is here to be lowered per language if a
                // measurement ever says it should be.
                confidence: 0.98,
                reason: "sentence-initial capital: \(token.effectiveText)"))
        }

        return edits
    }

    /// `text` with its first letter raised, or `nil` when raising it would be wrong or a no-op.
    ///
    /// Internal rather than private so the casing rule is testable on its own — it is the part
    /// that has to be right on `iPhone` and on `שלום`, and testing it through the whole pipeline
    /// would test the protection detector instead.
    static func capitalizingFirstLetter(_ text: String) -> String? {
        guard let first = text.first, first.isLetter else { return nil }

        // Any existing capital means the token already carries a casing decision — a brand, an
        // identifier, an acronym the detector missed. Raising the first letter of `iPhone` gives
        // `IPhone`, which is a worse string than the one we started with.
        guard !text.contains(where: \.isUppercase) else { return nil }

        let upper = String(first).uppercased()
        // Caseless scripts return the character unchanged; `ß` returns two characters. Both are
        // refused by the same test, which is why there is no script check here.
        guard upper.count == 1, upper != String(first) else { return nil }

        return upper + String(text.dropFirst())
    }
}
