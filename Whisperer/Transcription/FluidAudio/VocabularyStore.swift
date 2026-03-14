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

    /// Build tokenized vocabulary and CTC models from dictionary entries and prompt words.
    /// Returns nil if no valid terms are available.
    static func buildVocabulary(
        entries: [DictionaryEntry],
        promptWords: [String] = []
    ) async throws -> (vocabulary: CustomVocabularyContext, ctcModels: CtcModels)? {
        var terms: [(text: String, isCustom: Bool)] = []
        var seen: Set<String> = []

        // Prompt words first (highest priority — Parakeet equivalent of whisper's initial_prompt)
        for word in promptWords {
            let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = term.lowercased()
            if term.count >= minTermLength && !seen.contains(key) {
                terms.append((text: term, isCustom: true))
                seen.insert(key)
            }
        }

        // User custom dictionary entries (high priority)
        for entry in entries where entry.isEnabled && !entry.isBuiltIn {
            let term = entry.correctForm.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = term.lowercased()
            if term.count >= minTermLength && !seen.contains(key) {
                terms.append((text: term, isCustom: true))
                seen.insert(key)
            }
        }

        // Built-in dictionary entries
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

        // Sanitize config.json — HuggingFace files may contain trailing commas
        // that yyjson (strict JSON parser) rejects
        let cacheDir = CtcModels.defaultCacheDirectory(for: ctcModels.variant)
        sanitizeJsonFiles(in: cacheDir)

        // Load CTC tokenizer
        let ctcTokenizer = try await CtcTokenizer.load(from: cacheDir)

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

        let promptCount = min(promptWords.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).count >= minTermLength }.count, tokenizedTerms.count)
        Logger.info("VocabularyStore: Built vocabulary with \(tokenizedTerms.count) terms (\(promptCount) prompt words, \(cappedTerms.filter { $0.isCustom }.count - promptCount) custom dictionary)", subsystem: .transcription)
        return (vocabulary, ctcModels)
    }

    /// Remove trailing commas from JSON files in a directory.
    /// HuggingFace config files sometimes contain trailing commas
    /// which yyjson (strict JSON parser) rejects.
    private static func sanitizeJsonFiles(in directory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }) else { return }

        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let cleaned = content.replacingOccurrences(
                of: ",\\s*([}\\]])",
                with: "$1",
                options: .regularExpression
            )
            if cleaned != content {
                try? cleaned.write(to: file, atomically: true, encoding: .utf8)
                Logger.debug("Sanitized trailing commas in \(file.lastPathComponent)", subsystem: .transcription)
            }
        }
    }
}
#endif
