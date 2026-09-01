//
//  CorrectionPromptTokenizer.swift
//  Whisperer
//
//  Splits a finished transcript into the clickable words the correction card offers, and rebuilds
//  the transcript once one of them has been replaced.
//
//  Kept free of SwiftUI so the part that decides *what the learner is told* is testable without a
//  hosting view. The word pattern is deliberately the same one
//  `CorrectionLearningCandidateExtractor` mines with: a chip the user cannot learn from is a chip
//  that should never have been clickable.
//

import Foundation

struct CorrectionPromptToken: Equatable, Identifiable, Sendable {
    /// Position in the token array — also the identity a click reports back, so a repeated word
    /// ("the the") resolves to the one that was actually clicked.
    let index: Int
    let text: String
    /// True for the word tokens; false for the whitespace and punctuation between them.
    let isWord: Bool

    var id: Int { index }
}

/// One dictation's worth of clickable words, as offered by the correction card.
struct CorrectionPrompt: Identifiable, Equatable, Sendable {
    /// How much of a transcript the card shows. The misheard word is nearly always near the end of
    /// what was just said, and a 300-word chip wall is not a HUD.
    static let maximumWords = 40

    let id = UUID()
    let tokens: [CorrectionPromptToken]
    /// True when words were dropped off the front, so the card can show a leading ellipsis.
    let isTruncated: Bool

    /// What the learner is told the transcript was.
    var text: String { CorrectionPromptTokenizer.text(of: tokens) }
}

enum CorrectionPromptTokenizer {
    /// Same pattern as `CorrectionLearningCandidateExtractor.tokens(in:)`.
    private static let wordPattern = #"[\p{L}\p{N}][\p{L}\p{N}'’-]*"#

    /// Splits `text` into alternating word and separator tokens, keeping every character.
    ///
    /// `keepingLastWords` trims from the front at a word boundary — the misheard word is almost
    /// always near the end of what was just said, and a long transcript rendered as chips does not
    /// fit a HUD. Returns `[]` for text with no words.
    static func tokenize(_ text: String, keepingLastWords limit: Int = .max) -> [CorrectionPromptToken] {
        guard !text.isEmpty, limit > 0,
              let regex = try? NSRegularExpression(pattern: wordPattern) else { return [] }

        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        // Drop everything before the first word we intend to show, including the separator that
        // precedes it, so the card never opens on a dangling comma.
        let firstShown = max(0, matches.count - limit)
        let start = matches[firstShown].range.location

        var tokens: [CorrectionPromptToken] = []
        var cursor = start
        for match in matches[firstShown...] {
            if match.range.location > cursor {
                tokens.append(CorrectionPromptToken(
                    index: tokens.count,
                    text: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)),
                    isWord: false
                ))
            }
            tokens.append(CorrectionPromptToken(
                index: tokens.count,
                text: ns.substring(with: match.range),
                isWord: true
            ))
            cursor = NSMaxRange(match.range)
        }
        if cursor < ns.length {
            tokens.append(CorrectionPromptToken(
                index: tokens.count,
                text: ns.substring(from: cursor),
                isWord: false
            ))
        }
        return tokens
    }

    /// True when `tokenize` had to drop words off the front, so the card can show a leading ellipsis.
    static func isTruncated(_ text: String, keepingLastWords limit: Int) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: wordPattern) else { return false }
        let ns = text as NSString
        return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length)) > limit
    }

    /// The text the card is showing — what the learner is told the transcript *was*.
    static func text(of tokens: [CorrectionPromptToken]) -> String {
        tokens.map(\.text).joined()
    }

    /// The same text with one token swapped. Replaces by index, never by string: correcting the
    /// second "the" must not also rewrite the first.
    static func replacing(
        tokenAt index: Int,
        with replacement: String,
        in tokens: [CorrectionPromptToken]
    ) -> String? {
        guard tokens.indices.contains(index), tokens[index].isWord else { return nil }
        let trimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != tokens[index].text else { return nil }
        // A replacement containing whitespace would realign the token stream and mine a phrase
        // rewrite rather than the 1:1 substitution the card promised.
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return nil }

        var parts = tokens.map(\.text)
        parts[index] = trimmed
        return parts.joined()
    }
}
