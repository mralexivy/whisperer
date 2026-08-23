//
//  ScriptAnalyzer.swift
//  Whisperer
//
//  Unicode script classification for language routing stabilization.
//  Detects script families from transcript text, then maps to languages
//  within the user's allowed shortlist. Script ≠ language — this is
//  heuristic support for the probability-based router.
//

import Foundation

// MARK: - Script Family

enum ScriptFamily: String {
    case latin, cyrillic, hebrew, arabic, devanagari, thai, georgian
    case armenian, greek, hiragana, katakana, hangul, cjk
}

// MARK: - ScriptAnalyzer

enum ScriptAnalyzer {

    // MARK: - Script Detection Table

    // Each range maps to a script family. Single O(n) pass over unicode scalars.
    // Coverage is heuristic — sufficient for speech transcription output, not
    // comprehensive Unicode coverage (e.g., CJK Extensions B-J omitted).
    private static let scriptRanges: [(ClosedRange<UInt32>, ScriptFamily)] = [
        (0x0370...0x03FF, .greek),
        (0x0400...0x04FF, .cyrillic),
        (0x0500...0x052F, .cyrillic),     // Cyrillic Supplement
        (0x0530...0x058F, .armenian),
        (0x0590...0x05FF, .hebrew),
        (0x0600...0x06FF, .arabic),
        (0x0750...0x077F, .arabic),       // Arabic Supplement
        (0x0900...0x097F, .devanagari),
        (0x0E00...0x0E7F, .thai),
        (0x10A0...0x10FF, .georgian),
        (0x1100...0x11FF, .hangul),       // Hangul Jamo
        (0x3040...0x309F, .hiragana),
        (0x30A0...0x30FF, .katakana),
        (0x3400...0x4DBF, .cjk),          // CJK Extension A
        (0x4E00...0x9FFF, .cjk),          // CJK Unified Ideographs
        (0xAC00...0xD7AF, .hangul),       // Hangul Syllables
    ]

    // MARK: - Script → Language Mapping

    // Maps script families to candidate languages. Applied against the user's
    // allowed language shortlist — only languages in the shortlist get scores.
    private static let scriptToLanguages: [ScriptFamily: [TranscriptionLanguage]] = [
        .latin: [.english, .french, .german, .spanish, .italian, .portuguese, .dutch,
                 .polish, .czech, .swedish, .danish, .norwegian, .finnish, .turkish,
                 .indonesian, .vietnamese, .romanian, .hungarian, .catalan, .croatian,
                 .slovak, .slovenian, .latvian, .lithuanian, .estonian, .icelandic,
                 .albanian, .basque, .galician, .maltese, .malay, .tagalog, .swahili,
                 .haitian, .luxembourgish, .afrikaans, .welsh, .irish, .breton, .occitan,
                 .maori, .hawaiian, .somali, .sundanese, .javanese, .yoruba, .hausa, .shona],
        .cyrillic: [.russian, .ukrainian, .bulgarian, .serbian, .belarusian, .macedonian,
                    .kazakh, .mongolian, .tajik, .bashkir, .tatar, .turkmen, .uzbek],
        .hebrew: [.hebrew, .yiddish],
        .arabic: [.arabic, .persian, .urdu, .pashto, .sindhi],
        .devanagari: [.hindi, .marathi, .nepali, .sanskrit],
        .greek: [.greek],
        .armenian: [.armenian],
        .georgian: [.georgian],
        .thai: [.thai],
        .hangul: [.korean],
        .hiragana: [.japanese],
        .katakana: [.japanese],
        .cjk: [.chinese, .japanese, .korean],
    ]

    // MARK: - Public API

    /// Returns normalized distribution of script-matching languages from transcript text,
    /// filtered to only languages in the allowed shortlist.
    /// Empty string or no matching scripts returns empty dict (no script signal).
    /// O(n) scan of Unicode scalars.
    static func dominantScript(
        in text: String,
        allowedLanguages: [TranscriptionLanguage] = []
    ) -> [TranscriptionLanguage: Float] {
        guard !text.isEmpty else { return [:] }

        let allowedSet = Set(allowedLanguages)

        // Count occurrences per script family
        var scriptCounts: [ScriptFamily: Int] = [:]
        var latinCount = 0

        for scalar in text.unicodeScalars {
            guard let family = self.family(of: scalar) else { continue }
            if family == .latin {
                latinCount += 1
            } else {
                scriptCounts[family, default: 0] += 1
            }
        }

        if latinCount > 0 {
            scriptCounts[.latin] = latinCount
        }

        guard !scriptCounts.isEmpty else { return [:] }

        // CJK disambiguation: attribute CJK characters based on co-occurring scripts
        if let cjkCount = scriptCounts[.cjk], cjkCount > 0 {
            if scriptCounts[.hiragana] != nil || scriptCounts[.katakana] != nil {
                // Japanese context — attribute CJK to Japanese
                scriptCounts[.hiragana, default: 0] += cjkCount
                scriptCounts.removeValue(forKey: .cjk)
            } else if scriptCounts[.hangul] != nil {
                // Korean context — attribute CJK to Korean
                scriptCounts[.hangul, default: 0] += cjkCount
                scriptCounts.removeValue(forKey: .cjk)
            }
            // Otherwise CJK stays as-is (maps to chinese/japanese/korean candidates)
        }

        // Map script counts to language scores, filtered by allowed languages
        let totalChars = Float(scriptCounts.values.reduce(0, +))
        guard totalChars > 0 else { return [:] }

        var langScores: [TranscriptionLanguage: Float] = [:]

        for (family, count) in scriptCounts {
            let scriptProportion = Float(count) / totalChars
            guard let candidates = scriptToLanguages[family] else { continue }

            // Filter to allowed languages (or use all candidates if no filter)
            let matchingLangs: [TranscriptionLanguage]
            if allowedSet.isEmpty {
                matchingLangs = candidates
            } else {
                matchingLangs = candidates.filter { allowedSet.contains($0) }
            }

            guard !matchingLangs.isEmpty else { continue }

            // Distribute script proportion equally among matching languages
            let perLang = scriptProportion / Float(matchingLangs.count)
            for lang in matchingLangs {
                langScores[lang, default: 0] += perLang
            }
        }

        return langScores
    }

    /// Proportion of each script family among the text's letters, summing to 1.
    ///
    /// `dominantScript` cannot answer this — it maps straight to languages, so a single Latin
    /// character in an otherwise Hebrew transcript admits every Latin-script language at full
    /// weight. Callers that need "is this text *mostly* one script" need the shares.
    static func scriptShares(in text: String) -> [ScriptFamily: Float] {
        var counts: [ScriptFamily: Int] = [:]
        var total = 0
        for scalar in text.unicodeScalars {
            guard let family = family(of: scalar) else { continue }
            counts[family, default: 0] += 1
            total += 1
        }
        guard total > 0 else { return [:] }
        return counts.mapValues { Float($0) / Float(total) }
    }

    /// Languages plausibly written in `family`. Empty for families with no mapping.
    static func languages(for family: ScriptFamily) -> [TranscriptionLanguage] {
        scriptToLanguages[family] ?? []
    }

    /// Every script family `language` is plausibly written in — the reverse of `languages(for:)`.
    ///
    /// A set rather than one family because Japanese is legitimately hiragana, katakana *and* CJK
    /// within a single sentence, and Korean mixes hangul with CJK. Callers checking "is this text
    /// written in the language it claims" must accept any of them, so summing the shares over the
    /// whole set is the only correct test. Empty for a language no family lists.
    static func scriptFamilies(for language: TranscriptionLanguage) -> Set<ScriptFamily> {
        var families: Set<ScriptFamily> = []
        for (family, candidates) in scriptToLanguages where candidates.contains(language) {
            families.insert(family)
        }
        return families
    }

    /// Every script family present in `text`, with no language mapping and no normalization.
    ///
    /// `dominantScript` answers "which language is this", which needs the shortlist and the
    /// CJK disambiguation above. Protection needs the cruder question — "is this one token
    /// written in more than one script, or in a script other than the rest of the utterance"
    /// — and answering it through the language mapping would make a token's protection depend
    /// on the user's enabled-language list, which is unrelated to whether it is safe to edit.
    static func scriptFamilies(in text: String) -> Set<ScriptFamily> {
        var families: Set<ScriptFamily> = []
        for scalar in text.unicodeScalars {
            if let family = family(of: scalar) { families.insert(family) }
        }
        return families
    }

    /// Script family of one scalar, or `nil` for digits, punctuation, whitespace and symbols —
    /// which belong to no script and must not be counted as evidence for one.
    private static func family(of scalar: Unicode.Scalar) -> ScriptFamily? {
        let value = scalar.value

        // Latin is by far the most common case, so it is checked before the table.
        if (value >= 0x0041 && value <= 0x005A) ||
           (value >= 0x0061 && value <= 0x007A) ||
           (value >= 0x00C0 && value <= 0x024F) {
            return .latin
        }

        for (range, family) in scriptRanges where range.contains(value) {
            return family
        }
        return nil
    }
}
