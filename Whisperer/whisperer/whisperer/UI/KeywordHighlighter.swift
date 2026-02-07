//
//  KeywordHighlighter.swift
//  Whisperer
//
//  Utility for highlighting keywords (numbers, percentages, currencies) in transcription text
//

import Foundation
import SwiftUI

struct KeywordHighlighter {
    static let greenAccent = Color(red: 0.0, green: 0.82, blue: 0.42)  // #00D26A

    /// Highlight keywords (numbers, percentages, currencies) in text
    static func highlight(_ text: String) -> AttributedString {
        var attributedString = AttributedString(text)

        // Pattern for numbers (including decimals and commas)
        let numberPattern = #"\b\d{1,3}(?:,\d{3})*(?:\.\d+)?\b"#

        // Pattern for percentages
        let percentPattern = #"\b\d{1,3}(?:,\d{3})*(?:\.\d+)?%"#

        // Pattern for currencies ($ followed by numbers)
        let currencyPattern = #"\$\d{1,3}(?:,\d{3})*(?:\.\d{2})?"#

        // Combine all patterns
        let patterns = [percentPattern, currencyPattern, numberPattern]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }

            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, options: [], range: nsRange)

            for match in matches {
                if let range = Range(match.range, in: text) {
                    if let attrRange = Range<AttributedString.Index>(range, in: attributedString) {
                        attributedString[attrRange].foregroundColor = greenAccent
                        attributedString[attrRange].font = .system(size: 13, weight: .semibold)
                    }
                }
            }
        }

        return attributedString
    }
}
