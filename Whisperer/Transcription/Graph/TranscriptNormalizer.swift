//
//  TranscriptNormalizer.swift
//  Whisperer
//
//  The four passes `TranscriptPreCleaner` already runs — whitespace, duplicate punctuation,
//  repeated fillers, adjacent-word dedupe — expressed as gated edits against tokens instead of
//  regex substitutions against a string.
//
//  Two things change beyond the representation:
//
//  1. **The filler set is no longer Latin-only.** `["uh","um","er","ah","hmm"]` cannot fire on a
//     Hebrew or Russian transcript, so today those languages get no disfluency removal at all.
//  2. **Ambiguity is priced rather than excluded.** The shipping pass drops `like` for being
//     ambiguous and stops there. Here a marker that is sometimes a content word carries lower
//     confidence and faces the gate, so the decision is tunable and measurable instead of
//     binary and invisible.
//
//  Pure text. Identical on every ASR backend.
//

import Foundation

enum TranscriptNormalizer {

    // MARK: - Filler vocabulary

    /// Never a content word in any of these languages, in any context.
    private static let hardFillers: Set<String> = [
        // English
        "uh", "um", "uhm", "erm", "hmm", "hm", "mmm",
        // Hebrew
        "אמ", "אהה", "אממ", "אמם",
        // Russian
        "эм", "ммм", "эээ", "мм",
    ]

    /// A content word somewhere, a disfluency here. Removed at lower confidence so the gate can
    /// price the risk, and so a per-language threshold can disable a marker that turns out to
    /// carry meaning more often than the corpus suggested.
    ///
    /// English `like` is deliberately absent: `I like it` is far too common for the confidence
    /// to ever clear a 0.99-precision bar, which is the same conclusion the shipping pass
    /// reached — reached here by a threshold rather than by omission.
    private static let discourseFillers: Set<String> = [
        "כאילו", "יעני",          // Hebrew: "like", "meaning"
        "типа", "короче",         // Russian: "like", "in short"
    ]

    /// Multi-word discourse fillers, keyed by their first word.
    private static let discoursePhrases: [[String]] = [
        ["как", "бы"],            // Russian: "sort of"
        ["это", "самое"],         // Russian: "you know, that thing"
    ]

    /// Words whose immediate repetition is usually intentional, so adjacent-word dedupe leaves
    /// them alone. `very very fast` and `had had` are speech, not stutter — and the cost of
    /// being wrong is deleting a word the user said.
    private static let legitimateRepeats: Set<String> = [
        "had", "that", "very", "no", "yes", "ha", "כן", "לא", "מאוד", "да", "нет", "очень",
    ]

    // MARK: - Entry point

    /// Every normalization edit that applies to `graph`, in application order.
    ///
    /// Proposed, not applied — the gate judges these like any other edit. `apply(to:)` below is
    /// the convenience for callers that have already accepted the confidence policy.
    ///
    /// The four passes are sequential rather than independent, and each is computed against the
    /// result of the previous one on a scratch copy. Whitespace has to run last and has to see
    /// the deletions: removing a word leaves two adjacent gaps behind, and a pass that only ever
    /// looked at the original token sequence would never know they had become adjacent. Edits
    /// refused on the scratch copy — a hard span, a committed token — are dropped here rather
    /// than emitted, so the list a gate receives is exactly the list that would apply.
    static func proposals(for graph: TokenGraph) -> [TranscriptEdit] {
        var scratch = graph
        var accepted: [TranscriptEdit] = []
        for pass in [fillerEdits, duplicateWordEdits, duplicatePunctuationEdits, whitespaceEdits] {
            for edit in pass(scratch) where scratch.apply(edit) { accepted.append(edit) }
        }
        return accepted
    }

    @discardableResult
    static func apply(to graph: inout TokenGraph) -> Int {
        var applied = 0
        for edit in proposals(for: graph) where graph.apply(edit) { applied += 1 }
        return applied
    }

    // MARK: - Fillers

    private static func fillerEdits(_ graph: TokenGraph) -> [TranscriptEdit] {
        var edits: [TranscriptEdit] = []
        let words = wordPositions(in: graph)
        var skipUntil = -1

        for (offset, position) in words.enumerated() where offset > skipUntil {
            let token = graph.tokens[position]
            let key = fold(token.rawText)

            if let phrase = matchingPhrase(at: offset, in: words, of: graph) {
                for step in 0..<phrase.count {
                    edits.append(delete(graph.tokens[words[offset + step]],
                                        source: .filler, confidence: 0.90,
                                        reason: "filler phrase: \(phrase.joined(separator: " "))"))
                }
                skipUntil = offset + phrase.count - 1
                continue
            }
            if hardFillers.contains(key) {
                edits.append(delete(token, source: .filler, confidence: 1.0, reason: "filler: \(key)"))
            } else if discourseFillers.contains(key) {
                edits.append(delete(token, source: .filler, confidence: 0.90, reason: "discourse filler: \(key)"))
            }
        }
        return edits
    }

    private static func matchingPhrase(at offset: Int,
                                       in words: [Int],
                                       of graph: TokenGraph) -> [String]? {
        for phrase in discoursePhrases where offset + phrase.count <= words.count {
            let candidate = (0..<phrase.count).map { fold(graph.tokens[words[offset + $0]].rawText) }
            if candidate == phrase { return phrase }
        }
        return nil
    }

    // MARK: - Adjacent duplicates

    private static func duplicateWordEdits(_ graph: TokenGraph) -> [TranscriptEdit] {
        var edits: [TranscriptEdit] = []
        let words = wordPositions(in: graph)
        guard words.count > 1 else { return [] }

        for offset in 1..<words.count {
            let previous = graph.tokens[words[offset - 1]]
            let current = graph.tokens[words[offset]]
            let key = fold(current.rawText)

            guard key == fold(previous.rawText), !key.isEmpty,
                  !legitimateRepeats.contains(key),
                  // Only when nothing but whitespace separates them: `the cat, the cat` is a
                  // repetition of a phrase, not a stutter, and deleting one word breaks it.
                  graph.tokens[(words[offset - 1] + 1)..<words[offset]]
                      .allSatisfy({ $0.kind == .whitespace }) else { continue }

            edits.append(delete(current, source: .normalization, confidence: 0.95, reason: "adjacent duplicate: \(key)"))
        }
        return edits
    }

    // MARK: - Punctuation

    /// `....` → `.`, `,,` → `,`. Runs of the *same* mark only — `?!` is deliberate.
    private static func duplicatePunctuationEdits(_ graph: TokenGraph) -> [TranscriptEdit] {
        var edits: [TranscriptEdit] = []

        // Adjacency in the token sequence, not adjacency among punctuation: `. x .` is two
        // sentences, and skipping the word between them would collapse it into one.
        for index in graph.tokens.indices.dropFirst() {
            let token = graph.tokens[index]
            let previous = graph.tokens[index - 1]
            guard token.kind == .punctuation, previous.rawText == token.rawText,
                  isRepeatable(token.rawText) else { continue }
            edits.append(delete(token, source: .normalization,
                                confidence: 1.0, reason: "repeated punctuation"))
        }
        return edits
    }

    private static func isRepeatable(_ text: String) -> Bool {
        [".", ",", "!", "?"].contains(text)
    }

    // MARK: - Whitespace

    /// A maximal run of whitespace *tokens* becomes one space, or one newline if any token in
    /// the run contained a break — paragraph structure is content, and flattening it to a space
    /// destroys it. Runs at either end disappear.
    ///
    /// Runs, not single tokens: the tokenizer emits one token per contiguous gap, so two
    /// adjacent whitespace tokens only ever exist because a word between them was deleted. That
    /// is exactly the case this pass has to clean up, and it is why it runs after the others.
    private static func whitespaceEdits(_ graph: TokenGraph) -> [TranscriptEdit] {
        var edits: [TranscriptEdit] = []
        var index = 0

        while index < graph.tokens.count {
            guard graph.tokens[index].kind == .whitespace else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < graph.tokens.count, graph.tokens[end + 1].kind == .whitespace {
                end += 1
            }
            let run = graph.tokens[index...end]
            defer { index = end + 1 }

            if index == 0 || end == graph.tokens.count - 1 {
                edits.append(contentsOf: run.map {
                    delete($0, source: .normalization, confidence: 1.0, reason: "surrounding whitespace")
                })
                continue
            }

            let canonical = run.contains { $0.effectiveText.contains(where: \.isNewline) } ? "\n" : " "
            if run[run.startIndex].effectiveText != canonical {
                edits.append(TranscriptEdit(target: run[run.startIndex].id,
                                            operation: .replace(canonical),
                                            source: .normalization, confidence: 1.0,
                                            reason: "collapsed whitespace"))
            }
            edits.append(contentsOf: run.dropFirst().map {
                delete($0, source: .normalization, confidence: 1.0, reason: "collapsed whitespace")
            })
        }
        return edits
    }

    // MARK: - Helpers

    private static func wordPositions(in graph: TokenGraph) -> [Int] {
        graph.tokens.indices.filter { graph.tokens[$0].isWord }
    }

    private static func delete(_ token: TranscriptToken,
                               source: EditSource,
                               confidence: Float,
                               reason: String) -> TranscriptEdit {
        TranscriptEdit(target: token.id, operation: .delete, source: source,
                       confidence: confidence, reason: reason)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
