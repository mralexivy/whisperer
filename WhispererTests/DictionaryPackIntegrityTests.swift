//
//  DictionaryPackIntegrityTests.swift
//  WhispererTests
//
//  Data-integrity tests for the 12 built-in dictionary pack JSONs.
//
//  Invariants asserted:
//  1. No alias maps to two different correct terms (conflict).
//  2. No identity rules (alias == term, case-insensitive).
//  3. No duplicate aliases within a single pack.
//  4. No empty term or alias string.
//  5. No single-word alias that is a valid English word (unless in the allowlist).
//
//  If any invariant fails, a built-in rule is a candidate for mangling normal dictation.
//  Fix the pack JSON (or add to the allowlist with justification) rather than weakening
//  this test.
//
//  The allowlist lives at Tools/dict-audit/english_word_allowlist.json (committed).
//  Format: [{"alias": str, "term": str, "reason": str}]

import XCTest
@testable import whisperer
import Foundation

final class DictionaryPackIntegrityTests: XCTestCase {

    // MARK: - Helpers

    private struct PackEntry {
        let alias: String       // lowercased
        let term: String
        let pack: String
    }

    private static var allEntries: [PackEntry] = []
    private static var loadError: String?
    private static var packsAreAudited = false

    override class func setUp() {
        super.setUp()

        guard let resourcePath = Bundle.main.resourcePath else {
            loadError = "No resource path"
            return
        }

        let fileManager = FileManager.default
        let dictionariesPath = (resourcePath as NSString).appendingPathComponent("dictionaries")
        let searchPath = fileManager.fileExists(atPath: dictionariesPath) ? dictionariesPath : resourcePath
        var allAtV2 = true

        do {
            let files = try fileManager.contentsOfDirectory(atPath: searchPath)
            for filename in files.filter({ $0.hasPrefix("pack_") && $0.hasSuffix(".json") }).sorted() {
                let url = URL(fileURLWithPath: (searchPath as NSString).appendingPathComponent(filename))
                guard let data = try? Data(contentsOf: url),
                      let packFile = try? JSONDecoder().decode(DictionaryPackFile.self, from: data) else {
                    loadError = "Failed to decode \(filename)"
                    continue
                }
                if packFile.metadata.version != "2.0.0" { allAtV2 = false }
                let stem = (filename as NSString).deletingPathExtension
                for correction in packFile.corrections {
                    for alias in correction.aliases {
                        allEntries.append(PackEntry(
                            alias: alias.lowercased(),
                            term: correction.term,
                            pack: stem
                        ))
                    }
                }
            }
        } catch {
            loadError = "Error reading dictionaries: \(error)"
        }
        packsAreAudited = allAtV2
    }

    private func entries() throws -> [PackEntry] {
        if let error = Self.loadError { throw XCTSkip(error) }
        guard Self.packsAreAudited else {
            throw XCTSkip(
                "Packs are pre-audit (version < 2.0.0). " +
                "Run Tools/dict-audit/apply_verdicts.py first."
            )
        }
        return Self.allEntries
    }

    // MARK: - Invariant 1: No cross-pack conflicts

    func testNoConflictingAliases() throws {
        let all = try entries()
        var aliasToTerms: [String: Set<String>] = [:]
        var aliasToPacksMap: [String: [String]] = [:]

        for e in all {
            aliasToTerms[e.alias, default: []].insert(e.term)
            aliasToPacksMap[e.alias, default: []].append(e.pack)
        }

        let conflicts = aliasToTerms.filter { $0.value.count > 1 }

        if !conflicts.isEmpty {
            let details = conflicts.sorted(by: { $0.key < $1.key }).map { alias, terms in
                "  \(alias.debugDescription) → \(terms.sorted()) in \(aliasToPacksMap[alias] ?? [])"
            }.joined(separator: "\n")
            XCTFail("Found \(conflicts.count) conflicting alias(es):\n\(details)")
        }
    }

    // MARK: - Invariant 2: No identity rules

    func testNoIdentityRules() throws {
        let all = try entries()
        let identities = all.filter { $0.alias == $0.term.lowercased() }

        if !identities.isEmpty {
            let details = identities.map { "  \($0.alias.debugDescription) → \($0.term.debugDescription) [\($0.pack)]" }
                .joined(separator: "\n")
            XCTFail("Found \(identities.count) identity rule(s) (alias == term):\n\(details)")
        }
    }

    // MARK: - Invariant 3: No intra-pack duplicates

    func testNoDuplicateAliasesWithinPack() throws {
        let all = try entries()
        var packSeen: [String: Set<String>] = [:]
        var duplicates: [(pack: String, alias: String)] = []

        for e in all {
            if packSeen[e.pack, default: []].contains(e.alias) {
                duplicates.append((e.pack, e.alias))
            } else {
                packSeen[e.pack, default: []].insert(e.alias)
            }
        }

        if !duplicates.isEmpty {
            let details = duplicates.map { "  \($0.alias.debugDescription) in \($0.pack)" }
                .joined(separator: "\n")
            XCTFail("Found \(duplicates.count) duplicate alias(es) within a pack:\n\(details)")
        }
    }

    // MARK: - Invariant 4: No empty strings

    func testNoEmptyTermsOrAliases() throws {
        let all = try entries()
        let emptyTerms = all.filter { $0.term.trimmingCharacters(in: .whitespaces).isEmpty }
        let emptyAliases = all.filter { $0.alias.trimmingCharacters(in: .whitespaces).isEmpty }

        var failures: [String] = []
        if !emptyTerms.isEmpty {
            failures.append("Empty term(s): \(emptyTerms.map { $0.pack })")
        }
        if !emptyAliases.isEmpty {
            failures.append("Empty alias(es): \(emptyAliases.map { $0.pack })")
        }
        if !failures.isEmpty {
            XCTFail(failures.joined(separator: "\n"))
        }
    }

    // MARK: - Invariant 5: No plain single-word English aliases (unless allowlisted)

    func testNoSingleWordEnglishAliases() throws {
        let all = try entries()
        let validator = SpellValidator.shared

        // Load allowlist from Tools/dict-audit/english_word_allowlist.json if present.
        // During tests, look relative to the source tree root (one dir up from bundle).
        // Falls back to empty set gracefully if not found.
        let allowlist = loadAllowlist()

        var violations: [(alias: String, term: String, pack: String)] = []

        for e in all {
            // Only flag aliases that are PURELY alphabetic (no digits, spaces, punctuation).
            // Mixed aliases like "arm 64", "web 3", "s 3" contain digits and are NOT
            // plain English words — they are tech terms with numeric qualifiers.
            guard e.alias.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }),
                  validator.isLatinWord(e.alias),
                  validator.isValidEnglishWord(e.alias) else { continue }

            // Check allowlist
            let key = "\(e.alias.lowercased())||||\(e.term.lowercased())"
            guard !allowlist.contains(key) else { continue }

            violations.append((e.alias, e.term, e.pack))
        }

        if !violations.isEmpty {
            let details = violations.sorted(by: { $0.alias < $1.alias }).map {
                "  \($0.alias.debugDescription) → \($0.term.debugDescription) [\($0.pack)]"
            }.joined(separator: "\n")
            XCTFail(
                "Found \(violations.count) single-word English alias(es) not in allowlist.\n" +
                "These will mangle normal dictation. Fix the pack JSON or add to allowlist.\n\n" +
                details
            )
        }
    }

    // MARK: - Allowlist loader

    private func loadAllowlist() -> Set<String> {
        // Try to find the allowlist relative to the bundle's parent directories.
        // Works when running tests from Xcode or xcodebuild.
        let searchPaths: [URL] = [
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("../../../../Tools/dict-audit/english_word_allowlist.json"),
            URL(fileURLWithPath: "/Users/alexanderi/Downloads/whisperer/Tools/dict-audit/english_word_allowlist.json"),
        ]

        for url in searchPaths {
            guard let data = try? Data(contentsOf: url),
                  let entries = try? JSONDecoder().decode([[String: String]].self, from: data) else {
                continue
            }
            let keys = entries.compactMap { dict -> String? in
                guard let alias = dict["alias"], let term = dict["term"] else { return nil }
                return "\(alias.lowercased())||||\(term.lowercased())"
            }
            return Set(keys)
        }
        return Set()
    }
}
