//
//  MidSentenceCaseNormalizer.swift
//  Whisperer
//
//  Removes decoder-added title case inside sentences without flattening proper nouns.
//

import Foundation
import NaturalLanguage

enum MidSentenceCaseNormalizer {

    /// Normalizes a display hypothesis without running the rest of the transcript editor.
    /// Short-dictation preview uses this entry point; meetings run `proposals` as part of the
    /// shared deterministic editor. Keeping the rule here prevents the two live surfaces from
    /// drifting while letting the HUD avoid filler removal and punctuation changes mid-speech.
    static func normalize(text: String, dictionaryTerms: Set<String> = []) -> String {
        normalize(text: text, protectedWords: protectedWords(in: dictionaryTerms))
    }

    static func normalize(text: String, protectedWords: Set<String>) -> String {
        guard text.contains(where: \.isUppercase) else { return text }
        var graph = TokenGraph.from(text: text)
        ProtectionDetector.annotate(&graph)
        _ = ConfidenceGate().apply(proposals(for: graph, protectedWords: protectedWords),
                                   to: &graph)
        return graph.render()
    }

    /// The decoder failure is not ordinary title case: it raises apparently random words in a
    /// sentence (`they Are not switching ... think That ... Get better`). A capital is lowered
    /// only when position says it is not a sentence start and lexical context says it is ordinary
    /// prose. Names, places and organizations come from Apple's on-device tagger; product spelling
    /// comes from the same user + shipped dictionary the rest of the editor already trusts.
    static func proposals(for graph: TokenGraph,
                          protectedWords: Set<String> = []) -> [TranscriptEdit] {
        let openingIDs = Set(SentenceStructure.openings(in: graph).map {
            graph.tokens[$0.wordIndex].id
        })
        let words = graph.tokens.filter(\.isWord)
        let provisional = words.filter { token in
            isSimpleTitleCase(token.effectiveText)
                && !openingIDs.contains(token.id)
                && token.protection != .hard
                && !protectedWords.contains(token.effectiveText.lowercased())
        }
        guard !provisional.isEmpty else { return [] }

        // A normal transcript with only its sentence opener capitalized stops above, so the NLP
        // tagger is paid for only when there is actually an interior title-case decision to make.
        let rendered = graph.render()
        let languageCodes = detectedLanguageCodes(in: rendered)
        let lexicalEvidence = detectedLexicalEvidence(in: rendered)
        let spellLanguages = SpellValidator.shared.supportedLanguages(for: languageCodes)
        // `NLTagger`'s name tags are English-trained: on German or Russian it reads any interior
        // capital as a personal name, which is exactly the artifact being repaired. Outside
        // English the installed dictionary is the more trustworthy witness, so the name veto is
        // only honoured when English is actually one of the detected languages.
        let trustsNameTags = languageCodes.contains("en")
        let candidates = provisional.filter { token in
            !trustsNameTags || !lexicalEvidence.namedWords.contains(token.effectiveText.lowercased())
        }

        // Lexical tags cover English richly; installed spelling dictionaries supply the same
        // ordinary-word evidence for Russian and other languages. The burst rule is only the
        // fallback when macOS has no dictionary for the detected language—otherwise it would
        // flatten an unknown proper name merely because several casual words were also affected.
        let widespreadNoise = candidates.count >= 3
            && candidates.count * 5 >= max(1, words.count)
        let usesBurstFallback = widespreadNoise && spellLanguages.isEmpty

        return candidates.compactMap { token in
            let text = token.effectiveText
            guard usesBurstFallback
                    || lexicalEvidence.ordinaryWords.contains(text.lowercased())
                    || SpellValidator.shared.isKnownWord(text, languages: spellLanguages) else {
                return nil
            }
            guard let lowered = lowercasingFirstLetter(text) else { return nil }
            return TranscriptEdit(
                target: token.id,
                operation: .replace(lowered),
                source: .normalization,
                confidence: 0.98,
                reason: "spurious mid-sentence capital: \(text)")
        }
    }

    private static func isSimpleTitleCase(_ text: String) -> Bool {
        guard text.count > 1, let first = text.first, first.isUppercase else { return false }
        let remainder = text.dropFirst().filter(\.isLetter)
        guard !remainder.isEmpty else { return false }
        // Acronyms and mixed-case identifiers are casing decisions, not title-case noise.
        return !remainder.contains(where: \.isUppercase)
    }

    private static func lowercasingFirstLetter(_ text: String) -> String? {
        guard let first = text.first else { return nil }
        let lower = String(first).lowercased()
        guard lower.count == 1, lower != String(first) else { return nil }
        return lower + String(text.dropFirst())
    }

    /// Compile once per recording. The dictionary can contain thousands of multi-word aliases;
    /// splitting all of them at preview cadence would cost more than the casing decision itself.
    static func protectedWords(in terms: Set<String>) -> Set<String> {
        Set(terms.flatMap { term in
            term.split { !$0.isLetter && !$0.isNumber }
                // A multi-word alias such as `API design` owns API's spelling, not the ordinary
                // word `design`. Only canonical components carrying a casing decision protect it.
                .filter { $0.contains(where: \.isUppercase) }
                .map { $0.lowercased() }
        })
    }

    private struct LexicalEvidence {
        var namedWords: Set<String> = []
        var ordinaryWords: Set<String> = []
    }

    private static func detectedLexicalEvidence(in text: String) -> LexicalEvidence {
        guard !text.isEmpty else { return LexicalEvidence() }
        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass])
        tagger.string = text
        var evidence = LexicalEvidence()
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word,
                             scheme: .nameTypeOrLexicalClass,
                             options: options) { tag, range in
            if tag == .personalName || tag == .placeName || tag == .organizationName {
                for word in text[range].split(whereSeparator: {
                    !$0.isLetter && !$0.isNumber
                }) {
                    evidence.namedWords.insert(word.lowercased())
                }
            } else if let tag, tag != .noun && tag != .other {
                for word in text[range].split(whereSeparator: {
                    !$0.isLetter && !$0.isNumber
                }) {
                    evidence.ordinaryWords.insert(word.lowercased())
                }
            }
            return true
        }
        return evidence
    }

    /// Language recognition is whole-transcript and can return more than one plausible language,
    /// which is important for code-switched meetings. Only meaningful hypotheses reach the spell
    /// checker; it never scans all dictionaries looking for an accidental match.
    private static func detectedLanguageCodes(in text: String) -> [String] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 3)
            .filter { $0.value >= 0.10 }
            .sorted { $0.value > $1.value }
            .map { $0.key.rawValue }
    }
}
