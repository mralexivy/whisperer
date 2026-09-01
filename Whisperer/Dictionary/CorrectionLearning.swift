//
//  CorrectionLearning.swift
//  Whisperer
//
//  Conservative post-paste correction candidate collection.
//

import Foundation
#if !APP_STORE
import ApplicationServices
#endif

struct CorrectionLearningCandidate: Codable, Equatable, Hashable, Sendable {
    let observed: String
    let corrected: String
}

/// A pair that did not clear the auto-promotion gates but is well-formed enough to offer.
///
/// There is deliberately no repeat threshold. Replaying the miner over 1,779 real dictations
/// showed that *zero* candidate pairs recur even twice, so any "seen N times" gate would never
/// fire. A suggestion is shown on its first sighting; `sightings` is displayed as context, not
/// used as a gate.
struct CorrectionSuggestion: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let observed: String
    let corrected: String
    var sightings: Int
    let firstObservedAt: Date
    var lastObservedAt: Date
}

enum CorrectionLearningCandidateExtractor {
    static let maximumCharacters = 12_000
    static let maximumTokens = 1_000

    private struct Token: Equatable {
        let text: String
        let folded: String
    }

    /// Returns only isolated 1:1 word substitutions. Insertions, deletions and phrase rewrites are
    /// intentionally absent: without an authored classifier they are too ambiguous to learn from.
    static func extract(from pasted: String, edited: String, limit: Int = 4) -> [CorrectionLearningCandidate] {
        guard pasted != edited, limit > 0,
              pasted.count <= maximumCharacters,
              edited.count <= maximumCharacters else { return [] }
        let before = tokens(in: pasted)
        let after = tokens(in: edited)
        guard !before.isEmpty, !after.isEmpty,
              before.count <= maximumTokens,
              after.count <= maximumTokens else { return [] }

        let matches = longestCommonSubsequence(before, after)
        var candidates: [CorrectionLearningCandidate] = []
        var previousBefore = -1
        var previousAfter = -1

        for (nextBefore, nextAfter) in matches + [(before.count, after.count)] {
            let removed = nextBefore - previousBefore - 1
            let inserted = nextAfter - previousAfter - 1
            if removed == 1, inserted == 1 {
                let original = before[previousBefore + 1].text
                let replacement = after[previousAfter + 1].text
                if isEligible(original: original, replacement: replacement) {
                    candidates.append(.init(observed: original, corrected: replacement))
                    if candidates.count == limit { break }
                }
            }
            previousBefore = nextBefore
            previousAfter = nextAfter
        }

        var seen = Set<CorrectionLearningCandidate>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func tokens(in text: String) -> [Token] {
        guard let regex = try? NSRegularExpression(pattern: #"[\p{L}\p{N}][\p{L}\p{N}'’-]*"#) else {
            return []
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            let value = String(text[swiftRange])
            return Token(text: value, folded: value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        }
    }

    private static func longestCommonSubsequence(_ lhs: [Token], _ rhs: [Token]) -> [(Int, Int)] {
        var lengths = Array(repeating: Array(repeating: 0, count: rhs.count + 1), count: lhs.count + 1)
        if !lhs.isEmpty, !rhs.isEmpty {
            for i in stride(from: lhs.count - 1, through: 0, by: -1) {
                for j in stride(from: rhs.count - 1, through: 0, by: -1) {
                    lengths[i][j] = lhs[i].folded == rhs[j].folded
                        ? lengths[i + 1][j + 1] + 1
                        : max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
        }

        var result: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < lhs.count, j < rhs.count {
            if lhs[i].folded == rhs[j].folded {
                result.append((i, j))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }

    private static func isEligible(original: String, replacement: String) -> Bool {
        let foldedOriginal = original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let foldedReplacement = replacement.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard foldedOriginal != foldedReplacement else { return false }
        guard original.count >= 2, replacement.count >= 2 else { return false }
        guard scriptFamilies(in: original) == scriptFamilies(in: replacement) else { return false }
        return true
    }

    private static func scriptFamilies(in text: String) -> Set<String> {
        Set(text.unicodeScalars.compactMap { scalar in
            guard CharacterSet.letters.contains(scalar) else { return nil }
            switch scalar.value {
            case 0x0590...0x05FF: return "hebrew"
            case 0x0400...0x052F: return "cyrillic"
            case 0x0600...0x06FF: return "arabic"
            case 0x4E00...0x9FFF: return "han"
            default: return "latin-other"
            }
        })
    }
}

struct CorrectionLearningAnchor: Equatable, Sendable {
    let prefix: String
    let suffix: String

    init?(fieldValue: String, selectedRange: NSRange) {
        let value = fieldValue as NSString
        guard selectedRange.location != NSNotFound,
              selectedRange.location >= 0,
              selectedRange.length >= 0,
              NSMaxRange(selectedRange) <= value.length else { return nil }
        prefix = value.substring(to: selectedRange.location)
        suffix = value.substring(from: NSMaxRange(selectedRange))
    }

    /// Returns the current contents of the pasted region only while both outside anchors are
    /// untouched. This is the privacy and attribution boundary for the collector.
    func region(in currentFieldValue: String) -> String? {
        let current = currentFieldValue as NSString
        let prefixLength = (prefix as NSString).length
        let suffixLength = (suffix as NSString).length
        guard current.length >= prefixLength + suffixLength,
              current.substring(to: prefixLength) == prefix,
              current.substring(from: current.length - suffixLength) == suffix else { return nil }
        return current.substring(with: NSRange(
            location: prefixLength,
            length: current.length - prefixLength - suffixLength
        ))
    }
}

actor CorrectionSuggestionStore {
    static let shared = CorrectionSuggestionStore()

    private let fileURL: URL
    private var loaded = false
    private var suggestions: [CorrectionSuggestion] = []

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Whisperer", isDirectory: true)
            self.fileURL = base.appendingPathComponent("correction-suggestions.json")
        }
    }

    @discardableResult
    func record(_ observed: String, _ corrected: String, now: Date = Date()) -> [CorrectionSuggestion] {
        loadIfNeeded()
        if let index = suggestions.firstIndex(where: {
            $0.observed.caseInsensitiveCompare(observed) == .orderedSame &&
            $0.corrected.caseInsensitiveCompare(corrected) == .orderedSame
        }) {
            suggestions[index].sightings += 1
            suggestions[index].lastObservedAt = now
        } else {
            suggestions.append(.init(
                id: UUID(), observed: observed, corrected: corrected,
                sightings: 1, firstObservedAt: now, lastObservedAt: now
            ))
        }
        persist()
        return suggestions
    }

    func all() -> [CorrectionSuggestion] {
        loadIfNeeded()
        return suggestions
    }

    func remove(id: UUID) {
        loadIfNeeded()
        let before = suggestions.count
        suggestions.removeAll { $0.id == id }
        guard suggestions.count != before else { return }
        persist()
    }

    /// Removes a pending suggestion identified by its pair rather than its id — the correction
    /// card learns the pair through `CorrectionLearningService` and gets no id back.
    func remove(observed: String, corrected: String) {
        loadIfNeeded()
        let before = suggestions.count
        suggestions.removeAll {
            $0.observed.caseInsensitiveCompare(observed) == .orderedSame &&
            $0.corrected.caseInsensitiveCompare(corrected) == .orderedSame
        }
        guard suggestions.count != before else { return }
        persist()
    }

    func deleteAll() {
        loaded = true
        suggestions = []
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            Logger.error("Failed to delete correction suggestions: \(error.localizedDescription)", subsystem: .app)
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([CorrectionSuggestion].self, from: data) else { return }
        suggestions = decoded
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(suggestions).write(to: fileURL, options: .atomic)
        } catch {
            Logger.error("Failed to persist correction suggestions: \(error.localizedDescription)", subsystem: .app)
        }
    }
}

#if !APP_STORE
struct AXTextFieldSnapshot: Sendable {
    let pid: pid_t
    let elementHash: CFHashCode
    let value: String
    let selectedRange: NSRange
}

enum AXTextFieldSnapshotReader {
    static func read(pid: pid_t, expectedElementHash: CFHashCode? = nil) -> AXTextFieldSnapshot? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue else { return nil }
        let focused = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.1)
        let elementHash = CFHash(focused)
        guard expectedElementHash == nil || expectedElementHash == elementHash else { return nil }

        var textValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXValueAttribute as CFString,
            &textValue
        ) == .success,
        let value = textValue as? String else { return nil }

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success,
        let rangeValue,
        CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }

        var cfRange = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange),
              cfRange.location >= 0,
              cfRange.length >= 0 else { return nil }
        return AXTextFieldSnapshot(
            pid: pid,
            elementHash: elementHash,
            value: value,
            selectedRange: NSRange(location: cfRange.location, length: cfRange.length)
        )
    }
}
#endif
