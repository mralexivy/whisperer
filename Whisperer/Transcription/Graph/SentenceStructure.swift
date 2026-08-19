//
//  SentenceStructure.swift
//  Whisperer
//
//  Where the sentences are, as token addresses.
//
//  Both structural passes need the same answer to the same question — "is this word token the
//  first word of a sentence, and what gap precedes it" — and both must give it without reading a
//  single character of ASR evidence. `SentenceCaser` capitalizes the opener; `ParagraphSplitter`
//  may replace the gap with a break. Computing the boundaries once, here, is what keeps the two
//  from disagreeing about where a sentence starts, which would show up as a paragraph break
//  followed by a lowercase word.
//
//  Script-neutral by construction. A terminator is a character, not a case; Hebrew and Russian
//  reach exactly the same boundaries as English and simply have nothing to capitalize.
//

import Foundation

enum SentenceStructure {

    // MARK: - Opening

    /// The first word of a sentence, and the material immediately before it.
    struct Opening: Sendable {
        /// Index into `graph.tokens` of the sentence's first word token.
        let wordIndex: Int
        /// The whitespace token separating this sentence from the previous one. `nil` for the
        /// first sentence, and for a sentence that follows its terminator with no gap at all.
        let gapID: TokenID?
        /// Whether a terminal mark actually preceded this opening. False only for the very first
        /// opening in the graph, which begins a sentence by position rather than by punctuation.
        let isTerminated: Bool
        /// The last word token before the terminator — what decides whether the terminator ended
        /// a sentence or merely abbreviated a word.
        let previousWordIndex: Int?
    }

    // MARK: - Terminators

    /// Characters that end a sentence. `׃` is the Hebrew sof pasuq, `。` and `？` the CJK forms —
    /// present because the tokenizer is script-neutral and a Latin-only set would silently make
    /// every non-Latin transcript one sentence long.
    static let terminators: Set<Character> = [".", "!", "?", "…", "׃", "。", "！", "？"]

    /// Marks that may sit between a terminator and the next sentence without breaking the
    /// boundary: `He said "go." Then he left.`
    private static let closers: Set<Character> = ["\"", "'", "\u{2019}", "\u{201D}", ")", "]",
                                                  "}", "»", "”", "„"]

    /// Words whose trailing period abbreviates rather than terminates. Without this, `e.g. the`
    /// and `etc. and` become sentence openings and get a capital they should not have.
    ///
    /// Only the ones that occur in dictated technical speech. A longer list is not more correct —
    /// every entry is also a word that could genuinely end a sentence, and the cost of a missing
    /// entry is one capital letter while the cost of a wrong entry is a missing one.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "eg", "ie",
        "fig", "approx", "inc", "ltd", "co", "no", "al", "cf", "esp",
    ]

    /// Whether a terminator directly after `word` abbreviates it.
    ///
    /// A single letter is the general case — `e.g.`, `i.e.`, `U.S.`, and the `1.` of an
    /// enumeration all reduce to a one-character word before the dot — and the named list is the
    /// specific one.
    static func abbreviates(_ word: String) -> Bool {
        let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if folded.count <= 1 { return true }
        return abbreviations.contains(folded)
    }

    // MARK: - Scanning

    /// Every sentence opening in `graph`, in order.
    ///
    /// One backward walk per word token would be quadratic on a long dictation; this is a single
    /// forward pass that carries the boundary state, so it is linear in the token count and costs
    /// nothing measurable next to the regex passes that precede it.
    static func openings(in graph: TokenGraph) -> [Opening] {
        var openings: [Opening] = []

        // Boundary state, reset at every accepted terminator.
        var pendingBoundary = true          // the start of the transcript is a boundary
        var pendingTerminated = false
        var pendingGap: TokenID?
        var pendingPreviousWord: Int?
        var lastWordIndex: Int?

        for (index, token) in graph.tokens.enumerated() {
            switch token.kind {
            case .whitespace:
                // The gap nearest the opening is the one a break would be written into. After
                // normalization there is exactly one per boundary; before it there may be several.
                if pendingBoundary { pendingGap = token.id }

            case .punctuation:
                let character = token.effectiveText.first
                if let character, terminators.contains(character) {
                    // `e.g.` and `3.5`: the word before the dot decides. A digit-bearing word is
                    // never a sentence end — the tokenizer splits `3.5` into `3`, `.`, `5`.
                    let previous = lastWordIndex.map { graph.tokens[$0].effectiveText }
                    let terminates = previous.map { !abbreviates($0) } ?? false
                    if terminates {
                        pendingBoundary = true
                        pendingTerminated = true
                        pendingGap = nil
                        pendingPreviousWord = lastWordIndex
                    }
                } else if let character, !closers.contains(character) {
                    // Any other mark between the terminator and the next word — a comma, a dash —
                    // means whatever follows is not a clean sentence opening.
                    pendingBoundary = false
                    pendingTerminated = false
                    pendingGap = nil
                }

            case .word:
                if pendingBoundary {
                    openings.append(Opening(wordIndex: index,
                                            gapID: pendingGap,
                                            isTerminated: pendingTerminated,
                                            previousWordIndex: pendingPreviousWord))
                }
                pendingBoundary = false
                pendingTerminated = false
                pendingGap = nil
                pendingPreviousWord = nil
                lastWordIndex = index
            }
        }

        return openings
    }
}
