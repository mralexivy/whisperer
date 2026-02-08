//
//  SpellValidator.swift
//  Whisperer
//
//  Cached spell checker with script gating for mixed-language transcripts
//  Prevents fuzzy matching from correcting valid English words
//

import Foundation
import AppKit

final class SpellValidator: @unchecked Sendable {
    static let shared = SpellValidator()

    private let tag: Int
    private var cache: [String: Bool] = [:]
    private var order: [String] = []
    private let maxCache = 10_000
    private let lock = NSLock()

    private init() {
        self.tag = NSSpellChecker.uniqueSpellDocumentTag()
    }

    // Note: No deinit needed - this is a singleton that lives for the app's lifetime.
    // Calling NSSpellChecker.shared in deinit during app termination causes crashes
    // because the shared instance may already be deallocated.

    /// Check if a word is a valid English word
    /// Returns false for non-Latin scripts (Hebrew, Russian, etc.) - they bypass spell check
    /// Uses LRU cache to avoid repeated spell checker calls
    func isValidEnglishWord(_ word: String) -> Bool {
        let w = word.lowercased()

        lock.lock()
        if let cached = cache[w] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Only check Latin letters, length >= 4
        // Non-Latin scripts (Hebrew, Russian, etc.) return false to skip fuzzy matching
        guard w.count >= 4,
              w.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) && $0.isASCII }) else {
            remember(w, false)
            return false
        }

        // Access spell checker directly (don't store reference to avoid deallocation issues)
        // Use explicit English language for deterministic results
        var wordCount: Int = 0
        let misspelledRange = NSSpellChecker.shared.checkSpelling(
            of: w,
            startingAt: 0,
            language: "en",
            wrap: false,
            inSpellDocumentWithTag: tag,
            wordCount: &wordCount
        )

        let isValid = (misspelledRange.location == NSNotFound)
        remember(w, isValid)
        return isValid
    }

    /// Check if word contains only Latin ASCII letters
    func isLatinWord(_ word: String) -> Bool {
        word.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.letters.contains($0) }
    }

    private func remember(_ key: String, _ value: Bool) {
        lock.lock()
        defer { lock.unlock() }

        cache[key] = value
        order.append(key)

        // LRU eviction
        if order.count > maxCache {
            let drop = order.removeFirst()
            cache.removeValue(forKey: drop)
        }
    }

    /// Clear the cache (useful for testing)
    func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        order.removeAll()
    }
}
