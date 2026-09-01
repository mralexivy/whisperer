//
//  TrailingPeriodSuppressor.swift
//  Whisperer
//
//  Drops the final period from a one-line message dictated into a chat box.
//
//  Why this exists: a trailing period on a short chat message reads as terse — people do not
//  type one, so dictation that inserts one does not sound like the user. Wispr Flow does the
//  same thing and it is one of the details that makes their output feel native.
//
//  Why it is written this defensively: this edit is **not certifiable against any reference we
//  have.** `docs/knowledge/benchmarking/rules.md` rule 24 measured it — our two references
//  disagree about the utterance-final period on 18% of recordings (the authored gold terminates
//  98% of utterances because its author was told to punctuate; the whole-file decode terminates
//  82% because whisper often omits it), so any accuracy bar computed at that position measures
//  whisper's punctuation habit rather than this change. Rule 15 adds that the polish WER is
//  punctuation-folded and therefore structurally blind to a punctuation-only edit.
//
//  What is certifiable is the *scope*: that this is a no-op everywhere except the narrow case it
//  targets. So every condition below is a reason to decline, the default answer is "leave the
//  text alone", and `TrailingPeriodSuppressorTests` enumerates the table exhaustively. When the
//  measurement cannot carry the change, the containment has to.
//

import Foundation

enum TrailingPeriodSuppressor {

    /// Sentence-ending punctuation. A second one anywhere in the text means this is not the
    /// single-sentence message the suppression is scoped to.
    private static let terminators: Set<Character> = [".", "?", "!"]

    /// Words whose trailing period belongs to the word, not to the sentence. Stripping it
    /// produces a misspelling rather than a chat-style message.
    ///
    /// Not exhaustive and does not need to be: the `containsInteriorPeriod` and `isLikelyInitial`
    /// checks below catch the general shape (`e.g.`, `config.js`, `J.`), and anything this list
    /// misses fails safe as "leave the period alone".
    private static let abbreviations: Set<String> = [
        "etc", "vs", "approx", "est", "inc", "ltd", "dept", "min", "max",
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "no",
    ]

    /// Returns `text` with a single ASR-produced trailing period removed, or `text` unchanged.
    ///
    /// Declines unless *all* of the following hold:
    /// - the profile suppresses trailing periods (messaging only),
    /// - the text ends in exactly one `.` — never `…`, `...`, `?` or `!`,
    /// - that `.` is the only sentence terminator in the text (one sentence),
    /// - the final word is a plain word: not an abbreviation, not an initial, and containing no
    ///   interior period of its own (so `e.g.`, `config.js` and `3.5` are all left alone).
    static func suppress(_ text: String, profile: AppStyleProfile) -> String {
        guard profile.suppressesTrailingPeriod else { return text }
        return suppress(text)
    }

    /// Profile-independent form, for callers that have already decided the profile applies and
    /// for the test table. Same conditions, minus the profile check.
    static func suppress(_ text: String) -> String {
        // Operate on the trimmed text but preserve the original's trailing whitespace, so this
        // never silently reformats. A transcript that is only whitespace has no final word.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1, trimmed.hasSuffix(".") else { return text }

        // `...` and `…` are not a sentence-closing period; they are the speaker trailing off.
        let withoutFinalPeriod = String(trimmed.dropLast())
        guard let charBeforePeriod = withoutFinalPeriod.last,
              charBeforePeriod != ".",
              charBeforePeriod != "\u{2026}" else { return text }

        // Exactly one sentence. A second terminator anywhere means this is a multi-sentence
        // utterance, where the final period is doing real work.
        guard !withoutFinalPeriod.contains(where: { terminators.contains($0) }) else { return text }

        // A digit before the period is a decimal or an enumeration ("version 3.", "3.5"), not
        // the end of a sentence.
        guard !charBeforePeriod.isNumber else { return text }

        guard let finalWord = withoutFinalPeriod
            .split(whereSeparator: { $0.isWhitespace })
            .last
            .map(String.init) else { return text }

        // `e.g`, `config.js`, `whisper.cpp` — the period is part of the token.
        let containsInteriorPeriod = finalWord.contains(".")
        guard !containsInteriorPeriod else { return text }

        // A single letter before the period is an initial ("Alexander I."), not a sentence end.
        let isLikelyInitial = finalWord.count == 1 && finalWord.first?.isLetter == true
        guard !isLikelyInitial else { return text }

        let normalized = finalWord
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'()[]{}"))
        guard !abbreviations.contains(normalized) else { return text }

        // Preserve whatever trailing whitespace the original carried.
        let trailingWhitespace = text.suffix(from: text.range(of: trimmed)?.upperBound ?? text.endIndex)
        let leadingWhitespace = text.prefix(upTo: text.range(of: trimmed)?.lowerBound ?? text.startIndex)
        return leadingWhitespace + withoutFinalPeriod + trailingWhitespace
    }
}
