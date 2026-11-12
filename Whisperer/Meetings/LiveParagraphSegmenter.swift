//
//  LiveParagraphSegmenter.swift
//  Whisperer
//
//  Decides where a live meeting transcript breaks into paragraphs, one settled word at a time.
//  Design and the measurements behind every constant: docs/exec-plans/live-transcript-paragraphs.md.
//
//  Pure value type — no actors, no UI, no model. O(1) per word, so it can run on every Apple
//  result without showing up in a profile.
//

import Foundation

/// A word with its place on the audio clock. `start`/`end` are nil when the engine gave no timing
/// (Mode C): the segmenter then never invents a pause from arrival time.
nonisolated struct TimedWord: Equatable, Sendable {
    let text: String
    let start: Double?
    let end: Double?
}

nonisolated struct LiveParagraphSegmenter: Sendable {

    // MARK: - Tuning (docs/exec-plans/live-transcript-paragraphs.md §B)

    /// Never break a paragraph shorter than this, whatever the score.
    static let minimumWords = 12
    /// ...or shorter than this many seconds, unless the pause itself is `longPauseSeconds` or more.
    static let minimumSeconds = 5.0
    static let longPauseSeconds = 3.0
    static let breakScore = 3.0
    /// Mode C (no timing): from here the best gap wins, and at `forcedWords` one is forced.
    static let untimedWords = 90
    static let forcedWords = 140

    // MARK: - State

    private(set) var wordCount = 0
    private var openStart: Double?
    private var last: TimedWord?

    init() {}

    mutating func reset() {
        wordCount = 0
        openStart = nil
        last = nil
    }

    /// Whether a new paragraph starts at `word`, judged on the gap after the previous word. The
    /// word is then counted into the (new or continuing) open paragraph — call once per word, in
    /// order, settled words only: nothing decided here is ever revisited.
    mutating func breaksBefore(_ word: TimedWord) -> Bool {
        var broke = false
        if let previous = last, wordCount > 0 {
            broke = Self.shouldBreak(after: previous, before: word, paragraphWords: wordCount,
                                     paragraphSeconds: seconds(through: previous))
        }
        if broke || wordCount == 0 {
            wordCount = 0
            openStart = word.start
        }
        wordCount += 1
        last = word
        return broke
    }

    /// A speaker change: the turn boundary closes the paragraph by itself.
    mutating func startTurn() { reset() }

    private func seconds(through word: TimedWord) -> Double {
        guard let start = openStart, let end = word.end else { return 0 }
        return max(0, end - start)
    }

    // MARK: - Score

    static func shouldBreak(after previous: TimedWord, before next: TimedWord,
                            paragraphWords length: Int, paragraphSeconds: Double) -> Bool {
        var pause: Double?
        if let end = previous.end, let start = next.start { pause = max(0, start - end) }

        if let pause {
            var score = pause < 0.7 ? 0.0 : pause < 1.5 ? 1 : pause < 3 ? 2.5 : pause < 5 ? 4 : 6
            if endsSentence(previous.text) { score += 1.5 }
            if isContinuation(previous.text) { score -= 2 }
            score += length < 25 ? -3 : length < 60 ? 0 : length < 90 ? 1 : 2
            return score >= breakScore && length >= minimumWords
                && (paragraphSeconds >= minimumSeconds || pause >= longPauseSeconds)
        }

        // Mode C: punctuation, length and continuation only. Prefer a long paragraph to fragments.
        guard length >= untimedWords else { return false }
        if length >= forcedWords { return !insideToken(previous.text, next.text) }
        return endsSentence(previous.text) || !isContinuation(previous.text) && length >= untimedWords + 20
    }

    /// A sentence terminator at the end of the word. "v1.2" and "3.5" end in a digit, not a period.
    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.unicodeScalars.last else { return false }
        return ".?!…。".unicodeScalars.contains(last) && word.count > 1 || word == "?" || word == "!"
    }

    /// Words that start a clause that is not finished: a pause after one is a hesitation.
    static func isContinuation(_ word: String) -> Bool {
        let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        if continuationWords.contains(bare) { return true }
        // Hebrew: a lone prefix letter glued to nothing ("ו", "ש") is the whole word.
        return bare.count == 1 && hebrewPrefixes.contains(bare)
    }

    private static func insideToken(_ a: String, _ b: String) -> Bool {
        a.last?.isNumber == true && b.first?.isNumber == true
    }

    private static let continuationWords: Set<String> = [
        "and", "but", "because", "so", "or", "that", "which", "if", "then", "with",
        "и", "а", "но", "что", "потому", "поэтому", "или", "если", "чтобы",
        "אבל", "כי", "לכן", "או", "אם", "שזה", "ש", "ו",
    ]
    private static let hebrewPrefixes: Set<String> = ["ו", "ש", "כ", "ל", "ב", "ה"]
}
