//
//  SymSpell.swift
//  Whisperer
//
//  High-performance fuzzy string matching using Symmetric Delete spelling correction algorithm
//  Based on SymSpell: https://github.com/wolfgarbe/SymSpell
//

import Foundation

/// Represents a suggestion result from SymSpell lookup
struct SuggestItem: Equatable {
    let term: String           // The suggested dictionary word
    let distance: Int          // Edit distance from input
    let entry: DictionaryEntry // Full dictionary entry for this suggestion

    static func == (lhs: SuggestItem, rhs: SuggestItem) -> Bool {
        return lhs.term == rhs.term && lhs.distance == rhs.distance
    }
}

/// Verbosity level for suggestions
enum Verbosity {
    case top        // Only return the top suggestion
    case closest    // Return all suggestions with the smallest edit distance
    case all        // Return all suggestions within maxEditDistance
}

/// SymSpell spelling correction algorithm
class SymSpell {
    // Dictionary: deletion -> [original terms]
    // E.g., "docker" generates deletes: "ocker", "dcker", "doker", etc.
    // If we search for "doker", we generate its deletes and find "docker" matches
    private var deletes: [String: Set<String>] = [:]

    // Original dictionary entries by term
    private var dictionary: [String: DictionaryEntry] = [:]

    private let maxEditDistance: Int
    private let prefixLength: Int

    init(maxEditDistance: Int = 2, prefixLength: Int = 7) {
        self.maxEditDistance = maxEditDistance
        self.prefixLength = prefixLength
    }

    /// Add a dictionary entry to the index
    func createDictionaryEntry(key: String, entry: DictionaryEntry) {
        let keyLower = key.lowercased()

        // Store original entry
        dictionary[keyLower] = entry

        // Generate all deletions up to maxEditDistance
        let deletions = edits(keyLower, editDistance: 0, deleteWords: Set<String>())

        for deletion in deletions {
            if deletes[deletion] == nil {
                deletes[deletion] = Set<String>()
            }
            deletes[deletion]?.insert(keyLower)
        }
    }

    /// Rebuild the entire index from scratch
    func rebuild(with entries: [DictionaryEntry]) {
        deletes.removeAll()
        dictionary.removeAll()

        for entry in entries where entry.isEnabled {
            createDictionaryEntry(key: entry.incorrectForm, entry: entry)
        }

        Logger.debug("SymSpell rebuilt: \(dictionary.count) terms, \(deletes.count) deletes", subsystem: .app)
    }

    /// Lookup suggestions for an input word
    func lookup(input: String, verbosity: Verbosity = .closest, maxEditDistance: Int? = nil) -> [SuggestItem] {
        let inputLower = input.lowercased()
        let maxDist = maxEditDistance ?? self.maxEditDistance

        var suggestions = [SuggestItem]()
        var consideredDeletes = Set<String>()
        var consideredSuggestions = Set<String>()

        // Check if input is already in dictionary
        if let entry = dictionary[inputLower] {
            suggestions.append(SuggestItem(term: entry.correctForm, distance: 0, entry: entry))

            // If we only want the top match and distance is 0, return immediately
            if verbosity == .top {
                return suggestions
            }
        }

        // Generate deletions of the input word
        var candidates = [inputLower]
        consideredDeletes.insert(inputLower)

        for deleteDistance in 0..<maxDist {
            var tempCandidates = [String]()

            for candidate in candidates {
                // Stop if we already have a distance-0 match for top verbosity
                if verbosity == .top && !suggestions.isEmpty && suggestions[0].distance == 0 {
                    return suggestions
                }

                // Generate single-character deletions
                for i in 0..<candidate.count {
                    let delete = String(candidate.prefix(i) + candidate.suffix(candidate.count - i - 1))

                    if consideredDeletes.contains(delete) {
                        continue
                    }
                    consideredDeletes.insert(delete)

                    // Look up this deletion in our index
                    if let dictTerms = deletes[delete] {
                        for dictTerm in dictTerms {
                            if consideredSuggestions.contains(dictTerm) {
                                continue
                            }
                            consideredSuggestions.insert(dictTerm)

                            // Calculate actual edit distance
                            let distance = damerauLevenshteinDistance(inputLower, dictTerm)

                            if distance <= maxDist {
                                if let entry = dictionary[dictTerm] {
                                    let suggestion = SuggestItem(term: entry.correctForm, distance: distance, entry: entry)
                                    suggestions.append(suggestion)
                                }
                            }
                        }
                    }

                    // Add this deletion as a candidate for the next level
                    tempCandidates.append(delete)
                }
            }

            candidates = tempCandidates
        }

        // Sort by distance, then alphabetically
        suggestions.sort { (a, b) in
            if a.distance != b.distance {
                return a.distance < b.distance
            }
            return a.term < b.term
        }

        // Filter based on verbosity
        switch verbosity {
        case .top:
            return Array(suggestions.prefix(1))
        case .closest:
            if let minDistance = suggestions.first?.distance {
                return suggestions.filter { $0.distance == minDistance }
            }
            return suggestions
        case .all:
            return suggestions
        }
    }

    /// Lookup compound word corrections (for segmentation errors)
    /// This treats the input as a SINGLE term (joined words) and looks for matches
    /// It does NOT apply fuzzy matching to individual words separately
    func lookupCompound(input: String, maxEditDistance: Int? = nil) -> [SuggestItem] {
        // Join words without spaces and look up as single term
        // This handles cases like "githubrepo" → "github" (if in dictionary)
        let joinedInput = input.replacingOccurrences(of: " ", with: "").lowercased()

        // Only proceed if the joined version is meaningfully different
        guard joinedInput != input.lowercased() else {
            return []
        }

        // Look up the joined version as a single word
        return lookup(input: joinedInput, verbosity: .top, maxEditDistance: maxEditDistance)
    }

    // MARK: - Helper Methods

    /// Generate all possible deletions up to maxEditDistance
    private func edits(_ word: String, editDistance: Int, deleteWords: Set<String>) -> Set<String> {
        var result = deleteWords
        result.insert(word)

        if editDistance < maxEditDistance {
            for i in 0..<word.count {
                let delete = String(word.prefix(i) + word.suffix(word.count - i - 1))

                if !result.contains(delete) {
                    result.insert(delete)
                    // Recursively generate deletions
                    result = result.union(edits(delete, editDistance: editDistance + 1, deleteWords: result))
                }
            }
        }

        return result
    }

    /// Damerau-Levenshtein distance (allows transpositions)
    private func damerauLevenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1Array = Array(s1)
        let s2Array = Array(s2)
        let len1 = s1Array.count
        let len2 = s2Array.count

        if len1 == 0 { return len2 }
        if len2 == 0 { return len1 }

        var matrix = Array(repeating: Array(repeating: 0, count: len2 + 1), count: len1 + 1)

        for i in 0...len1 {
            matrix[i][0] = i
        }

        for j in 0...len2 {
            matrix[0][j] = j
        }

        for i in 1...len1 {
            for j in 1...len2 {
                let cost = s1Array[i - 1] == s2Array[j - 1] ? 0 : 1

                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,           // deletion
                    matrix[i][j - 1] + 1,           // insertion
                    matrix[i - 1][j - 1] + cost     // substitution
                )

                // Transposition
                if i > 1 && j > 1 &&
                   s1Array[i - 1] == s2Array[j - 2] &&
                   s1Array[i - 2] == s2Array[j - 1] {
                    matrix[i][j] = min(matrix[i][j], matrix[i - 2][j - 2] + cost)
                }
            }
        }

        return matrix[len1][len2]
    }
}
