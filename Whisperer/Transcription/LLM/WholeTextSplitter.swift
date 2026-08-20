//
//  WholeTextSplitter.swift
//  Whisperer
//
//  Cuts a finished transcript into segments that can be corrected in parallel.
//
//  The streaming path gets its batching for free — VAD hands it several chunks and they are
//  corrected together. The non-streaming path has the opposite problem: the whole text is present
//  at once and is sent as a *single* prompt, so a 5,000-character recording is one long serial
//  decode. The history DB has 123 long and 12 very-long recordings (avg 5,735 chars); those are the
//  ones where a user waits, and they are also the easiest to batch, because there is nothing to
//  wait for.
//
//  The cut has to be at sentence boundaries. Correction is a local rewrite — punctuation,
//  capitalisation, filler removal — so a segment that starts mid-sentence is out of distribution
//  for the model in exactly the way `ChunkLLMCoordinator`'s fragment mode exists to handle, and the
//  same seam repair then cleans up the joins.
//

import Foundation

enum WholeTextSplitter {

    // MARK: - Correction split (dictation whole-text path)

    /// Below this, a text is left as one segment. Splitting a short text costs a seam and buys at
    /// most one extra row of batch width, and the single-pass behaviour on short dictations is what
    /// the measured prompt-quality corpus in `docs/knowledge/llm/criteria.md` was scored against.
    static let minimumSplitLength = 400

    /// Target segment size, in characters. Around the p90 real chunk (145 chars) and comfortably
    /// inside the model's comfort zone for a `Correct` pass, so segments look like the streaming
    /// chunks the fragment prompt was tuned on.
    static let targetSegmentLength = 200

    /// A single sentence longer than this is split anyway, on the best inner boundary available.
    /// Dictation produces run-ons with no terminal punctuation at all; without this, "no sentence
    /// boundaries" would mean "no batching" on precisely the longest inputs.
    static let maximumSegmentLength = 600

    /// Splits `text` into segments to be corrected independently and rejoined.
    ///
    /// Returns a single-element array when the text is short or has no usable boundary — callers do
    /// not need to special-case that; a batch of one falls back to the single-stream path anyway.
    /// The concatenation of the returned segments, joined by a single space, contains every word of
    /// the input in order: nothing is dropped, which the tests assert word for word.
    static func split(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumSplitLength else { return [trimmed] }

        var segments: [String] = []
        var current = ""
        for sentence in sentences(of: trimmed) {
            // A sentence that would overshoot the target on its own goes into its own segment (or
            // several), rather than being welded onto the previous one.
            if current.count + sentence.count > targetSegmentLength, !current.isEmpty {
                segments.append(current)
                current = ""
            }
            if sentence.count > maximumSegmentLength {
                segments.append(contentsOf: hardSplit(sentence))
            } else if current.isEmpty {
                current = sentence
            } else {
                current += " " + sentence
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments.isEmpty ? [trimmed] : segments
    }

    // MARK: - Summary split (meeting overview map-reduce path)

    /// Minimum transcript length before splitting into chunks for parallel summarisation.
    /// Below this, single-pass overview generation is faster and the batch win is negligible.
    static let summaryMinimumSplitLength = 1_200

    /// Target chunk size for the map step. Larger than `targetSegmentLength` because
    /// summarisation needs cross-sentence context that a correction pass does not.
    static let summaryTargetChunkLength = 1_000

    /// Maximum chunk size before a hard split is forced. Sized for ~250 tokens per chunk at
    /// 4 chars/token, which keeps each map call well within the 300-token output budget.
    static let summaryMaximumChunkLength = 3_000

    /// Splits a transcript for parallel map-reduce summarisation.
    ///
    /// Returns a single-element array when the text is shorter than `summaryMinimumSplitLength`
    /// or has no usable sentence boundaries — callers treat width ≤ 2 as a single-pass fallback.
    /// Each chunk is large enough to summarise independently while preserving [Ns] markers.
    static func summarySplit(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= summaryMinimumSplitLength else { return [trimmed] }

        var segments: [String] = []
        var current = ""
        for sentence in sentences(of: trimmed) {
            if current.count + sentence.count > summaryTargetChunkLength, !current.isEmpty {
                segments.append(current)
                current = ""
            }
            if sentence.count > summaryMaximumChunkLength {
                segments.append(contentsOf: hardSummarySplit(sentence))
            } else if current.isEmpty {
                current = sentence
            } else {
                current += " " + sentence
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments.isEmpty ? [trimmed] : segments
    }

    private static func hardSummarySplit(_ sentence: String) -> [String] {
        var segments: [String] = []
        var current = ""
        for word in sentence.split(separator: " ", omittingEmptySubsequences: true) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count > summaryTargetChunkLength, !current.isEmpty {
                segments.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// Sentence-ish units. `enumerateSubstrings(.bySentences)` is used rather than a regex on
    /// `.!?` because it handles abbreviations, quotes and non-Latin punctuation — Hebrew and
    /// Russian are 17% of the corpus and a naive split mangles both.
    private static func sentences(of text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex ..< text.endIndex, options: .bySentences) {
            substring, _, _, _ in
            let piece = substring?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !piece.isEmpty { result.append(piece) }
        }
        // A run-on with no terminal punctuation comes back as one substring, which is correct and
        // is what `hardSplit` is for.
        return result.isEmpty ? [text] : result
    }

    /// Splits an over-long sentence on the best boundary available: a comma-ish pause if there is
    /// one near the target, otherwise a word boundary. Never mid-word — a split inside a word is a
    /// spelling error the model will confidently "correct".
    private static func hardSplit(_ sentence: String) -> [String] {
        var segments: [String] = []
        var current = ""
        for word in sentence.split(separator: " ", omittingEmptySubsequences: true) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count > targetSegmentLength,
               current.count >= targetSegmentLength / 2,
               // Prefer to break just after a pause, so the seam falls where the speaker paused.
               current.last.map({ ",;:—".contains($0) }) ?? false {
                segments.append(current)
                current = String(word)
            } else if candidate.count > maximumSegmentLength {
                segments.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }
}
