//
//  FileTranscriptParagraphs.swift
//  Whisperer
//
//  Turns a finished file transcription — one unbroken run of text — into readable paragraphs with
//  an approximate start time each. Language-agnostic: sentences and words come from NaturalLanguage
//  (which handles scripts without spaces, like Chinese, Japanese and Thai), never from whitespace or
//  a list of English words.
//
//  Pure and deterministic: no actors, no UI, no I/O.
//

import Foundation
import NaturalLanguage

/// Where a chunk began on the audio clock, in words counted from the start of the transcript.
/// The last anchor is the end of the transcript.
nonisolated struct FileTranscriptAnchor: Equatable, Sendable {
    let word: Int
    let seconds: Double
}

nonisolated struct FileTranscriptParagraph: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let words: Int
    /// Approximate (chunks are 30 s long, times between them are interpolated). Nil when the
    /// transcript carried no timing.
    let start: Double?
}

nonisolated enum FileTranscriptParagraphs {

    /// A paragraph closes at the first sentence end at or past this many words...
    static let targetWords = 55
    /// ...and never grows past this unless one sentence alone is longer.
    static let maxWords = 120
    /// A closing paragraph shorter than this is folded into the one before it.
    static let minimumTrailingWords = 15

    static func wordCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }

    static func split(_ text: String, anchors: [FileTranscriptAnchor] = []) -> [FileTranscriptParagraph] {
        let sentences = sentenceSpans(of: text)
        guard !sentences.isEmpty else { return [] }

        // Group sentences into paragraphs, remembering the word index each one starts at.
        struct Group { var range: Range<String.Index>; var startWord: Int; var words: Int }
        var groups: [Group] = []
        var open: Group?
        var wordsBefore = 0
        for sentence in sentences {
            if var current = open {
                if current.words >= targetWords || (current.words >= minimumTrailingWords && current.words + sentence.words > maxWords) {
                    groups.append(current)
                    open = Group(range: sentence.range, startWord: wordsBefore, words: sentence.words)
                } else {
                    current.range = current.range.lowerBound..<sentence.range.upperBound
                    current.words += sentence.words
                    open = current
                }
            } else {
                open = Group(range: sentence.range, startWord: wordsBefore, words: sentence.words)
            }
            wordsBefore += sentence.words
        }
        if let last = open {
            if last.words < minimumTrailingWords, var previous = groups.popLast() {
                previous.range = previous.range.lowerBound..<last.range.upperBound
                previous.words += last.words
                groups.append(previous)
            } else {
                groups.append(last)
            }
        }

        let scale = anchorScale(anchors: anchors, totalWords: wordsBefore)
        return groups.enumerated().map { index, group in
            FileTranscriptParagraph(
                id: index,
                text: String(text[group.range]).trimmingCharacters(in: .whitespacesAndNewlines),
                words: group.words,
                start: seconds(atWord: Double(group.startWord) * scale, anchors: anchors))
        }
    }

    // MARK: - Sentences

    private struct Span { let range: Range<String.Index>; let words: Int }

    private static func sentenceSpans(of text: String) -> [Span] {
        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        sentenceTokenizer.string = text
        let wordTokenizer = NLTokenizer(unit: .word)
        wordTokenizer.string = text
        var spans: [Span] = []
        sentenceTokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            var count = 0
            wordTokenizer.enumerateTokens(in: range) { _, _ in
                count += 1
                return true
            }
            if count > 0 { spans.append(Span(range: range, words: count)) }
            return true
        }
        return spans
    }

    // MARK: - Time

    /// The dictionary pass can add or drop a word, so the anchors' word counts and the final text's
    /// are not always equal; scale the position instead of trusting it.
    private static func anchorScale(anchors: [FileTranscriptAnchor], totalWords: Int) -> Double {
        guard let end = anchors.last, end.word > 0, totalWords > 0 else { return 1 }
        return Double(end.word) / Double(totalWords)
    }

    private static func seconds(atWord position: Double, anchors: [FileTranscriptAnchor]) -> Double? {
        guard anchors.count >= 2 else { return anchors.first?.seconds }
        var lower = anchors[anchors.count - 2]
        var upper = anchors[anchors.count - 1]
        for index in 0..<(anchors.count - 1) where Double(anchors[index + 1].word) > position {
            lower = anchors[index]
            upper = anchors[index + 1]
            break
        }
        let span = Double(upper.word - lower.word)
        guard span > 0 else { return lower.seconds }
        let fraction = min(1, max(0, (position - Double(lower.word)) / span))
        return lower.seconds + fraction * (upper.seconds - lower.seconds)
    }
}
