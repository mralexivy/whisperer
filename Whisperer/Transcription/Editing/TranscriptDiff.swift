//
//  TranscriptDiff.swift
//  Whisperer
//
//  Turns a model's rewritten string back into token-addressed edits.
//
//  This is what makes a generative model gateable. `LLMPostProcessor` returns prose, and the
//  only decision the caller can make about prose is accept-all or reject-all — which is why
//  `TranscriptPostValidator` throws away thirty-nine good corrections to stop one bad one.
//  Diffing the prose against the token graph converts one irreversible decision into forty
//  reversible ones, each of which `ConfidenceGate` judges on its own.
//
//  **Why a real alignment and not offsets.** The obvious implementation — find the changed
//  character ranges — fails on exactly this app's input. Hebrew, Russian and English mix
//  inside one utterance; UTF-16 offsets, grapheme counts and visual order all disagree there,
//  and they disagree silently. Token alignment has none of those failure modes: the unit of
//  comparison is a whole token, string equality in Swift is canonical-equivalence based (so
//  differently-composed niqqud or a Cyrillic breve compares equal rather than diffing), and
//  the result is addressed by `TokenID`, which survives every insertion and deletion around it.
//
//  **Byte-exactness.** The revised text is tokenized by `TokenGraph`'s own tokenizer, and
//  whitespace is a token there, so applying every emitted edit reproduces the model's output
//  character for character — where the graph permits it. Where it does not (a hard-protected
//  span, a `.userFinal` token, an edit the gate refuses) the output is the original text for
//  that token and the model's text everywhere else. That partial outcome is the feature.
//

import Foundation

enum TranscriptDiff {

    // MARK: - Entry points

    /// Diff a model's rewrite against the graph it was produced from.
    static func edits(from graph: TokenGraph,
                      to revised: String,
                      source: EditSource,
                      confidence: Float) -> [TranscriptEdit] {
        edits(from: graph.tokens, to: revised, source: source, confidence: confidence)
    }

    /// Diff a model's rewrite against a token sequence.
    ///
    /// Takes tokens rather than a graph because a model is handed tokens, not a graph — it has
    /// no business seeing the edit log or the protection mask, and keeping the signature narrow
    /// is what stops a future implementation from reading them.
    static func edits(from original: [TranscriptToken],
                      to revised: String,
                      source: EditSource,
                      confidence: Float) -> [TranscriptEdit] {
        guard !original.isEmpty else { return [] }

        // A model that returns nothing is a model that failed, not a model that decided the
        // utterance should be empty. Emitting a delete per token would be the literal diff and
        // the worst possible outcome, so this case is refused before alignment runs.
        let hasLetters = original.contains { $0.effectiveText.contains(where: \.isLetter) }
        if hasLetters, !revised.contains(where: \.isLetter) {
            Logger.warning("Diff refused: \(source.rawValue) returned no letters for a "
                           + "\(original.count)-token input", subsystem: .transcription)
            return []
        }

        let before = original.map(\.effectiveText)
        // Tokenize the revision with the graph's own tokenizer rather than a second one. Two
        // tokenizers that disagree on `don't` or `snake_case` would manufacture edits out of
        // their disagreement, which is a diff bug that looks exactly like a model bug.
        let after = TokenGraph.from(text: revised).tokens.map(\.rawText)

        guard let operations = align(before, after) else {
            Logger.warning("Diff refused: \(before.count)x\(after.count) tokens exceeds the "
                           + "alignment budget", subsystem: .transcription)
            return []
        }

        return build(operations: operations,
                     original: original,
                     revisedPieces: after,
                     source: source,
                     confidence: confidence)
    }

    // MARK: - Alignment

    private enum Operation {
        /// Indices are into the full `before` / `after` arrays, not into the trimmed middle.
        case match(before: Int, after: Int)
        case substitute(before: Int, after: Int)
        case delete(before: Int)
        case insert(after: Int)
    }

    /// Full-matrix Levenshtein, O(m·n) in time and memory, over the *middle* of the two
    /// sequences.
    ///
    /// The common prefix and suffix are stripped first, which is not a micro-optimization here:
    /// a correction pass changes a handful of tokens in a transcript of hundreds, so the matrix
    /// that actually gets allocated is tiny even when the transcript is not. Myers would be
    /// asymptotically better on the pathological case, but it produces no substitutions — every
    /// one arrives as a delete/insert pair needing to be re-paired afterwards — and that
    /// re-pairing is the part that would get subtly wrong around RTL runs.
    ///
    /// Returns `nil` when even the trimmed matrix would exceed the budget. The caller treats
    /// that as "no edits", which is the conservative direction: a diff too large to compute is
    /// a model output too different from the input to trust.
    private static func align(_ before: [String], _ after: [String]) -> [Operation]? {
        let m = before.count
        let n = after.count

        var prefix = 0
        while prefix < m, prefix < n, before[prefix] == after[prefix] { prefix += 1 }

        var suffix = 0
        while suffix < m - prefix, suffix < n - prefix,
              before[m - 1 - suffix] == after[n - 1 - suffix] { suffix += 1 }

        let a = Array(before[prefix..<(m - suffix)])
        let b = Array(after[prefix..<(n - suffix)])
        let p = a.count
        let q = b.count

        guard (p + 1) * (q + 1) <= maxAlignmentCells else { return nil }

        // Flat row-major matrix: `cost[i * (q + 1) + j]`. Backtracking reads the costs directly
        // rather than a parallel direction matrix — one allocation instead of two, and the
        // tie-breaking order is then explicit at the point it matters.
        var cost = [Int32](repeating: 0, count: (p + 1) * (q + 1))
        for i in 0...p { cost[i * (q + 1)] = Int32(i) }
        for j in 0...q { cost[j] = Int32(j) }

        if p > 0, q > 0 {
            for i in 1...p {
                let row = i * (q + 1)
                let previousRow = (i - 1) * (q + 1)
                for j in 1...q {
                    let substitution = cost[previousRow + j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                    let deletion = cost[previousRow + j] + 1
                    let insertion = cost[row + j - 1] + 1
                    cost[row + j] = min(substitution, min(deletion, insertion))
                }
            }
        }

        var reversed: [Operation] = []
        var i = p
        var j = q
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let equal = a[i - 1] == b[j - 1]
                if cost[i * (q + 1) + j] == cost[(i - 1) * (q + 1) + j - 1] + (equal ? 0 : 1) {
                    // Diagonal first, deliberately: a token that changed should read as one
                    // `.replace` and not as a delete followed by an insert, because the gate
                    // judges a replacement against the token it replaces and has nothing to
                    // judge an orphaned insertion against.
                    reversed.append(equal
                        ? .match(before: prefix + i - 1, after: prefix + j - 1)
                        : .substitute(before: prefix + i - 1, after: prefix + j - 1))
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if i > 0, cost[i * (q + 1) + j] == cost[(i - 1) * (q + 1) + j] + 1 {
                reversed.append(.delete(before: prefix + i - 1))
                i -= 1
                continue
            }
            guard j > 0 else { break }
            reversed.append(.insert(after: prefix + j - 1))
            j -= 1
        }

        var operations: [Operation] = []
        operations.reserveCapacity(prefix + reversed.count + suffix)
        for k in 0..<prefix { operations.append(.match(before: k, after: k)) }
        operations.append(contentsOf: reversed.reversed())
        for k in 0..<suffix {
            operations.append(.match(before: m - suffix + k, after: n - suffix + k))
        }
        return operations
    }

    /// 8 MB of `Int32` at the worst case. Past this the input is not a corrected transcript,
    /// it is a different one.
    private static let maxAlignmentCells = 2_000_000

    // MARK: - Edit construction

    private static func build(operations: [Operation],
                              original: [TranscriptToken],
                              revisedPieces: [String],
                              source: EditSource,
                              confidence: Float) -> [TranscriptEdit] {
        var replacement: [Int: String] = [:]
        var suffixInsert: [Int: String] = [:]
        var prefixInsert: [Int: String] = [:]
        var deleted: Set<Int> = []

        // An insertion has to hang off a token that still exists after the diff is applied, so
        // it is anchored to the nearest *surviving* token before it — never to a token this
        // same diff deletes, which would make the insert a no-op against a missing ID. Runs of
        // consecutive insertions are coalesced into one edit: two `.insertAfter`s on the same
        // target would apply in reverse order, since each inserts directly after the anchor.
        var lastSurvivor: Int?
        var leading: String = ""
        var run: String = ""

        func flushRun() {
            guard !run.isEmpty else { return }
            if let anchor = lastSurvivor {
                suffixInsert[anchor, default: ""] += run
            } else {
                leading += run
            }
            run = ""
        }

        func claimLeading(for index: Int) {
            guard !leading.isEmpty else { return }
            prefixInsert[index] = leading
            leading = ""
        }

        for operation in operations {
            switch operation {
            case .insert(let j):
                run += revisedPieces[j]
            case .match(let i, _):
                flushRun()
                claimLeading(for: i)
                lastSurvivor = i
            case .substitute(let i, let j):
                flushRun()
                claimLeading(for: i)
                replacement[i] = revisedPieces[j]
                lastSurvivor = i
            case .delete(let i):
                flushRun()
                deleted.insert(i)
            }
        }
        flushRun()

        // Text inserted before every surviving token has nowhere to hang: `EditOperation` has
        // no `insertBefore`, on purpose — an insertion before token zero is not addressable by
        // any existing token. Folding it into the first survivor as a prefix keeps the render
        // byte-exact. If nothing survives at all, the last resort is to resurrect the first
        // deleted token as the carrier rather than lose the model's output entirely.
        if !leading.isEmpty {
            if let carrier = deleted.min() {
                deleted.remove(carrier)
                replacement[carrier] = leading
                leading = ""
            } else {
                Logger.warning("Diff dropped a leading insertion with no anchor "
                               + "(\(source.rawValue))", subsystem: .transcription)
            }
        }

        var edits: [TranscriptEdit] = []
        for (index, token) in original.enumerated() {
            if deleted.contains(index) {
                edits.append(TranscriptEdit(
                    target: token.id,
                    operation: .delete,
                    source: source,
                    confidence: confidence,
                    reason: "\(source.rawValue) diff: deleted \(quoted(token.effectiveText))"))
                continue
            }

            let text = (prefixInsert[index] ?? "") + (replacement[index] ?? token.effectiveText)
            if text != token.effectiveText {
                edits.append(TranscriptEdit(
                    target: token.id,
                    operation: .replace(text),
                    source: source,
                    confidence: confidence,
                    reason: "\(source.rawValue) diff: \(quoted(token.effectiveText)) → "
                          + "\(quoted(text))"))
            }

            if let inserted = suffixInsert[index], !inserted.isEmpty {
                edits.append(TranscriptEdit(
                    target: token.id,
                    operation: .insertAfter(inserted),
                    source: source,
                    confidence: confidence,
                    reason: "\(source.rawValue) diff: inserted \(quoted(inserted)) after "
                          + "\(quoted(token.effectiveText))"))
            }
        }
        return edits
    }

    /// Quoted with visible whitespace. A diff reason that reads `'' → ' '` is unreadable in a
    /// log, and whitespace edits are most of what a punctuation pass produces.
    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\n", with: "\\n")
                  .replacingOccurrences(of: " ", with: "␣") + "'"
    }
}
