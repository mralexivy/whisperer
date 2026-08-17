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
    compactionThreshold: Double = 0.10,
    prefillPositionBudget: Int = 1024,
    syncEvery: Int = 4
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

        // A factory rather than one cache: `generateBatchTokens` prefills in row groups to keep
        // the `[rows, promptLen, vocab]` logits intermediate bounded, and each group needs its
        // own cache of the right width.
        let makeCache: (Int) -> [any KVCache]
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
            // Only the cache matters here — the prefix's logits are thrown away, and this pass is
            // ~880 positions long. Through `callAsFunction` that is 880 fp32 vocabulary rows, the
            // single largest allocation in the whole run at 1.5 GB and the reason peak memory was
            // 3859 MB at *every* batch width. `prefillLogits` projects one position instead.
            if let selective = model as? SelectivePrefillModel {
                eval(selective.prefillLogits(prefix, cache: warm, positions: [prefixLength - 1]))
            } else {
                eval(model(prefix, cache: warm))
            }

            // Broadcast per group. The source `warm` cache is left untouched by
            // `broadcastWarmCache`, which is what makes it reusable across groups and batches.
            makeCache = { broadcastWarmCache(warm, to: $0) }
            suffixes = full.map { Array($0[prefixLength...]) }
            box.warmPrefixTokens = prefixLength
        } else {
            // A fresh cache takes its batch width from the first update, so nothing special is
            // needed here to make it B-wide.
            makeCache = { _ in model.newCache(parameters: nil) }
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
            makeCache: makeCache,
            promptSuffixes: suffixes,
            maxTokens: maxTokens,
            eosTokenIds: eosIds,
            repetitionPenalty: repetitionPenalty,
            compactionThreshold: compactionThreshold,
            prefillPositionBudget: prefillPositionBudget,
            syncEvery: syncEvery,
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

// MARK: - Prompt shape

/// Token counts for a batch, measured with the model's own tokenizer.
struct PromptShape {
    /// Tokens in the shared system prefix — prefilled once and broadcast, so it costs KV per row
    /// but nothing in the batched prefill.
    let systemPrefixTokens: Int
    /// Longest per-row suffix. Right-padding makes every row this long, so this is what the
    /// batched prefill actually runs.
    let maxSuffixTokens: Int
    /// Sum of unpadded suffixes, for reporting how much of the prefill is padding.
    let totalSuffixTokens: Int
}

/// What `BatchMemoryPlanner` needs in order to plan a real batch.
///
/// Measured rather than estimated: the `Correct` system prompt is long enough that a
/// chars/4 guess would be off by enough to make the memory projection meaningless, and the whole
/// value of the projection is that it can be checked against what MLX reports.
@MainActor
func measurePromptShape(
    _ processor: LLMPostProcessor, rows: [(system: String, user: String)]
) async throws -> PromptShape {
    guard let container = processor.modelContainer else { throw BatchedLLMHarnessError.notLoaded }
    guard !rows.isEmpty else { return PromptShape(systemPrefixTokens: 0, maxSuffixTokens: 0, totalSuffixTokens: 0) }
    let systemPrompt = rows[0].system
    let users = rows.map(\.user)

    final class ShapeBox: @unchecked Sendable {
        var shape = PromptShape(systemPrefixTokens: 0, maxSuffixTokens: 0, totalSuffixTokens: 0)
        var failure: String?
    }
    let box = ShapeBox()

    try await container.perform { context in
        func tokens(for user: String) throws -> [Int] {
            try context.tokenizer.applyChatTemplate(
                messages: [["role": "system", "content": systemPrompt],
                           ["role": "user", "content": user]],
                tools: nil, additionalContext: ["enable_thinking": false])
        }
        do {
            let probeA = try tokens(for: ".")
            let probeB = try tokens(for: "X")
            var prefix = 0
            while prefix < probeA.count, prefix < probeB.count, probeA[prefix] == probeB[prefix] {
                prefix += 1
            }
            let suffixes = try users.map { try tokens(for: $0).count - prefix }
            box.shape = PromptShape(
                systemPrefixTokens: prefix,
                maxSuffixTokens: suffixes.max() ?? 0,
                totalSuffixTokens: suffixes.reduce(0, +))
        } catch {
            box.failure = "chat template failed: \(error)"
        }
    }
    if let failure = box.failure { throw BatchedLLMHarnessError.internalFailure(failure) }
    return box.shape
}

// MARK: - Raw kernel probe

/// One point of the raw decode-kernel curve, with the decode loop's own overhead separated out.
struct RawStepCost {
    let batch: Int
    /// ms per `model(y, cache:)` + `eval`. No tokenizer, no argmax, no value read back to the CPU.
    /// This is the hardware's number and nothing else.
    let kernelMs: Double
    /// ms per step for the same forward pass *plus* the argmax and the `asArray` that greedy
    /// decode needs in order to see whether a row hit EOS.
    let withPickMs: Double
    /// Peak `Memory.activeMemory` observed at this width, in MB.
    let activeMB: Double
}

/// Times the decode step itself across batch widths, stripped of everything the decode loop wraps
/// around it.
///
/// The reason this exists separately from the throughput sweep: an aggregate tok/s figure mixes
/// the GPU kernel, the per-step GPU→CPU sync, the tokenizer, the degeneration guard, and Swift
/// string appends. If that figure plateaus, the plateau could be any of them, and "the kernel is
/// compute-bound" would be an assumption rather than a measurement. Here the only thing between
/// two timer reads is the forward pass, so a flat curve means widening really is free and a linear
/// one means the GPU is saturated — with no third explanation available.
///
/// - Parameter promptTokens: length of the per-row prefill. Held identical across rows so nothing
///   is padded and the decode state is the same shape at every width.
@MainActor
func probeRawStepCost(
    _ processor: LLMPostProcessor,
    widths: [Int],
    promptTokens: Int,
    steps: Int
) async throws -> [RawStepCost] {
    guard let container = processor.modelContainer else { throw BatchedLLMHarnessError.notLoaded }
    let box = RawStepBox()

    try await container.perform { context in
        guard let model = context.model as? any LLMModel else {
            box.failure = "model is not an LLMModel"
            return
        }
        // An arbitrary in-vocabulary id, reused for every position. Content is irrelevant: the
        // cost of a decode step depends on the shapes and the cache offset, not on which tokens
        // are in it, and using real text here would only add tokenizer time to a kernel probe.
        let filler = Int32(1000)

        for width in widths {
            let cache = model.newCache(parameters: nil)
            let prompt = MLXArray(Array(repeating: filler, count: width * promptTokens))
                .reshaped(width, promptTokens)
            eval(model(prompt, cache: cache))

            let y = MLXArray(Array(repeating: filler, count: width)).reshaped(width, 1)

            // Warm-up outside the timing: the first step at a shape Metal has not seen compiles
            // and specialises kernels, and at these durations that would be most of the reading.
            for _ in 0 ..< 3 { eval(model(y, cache: cache)) }

            let kernelStart = Date()
            for _ in 0 ..< steps { eval(model(y, cache: cache)) }
            let kernelMs = -kernelStart.timeIntervalSinceNow * 1000 / Double(steps)

            let pickStart = Date()
            for _ in 0 ..< steps {
                let logits = model(y, cache: cache)
                _ = argMax(logits[0..., -1, 0...], axis: -1).asArray(Int32.self)
            }
            let withPickMs = -pickStart.timeIntervalSinceNow * 1000 / Double(steps)

            box.points.append(RawStepCost(
                batch: width, kernelMs: kernelMs, withPickMs: withPickMs,
                activeMB: Double(Memory.activeMemory) / 1024 / 1024))
        }
    }

    if let failure = box.failure { throw BatchedLLMHarnessError.incapableModel(failure) }
    return box.points
}

private final class RawStepBox: @unchecked Sendable {
    var points: [RawStepCost] = []
    var failure: String?
}

// MARK: - Memory decomposition

/// Peak and resident memory attributable to one stage of a batched generation.
struct MemoryStage {
    let name: String
    /// MLX peak over this stage alone — the counter is reset at the start of each one, so the
    /// figure is the stage's own high-water mark and not the run's.
    let peakMB: Double
    /// Resident memory once the stage has settled.
    let activeMB: Double
}

/// Splits the memory cost of a batched run into the stages that allocate.
///
/// Curve-fitting a total against a formula is how a memory model ends up with a fudge constant
/// that is wrong on the next machine. Each stage here is reset, run, and read separately, so the
/// terms in `BatchMemoryPlanner` can be checked against the thing each one claims to describe:
///
///  - `weights` — what the loaded model costs before anything runs.
///  - `warmPrefill` — the batch-1 pass over the shared system prefix. It is *not* part of the
///    batched prefill, but it is part of the run's peak, and the planner initially ignored it.
///  - `broadcast` — tiling that warm cache to `width` rows.
///  - `batchPrefill` — the padded suffix pass, the term the position budget bounds.
///  - `decode` — steady state.
@MainActor
func probeMemoryStages(
    _ processor: LLMPostProcessor, texts: [String], steps: Int
) async throws -> (stages: [MemoryStage], prefixTokens: Int, maxSuffixTokens: Int) {
    guard let container = processor.modelContainer else { throw BatchedLLMHarnessError.notLoaded }
    let rows = texts.map { correctPrompt(for: $0, fragment: true) }
    let systemPrompt = rows[0].system
    let width = texts.count

    let box = StageBox()
    try await container.perform { context in
        guard let model = context.model as? any LLMModel else {
            box.failure = "model is not an LLMModel"
            return
        }
        func tokens(for user: String) throws -> [Int] {
            try context.tokenizer.applyChatTemplate(
                messages: [["role": "system", "content": systemPrompt],
                           ["role": "user", "content": user]],
                tools: nil, additionalContext: ["enable_thinking": false])
        }

        func stage(_ name: String, _ work: () -> Void) {
            Memory.clearCache()
            Memory.peakMemory = 0
            work()
            box.stages.append(MemoryStage(
                name: name,
                peakMB: Double(Memory.peakMemory) / 1_048_576,
                activeMB: Double(Memory.activeMemory) / 1_048_576))
        }

        stage("weights") {}

        let full: [[Int]]
        let prefixLength: Int
        do {
            full = try rows.map { try tokens(for: $0.user) }
            let probeA = try tokens(for: ".")
            let probeB = try tokens(for: "X")
            var length = 0
            while length < probeA.count, length < probeB.count, probeA[length] == probeB[length] {
                length += 1
            }
            prefixLength = length
            box.prefixTokens = length
            box.maxSuffixTokens = full.map { $0.count - length }.max() ?? 0
        } catch {
            box.failure = "chat template failed: \(error)"
            return
        }
        guard prefixLength > 0, full.allSatisfy({ $0.count > prefixLength }) else {
            box.failure = "degenerate system prefix (\(prefixLength) tokens)"
            return
        }

        var warm: [any KVCache] = []
        stage("warmPrefill") {
            warm = model.newCache(parameters: nil)
            let prefix = MLXArray(full[0][..<prefixLength].map(Int32.init))[.newAxis]
            // Matches what `runBatchedGeneration` does, or this stage would measure a warm prefill
            // production no longer performs.
            if let selective = model as? SelectivePrefillModel {
                eval(selective.prefillLogits(prefix, cache: warm, positions: [prefixLength - 1]))
            } else {
                eval(model(prefix, cache: warm))
            }
        }

        var cache: [any KVCache] = []
        stage("broadcast") {
            cache = broadcastWarmCache(warm, to: width)
            eval(cache.flatMap { $0.state })
        }

        let suffixes = full.map { Array($0[prefixLength...]) }
        let maxLen = suffixes.map(\.count).max() ?? 1
        var last: MLXArray?
        stage("batchPrefill") {
            var flat = [Int32]()
            flat.reserveCapacity(width * maxLen)
            for suffix in suffixes {
                flat.append(contentsOf: suffix.map(Int32.init))
                flat.append(contentsOf: repeatElement(Int32(suffix[suffix.count - 1]),
                                                      count: maxLen - suffix.count))
            }
            let prompt = MLXArray(flat).reshaped(width, maxLen)
            let logits: MLXArray
            if let selective = model as? SelectivePrefillModel {
                logits = selective.prefillLogits(prompt, cache: cache,
                                                 positions: suffixes.map { $0.count - 1 })
            } else {
                logits = model(prompt, cache: cache)
            }
            let picked = argMax(logits[0..., -1, 0...], axis: -1)
            eval(picked)
            last = picked
        }

        stage("decode") {
            var y = last!.reshaped(width, 1)
            for _ in 0 ..< steps {
                let logits = model(y, cache: cache)
                y = argMax(logits[0..., -1, 0...], axis: -1).reshaped(width, 1)
                eval(y)
            }
        }
    }

    if let failure = box.failure { throw BatchedLLMHarnessError.incapableModel(failure) }
    return (box.stages, box.prefixTokens, box.maxSuffixTokens)
}

/// Token shape observed by the most recent `probeMemoryStages` call, so a caller can report the
/// stage table against the lengths that produced it.
private final class StageBox: @unchecked Sendable {
    var stages: [MemoryStage] = []
    var prefixTokens = 0
    var maxSuffixTokens = 0
    var failure: String?
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
