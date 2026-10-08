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
    // Avoid scanning every dictionary phrase for every transcription. Most recordings
    // contain only a small subset of the phrases' first words.
    private var phraseKeysByFirstToken: [String: [String]] = [:]

    // SymSpell for high-performance fuzzy matching
    private var symSpell: SymSpell?

    // Phonetic matcher for voice-specific corrections
    private var phoneticMatcher: PhoneticMatcher?

    // Spell validator to prevent fuzzy matching of valid English words
    private let spellValidator = SpellValidator.shared

    // Compiled patterns for `correctCompoundWords`, keyed by pattern string.
    //
    // The compilation used to sit inside the word-pair scan, so a transcript that repeats a
    // phrase re-parsed and re-compiled the same pattern once per occurrence. `NSRegularExpression`
    // compilation is the expensive half of a regex: matching a compiled instance is thread-safe
    // and cheap, parsing the pattern is neither. On the 15,309-character transcript that took
    // 2177 ms this was the second-largest term after the index walks in `replaceAllOccurrences`.
    //
    // Bounded by the dictionary, not by the input: a pattern is only built when a word pair or
    // triple already matched `phraseLookup` or a SymSpell entry, so the key space is the phrase
    // set. `rebuild(with:)` clears it, because an entry can change its `incorrectForm`.
    private var compiledPhrasePatterns: [String: NSRegularExpression] = [:]

    init(entries: [DictionaryEntry]) {
        self.symSpell = SymSpell(maxEditDistance: 2, prefixLength: 7)
        self.phoneticMatcher = PhoneticMatcher()
        rebuild(with: entries)
    }

    func rebuild(with entries: [DictionaryEntry]) {
        exactLookup.removeAll()
        phraseLookup.removeAll()
        phraseKeysByFirstToken.removeAll()
        compiledPhrasePatterns.removeAll()

        for entry in entries where entry.isEnabled {
            let incorrect = entry.incorrectForm.lowercased()

            // Drop identity rules at index time — they can never produce a non-equal substitution
            // because the replacement is literally the same string. Note: incorrectForm is stored
            // lowercased (see DictionaryEntry.init), so "a" → "A" is NOT identity ("a" != "A").
            guard incorrect != entry.correctForm else { continue }

            // Check if it's a multi-word phrase
            if incorrect.contains(" ") {
                phraseLookup[incorrect] = entry
                if let firstToken = searchTokens(in: incorrect).first {
                    phraseKeysByFirstToken[firstToken, default: []].append(incorrect)
                }
            } else {
                exactLookup[incorrect] = entry
            }
        }

        // Rebuild SymSpell and PhoneticMatcher indexes.
        // Auto-learned entries are deliberately excluded: they were promoted from a single observed
        // mishearing, so they are only trustworthy for the exact string that was observed. Feeding
        // `glyn → Glean` to the fuzzy indexes would also pull in `glynn`, `glyns` and every soundex
        // neighbour. Confirming an entry clears `observedSource` and it joins the indexes then.
        let fuzzyEntries = entries.filter { $0.isEnabled && !$0.isAutoLearned }
        symSpell?.rebuild(with: fuzzyEntries)
        phoneticMatcher?.rebuild(with: fuzzyEntries)

        Logger.debug("CorrectionEngine rebuilt: \(exactLookup.count) words, \(phraseLookup.count) phrases", subsystem: .app)
    }

    func applyCorrections(_ text: String, maxEditDistance: Int = 2, usePhonetic: Bool = true) -> CorrectionResult {
        let startTime = Date()
        var corrections: [(range: Range<String.Index>, original: String, replacement: String, category: String?, notes: String?, entryId: UUID)] = []

        // Tokenize the input text while preserving punctuation and spacing
        var result = text

        // First pass: multi-word phrases (longer matches first).
        // Ambiguous all-English phrase aliases (e.g. "to do" → TODO, "not a bug" → NOTABUG) are
        // removed by the LLM data audit rather than blocked here. A phrase-level engine guard was
        // tried and produced false negatives: phonetic spellings like "java script" → JavaScript
        // and "type script" → TypeScript use common English tokens and were incorrectly blocked.
        let inputTokens = Set(searchTokens(in: result.lowercased()))
        let candidatePhrases = Set(inputTokens.flatMap { phraseKeysByFirstToken[$0] ?? [] })
        let sortedPhrases = candidatePhrases.sorted { $0.count > $1.count }
        for phrase in sortedPhrases {
            guard let entry = phraseLookup[phrase] else { continue }
            result = replaceAllOccurrences(in: result, of: phrase, with: entry.correctForm, entry: entry, corrections: &corrections)
        }

        // Second pass: compound word segmentation errors (e.g., "post gres" -> "PostgreSQL")
        if maxEditDistance > 0 {
            result = correctCompoundWords(result, maxEditDistance: maxEditDistance, corrections: &corrections)
        }

        // Third pass: single word corrections
        let words = result.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        var processedText = result

        // Each distinct word is handled once. `replaceWord` already rewrites *every* occurrence,
        // so visiting a repeated word again re-scans text that has already been corrected. For an
        // ordinary entry the repeat visits are harmless no-ops, but an entry whose replacement
        // contains its own search term (`gpt → GPT model`) matches its own output: "gpt and gpt"
        // became "GPT model model and GPT model model", one extra expansion per duplicate.
        // Deduplicating case-insensitively matches `replaceWord`'s own case-insensitive search.
        var handledWords = Set<String>()

        for word in words {
            let wordLower = word.lowercased()
            guard handledWords.insert(wordLower).inserted else { continue }
            let wordLength = wordLower.count

            // Try exact match first (works for any word length).
            // Safety gate for built-in and auto-learned entries: if the alias is a valid English
            // word, skip. Only entries the user authored by hand (isBuiltIn == false and not
            // auto-learned) always fire — the user explicitly asked for those.
            //
            // Auto-learned entries already passed the same spell gate at promotion time; repeating
            // it here is defence in depth, so an imported or hand-edited row cannot bypass it.
            // Without it a learned `backend → firebase` would rewrite every "backend" ever dictated.
            if let entry = exactLookup[wordLower] {
                let shouldApply = (!entry.isBuiltIn && !entry.isAutoLearned) || !isValidEnglishAlias(wordLower)
                if shouldApply {
                    processedText = replaceWord(processedText, word: String(word), entry: entry, corrections: &corrections)
                }
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

    /// Returns true if the single-word alias is a valid English word.
    /// Used to gate built-in exact-match corrections so ordinary words like "closure" or
    /// "hassle" are never replaced by tech terms in normal dictation.
    private func isValidEnglishAlias(_ word: String) -> Bool {
        spellValidator.isLatinWord(word) && spellValidator.isValidEnglishWord(word)
    }

    private func searchTokens(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { $0.lowercased() }
    }

    /// Returns the compiled form of `pattern`, compiling it on first use.
    ///
    /// The two callers build different patterns for the same words (`\s+` for an exact phrase
    /// hit, `\s*` for a segmentation hit), so the pattern string is the right key: it is what
    /// the compiler actually consumes, and two spellings of one phrase must not share an entry.
    /// A malformed pattern returns nil and is not cached, which keeps the caller's old
    /// `try?`-and-skip behaviour.
    private func compiledPattern(_ pattern: String) -> NSRegularExpression? {
        if let cached = compiledPhrasePatterns[pattern] { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            Logger.error("CorrectionEngine could not compile phrase pattern: \(pattern)", subsystem: .app)
            return nil
        }
        compiledPhrasePatterns[pattern] = regex
        return regex
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
                    if let regex = compiledPattern(pattern) {
                        let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
                        if let match = regex.firstMatch(in: result, range: nsRange),
                           let range = Range(match.range, in: result) {
                            let originalText = String(result[range])
                            result.replaceSubrange(range, with: entry.correctForm)

                            if originalText != entry.correctForm {
                                corrections.append((range: range, original: originalText, replacement: entry.correctForm, category: entry.category, notes: entry.notes, entryId: entry.id))
                            }
                            matched = true
                            i += phraseLength
                            break
                        }
                    }
                }

                // Try fuzzy match for the combined phrase (joined without space)
                // This handles "githubrepo" → "GitHub repo" type errors
                // Skip if any word in the phrase is a single character (likely an apostrophe fragment)
                if !matched && maxEditDistance > 0 && phraseWords.allSatisfy({ $0.count >= 2 }) {
                    let joinedPhrase = phraseWords.joined().lowercased()
                    // Only attempt if the joined phrase is long enough to be meaningful
                    if joinedPhrase.count >= 5,
                       let suggestions = symSpell?.lookup(input: joinedPhrase, verbosity: .top, maxEditDistance: maxEditDistance),
                       let best = suggestions.first,
                       best.distance > 0 && best.distance <= maxEditDistance {
                        // Only accept if the match is very close (distance <= 1 for compound)
                        if best.distance <= 1 {
                            let pattern = phraseWords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "\\s*")
                            if let regex = compiledPattern(pattern) {
                                let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
                                if let match = regex.firstMatch(in: result, range: nsRange),
                                   let range = Range(match.range, in: result) {
                                    let originalText = String(result[range])
                                    result.replaceSubrange(range, with: best.entry.correctForm)

                                    if originalText != best.entry.correctForm {
                                        corrections.append((range: range, original: originalText, replacement: best.entry.correctForm, category: best.entry.category, notes: "Segmentation correction", entryId: best.entry.id))
                                    }
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
        replaceAllOccurrences(in: text, of: word, with: entry.correctForm, entry: entry, corrections: &corrections)
    }

    /// Replaces every word-boundary-respecting, case-insensitive occurrence of `needle`.
    ///
    /// Builds the output left to right instead of mutating a copy in place. The previous version
    /// searched and edited one live string and carried positions as integer offsets, because
    /// `replaceSubrange` invalidates every `String.Index` it touches and a `lowercased()` snapshot
    /// cannot supply valid indices either (`lowercased()` can change the character count). Integer
    /// offsets survive a resize, but `String.Index` is not random access, so converting them back
    /// cost a full O(n) walk — three to five of them per loop iteration, plus an O(n)
    /// `result.count` in the loop condition itself and an O(n) memmove per replacement. On a
    /// 15,309-character transcript the whole correction pass measured 2177 ms, against a 58 ms
    /// mean. That time is spent between the ASR result and the paste, so the user feels all of it.
    ///
    /// The scan here never edits the string it searches, so no index is ever invalidated and no
    /// offset ever has to be resolved: the cursor is a `String.Index` into the immutable `text`,
    /// and each iteration advances it past the match it just handled. The pass is O(n) in total.
    ///
    /// The output is identical to the old in-place edit, including the two subtleties that matter:
    ///
    /// - Searching the *live* string let a replacement match itself. It never did in practice,
    ///   because the resume position was the end of the inserted replacement, so the inserted text
    ///   was skipped. Resuming at `range.upperBound` in `text` skips exactly the same region, so
    ///   `gpt → GPT model` still expands once per occurrence rather than feeding on its own output.
    /// - The left word-boundary test looked at the character *before* the match in the partly
    ///   rewritten string, which is the last character already emitted. `output.last` is that same
    ///   character, so an adjacent earlier replacement still shapes the boundary decision.
    ///
    /// Recorded correction ranges are character offsets resolved against the finished string in
    /// one forward walk. Every later replacement sits at a higher offset than an earlier one, so
    /// resolving late gives the same offsets the old code produced eagerly, and the indices are
    /// valid in the string this function actually returns.
    private func replaceAllOccurrences(
        in text: String,
        of needle: String,
        with replacement: String,
        entry: DictionaryEntry,
        corrections: inout [(range: Range<String.Index>, original: String, replacement: String, category: String?, notes: String?, entryId: UUID)]
    ) -> String {
        guard !needle.isEmpty else { return text }

        var output = ""
        output.reserveCapacity(text.count)
        var cursor = text.startIndex
        // Character offset of each accepted replacement within `output`, with the text it replaced.
        var pending: [(offset: Int, original: String)] = []
        var emitted = 0

        while let range = text.range(of: needle, options: .caseInsensitive,
                                     range: cursor..<text.endIndex) {
            // A zero-width or non-advancing match would spin forever.
            guard range.upperBound > cursor else { break }

            output.append(contentsOf: text[cursor..<range.lowerBound])
            emitted += text.distance(from: cursor, to: range.lowerBound)

            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            guard isWordBoundary(before: output.last, after: after) else {
                // Not a whole word. Emit the match untouched and look past it.
                output.append(contentsOf: text[range])
                emitted += text.distance(from: range.lowerBound, to: range.upperBound)
                cursor = range.upperBound
                continue
            }

            let originalText = String(text[range])
            if originalText != replacement {
                pending.append((offset: emitted, original: originalText))
            }
            output.append(replacement)
            emitted += replacement.count
            cursor = range.upperBound
        }

        output.append(contentsOf: text[cursor...])

        // Resolve the recorded offsets in one forward walk rather than one walk each.
        var indexCursor = output.startIndex
        var walked = 0
        let replacementLength = replacement.count
        for item in pending {
            indexCursor = output.index(indexCursor, offsetBy: item.offset - walked)
            walked = item.offset
            let upper = output.index(indexCursor, offsetBy: replacementLength)
            corrections.append((range: indexCursor..<upper, original: item.original, replacement: replacement, category: entry.category, notes: entry.notes, entryId: entry.id))
        }

        return output
    }

    /// Word-boundary test for a match, expressed over the two neighbouring characters.
    ///
    /// `nil` means the match touches an end of the string, which counts as a boundary. Taking the
    /// characters rather than a range keeps the caller free to compare the preceding character of
    /// the *output* against the following character of the *input*, which is what the old in-place
    /// edit effectively did.
    private func isWordBoundary(before: Character?, after: Character?) -> Bool {
        let beforeBoundary = before.map { !$0.isLetter && !$0.isNumber } ?? true
        let afterBoundary = after.map { !$0.isLetter && !$0.isNumber } ?? true
        return beforeBoundary && afterBoundary
    }
}
