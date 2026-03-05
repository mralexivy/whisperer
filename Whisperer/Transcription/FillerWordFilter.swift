//
//  FillerWordFilter.swift
//  Whisperer
//
//  Removes filler words (um, uh, er, etc.) from transcribed text
//

import Foundation

struct FillerWordFilter {
    static let defaultFillerWords: Set<String> = [
        "um", "uh", "erm", "er", "ah", "hmm"
    ]

    /// Remove filler words from transcribed text using word-boundary matching.
    /// Handles single-word fillers only — preserves words that contain fillers
    /// as substrings (e.g., "umbrella" is not affected when filtering "um").
    static func removeFillers(
        from text: String,
        fillerWords: Set<String>? = nil
    ) -> String {
        let fillers = fillerWords ?? defaultFillerWords
        guard !fillers.isEmpty, !text.isEmpty else { return text }

        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        let filtered = words.filter { word in
            // Normalize: lowercase, strip punctuation for matching
            let normalized = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return !fillers.contains(normalized)
        }

        var result = filtered.joined(separator: " ")

        // Clean up orphaned punctuation artifacts
        result = result.replacingOccurrences(of: ", ,", with: ",")
        result = result.replacingOccurrences(of: "  ", with: " ")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
