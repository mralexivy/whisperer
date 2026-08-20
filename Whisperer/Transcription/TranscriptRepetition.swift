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
}
