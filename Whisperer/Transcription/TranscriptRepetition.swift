//
//  TranscriptRepetition.swift
//  Whisperer
//
//  Detects decoder repetition loops in a finished decode result.
//

import Foundation

/// Text-level detection of a whisper decoder repetition loop.
///
/// Distinct from `EagerStreamEngine`'s repetition guard, which works on *words with sample
/// indices* and protects the confirmed stream across passes. This one works on a plain string
/// and is the last line of defence for text that never went through the engine — the VAD chunk
/// path, the tail decode, and the eager hypothesis the stop path reuses as final output.
///
/// ### Why it scans every offset, not just the prefix
///
/// The check this replaces built its candidate phrase from `words.prefix(phraseLen)` and counted
/// occurrences of that one phrase. A loop that starts anywhere other than word 0 is invisible to
/// it. On 2026-08-20 a dictation pasted 1164 characters ending in `the right of` repeated 34
/// times; the string began `this language accordingly also in live`, so all four prefix phrases
/// occurred exactly once and the guard returned false. The loop reached the clipboard.
///
/// ### Why consecutive runs, not total occurrences
///
/// A long dictation legitimately says the same three words twice, far apart — counting total
/// occurrences would reject it. A stuck decoder emits the phrase *back to back*. Counting the
/// longest consecutive run is what separates the two, and it is also what makes the threshold
/// meaningful: three copies in a row is not something a speaker does by accident.
enum TranscriptRepetition {

    /// Shortest phrase considered. Below three words the false-positive risk is real: "no no no"
    /// and "very very very" are things people say.
    static let minimumPhraseLength = 3

    /// Longest phrase considered. Loops are short by nature — the decoder is stuck on a few
    /// tokens, not reciting a sentence — and every extra length costs another pass over the array.
    static let maximumPhraseLength = 6

    /// Consecutive copies that mean a loop. Two is real speech ("that's it, that's it"); three
    /// back-to-back is not.
    static let maximumConsecutiveCopies = 3

    /// True when `words` contains a phrase repeated `maximumConsecutiveCopies` times back to back.
    ///
    /// `words` is expected pre-lowercased and whitespace-split by the caller — this runs on every
    /// decode result on the hot path, so it does not re-normalize.
    ///
    /// Cost is O(n) comparisons per phrase length, with no allocation: the text is periodic with
    /// period `length` exactly where `words[i] == words[i + length]`, so a run of `length · (copies
    /// - 1)` consecutive such positions is `copies` copies back to back. Counting the run instead
    /// of comparing whole windows is what keeps this linear. The version this replaces called
    /// `components(separatedBy:)` over the whole string per phrase length, allocating an array of
    /// substrings each time.
    static func containsLoop(words: [Substring]) -> Bool {
        guard words.count >= minimumPhraseLength * maximumConsecutiveCopies else { return false }

        for length in minimumPhraseLength...maximumPhraseLength {
            // Need room for the required number of copies before the length is worth trying.
            // Lengths only grow, so the first one that does not fit ends the search.
            guard words.count >= length * maximumConsecutiveCopies else { break }

            // Exactly `copies` back-to-back copies of a `length`-word phrase span
            // `length · copies` words, within which `words[i] == words[i + length]` holds for
            // `length · (copies - 1)` consecutive positions. Requiring the full run is what keeps
            // the threshold honest: 8 words of a 3-word phrase is 2⅔ copies and must not fire.
            let requiredRun = length * (maximumConsecutiveCopies - 1)
            var run = 0
            for index in 0..<(words.count - length) {
                run = words[index] == words[index + length] ? run + 1 : 0
                if run >= requiredRun { return true }
            }
        }

        return false
    }

    // MARK: - Character-level spirals

    /// Longest character cycle considered. A character spiral is a decoder stuck on one or two
    /// tokens, not on a phrase — `containsLoop` already owns everything phrase-shaped.
    static let characterCycleMaxPeriod = 4

    /// Characters a cycle must span before it counts as degenerate.
    ///
    /// Measured, not chosen. Every repeated-character run in five days of
    /// `~/Library/Logs/Whisperer/whisperer-2026-09-*.log` was either benign and at most **7**
    /// characters (digits inside sample counts, `*` in a log marker) or the spiral itself at
    /// **72-100**. Sixteen is twice the largest benign run and a quarter of the smallest real
    /// one, so neither side is close to the line.
    static let minimumDegenerateSpan = 16

    /// True when `text` contains a cycle of at most `characterCycleMaxPeriod` scalars repeated
    /// across at least `minimumDegenerateSpan` characters.
    ///
    /// ### Why this exists next to `containsLoop`
    ///
    /// `containsLoop` splits on spaces and needs nine words before it can fire. A character
    /// spiral has **no spaces** — it is one enormous word — so every caller of `containsLoop`
    /// was structurally blind to it. On 2026-09-15 a 23-minute Hebrew meeting came back with
    /// refine windows 59-61 decoded as a 90-100 character run of `ה`, the word-level guard
    /// returned false for all of them, and the run was then fed back as the *initial prompt* for
    /// the next window and rendered as a wall of one letter in the transcript.
    static func containsCharacterLoop(in text: String) -> Bool {
        firstDegenerateRun(in: Array(text.unicodeScalars)) != nil
    }

    /// `text` with every degenerate run collapsed to a single copy of its cycle.
    ///
    /// A collapse rather than a rejection because the spiral arrives welded to real speech:
    /// the 2026-09-15 payload was `להיות בעיני פוזיטי א` followed by ninety `ה`. Dropping the
    /// string would have thrown away three real words to remove one artefact.
    ///
    /// Returns `text` itself when there is nothing to collapse, so the overwhelmingly common
    /// case costs one scan and no allocation beyond it.
    static func collapsingDegenerateRuns(in text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        guard firstDegenerateRun(in: scalars) != nil else { return text }

        // Re-scan after each collapse rather than collecting ranges up front: removing a run can
        // join its neighbours into a new one (`אההה…אההה…` → `אהאה`), and a second pass over a
        // string this short is cheaper than reasoning about overlapping ranges.
        while let run = firstDegenerateRun(in: scalars) {
            // Copied out before the mutation: `replaceSubrange` with a slice of the same array
            // is an overlapping access.
            let unit = Array(scalars[run.range.lowerBound..<(run.range.lowerBound + run.period)])
            scalars.replaceSubrange(run.range, with: unit)
        }

        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// Where the first degenerate run sits, and the length of its repeating unit.
    ///
    /// Same periodicity trick as `containsLoop`: the text is periodic with period `p` exactly
    /// where `scalars[i] == scalars[i + p]`, so a run of consecutive such positions of length
    /// `n` means `n + p` scalars are covered by repeats of a `p`-scalar unit.
    private static func firstDegenerateRun(
        in scalars: [UnicodeScalar]
    ) -> (range: Range<Int>, period: Int)? {
        guard scalars.count >= minimumDegenerateSpan else { return nil }

        for period in 1...characterCycleMaxPeriod {
            // Span `minimumDegenerateSpan` needs this many matching positions…
            let requiredRun = minimumDegenerateSpan - period
            // …and the unit must still repeat at least three times over that span, so a long
            // period cannot qualify on two-and-a-bit copies.
            guard requiredRun >= period * 2 else { continue }

            var run = 0
            var start = 0
            for index in 0..<(scalars.count - period) {
                if scalars[index] == scalars[index + period] {
                    if run == 0 { start = index }
                    run += 1
                    if run >= requiredRun, isAlphanumeric(scalars[start..<(start + period)]) {
                        // Extend to the end of the periodicity — the loop above stops at the
                        // threshold, not at the end of the run.
                        var end = index + period
                        while end < scalars.count, scalars[end - period] == scalars[end] { end += 1 }
                        return (start..<end, period)
                    }
                } else {
                    run = 0
                }
            }
        }

        return nil
    }

    /// A repeating unit only counts when it carries a letter or a digit. Without this, a `……………`
    /// elision marker, a `--------------` rule and a row of exclamation marks all read as spirals
    /// — all three occur in real transcripts and in this app's own prompts.
    private static func isAlphanumeric(_ unit: ArraySlice<UnicodeScalar>) -> Bool {
        unit.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
