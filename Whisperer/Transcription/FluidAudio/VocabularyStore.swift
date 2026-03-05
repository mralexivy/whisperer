//
//  VocabularyStore.swift
//  Whisperer
//
//  Builds CTC vocabulary from dictionary entries for FluidAudio vocabulary boosting
//

#if arch(arm64)
import Foundation
import FluidAudio

struct VocabularyStore {
    /// Maximum terms for CTC vocabulary boosting
    static let maxTerms = 256
    /// Minimum character length for a term to be useful
    static let minTermLength = 3

    // CTC rescoring tuning defaults (from FluidVoice production values)
    static let alpha: Float = 2.8
    static let minCtcScore: Float = -2.2
    static let minSimilarity: Float = 0.72
    static let minCombinedConfidence: Float = 0.64

    /// Build tokenized vocabulary and CTC models from dictionary entries for FluidAudio vocabulary boosting.
    /// Returns nil if no valid terms are available.
    static func buildVocabulary(
        entries: [DictionaryEntry]
    ) async throws -> (vocabulary: CustomVocabularyContext, ctcModels: CtcModels)? {
        // Collect unique terms: user custom entries first (higher priority), then built-in
        var terms: [(text: String, isCustom: Bool)] = []
        var seen: Set<String> = []

        // User custom entries first (highest priority)
        for entry in entries where entry.isEnabled && !entry.isBuiltIn {
            let term = entry.correctForm.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = term.lowercased()
            if term.count >= minTermLength && !seen.contains(key) {
                terms.append((text: term, isCustom: true))
                seen.insert(key)
            }
        }

        // Built-in entries
        for entry in entries where entry.isEnabled && entry.isBuiltIn {
            guard terms.count < maxTerms else { break }
            let term = entry.correctForm.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = term.lowercased()
            if term.count >= minTermLength && !seen.contains(key) {
                terms.append((text: term, isCustom: false))
                seen.insert(key)
            }
        }

        // Cap at maxTerms
        let cappedTerms = Array(terms.prefix(maxTerms))

        guard !cappedTerms.isEmpty else {
            Logger.debug("VocabularyStore: No terms for CTC boosting", subsystem: .transcription)
            return nil
        }

        // Download and load CTC models
        let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)

        // Load CTC tokenizer
        let ctcTokenizer = try await CtcTokenizer.load(
            from: CtcModels.defaultCacheDirectory(for: ctcModels.variant)
        )

        // Tokenize each term — only include terms that tokenize successfully
        let tokenizedTerms: [CustomVocabularyTerm] = cappedTerms.compactMap { term in
            let tokens = ctcTokenizer.encode(term.text)
            guard !tokens.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: term.text,
                weight: term.isCustom ? 8.0 : nil,
                aliases: nil,
                tokenIds: nil,
                ctcTokenIds: tokens
            )
        }

        guard !tokenizedTerms.isEmpty else {
            Logger.debug("VocabularyStore: CTC tokenization produced no valid terms", subsystem: .transcription)
            return nil
        }

        let vocabulary = CustomVocabularyContext(
            terms: tokenizedTerms,
            alpha: alpha,
            minCtcScore: minCtcScore,
            minSimilarity: minSimilarity,
            minCombinedConfidence: minCombinedConfidence,
            minTermLength: minTermLength
        )

        Logger.info("VocabularyStore: Built vocabulary with \(tokenizedTerms.count) terms (\(cappedTerms.filter { $0.isCustom }.count) custom)", subsystem: .transcription)
        return (vocabulary, ctcModels)
    }
}
#endif
