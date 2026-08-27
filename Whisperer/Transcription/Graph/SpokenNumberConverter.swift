//
//  SpokenNumberConverter.swift
//  Whisperer
//
//  `three hundred twenty milliseconds` → `320 milliseconds`. One of the four jobs `AIMode.correct`
//  does that the deterministic passes did not, and the reason 64% of utterances still reached the
//  4B even when their punctuation was already finished.
//
//  **Compounds only, never a lone numeral.** `twenty four` is unambiguously 24; `one` is
//  overwhelmingly `one of the things`, `no one`, `one more time`. On the 400-recording corpus a
//  spelled-out numeral appears in 48 utterances and 31 of those are the word `one` — so a rule
//  that converted single numerals would be wrong more often than right, and one that converts
//  only well-formed multi-word numerals is wrong essentially never. Lone numerals are not
//  converted and are not silently dropped either: `DeterministicPolisher.needsGenerativePass`
//  routes them to the model, which is the honest answer to a case we cannot decide.
//
//  **English only.** Hebrew and Russian cardinals inflect for gender and case — `שתי` / `שתיים`,
//  `два` / `две` / `двух` — so the word form is not recoverable from the digit and a conversion
//  loses information the reader needs. Those go to the model, and `needsGenerativePass` says so.
//
//  Runs before `TranscriptNormalizer` for one mechanical reason: a conversion deletes two of the
//  three words in `three hundred twenty`, and the normalizer's whitespace pass is what closes the
//  gaps the deletions leave behind.
//

import Foundation

enum SpokenNumberConverter {

    // MARK: - Vocabulary

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9,
    ]

    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]

    /// Scales written as digits — `three hundred twenty` is `320`, not `3 hundred 20`.
    private static let numericScales: [String: Int] = ["hundred": 100, "thousand": 1000]

    /// Scales kept as words. `five million` is written `5 million`, never `5000000`: the digit
    /// form is technically equal and is not what anyone means by it.
    private static let wordScales: Set<String> = ["million", "billion", "trillion"]

    /// Idioms whose digit form is not their numeric value. Matched before the parser, because
    /// `twenty four seven` parses as 24 followed by a stray 7 and means neither.
    private static let idioms: [(words: [String], text: String)] = [
        (["twenty", "four", "seven"], "24/7"),
        (["nine", "to", "five"], "9-to-5"),
    ]

    // MARK: - Word classification

    private enum Numeral {
        case unit(Int)      // 0–9
        case teen(Int)      // 10–19
        case tens(Int)      // 20, 30 … 90
        case numericScale(Int)
        case wordScale(String)
        case connector      // "and", between a scale and its remainder
    }

    private static func classify(_ word: String) -> Numeral? {
        let key = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if let value = units[key] { return .unit(value) }
        if let value = teens[key] { return .teen(value) }
        if let value = tens[key] { return .tens(value) }
        if let value = numericScales[key] { return .numericScale(value) }
        if wordScales.contains(key) { return .wordScale(key) }
        if key == "and" { return .connector }
        return nil
    }

    // MARK: - Entry point

    /// Digit conversions for every well-formed multi-word cardinal in `graph`.
    ///
    /// Each conversion is one `replace` on the run's first word and a `delete` for the rest, so
    /// the gate sees ordinary edits and the graph's log records exactly which words became which
    /// digits.
    static func proposals(for graph: TokenGraph) -> [TranscriptEdit] {
        let words = graph.tokens.indices.filter { graph.tokens[$0].isWord }
        guard words.count > 1 else { return [] }

        var edits: [TranscriptEdit] = []
        var offset = 0

        while offset < words.count {
            guard let run = numeralRun(startingAt: offset, words: words, graph: graph) else {
                offset += 1
                continue
            }
            edits.append(contentsOf: run.edits)
            offset = run.nextOffset
        }

        return edits
    }

    // MARK: - Run matching

    private struct Run {
        let edits: [TranscriptEdit]
        let nextOffset: Int
    }

    private static func numeralRun(startingAt offset: Int,
                                   words: [Int],
                                   graph: TokenGraph) -> Run? {
        if let idiom = idiomRun(startingAt: offset, words: words, graph: graph) { return idiom }
        return parsedRun(startingAt: offset, words: words, graph: graph)
    }

    private static func idiomRun(startingAt offset: Int,
                                 words: [Int],
                                 graph: TokenGraph) -> Run? {
        for idiom in idioms where offset + idiom.words.count <= words.count {
            let span = Array(words[offset..<(offset + idiom.words.count)])
            guard onlyWhitespaceBetween(span, in: graph), editable(span, in: graph) else { continue }
            let spoken = span.map { fold(graph.tokens[$0].effectiveText) }
            guard spoken == idiom.words else { continue }
            return Run(edits: rewrite(span, to: idiom.text, in: graph,
                                      reason: "spoken idiom: \(idiom.words.joined(separator: " "))"),
                       nextOffset: offset + idiom.words.count)
        }
        return nil
    }

    /// The longest well-formed cardinal starting at `offset`, as edits — or `nil` if there is
    /// none, or if it is a single word, which this pass never touches.
    private static func parsedRun(startingAt offset: Int,
                                  words: [Int],
                                  graph: TokenGraph) -> Run? {
        var total = 0            // completed thousands and above
        var current = 0          // the group being accumulated
        var numeralWords = 0     // words that carried a value, so `and` does not count
        var retainedScale: String?
        var end = offset         // exclusive
        var previous: Numeral?

        loop: while end < words.count {
            guard let numeral = classify(graph.tokens[words[end]].effectiveText) else { break }
            guard follows(numeral, previous) else { break }

            switch numeral {
            // Every arithmetic step reports overflow instead of trapping. Dictation can produce
            // an arbitrarily long chain of scale words — "one hundred hundred hundred …" is
            // grammatical to `follows` — and ten of them overflow Int64. On overflow the run
            // simply ends before the offending word, so the words parsed so far still convert
            // and the rest is left as text. Nothing is mutated before the check, so the value
            // stays consistent with the span.
            case .unit(let value), .teen(let value), .tens(let value):
                let (sum, overflowed) = current.addingReportingOverflow(value)
                if overflowed { break loop }
                current = sum
                numeralWords += 1
            case .numericScale(let value):
                let (product, productOverflowed) = max(current, 1).multipliedReportingOverflow(by: value)
                if productOverflowed { break loop }
                if value >= 1000 {
                    let (sum, sumOverflowed) = total.addingReportingOverflow(product)
                    if sumOverflowed { break loop }
                    total = sum
                    current = 0
                } else {
                    current = product
                }
                numeralWords += 1
            case .wordScale(let name):
                // The scale word stays; the run ends with it.
                retainedScale = name
                end += 1
                previous = numeral
                break loop
            case .connector:
                break
            }

            end += 1
            previous = numeral
        }

        // A trailing connector belongs to the sentence, not to the number: `twenty and then`.
        if case .some(.connector) = previous {
            end -= 1
        }

        let span = Array(words[offset..<end])
        guard numeralWords >= 2 || (numeralWords >= 1 && retainedScale != nil),
              span.count >= 2,
              onlyWhitespaceBetween(span, in: graph),
              editable(span, in: graph) else { return nil }

        let (value, valueOverflowed) = total.addingReportingOverflow(current)
        guard !valueOverflowed, value > 0 else { return nil }

        let digits = retainedScale.map { "\(value) \($0)" } ?? "\(value)"
        let spoken = span.map { fold(graph.tokens[$0].effectiveText) }.joined(separator: " ")
        return Run(edits: rewrite(span, to: digits, in: graph,
                                  reason: "spoken number: \(spoken) → \(digits)"),
                   nextOffset: end)
    }

    /// The grammar, as one table. Anything not listed ends the run rather than being coerced —
    /// `two three` is two numbers, not 23, and `twenty hundred` is not a number at all.
    private static func follows(_ numeral: Numeral, _ previous: Numeral?) -> Bool {
        guard let previous else {
            // A run may not open with a bare scale: `hundred milliseconds` has no multiplier.
            switch numeral {
            case .numericScale, .wordScale, .connector: return false
            default: return true
            }
        }

        switch (previous, numeral) {
        // A value may always be followed by a scale that multiplies it.
        case (.unit, .numericScale), (.teen, .numericScale), (.tens, .numericScale):
            return true
        case (.unit, .wordScale), (.teen, .wordScale), (.tens, .wordScale):
            return true
        // `twenty four`, but not `twenty twenty` or `four four`.
        case (.tens, .unit):
            return true
        // The remainder after a scale: `three hundred twenty`, `two thousand nineteen`.
        case (.numericScale, .unit), (.numericScale, .teen), (.numericScale, .tens),
             (.connector, .unit), (.connector, .teen), (.connector, .tens):
            return true
        // `two thousand` then `million`? No. One scale word per run.
        case (.numericScale, .numericScale), (.numericScale, .wordScale):
            return true
        // `three hundred and twenty`.
        case (.numericScale, .connector):
            return true
        default:
            return false
        }
    }

    // MARK: - Edits

    private static func rewrite(_ span: [Int], to text: String, in graph: TokenGraph,
                                reason: String) -> [TranscriptEdit] {
        var edits: [TranscriptEdit] = [
            TranscriptEdit(target: graph.tokens[span[0]].id,
                           operation: .replace(text),
                           source: .normalization,
                           confidence: 0.95,
                           reason: reason)
        ]
        edits += span.dropFirst().map {
            TranscriptEdit(target: graph.tokens[$0].id,
                           operation: .delete,
                           source: .normalization,
                           confidence: 0.95,
                           reason: reason)
        }
        return edits
    }

    // MARK: - Guards

    /// Only whitespace may separate the words of one number. A comma or a dash means the speaker
    /// enumerated rather than counted: `there were twenty, four of them left`.
    private static func onlyWhitespaceBetween(_ span: [Int], in graph: TokenGraph) -> Bool {
        for (first, second) in zip(span, span.dropFirst()) {
            guard graph.tokens[(first + 1)..<second].allSatisfy({ $0.kind == .whitespace })
            else { return false }
        }
        return true
    }

    /// No part of a number may sit inside a protected span. Restated here rather than left to the
    /// gate because a run is atomic: the gate judges each edit alone and would happily delete two
    /// of three words while refusing the replacement, leaving `hundred twenty` as `hundred`.
    private static func editable(_ span: [Int], in graph: TokenGraph) -> Bool {
        span.allSatisfy {
            graph.tokens[$0].protection == .ordinary && graph.tokens[$0].lifecycle != .userFinal
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }
}
