//
//  CorrectionEngine.swift
//  Whisperer
//
//  High-performance text correction engine using HashMap and Trie
//

import Foundation

struct CorrectionResult {
    let text: String
    let corrections: [(range: Range<String.Index>, original: String, replacement: String, category: String?, notes: String?, entryId: UUID)]
}

class CorrectionEngine {
    // Fast O(1) exact lookup for single words - maps incorrectForm to DictionaryEntry
    private var exactLookup: [String: DictionaryEntry] = [:]

    // Multi-word phrase matching
    private var phraseLookup: [String: DictionaryEntry] = [:]

    // SymSpell for high-performance fuzzy matching
    private var symSpell: SymSpell?

    // Phonetic matcher for voice-specific corrections
    private var phoneticMatcher: PhoneticMatcher?

    // Spell validator to prevent fuzzy matching of valid English words
    private let spellValidator = SpellValidator.shared

    init(entries: [DictionaryEntry]) {
        self.symSpell = SymSpell(maxEditDistance: 2, prefixLength: 7)
        self.phoneticMatcher = PhoneticMatcher()
        rebuild(with: entries)
    }

    func rebuild(with entries: [DictionaryEntry]) {
        exactLookup.removeAll()
        phraseLookup.removeAll()

        for entry in entries where entry.isEnabled {
            let incorrect = entry.incorrectForm.lowercased()

            // Check if it's a multi-word phrase
            if incorrect.contains(" ") {
                phraseLookup[incorrect] = entry
            } else {
                exactLookup[incorrect] = entry
            }
        }

        // Rebuild SymSpell and PhoneticMatcher indexes
        symSpell?.rebuild(with: entries.filter { $0.isEnabled })
        phoneticMatcher?.rebuild(with: entries.filter { $0.isEnabled })

        Logger.debug("CorrectionEngine rebuilt: \(exactLookup.count) words, \(phraseLookup.count) phrases", subsystem: .app)
    }

    func applyCorrections(_ text: String, maxEditDistance: Int = 2, usePhonetic: Bool = true) -> CorrectionResult {
        let startTime = Date()
        var corrections: [(range: Range<String.Index>, original: String, replacement: String, category: String?, notes: String?, entryId: UUID)] = []

        // Tokenize the input text while preserving punctuation and spacing
        var result = text
        var offset = 0

        // First pass: multi-word phrases (longer matches first)
        let sortedPhrases = phraseLookup.keys.sorted { $0.count > $1.count }
        for phrase in sortedPhrases {
            guard let entry = phraseLookup[phrase] else { continue }
            let replacement = entry.correctForm

            // Case-insensitive search
            let searchText = result.lowercased()
            var searchRange = searchText.startIndex..<searchText.endIndex

            while let range = searchText.range(of: phrase, options: .caseInsensitive, range: searchRange) {
                // Check word boundaries
                let isWordBoundary = isAtWordBoundary(in: searchText, range: range)
                if isWordBoundary {
                    // Get the actual range in the original string
                    let originalText = String(result[range])
                    result.replaceSubrange(range, with: replacement)

                    corrections.append((range: range, original: originalText, replacement: replacement, category: entry.category, notes: entry.notes, entryId: entry.id))

                    // Adjust search range to continue after this replacement
                    let newIndex = result.index(range.lowerBound, offsetBy: replacement.count)
                    if newIndex < result.endIndex {
                        searchRange = newIndex..<searchText.endIndex
                    } else {
                        break
                    }
                } else {
                    // Move past this match
                    if range.upperBound < searchText.endIndex {
                        searchRange = range.upperBound..<searchText.endIndex
                    } else {
                        break
                    }
                }
            }
        }

        // Second pass: compound word segmentation errors (e.g., "post gres" -> "PostgreSQL")
        if maxEditDistance > 0 {
            result = correctCompoundWords(result, maxEditDistance: maxEditDistance, corrections: &corrections)
        }

        // Third pass: single word corrections
        let words = result.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        var processedText = result

        for word in words {
            let wordLower = word.lowercased()
            let wordLength = wordLower.count

            // Try exact match first (works for any word length)
            if let entry = exactLookup[wordLower] {
                processedText = replaceWord(processedText, word: String(word), entry: entry, corrections: &corrections)
                continue
            }

            // For fuzzy matching, check if word is valid English
            // Skip spell check for non-Latin words (Hebrew, Russian, etc.) - they also skip fuzzy
            let isLatinWord = spellValidator.isLatinWord(wordLower)
            let isValidEnglishWord = isLatinWord && spellValidator.isValidEnglishWord(wordLower)

            // Skip fuzzy matching if:
            // 1. Word is a valid English word (prevents "cloud" → "Claude")
            // 2. Word is non-Latin script (prevents mangling Hebrew/Russian)
            guard !isValidEnglishWord && isLatinWord else {
                continue
            }

            // Try SymSpell fuzzy match - ONLY for invalid/unknown Latin words
            if maxEditDistance > 0 && wordLength >= 4,
               let suggestions = symSpell?.lookup(input: wordLower, verbosity: .top, maxEditDistance: maxEditDistance),
               let best = suggestions.first,
               best.distance > 0 {
                // Edit distance should be less than 1/3 of word length
                if best.distance <= max(1, wordLength / 3) {
                    processedText = replaceWord(processedText, word: String(word), entry: best.entry, corrections: &corrections)
                    continue
                }
            }

            // Try phonetic match as fallback - also only for invalid Latin words
            if usePhonetic && wordLength >= 4,
               let phoneticMatches = phoneticMatcher?.findMatches(wordLower, maxResults: 1),
               let best = phoneticMatches.first,
               best.similarity >= 0.7 {
                processedText = replaceWord(processedText, word: String(word), entry: best.entry, corrections: &corrections)
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed > 0.001 {
            Logger.debug("Correction took \(String(format: "%.2f", elapsed * 1000))ms for \(corrections.count) corrections", subsystem: .app)
        }

        return CorrectionResult(text: processedText, corrections: corrections)
    }

    private func correctCompoundWords(_ text: String, maxEditDistance: Int, corrections: inout [(range: Range<String.Index>, original: String, replacement: String, category: String?, notes: String?, entryId: UUID)]) -> String {
        // This function handles segmentation errors where multi-word phrases
        // are in the dictionary (e.g., "post gres" → "PostgreSQL")
        // We ONLY correct if the combined phrase exists in phraseLookup
        // We do NOT apply fuzzy matching to individual words and recombine

        var result = text
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)

        guard words.count >= 2 else { return result }

        // Look for word pairs/triples that match phrases in our dictionary
        var i = 0
        while i < words.count - 1 {
            var matched = false

            // Try 3-word phrases first, then 2-word
            for phraseLength in [3, 2] {
                guard i + phraseLength <= words.count else { continue }

                let phraseWords = Array(words[i..<i+phraseLength])
                let phrase = phraseWords.joined(separator: " ").lowercased()

                // Check exact match in phrase lookup
                if let entry = phraseLookup[phrase] {
                    // Found an exact phrase match - replace it
                    let pattern = phraseWords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "\\s+")
                    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                        let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
                        if let match = regex.firstMatch(in: result, range: nsRange),
                           let range = Range(match.range, in: result) {
                            let originalText = String(result[range])
                            result.replaceSubrange(range, with: entry.correctForm)

                            corrections.append((range: range, original: originalText, replacement: entry.correctForm, category: entry.category, notes: entry.notes, entryId: entry.id))
                            matched = true
                            i += phraseLength
                            break
                        }
                    }
                }

                // Try fuzzy match for the combined phrase (joined without space)
                // This handles "githubrepo" → "GitHub repo" type errors
                if !matched && maxEditDistance > 0 {
                    let joinedPhrase = phraseWords.joined().lowercased()
                    if let suggestions = symSpell?.lookup(input: joinedPhrase, verbosity: .top, maxEditDistance: maxEditDistance),
                       let best = suggestions.first,
                       best.distance > 0 && best.distance <= maxEditDistance {
                        // Only accept if the match is very close (distance <= 1 for compound)
                        if best.distance <= 1 {
                            let pattern = phraseWords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "\\s*")
                            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                                let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
                                if let match = regex.firstMatch(in: result, range: nsRange),
                                   let range = Range(match.range, in: result) {
                                    let originalText = String(result[range])
                                    result.replaceSubrange(range, with: best.entry.correctForm)

                                    corrections.append((range: range, original: originalText, replacement: best.entry.correctForm, category: best.entry.category, notes: "Segmentation correction", entryId: best.entry.id))
                                    matched = true
                                    i += phraseLength
                                    break
                                }
                            }
                        }
                    }
                }
            }

            if !matched {
                i += 1
            }
        }

        return result
    }

    private func replaceWord(_ text: String, word: String, entry: DictionaryEntry, corrections: inout [(range: Range<String.Index>, original: String, replacement: String, category: String?, notes: String?, entryId: UUID)]) -> String {
        var result = text
        let searchText = result.lowercased()
        let searchWord = word.lowercased()
        let replacement = entry.correctForm
        var searchRange = searchText.startIndex..<searchText.endIndex

        while let range = searchText.range(of: searchWord, options: .literal, range: searchRange) {
            // Check word boundaries
            if isAtWordBoundary(in: searchText, range: range) {
                let originalText = String(result[range])
                result.replaceSubrange(range, with: replacement)

                corrections.append((range: range, original: originalText, replacement: replacement, category: entry.category, notes: entry.notes, entryId: entry.id))

                // Adjust search range
                let newIndex = result.index(range.lowerBound, offsetBy: replacement.count)
                if newIndex < result.endIndex {
                    searchRange = newIndex..<result.endIndex
                } else {
                    break
                }
            } else {
                // Move past this match
                if range.upperBound < searchText.endIndex {
                    searchRange = range.upperBound..<searchText.endIndex
                } else {
                    break
                }
            }
        }

        return result
    }

    private func isAtWordBoundary(in text: String, range: Range<String.Index>) -> Bool {
        let beforeBoundary: Bool
        if range.lowerBound == text.startIndex {
            beforeBoundary = true
        } else {
            let charBefore = text[text.index(before: range.lowerBound)]
            beforeBoundary = !charBefore.isLetter && !charBefore.isNumber
        }

        let afterBoundary: Bool
        if range.upperBound == text.endIndex {
            afterBoundary = true
        } else {
            let charAfter = text[range.upperBound]
            afterBoundary = !charAfter.isLetter && !charAfter.isNumber
        }

        return beforeBoundary && afterBoundary
    }
}
