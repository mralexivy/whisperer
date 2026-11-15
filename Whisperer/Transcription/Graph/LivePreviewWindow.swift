//
//  LivePreviewWindow.swift
//  Whisperer
//
//  Bounds the work the live preview does per update.
//
//  The live preview is polished on the main actor for every text update (about three a second). The polish
//  pipeline is linear in the text it is given at best and quadratic in the number of edits at worst — every
//  deleted or inserted token renumbers the rest of the graph — so its cost depends on how long the live tail
//  has grown, not on what changed. On 2026-11-15 a long meeting with languages flipping every few seconds
//  grew the tail until each update cost more than the next one's budget: the main thread sat at 100% CPU for
//  fifty minutes and the app stopped responding.
//
//  Only the most recent text can still change as new words arrive, and only the recent text is read on a
//  live preview, so only that is polished. The older head passes through exactly as the decoder produced it;
//  it is already rolled into the committed transcript, where the full polish runs off the main actor.
//

import Foundation

nonisolated enum LivePreviewWindow {

    /// Most characters one live update may polish. About two minutes of speech, far more than one utterance.
    static let maxPolishedCharacters = 1_200

    /// How far past the nominal cut to look for a sentence end, so the window usually starts a sentence.
    private static let sentenceSearchSlack = 240

    /// Splits `text` so that only the tail needs polishing. Returns nil when the whole text fits the budget.
    /// The cut falls on whitespace (never inside a word, a grapheme or an RTL run), preferring just after a
    /// sentence terminator.
    static func split(_ text: String, limit: Int = maxPolishedCharacters) -> (head: Substring, tail: Substring)? {
        guard limit > 0, text.utf16.count > limit else { return nil }
        let characters = text.count
        guard characters > limit else { return nil }
        let nominal = text.index(text.endIndex, offsetBy: -limit)
        let searchEnd = text.index(nominal, offsetBy: min(sentenceSearchSlack, limit / 4), limitedBy: text.endIndex) ?? text.endIndex

        var sentenceCut: String.Index?
        var wordCut: String.Index?
        var i = nominal
        while i < searchEnd {
            let c = text[i]
            if c.isWhitespace {
                let next = text.index(after: i)
                if wordCut == nil { wordCut = next }
                if i > text.startIndex {
                    let before = text[text.index(before: i)]
                    if ".?!…".contains(before) { sentenceCut = next; break }
                }
            }
            i = text.index(after: i)
        }
        guard let cut = sentenceCut ?? wordCut, cut < text.endIndex else { return nil }
        return (text[..<cut], text[cut...])
    }

    /// Applies `transform` to the recent window of `text` only. Text within the budget is transformed whole.
    static func apply(to text: String, limit: Int = maxPolishedCharacters, _ transform: (String) -> String) -> String {
        guard let (head, tail) = split(text, limit: limit) else { return transform(text) }
        let polished = transform(String(tail))
        return polished.isEmpty ? text : String(head) + polished
    }
}
