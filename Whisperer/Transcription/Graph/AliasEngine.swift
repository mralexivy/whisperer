//
//  AliasEngine.swift
//  Whisperer
//
//  Canonical-spelling substitution: `chat gpt → ChatGPT`, `postgress → PostgreSQL`.
//
//  Not a second dictionary. `CorrectionEngine.applyCorrections` already returns per-correction
//  ranges and an `entryId`, so what is new here is (a) addressing token IDs instead of
//  `Range<String.Index>` into a string that is about to be mutated, (b) an explicit precedence
//  order when two sources disagree, and (c) longest-match-wins over a trie rather than a
//  descending-length scan of every phrase in the dictionary.
//
//  Purely textual, so it behaves identically on every ASR backend — this is one of the pieces
//  that makes the engine-independence claim true rather than aspirational.
//

import Foundation

// MARK: - Precedence

/// Who supplied an alias. When two sources map the same phrase, the higher case wins — and it
/// wins outright rather than by score, because "the user typed this spelling" is not a
/// confidence to be averaged against a shipped table.
enum AliasSource: Int, Sendable, Comparable, CaseIterable {
    /// Learned automatically from the user's own accepted corrections. Weakest: inferred.
    case learned = 0
    /// Shipped with the app — the small tech lexicon below.
    case shipped = 1
    /// Installed dictionary pack.
    case application = 2
    /// Organization-provided vocabulary.
    case organization = 3
    /// Typed by this user. Strongest: stated, not inferred.
    case user = 4

    static func < (lhs: AliasSource, rhs: AliasSource) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Calibrated per source, per the gate's contract. A stated spelling is certain; an
    /// inferred one is not, and must be able to lose to a stronger signal downstream.
    var confidence: Float {
        switch self {
        case .user, .organization: return 1.0
        case .application, .shipped: return 0.95
        case .learned: return 0.80
        }
    }
}

// MARK: - Engine

struct AliasEngine: Sendable {

    // MARK: Table

    private struct Alias: Sendable {
        let replacement: String
        let source: AliasSource
    }

    /// Phrases keyed by their folded words joined with a single space.
    ///
    /// Deliberately not a node trie. A trie of reference types deallocates recursively, and in
    /// this target a plain `class` picks up actor isolation — so tearing one down ran every
    /// node's `deinit` through `swift_task_deinitOnExecutorImpl` and crashed in the allocator.
    /// A flat table has no such teardown, and the lookup cost it trades away is bounded by
    /// `maxPhraseWords`, which is 2 for the shipped lexicon.
    private let table: [String: Alias]

    /// Longest phrase in the table, in words. The match window; 1 when the table is empty.
    private let maxPhraseWords: Int

    // MARK: Construction

    /// - Parameters:
    ///   - entries: `DictionaryManager.entries`. Disabled entries are skipped here rather than
    ///     filtered by the caller, so a toggle in the UI cannot be forgotten at one call site.
    ///   - includeShippedLexicon: the built-in tech terms. Off in tests that assert on user
    ///     entries alone.
    init(entries: [DictionaryEntry] = [], includeShippedLexicon: Bool = true) {
        var table: [String: Alias] = [:]
        var longest = 1

        func insert(phrase: String, replacement: String, source: AliasSource) {
            let keys = Self.keys(in: phrase)
            guard !keys.isEmpty else { return }
            let key = keys.joined(separator: " ")
            // Precedence, not last-write-wins: build order must not decide the outcome.
            if let existing = table[key], existing.source > source { return }
            table[key] = Alias(replacement: replacement, source: source)
            longest = max(longest, keys.count)
        }

        if includeShippedLexicon {
            for (incorrect, correct) in Self.shippedLexicon {
                insert(phrase: incorrect, replacement: correct, source: .shipped)
            }
        }
        for entry in entries where entry.isEnabled {
            insert(phrase: entry.incorrectForm,
                   replacement: entry.correctForm,
                   source: entry.isBuiltIn ? .application : .user)
        }

        self.table = table
        self.maxPhraseWords = longest
    }

    // MARK: Matching

    /// Every alias substitution that applies to `graph`, longest match first, as edits.
    ///
    /// Emits but does not apply — the gate judges these like any other proposal, and a caller
    /// that wants the edit log to reflect what the gate rejected needs them separately.
    func proposals(for graph: TokenGraph) -> [TranscriptEdit] {
        var edits: [TranscriptEdit] = []
        var index = 0

        while index < graph.tokens.count {
            guard graph.tokens[index].isWord,
                  let match = longestMatch(in: graph, startingAt: index) else {
                index += 1
                continue
            }

            // The first token becomes the canonical spelling; everything the phrase covered
            // after it — including the spaces — is deleted, so `chat gpt` renders as `ChatGPT`
            // rather than `ChatGPT ` with a stranded gap.
            let covered = Array(index...match.endIndex)
            edits.append(TranscriptEdit(
                target: graph.tokens[index].id,
                operation: .replace(match.replacement),
                source: .alias,
                confidence: match.source.confidence,
                reason: "alias(\(match.source)): \(graph.tokens[index].rawText) → \(match.replacement)"))
            for position in covered.dropFirst() {
                edits.append(TranscriptEdit(
                    target: graph.tokens[position].id,
                    operation: .delete,
                    source: .alias,
                    confidence: match.source.confidence,
                    reason: "alias(\(match.source)): absorbed into \(match.replacement)"))
            }

            index = match.endIndex + 1
        }

        return edits
    }

    /// Apply every alias proposal and hard-protect the results.
    ///
    /// A canonical spelling that a later pass is free to "correct" was not worth substituting,
    /// so protection is part of the operation rather than a courtesy the caller must remember.
    @discardableResult
    func apply(to graph: inout TokenGraph) -> Int {
        let edits = proposals(for: graph)
        var applied = 0
        var replaced: [TokenID] = []
        for edit in edits where graph.apply(edit) {
            applied += 1
            if case .replace = edit.operation { replaced.append(edit.target) }
        }
        graph.protect(replaced, as: .hard)
        return applied
    }

    private struct Match {
        let endIndex: Int          // index into graph.tokens of the phrase's last token
        let replacement: String
        let source: AliasSource
    }

    /// Longest phrase in the table that starts at `start`. Whitespace between words is skipped;
    /// punctuation ends the window, so `chat, gpt` is two things and not one.
    private func longestMatch(in graph: TokenGraph, startingAt start: Int) -> Match? {
        // Collect up to `maxPhraseWords` consecutive words and where each one sits.
        var keys: [String] = []
        var endIndices: [Int] = []
        var position = start

        while position < graph.tokens.count, keys.count < maxPhraseWords {
            let token = graph.tokens[position]
            if token.kind == .whitespace {
                position += 1
                continue
            }
            guard token.isWord else { break }
            keys.append(Self.key(token.rawText))
            endIndices.append(position)
            position += 1
        }

        // Longest window first, so `cloud code` beats `cloud`.
        for length in stride(from: keys.count, through: 1, by: -1) {
            guard let alias = table[keys[0..<length].joined(separator: " ")] else { continue }
            let end = endIndices[length - 1]
            guard isEditable(graph, from: start, through: end) else { continue }
            return Match(endIndex: end, replacement: alias.replacement, source: alias.source)
        }
        return nil
    }

    /// A phrase is substitutable only if *every* token it covers can be edited. Applying half a
    /// multi-word alias — the replacement lands, the delete is refused — would corrupt the text
    /// in a way no individual edit ever can.
    private func isEditable(_ graph: TokenGraph, from start: Int, through end: Int) -> Bool {
        graph.tokens[start...end].allSatisfy {
            $0.protection != .hard && $0.lifecycle != .userFinal
        }
    }

    // MARK: Normalization

    private static func keys(in phrase: String) -> [String] {
        phrase.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { key(String($0)) }
    }

    /// Case- and diacritic-insensitive, so `PostGress` and `postgress` are one key. Folding is
    /// locale-independent on purpose: a user with a Turkish locale must not get a different
    /// dictionary than a user with an English one for the same English term.
    private static func key(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: Shipped lexicon

    /// Deliberately small, and limited to terms whose misspelling is an *ASR* error rather than
    /// a typo — these are things a speech model mishears, not things a typist mistypes. Every
    /// entry here is a claim that the left side is never a word the user meant, so the bar is
    /// high and the list grows only from observed transcripts.
    static let shippedLexicon: [(String, String)] = [
        ("chat gpt", "ChatGPT"),
        ("chatgpt", "ChatGPT"),
        ("postgress", "PostgreSQL"),
        ("post gress", "PostgreSQL"),
        // Not `postgres` — that is what the product is actually called, so substituting it
        // would be changing the user's word rather than fixing the ASR's.
        ("kubernetis", "Kubernetes"),
        ("kubernates", "Kubernetes"),
        ("cuber netis", "Kubernetes"),
        ("java script", "JavaScript"),
        ("type script", "TypeScript"),
        ("git hub", "GitHub"),
        ("git lab", "GitLab"),
        ("my sequel", "MySQL"),
        ("no sequel", "NoSQL"),
        ("redis", "Redis"),
        ("docker", "Docker"),
        ("xcode", "Xcode"),
        ("swift ui", "SwiftUI"),
        ("app kit", "AppKit"),
        ("open ai", "OpenAI"),
        ("anthropic", "Anthropic"),
        ("cloud code", "Claude Code"),
        ("web socket", "WebSocket"),
        ("graph ql", "GraphQL"),
    ]
}
