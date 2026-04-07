//
//  TranscriptPreCleaner.swift
//  Whisperer
//
//  Rule-based pre-cleaning before LLM inference: normalize, dedup, protect tokens
//

import Foundation

struct TranscriptPreCleaner {

    struct PreCleanResult {
        let text: String
        let placeholders: [String: String]  // "__URL_1__" → "https://..."
    }

    /// Full pipeline: normalize → dedup punctuation → remove fillers → dedup words → protect tokens
    static func preclean(_ text: String) -> PreCleanResult {
        var result = text
        result = normalizeWhitespace(result)
        result = collapseDuplicatePunctuation(result)
        result = removeRepeatedFillers(result)
        result = dedupeAdjacentWords(result)
        let (protected, placeholders) = protectTokens(result)
        return PreCleanResult(text: protected, placeholders: placeholders)
    }

    /// Restore placeholders in LLM output back to original tokens
    static func restorePlaceholders(_ text: String, _ placeholders: [String: String]) -> String {
        guard !placeholders.isEmpty else { return text }
        var result = text
        for (placeholder, original) in placeholders {
            result = result.replacingOccurrences(of: placeholder, with: original)
        }
        return result
    }

    // MARK: - Individual Steps

    /// Trim, collapse multiple spaces, normalize line breaks
    static func normalizeWhitespace(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse multiple spaces to single
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        // Normalize line breaks
        result = result.replacingOccurrences(of: "\r\n", with: "\n")
        result = result.replacingOccurrences(of: "\r", with: "\n")
        return result
    }

    /// Collapse runs of duplicate punctuation: "...." → ".", ",," → ","
    static func collapseDuplicatePunctuation(_ text: String) -> String {
        var result = text
        // Collapse repeated periods (but preserve "..." as ellipsis → "…" or just ".")
        result = result.replacingOccurrences(
            of: "\\.{2,}",
            with: ".",
            options: .regularExpression
        )
        // Collapse repeated commas
        result = result.replacingOccurrences(
            of: ",{2,}",
            with: ",",
            options: .regularExpression
        )
        // Collapse repeated exclamation/question marks (keep single)
        result = result.replacingOccurrences(
            of: "!{2,}",
            with: "!",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "\\?{2,}",
            with: "?",
            options: .regularExpression
        )
        return result
    }

    /// Remove only standalone repeated fillers: "uh uh", "um um", "er er"
    /// and sentence-initial isolated fillers: "Uh, I think..." → "I think..."
    /// Does NOT remove single-occurrence mid-sentence fillers or ambiguous words like "like"
    static func removeRepeatedFillers(_ text: String) -> String {
        let fillers = ["uh", "um", "er", "ah", "hmm"]
        var result = text

        // Remove repeated adjacent fillers: "uh uh" → "", "um um um" → ""
        for filler in fillers {
            let repeatedPattern = "\\b(\(filler)\\s+){2,}\(filler)\\b|\\b\(filler)\\s+\(filler)\\b"
            result = result.replacingOccurrences(
                of: repeatedPattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Remove sentence-initial isolated filler followed by comma/space
        // "Uh, I think" → "I think", "Um so" → "so"
        for filler in fillers {
            let sentenceStartPattern = "(?:^|(?<=[\\.!\\?]\\s))\(filler)[,]?\\s+"
            result = result.replacingOccurrences(
                of: sentenceStartPattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Clean up any resulting double spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove immediately repeated adjacent words: "the the" → "the", "я я" → "я"
    /// Case-insensitive, keeps first occurrence
    static func dedupeAdjacentWords(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > 1 else { return text }

        var result: [Substring] = [words[0]]
        for i in 1..<words.count {
            let prev = words[i - 1].lowercased().trimmingCharacters(in: .punctuationCharacters)
            let curr = words[i].lowercased().trimmingCharacters(in: .punctuationCharacters)
            if prev != curr || prev.isEmpty {
                result.append(words[i])
            }
        }

        return result.joined(separator: " ")
    }

    // MARK: - Token Protection

    /// Detect and replace technical tokens with numbered placeholders.
    /// Order matters — more specific patterns first to prevent partial matches.
    static func protectTokens(_ text: String) -> (text: String, placeholders: [String: String]) {
        var result = text
        var placeholders: [String: String] = [:]
        var counter = 0

        let patterns: [(String, String)] = [
            // URLs
            ("https?://\\S+", "URL"),
            // Email addresses
            ("\\S+@\\S+\\.\\S+", "EMAIL"),
            // Repo/package names with slash: mlx-community/Qwen3.5
            ("[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+", "REPO"),
            // Branded versioned names (hyphen-separated): gpt-4.1, claude-3, Qwen3.5-4B
            ("[a-zA-Z]+-\\d+(?:\\.\\d+)*(?:-[a-zA-Z0-9]+)*", "MODEL"),
            // Branded versioned names (embedded version): Qwen3.5, Gemini2.5
            ("[a-zA-Z]+\\d+\\.\\d+(?:\\.\\d+)*(?:-[a-zA-Z0-9]+)*", "MODEL"),
            // Slash paths: /v1/chat/completions
            ("/[a-zA-Z0-9/_.-]+", "PATH"),
            // CLI flags: --mask-prompt, --no-verify
            ("--[a-z][-a-z]+", "FLAG"),
            // Plain version numbers with leading v: v2.31.3
            ("v\\d+\\.\\d+(?:\\.\\d+)*", "VER"),
            // camelCase identifiers: loadModel, maxTokens
            ("[a-z]+[A-Z][a-zA-Z]+", "IDENT"),
            // snake_case identifiers: mask_prompt, top_k
            ("[a-z]+(?:_[a-z0-9]+)+", "IDENT"),
            // kebab-case identifiers (2+ hyphens): mlx-swift-lm
            ("[a-z]+(?:-[a-z0-9]+){2,}", "IDENT"),
            // IPv4 + optional port
            ("\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}(?::\\d+)?", "IP"),
            // Backtick-wrapped code
            ("`[^`]+`", "CODE"),
        ]

        for (pattern, prefix) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            // Find all matches, replace from last to first to preserve ranges
            let matches = regex.matches(in: result, range: range)
            for match in matches.reversed() {
                guard let matchRange = Range(match.range, in: result) else { continue }
                let token = String(result[matchRange])
                // Skip if already a placeholder
                if token.hasPrefix("__") && token.hasSuffix("__") { continue }
                // Skip single-char matches and common words
                if token.count < 3 { continue }
                let placeholder = "__\(prefix)_\(counter)__"
                placeholders[placeholder] = token
                result.replaceSubrange(matchRange, with: placeholder)
                counter += 1
            }
        }

        return (result, placeholders)
    }
}
