//
//  PhoneticMatcher.swift
//  Whisperer
//
//  Phonetic/fuzzy matching for common technical term mishearings
//  Includes Soundex and Metaphone algorithms for voice-specific corrections
//

import Foundation

class PhoneticMatcher {
    // Dictionary of terms indexed by their phonetic codes
    private var soundexIndex: [String: Set<String>] = [:]
    private var metaphoneIndex: [String: Set<String>] = [:]
    private var termToEntry: [String: DictionaryEntry] = [:]

    // Common phonetic transformations for technical terms (legacy fallback)
    private let transformations: [(pattern: String, matches: [String])] = [
        // Kubernetes variations
        ("kubernetes", ["coopernetties", "cooper netties", "coopernet ease", "koo ber net ease"]),

        // PostgreSQL variations
        ("postgresql", ["post gress", "postgress", "post gres queue el", "postgres queue el"]),

        // GraphQL variations
        ("graphql", ["graph queue el", "graph ql", "graphical"]),

        // TypeScript variations
        ("typescript", ["type script", "typescripts"]),

        // JavaScript variations
        ("javascript", ["java script", "javascripts"]),

        // React Native
        ("react native", ["react native", "reactnative"]),

        // MongoDB
        ("mongodb", ["mongo db", "mongod b"]),

        // Redis
        ("redis", ["read is", "red is"]),

        // Docker
        ("docker", ["dock er", "doker"]),

        // Common tech abbreviations
        ("api", ["a p i", "ay pee eye"]),
        ("sql", ["s q l", "sequel", "s queue el"]),
        ("html", ["h t m l"]),
        ("css", ["c s s"]),
        ("json", ["j son", "jason"]),
    ]

    /// Rebuild phonetic indexes from dictionary entries
    func rebuild(with entries: [DictionaryEntry]) {
        soundexIndex.removeAll()
        metaphoneIndex.removeAll()
        termToEntry.removeAll()

        for entry in entries where entry.isEnabled {
            let term = entry.incorrectForm.lowercased()
            termToEntry[term] = entry

            // Index by Soundex
            let soundexCode = soundex(term)
            if soundexIndex[soundexCode] == nil {
                soundexIndex[soundexCode] = Set<String>()
            }
            soundexIndex[soundexCode]?.insert(term)

            // Index by Metaphone
            let metaphoneCode = metaphone(term)
            if metaphoneIndex[metaphoneCode] == nil {
                metaphoneIndex[metaphoneCode] = Set<String>()
            }
            metaphoneIndex[metaphoneCode]?.insert(term)
        }

        Logger.debug("PhoneticMatcher rebuilt: \(termToEntry.count) terms indexed", subsystem: .app)
    }

    /// Find phonetic matches for input word
    func findMatches(_ input: String, maxResults: Int = 5) -> [(term: String, similarity: Double, entry: DictionaryEntry)] {
        let normalized = input.lowercased().trimmingCharacters(in: .whitespaces)

        var results: [(term: String, similarity: Double, entry: DictionaryEntry)] = []

        // 1. Check legacy transformations first (highest priority)
        for (correct, variations) in transformations {
            for variation in variations {
                if normalized == variation.lowercased() {
                    if let entry = termToEntry[correct] {
                        return [(correct, 1.0, entry)]
                    }
                }
            }
        }

        // 2. Try Soundex matching
        let inputSoundex = soundex(normalized)
        if let matches = soundexIndex[inputSoundex] {
            for match in matches {
                if let entry = termToEntry[match] {
                    let similarity = phoneticSimilarity(word1: normalized, word2: match)
                    results.append((match, similarity, entry))
                }
            }
        }

        // 3. Try Metaphone matching
        let inputMetaphone = metaphone(normalized)
        if let matches = metaphoneIndex[inputMetaphone] {
            for match in matches {
                if let entry = termToEntry[match] {
                    // Avoid duplicates from Soundex
                    if !results.contains(where: { $0.term == match }) {
                        let similarity = phoneticSimilarity(word1: normalized, word2: match)
                        results.append((match, similarity, entry))
                    }
                }
            }
        }

        // Sort by similarity (highest first) and return top results
        results.sort { $0.similarity > $1.similarity }
        return Array(results.prefix(maxResults))
    }

    /// Legacy method for backwards compatibility
    func findMatch(_ input: String) -> String? {
        let matches = findMatches(input, maxResults: 1)
        return matches.first?.term
    }

    // MARK: - Soundex Algorithm

    /// Soundex phonetic encoding (American Soundex)
    func soundex(_ word: String) -> String {
        let word = word.uppercased().filter { $0.isLetter }
        guard !word.isEmpty else { return "0000" }

        let chars = Array(word)
        var result = String(chars[0])

        let soundexMap: [Character: Character] = [
            "B": "1", "F": "1", "P": "1", "V": "1",
            "C": "2", "G": "2", "J": "2", "K": "2", "Q": "2", "S": "2", "X": "2", "Z": "2",
            "D": "3", "T": "3",
            "L": "4",
            "M": "5", "N": "5",
            "R": "6"
        ]

        var lastCode: Character = "0"
        if let firstCode = soundexMap[chars[0]] {
            lastCode = firstCode
        }

        for i in 1..<chars.count {
            if let code = soundexMap[chars[i]] {
                if code != lastCode {
                    result.append(code)
                    lastCode = code

                    if result.count == 4 {
                        break
                    }
                }
            } else {
                // Vowels and non-mapped consonants reset the sequence
                lastCode = "0"
            }
        }

        // Pad with zeros
        while result.count < 4 {
            result.append("0")
        }

        return result
    }

    // MARK: - Metaphone Algorithm (Simplified)

    /// Simplified Metaphone phonetic encoding
    func metaphone(_ word: String) -> String {
        let word = word.uppercased().filter { $0.isLetter }
        guard !word.isEmpty else { return "" }

        var result = ""
        var chars = Array(word)

        // Remove duplicate letters
        chars = chars.enumerated().filter { index, char in
            index == 0 || char != chars[index - 1]
        }.map { $0.element }

        for i in 0..<chars.count {
            let char = chars[i]
            let prev = i > 0 ? chars[i - 1] : Character(" ")
            let next = i < chars.count - 1 ? chars[i + 1] : Character(" ")

            switch char {
            case "A", "E", "I", "O", "U":
                if i == 0 { result.append(char) }
            case "B":
                if i == chars.count - 1 && prev == "M" {
                    // Silent B after M at end
                    continue
                }
                result.append("B")
            case "C":
                if next == "H" {
                    result.append("X")
                } else if next == "I" || next == "E" || next == "Y" {
                    result.append("S")
                } else {
                    result.append("K")
                }
            case "D":
                if next == "G" && (i + 2 < chars.count) && "EIY".contains(chars[i + 2]) {
                    result.append("J")
                } else {
                    result.append("T")
                }
            case "G":
                if next == "H" && i < chars.count - 2 {
                    continue // Skip GH
                } else if next == "N" && i == chars.count - 2 {
                    continue // Silent G before N at end
                } else if "EIY".contains(next) {
                    result.append("J")
                } else {
                    result.append("K")
                }
            case "H":
                if "AEIOU".contains(prev) && !"AEIOU".contains(next) {
                    continue // Skip H after vowel if not before vowel
                }
                result.append("H")
            case "K":
                if prev != "C" {
                    result.append("K")
                }
            case "P":
                if next == "H" {
                    result.append("F")
                } else {
                    result.append("P")
                }
            case "Q":
                result.append("K")
            case "S":
                if next == "H" {
                    result.append("X")
                } else if i < chars.count - 2 && next == "I" && (chars[i + 2] == "O" || chars[i + 2] == "A") {
                    result.append("X")
                } else {
                    result.append("S")
                }
            case "T":
                if next == "H" {
                    result.append("0")
                } else if i < chars.count - 2 && next == "I" && (chars[i + 2] == "O" || chars[i + 2] == "A") {
                    result.append("X")
                } else {
                    result.append("T")
                }
            case "V":
                result.append("F")
            case "W", "Y":
                if "AEIOU".contains(next) {
                    result.append(char)
                }
            case "X":
                result.append("KS")
            case "Z":
                result.append("S")
            default:
                result.append(char)
            }
        }

        return result
    }

    // MARK: - Similarity Scoring

    /// Calculate phonetic similarity between two words (0.0 to 1.0)
    func phoneticSimilarity(word1: String, word2: String) -> Double {
        let soundex1 = soundex(word1)
        let soundex2 = soundex(word2)
        let metaphone1 = metaphone(word1)
        let metaphone2 = metaphone(word2)

        var score = 0.0

        // Soundex exact match: +0.5
        if soundex1 == soundex2 {
            score += 0.5
        }

        // Metaphone exact match: +0.5
        if metaphone1 == metaphone2 {
            score += 0.5
        }

        // Levenshtein distance penalty
        let distance = levenshteinDistance(word1, word2)
        let maxLen = max(word1.count, word2.count)
        if maxLen > 0 {
            let editSimilarity = 1.0 - (Double(distance) / Double(maxLen))
            score = (score + editSimilarity) / 2.0
        }

        return min(max(score, 0.0), 1.0)
    }

    // MARK: - Helper Methods

    // Simple Levenshtein distance implementation
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1 = Array(s1)
        let s2 = Array(s2)

        var distances = Array(repeating: Array(repeating: 0, count: s2.count + 1), count: s1.count + 1)

        for i in 0...s1.count {
            distances[i][0] = i
        }

        for j in 0...s2.count {
            distances[0][j] = j
        }

        for i in 1...s1.count {
            for j in 1...s2.count {
                if s1[i - 1] == s2[j - 1] {
                    distances[i][j] = distances[i - 1][j - 1]
                } else {
                    distances[i][j] = min(
                        distances[i - 1][j] + 1,      // deletion
                        distances[i][j - 1] + 1,      // insertion
                        distances[i - 1][j - 1] + 1   // substitution
                    )
                }
            }
        }

        return distances[s1.count][s2.count]
    }
}
