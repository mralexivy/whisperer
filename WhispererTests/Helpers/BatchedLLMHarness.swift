//
//  BatchedLLMHarness.swift
//  WhispererTests
//
//  Drives `generateBatchTokens` against the real loaded model, with the real `Correct` prompt
//  and real chunk text from the history database.
//
//  Everything here reaches through `LLMPostProcessor.modelContainer` rather than through
//  `process(...)`. That is deliberate: `process` is the production path with its timeout ladder,
//  pre-cleaner, and post-validator, and every one of those would land in the measurement. What
//  is being measured is decode throughput, so the prompt construction is replicated exactly and
//  nothing else is.
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import XCTest
@testable import whisperer

// MARK: - Prompt construction

/// The real `Correct` mode, as the app ships it. Named `correctAIMode` because two existing
/// test files already declare a global `correctMode()`.
var correctAIMode: AIMode {
    AIMode.builtInModes.first { $0.id == AIMode.correctModeId }!
}

/// Splits an `AIMode` prompt into system prompt + user envelope.
///
/// A copy of `AppState.splitPrompt` plus the two lines `applyLLMPostProcessing` appends. It is
/// duplicated rather than shared because those are `private` to `AppState`, and because a
/// benchmark that silently drifted from the shipping prompt would report throughput for a prompt
/// no user ever sends — the system prefix length is a direct input to prefill cost.
func correctPrompt(for text: String, fragment: Bool) -> (system: String, user: String) {
    let parts = correctAIMode.prompt.components(separatedBy: "{transcript}")
    var system = parts[0]
    if let inputRange = system.range(of: "[INPUT]", options: .backwards) {
        system = String(system[..<inputRange.lowerBound])
    }
    system = system.trimmingCharacters(in: .whitespacesAndNewlines)
    system += "\nDo not include [INPUT] or [/INPUT] in your response."
    if fragment {
        system += "\n\nThis is a speech fragment from a continuous dictation stream…"
    }
    return (system, "[INPUT]\n\(text)\n[/INPUT]")
}

// MARK: - Results

struct BatchRunResult {
    /// One output per input row, in input order.
    let texts: [String]
    let stats: BatchStats
    /// Tokens in the shared warm system prefix, or 0 when the run prefilled cold.
    let warmPrefixTokens: Int
}

/// `container.perform` takes a `@Sendable` closure, so results come back through a box — the
/// same shape `LLMPostProcessor.MTPWarmBox` uses for the same reason.
private final class RunBox: @unchecked Sendable {
    var texts: [String] = []
    var stats = BatchStats()
    var warmPrefixTokens = 0
    var failure: String?
}

// MARK: - Driver

enum BatchedLLMHarnessError: Error, CustomStringConvertible {
    case notLoaded
    case incapableModel(String)
    case internalFailure(String)

    var description: String {
        switch self {
        case .notLoaded: return "no model container — load a model first"
        case .incapableModel(let why): return "model unusable: \(why)"
        case .internalFailure(let why): return why
        }
    }
}

/// Runs one batch of prompts through `generateBatchTokens`.
///
/// - Parameter warmPrefix: when true the shared system prefix is prefilled once at batch 1 and
///   broadcast across the rows, which is what production would do. When false every row prefills
///   the whole prompt itself. The two must produce identical text; that is test 2.
/// - Parameter rows: `(systemPrompt, userMessage)` pairs. All system prompts must be identical —
///   a batch is keyed on the system prefix, because that prefix is the shared warm cache.
@MainActor
func runBatchedGeneration(
    _ processor: LLMPostProcessor,
    rows: [(system: String, user: String)],
    maxTokens: Int,
    warmPrefix: Bool,
    repetitionPenalty: Float = 1.0,
    compactionThreshold: Double = 0.5
) async throws -> BatchRunResult {
    guard let container = processor.modelContainer else { throw BatchedLLMHarnessError.notLoaded }
    guard !rows.isEmpty else { return BatchRunResult(texts: [], stats: BatchStats(), warmPrefixTokens: 0) }
    let systemPrompt = rows[0].system
    precondition(rows.allSatisfy { $0.system == systemPrompt },
                 "a batch shares one system prefix; mixing prompts is not a batch")

    let box = RunBox()
    let userMessages = rows.map(\.user)

    try await container.perform { context in
        let tokenizer = context.tokenizer
        guard let model = context.model as? any LLMModel else {
            box.failure = "model is not an LLMModel"
            return
        }

        // Same EOS assembly as `LLMPostProcessor.processMTP`, including the by-name safety net —
        // a batch that missed `<|im_end|>` would run every row to `maxTokens` and report a
        // throughput number that is real but meaningless.
        var eosIds = context.configuration.eosTokenIds
        if let eos = tokenizer.eosTokenId { eosIds.insert(eos) }
        for token in context.configuration.extraEOSTokens {
            if let id = tokenizer.convertTokenToId(token) { eosIds.insert(id) }
        }
        for name in ["<|im_end|>", "<|endoftext|>"] {
            if let id = tokenizer.convertTokenToId(name) { eosIds.insert(id) }
        }

        func tokens(for user: String) throws -> [Int] {
            try tokenizer.applyChatTemplate(
                messages: [["role": "system", "content": systemPrompt],
                           ["role": "user", "content": user]],
                tools: nil, additionalContext: ["enable_thinking": false])
        }

        let full: [[Int]]
        do { full = try userMessages.map(tokens(for:)) } catch {
            box.failure = "chat template failed: \(error)"
            return
        }

        let cache: [any KVCache]
        let suffixes: [[Int]]

        if warmPrefix {
            // Prefix boundary found the same way `runMTPWarmup` finds it: the longest common
            // token prefix of two templates that differ only in user content. Deriving it from
            // the batch's own rows instead would make the prefix depend on how similar the
            // chunks happened to be, and the warm cache is supposed to be reusable across
            // batches.
            guard let probeA = try? tokens(for: "."), let probeB = try? tokens(for: "X") else {
                box.failure = "could not probe the system prefix boundary"
                return
            }
            var prefixLength = 0
            while prefixLength < probeA.count, prefixLength < probeB.count,
                  probeA[prefixLength] == probeB[prefixLength] { prefixLength += 1 }
            guard prefixLength > 0, full.allSatisfy({ $0.count > prefixLength }) else {
                box.failure = "system prefix boundary is degenerate (\(prefixLength) tokens)"
                return
            }

            let warm = model.newCache(parameters: nil)
            let prefix = MLXArray(probeA[..<prefixLength].map(Int32.init))[.newAxis]
            eval(model(prefix, cache: warm))

            cache = broadcastWarmCache(warm, to: rows.count)
            suffixes = full.map { Array($0[prefixLength...]) }
            box.warmPrefixTokens = prefixLength
        } else {
            // A fresh cache takes its batch width from the first update, so nothing special is
            // needed here to make it B-wide.
            cache = model.newCache(parameters: nil)
            suffixes = full
        }

        var pieces = [String](repeating: "", count: rows.count)
        // Per row, exactly as the single-stream path has it: without this a looping row runs to
        // `maxTokens` and inflates the very throughput figure being reported.
        var guards = (0 ..< rows.count).map { _ in DegenerationGuard<Int>() }
        var charCounts = [Int](repeating: 0, count: rows.count)

        let stats = generateBatchTokens(
            model: model,
            tokenizer: tokenizer,
            cache: cache,
            promptSuffixes: suffixes,
            maxTokens: maxTokens,
            eosTokenIds: eosIds,
            repetitionPenalty: repetitionPenalty,
            compactionThreshold: compactionThreshold,
            onToken: { row, tokenId in
                let piece = tokenizer.decode(tokens: [tokenId])
                let before = charCounts[row]
                pieces[row] += piece
                charCounts[row] += piece.count
                if let rewind = guards[row].record(tokenId, lengthBefore: before) {
                    pieces[row] = String(pieces[row].prefix(rewind))
                    charCounts[row] = rewind
                    return false
                }
                return true
            })

        box.texts = pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        box.stats = stats
    }

    if let failure = box.failure { throw BatchedLLMHarnessError.incapableModel(failure) }
    return BatchRunResult(texts: box.texts, stats: box.stats, warmPrefixTokens: box.warmPrefixTokens)
}

/// Runs the same rows one at a time. The serial reference for the equality tests, and the B=1
/// point of the throughput sweep.
///
/// Deliberately the *same function* at `rows.count == 1` rather than a separately written
/// single-stream loop: the comparison has to isolate batching, not two different implementations
/// of greedy decode.
@MainActor
func runSerialGeneration(
    _ processor: LLMPostProcessor,
    rows: [(system: String, user: String)],
    maxTokens: Int,
    warmPrefix: Bool,
    repetitionPenalty: Float = 1.0
) async throws -> BatchRunResult {
    var texts: [String] = []
    var total = BatchStats()
    var warmTokens = 0
    for row in rows {
        let result = try await runBatchedGeneration(
            processor, rows: [row], maxTokens: maxTokens,
            warmPrefix: warmPrefix, repetitionPenalty: repetitionPenalty)
        texts.append(contentsOf: result.texts)
        warmTokens = result.warmPrefixTokens
        total.rowCount += result.stats.rowCount
        total.tokenCount += result.stats.tokenCount
        total.steps += result.stats.steps
        total.promptTokenCount += result.stats.promptTokenCount
        total.padTokenCount += result.stats.padTokenCount
        total.prefillTime += result.stats.prefillTime
        total.generateTime += result.stats.generateTime
    }
    return BatchRunResult(texts: texts, stats: total, warmPrefixTokens: warmTokens)
}

// MARK: - Corpus selection

/// Real chunk texts from the frozen Phase 0a corpus, stratified so the fragile scripts are
/// present. Returns fewer than asked for rather than padding with repeats — a duplicated row
/// would decode identically to its twin and quietly overstate how well batching handles variety.
func realChunkTexts(count: Int, corpus: ChunkStreamCorpus) -> [String] {
    var byLanguage: [String: [String]] = [:]
    for stream in corpus.streams {
        for chunk in stream.chunks
        where chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 12 {
            byLanguage[stream.language, default: []].append(chunk.text)
        }
    }
    // Round-robin across languages in a fixed order so a run is reproducible.
    let languages = byLanguage.keys.sorted()
    var cursors = [String: Int](uniqueKeysWithValues: languages.map { ($0, 0) })
    var picked: [String] = []
    var exhausted = false
    while picked.count < count, !exhausted {
        exhausted = true
        for language in languages {
            guard picked.count < count else { break }
            let cursor = cursors[language]!
            guard cursor < byLanguage[language]!.count else { continue }
            picked.append(byLanguage[language]![cursor])
            cursors[language] = cursor + 1
            exhausted = false
        }
    }
    return picked
}

// MARK: - Logit-level comparison

/// How far one row's prefill logits move when the row is decoded inside a ragged batch instead of
/// alone.
struct RowLogitDelta {
    let maxAbsDiff: Float
    /// Gap between the top two logits at B=1. A `maxAbsDiff` well below this cannot flip the
    /// greedy pick; a `maxAbsDiff` comparable to it explains an occasional flip without any bug.
    let top2Gap: Float
    let argmaxMatches: Bool
}

/// Compares the last-real-token prefill logits of each row, batched versus alone.
///
/// Text-level equality is a blunt instrument for this question: it only reports a difference once
/// a near-tie has actually flipped, and it cannot say by how much. Logits say whether the batched
/// path is reproducing the same arithmetic to within float noise or getting a materially different
/// answer, which is the difference between "the hardware is not batch-invariant" and "the padding
/// is wrong".
@MainActor
func compareRaggedPrefillLogits(
    _ processor: LLMPostProcessor, texts: [String]
) async throws -> [RowLogitDelta] {
    guard let container = processor.modelContainer else { throw BatchedLLMHarnessError.notLoaded }
    let rows = texts.map { correctPrompt(for: $0, fragment: true) }
    let systemPrompt = rows[0].system

    let box = LogitBox()
    try await container.perform { context in
        let tokenizer = context.tokenizer
        guard let model = context.model as? any LLMModel else {
            box.failure = "model is not an LLMModel"
            return
        }
        let sequences: [[Int]]
        do {
            sequences = try rows.map { row in
                try tokenizer.applyChatTemplate(
                    messages: [["role": "system", "content": systemPrompt],
                               ["role": "user", "content": row.user]],
                    tools: nil, additionalContext: ["enable_thinking": false])
            }
        } catch {
            box.failure = "chat template failed: \(error)"
            return
        }

        // Batched, ragged, right-padded — the path under test.
        let lengths = sequences.map(\.count)
        let maxLen = lengths.max() ?? 0
        var flat = [Int32]()
        for (index, tokens) in sequences.enumerated() {
            flat += tokens.map(Int32.init)
            flat += repeatElement(Int32(tokens[tokens.count - 1]), count: maxLen - lengths[index])
        }
        let batchCache = model.newCache(parameters: nil)
        if lengths.contains(where: { $0 != maxLen }) {
            let padding = MLXArray(lengths.map { Int32(maxLen - $0) })
            for c in batchCache {
                guard let base = c as? BaseKVCache else { continue }
                base.rightPadding = padding
                base.rightPaddingEnd = base.offset + maxLen
            }
        }
        let batched = model(MLXArray(flat).reshaped(sequences.count, maxLen), cache: batchCache)
        eval(batched)

        for (index, tokens) in sequences.enumerated() {
            let soloCache = model.newCache(parameters: nil)
            let solo = model(MLXArray(tokens.map(Int32.init))[.newAxis], cache: soloCache)
            let soloRow = solo[0, tokens.count - 1, 0...]
            let batchRow = batched[index, lengths[index] - 1, 0...]
            eval(soloRow, batchRow)

            let diff = abs(soloRow - batchRow).max().item(Float.self)
            let soloTop = argMax(soloRow).item(Int.self)
            let batchTop = argMax(batchRow).item(Int.self)
            // Second-best at B=1: mask the winner and take the max again.
            let sorted = MLX.sorted(soloRow)
            let count = soloRow.dim(0)
            let gap = (sorted[count - 1] - sorted[count - 2]).item(Float.self)
            box.deltas.append(RowLogitDelta(
                maxAbsDiff: diff, top2Gap: gap, argmaxMatches: soloTop == batchTop))
        }
    }
    if let failure = box.failure { throw BatchedLLMHarnessError.incapableModel(failure) }
    return box.deltas
}

private final class LogitBox: @unchecked Sendable {
    var deltas: [RowLogitDelta] = []
    var failure: String?
}
