//
//  ScriptAnalyzer.swift
//  Whisperer
//
//  Unicode script classification for language routing stabilization
//

import Foundation

enum ScriptAnalyzer {
    /// Returns normalized distribution of script-matching languages from transcript text.
    /// Empty string returns empty dict (no script signal).
    /// O(n) scan of Unicode scalars.
    static func dominantScript(in text: String) -> [TranscriptionLanguage: Float] {
        guard !text.isEmpty else { return [:] }

        var hebrewCount = 0
        var cyrillicCount = 0
        var latinCount = 0

        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value >= 0x0590 && value <= 0x05FF {
                hebrewCount += 1
            } else if value >= 0x0400 && value <= 0x04FF {
                cyrillicCount += 1
            } else if (value >= 0x0041 && value <= 0x005A) ||
                      (value >= 0x0061 && value <= 0x007A) ||
                      (value >= 0x00C0 && value <= 0x024F) {
                latinCount += 1
            }
        }

        let total = Float(hebrewCount + cyrillicCount + latinCount)
        guard total > 0 else { return [:] }

        var result: [TranscriptionLanguage: Float] = [:]
        if hebrewCount > 0 {
            result[.hebrew] = Float(hebrewCount) / total
        }
        if cyrillicCount > 0 {
            result[.russian] = Float(cyrillicCount) / total
        }
        if latinCount > 0 {
            result[.english] = Float(latinCount) / total
        }

        return result
    }
}
