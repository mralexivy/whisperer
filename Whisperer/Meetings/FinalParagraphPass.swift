//
//  FinalParagraphPass.swift
//  Whisperer
//
//  The second pass over a finished meeting's transcript: re-cuts the cards into paragraphs with
//  the same scorer the live path uses (`LiveParagraphSegmenter`), but on text Whisper has
//  punctuated end to end, so a sentence end is trusted (weight 2.5, not 1.5).
//
//  Live cards were cut on settled words as they arrived; the whole-recording decode that replaces
//  their text has real sentences. This merges fragments the live cut left, splits walls at
//  sentence ends, and leaves everything else — every word, in order — untouched.
//
//  Pure and idempotent: no actors, no model, no I/O.
//

import Foundation

nonisolated enum FinalParagraphPass {

    /// Trailing paragraph shorter than this is folded back into the one before it.
    static let minimumTrailingWords = 8

    /// A span of one turn's text: a whole original segment, or one sentence of a divisible one.
    private struct Unit {
        var text: String
        var words: Int
        var start: Double
        var end: Double
        /// Silence between the previous unit's end and this one's start, when the two were
        /// separate segments. Inside one segment no pause is known, so 0.
        var pauseBefore: Double
        var source: Int          // index into the turn
        var index: Int           // sentence index within its source
        var count: Int           // sentences its source was cut into (1 = indivisible)
    }

    static func apply(_ segments: [MeetingSegment]) -> [MeetingSegment] {
        guard segments.count > 1 || segments.contains(where: { wordCount($0.text) >= LiveParagraphSegmenter.untimedWords }) else {
            return segments
        }
        var result: [MeetingSegment] = []
        var turn: [Int] = []
        func flushTurn() {
            guard !turn.isEmpty else { return }
            result.append(contentsOf: repaginate(turn.map { segments[$0] }, indices: turn))
            turn = []
        }
        for (index, segment) in segments.enumerated() {
            // A tagged card is somebody's decision about that exact span: a barrier.
            if !segment.tags.isEmpty {
                flushTurn()
                result.append(segment)
                continue
            }
            if let last = turn.last, !sameTurn(segments[last], segment) { flushTurn() }
            turn.append(index)
        }
        flushTurn()
        return result
    }

    private static func sameTurn(_ a: MeetingSegment, _ b: MeetingSegment) -> Bool {
        a.speakerIndex == b.speakerIndex && a.speakerName == b.speakerName
    }

    // MARK: - One turn

    private static func repaginate(_ turn: [MeetingSegment], indices: [Int]) -> [MeetingSegment] {
        var units: [Unit] = []
        for (position, segment) in turn.enumerated() {
            let pause = position == 0 ? 0 : max(0, segment.timestamp - turn[position - 1].endTimestamp)
            // A card the editor or the AI has rewritten keeps its raw text for the Original toggle,
            // and that text cannot be cut to match: it moves whole.
            let sentences = segment.rawText == nil ? sentenceSpans(segment.text) : [segment.text]
            let totalChars = max(1, sentences.reduce(0) { $0 + $1.count })
            var cursor = segment.timestamp
            for (offset, sentence) in sentences.enumerated() {
                let share = Double(sentence.count) / Double(totalChars)
                let end = offset == sentences.count - 1
                    ? max(segment.endTimestamp, cursor)
                    : cursor + max(0, segment.endTimestamp - segment.timestamp) * share
                units.append(Unit(text: sentence, words: wordCount(sentence), start: cursor, end: end,
                                  pauseBefore: offset == 0 ? pause : 0, source: position,
                                  index: offset, count: sentences.count))
                cursor = end
            }
        }
        guard !units.isEmpty else { return turn }

        // Walk the units, closing a paragraph where the scorer says.
        var groups: [[Unit]] = [[units[0]]]
        var words = units[0].words
        var paragraphStart = units[0].start
        for unit in units.dropFirst() {
            let previous = groups[groups.count - 1].last!
            let breaks = LiveParagraphSegmenter.shouldBreak(
                after: TimedWord(text: lastToken(previous.text), start: nil, end: 0),
                before: TimedWord(text: firstToken(unit.text), start: unit.pauseBefore, end: nil),
                paragraphWords: words,
                paragraphSeconds: max(0, previous.end - paragraphStart),
                sentenceWeight: LiveParagraphSegmenter.finalSentenceWeight)
            if breaks {
                groups.append([unit])
                words = unit.words
                paragraphStart = unit.start
            } else {
                groups[groups.count - 1].append(unit)
                words += unit.words
            }
        }
        // A stub left after the last break belongs to the paragraph it finished.
        if groups.count > 1, groups[groups.count - 1].reduce(0, { $0 + $1.words }) < minimumTrailingWords {
            let stub = groups.removeLast()
            groups[groups.count - 1].append(contentsOf: stub)
        }

        return groups.map { group in build(group, turn: turn) }
    }

    /// One output card from `group`. A group that is exactly one original card returns it
    /// untouched, so an unchanged transcript round-trips byte for byte.
    private static func build(_ group: [Unit], turn: [MeetingSegment]) -> MeetingSegment {
        let sources = Array(Set(group.map(\.source))).sorted()
        if sources.count == 1, group.count == group[0].count { return turn[sources[0]] }

        let first = turn[sources[0]]
        let anyRaw = sources.contains { turn[$0].rawText != nil }
        let rawText: String? = anyRaw
            ? sources.map { turn[$0].rawText ?? turn[$0].text }.joined(separator: " ")
            : nil
        return MeetingSegment(
            // The card that begins where its first source began keeps that source's identity.
            id: group[0].index == 0 ? first.id : UUID(),
            timestamp: group[0].start,
            endTimestamp: group[group.count - 1].end,
            text: group.map(\.text).joined(separator: " "),
            speakerName: first.speakerName,
            speakerIndex: first.speakerIndex,
            tags: [],
            rawText: rawText,
            language: first.language)
    }

    // MARK: - Text

    /// Sentences of `text`, each keeping its terminator; the pieces rejoin with single spaces to the
    /// original words. A terminator inside a token ("v1.2", "3.5", "e.g.x") is not a sentence end.
    static func sentenceSpans(_ text: String) -> [String] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        var spans: [String] = []
        var current: [String] = []
        for token in tokens {
            current.append(token)
            if LiveParagraphSegmenter.endsSentence(token) {
                spans.append(current.joined(separator: " "))
                current = []
            }
        }
        if !current.isEmpty { spans.append(current.joined(separator: " ")) }
        return spans
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func lastToken(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
    }

    private static func firstToken(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
    }
}
