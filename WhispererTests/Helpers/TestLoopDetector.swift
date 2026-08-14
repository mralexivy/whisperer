//
//  TestLoopDetector.swift
//  WhispererTests
//
//  Detects the decode failure this project keeps hitting: a greedy 4B model falling into
//  a cycle and emitting it until something cuts it off.
//

import Foundation

/// Consecutive n-gram repetition in generated text.
///
/// Deliberately a re-implementation of `MeetingOverviewParser`'s gate rather than a call
/// into it. The parser now *trims* a loop away, so a test that measured quality through the
/// parser would report a clean summary for exactly the decode this exists to catch — and a
/// test that called the parser's own detector would pass whenever both were wrong the same
/// way. This one looks at the raw model output, before anything repairs it.
enum TestLoopDetector {

    /// The repeated phrase, when the text repeats one back-to-back enough times to be a
    /// decode failure rather than speech. A single word needs five runs ("really, really,
    /// really" is emphasis); two or more words need three.
    static func firstRepeat(in text: String, maxPhrase: Int = 5) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for n in 1...maxPhrase {
            let needed = n == 1 ? 5 : 3
            guard words.count >= n * needed else { continue }
            for i in 0...(words.count - n * needed) {
                let phrase = Array(words[i..<(i + n)])
                var repeats = 1
                while i + n * (repeats + 1) <= words.count,
                      Array(words[(i + n * repeats)..<(i + n * (repeats + 1))]) == phrase {
                    repeats += 1
                }
                if repeats >= needed { return phrase.joined(separator: " ") }
            }
        }
        return nil
    }
}
