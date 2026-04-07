//
//  TranscriptPostValidator.swift
//  Whisperer
//
//  Mode-aware validation of LLM output against original input
//

import Foundation

struct TranscriptPostValidator {

    enum ValidationProfile {
        case strict      // Correct, Grammar — tight constraints
        case moderate    // Rewrite, Coding, Email — looser growth/shrink
        case permissive  // Format, Creative, List Format — allow structural changes
        case translate   // Translate — skip script check entirely
        case summarize   // Summarize — skip shrink check
    }

    /// Validate LLM output against the original input using mode-appropriate rules
    static func validate(
        original: String,
        processed: String,
        profile: ValidationProfile
    ) -> (valid: Bool, reason: String?) {
        // Non-empty check (all profiles)
        let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, "output is empty")
        }

        // Script consistency (skip for translate)
        if profile != .translate {
            let originalScript = dominantScript(original)
            let processedScript = dominantScript(trimmed)
            if let orig = originalScript, let proc = processedScript, orig != proc {
                return (false, "script changed from \(orig) to \(proc)")
            }
        }

        // Length growth check
        let growthLimit: Float = {
            switch profile {
            case .strict: return 1.3
            case .moderate: return 1.5
            case .permissive: return 2.0
            case .translate: return 2.0
            case .summarize: return 1.0
            }
        }()
        if original.count > 10 && Float(trimmed.count) > Float(original.count) * growthLimit {
            return (false, "output grew \(String(format: "%.1f", Float(trimmed.count) / Float(original.count)))x (limit \(growthLimit)x)")
        }

        // Length shrink check (skip for summarize)
        if profile != .summarize {
            let shrinkLimit: Float = {
                switch profile {
                case .strict: return 0.5
                case .moderate, .permissive, .translate: return 0.3
                case .summarize: return 0.0 // unreachable
                }
            }()
            if original.count > 10 && Float(trimmed.count) < Float(original.count) * shrinkLimit {
                return (false, "output shrank to \(String(format: "%.1f", Float(trimmed.count) / Float(original.count)))x (limit \(shrinkLimit)x)")
            }
        }

        // Number preservation
        if profile != .summarize {
            let originalNumbers = extractNumbers(original)
            if !originalNumbers.isEmpty {
                let processedNumbers = Set(extractNumbers(trimmed))
                let missing = originalNumbers.filter { !processedNumbers.contains($0) }

                switch profile {
                case .strict:
                    // 100% preservation required
                    if !missing.isEmpty {
                        return (false, "missing numbers: \(missing.joined(separator: ", "))")
                    }
                case .moderate, .permissive, .translate:
                    // 80% preservation
                    let preserved = originalNumbers.count - missing.count
                    let ratio = Float(preserved) / Float(originalNumbers.count)
                    if ratio < 0.8 {
                        return (false, "only \(Int(ratio * 100))% of numbers preserved (need 80%)")
                    }
                case .summarize:
                    break // unreachable
                }
            }
        }

        return (true, nil)
    }

    /// Map mode IDs to validation profiles
    static func profileFor(modeId: UUID) -> ValidationProfile {
        switch modeId {
        case AIMode.correctModeId, AIMode.grammarModeId:
            return .strict
        case AIMode.rewriteModeId, AIMode.codingModeId, AIMode.emailModeId:
            return .moderate
        case AIMode.formatModeId, AIMode.creativeModeId, AIMode.listFormatModeId:
            return .permissive
        case AIMode.translateModeId:
            return .translate
        case AIMode.summarizeModeId:
            return .summarize
        default:
            return .moderate
        }
    }

    // MARK: - Script Detection

    private enum ScriptFamily: String {
        case latin, cyrillic, hebrew, arabic, cjk, devanagari, greek, other
    }

    /// Determine the dominant Unicode script family in a string
    private static func dominantScript(_ text: String) -> ScriptFamily? {
        var counts: [ScriptFamily: Int] = [:]

        for scalar in text.unicodeScalars {
            let family = scriptFamily(scalar)
            if family != .other {
                counts[family, default: 0] += 1
            }
        }

        guard let dominant = counts.max(by: { $0.value < $1.value }) else {
            return nil
        }
        return dominant.key
    }

    private static func scriptFamily(_ scalar: Unicode.Scalar) -> ScriptFamily {
        let v = scalar.value
        switch v {
        case 0x0041...0x024F: return .latin     // Basic Latin + Latin Extended
        case 0x0400...0x04FF: return .cyrillic   // Cyrillic
        case 0x0500...0x052F: return .cyrillic   // Cyrillic Supplement
        case 0x0590...0x05FF: return .hebrew     // Hebrew
        case 0xFB1D...0xFB4F: return .hebrew     // Hebrew Presentation Forms
        case 0x0600...0x06FF: return .arabic     // Arabic
        case 0x0750...0x077F: return .arabic     // Arabic Supplement
        case 0x0900...0x097F: return .devanagari // Devanagari
        case 0x0370...0x03FF: return .greek      // Greek
        case 0x4E00...0x9FFF: return .cjk        // CJK Unified Ideographs
        case 0x3400...0x4DBF: return .cjk        // CJK Extension A
        case 0x3040...0x309F: return .cjk        // Hiragana
        case 0x30A0...0x30FF: return .cjk        // Katakana
        case 0xAC00...0xD7AF: return .cjk        // Hangul Syllables
        default: return .other
        }
    }

    // MARK: - Number Extraction

    /// Extract all numeric sequences from text
    private static func extractNumbers(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\d+") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
