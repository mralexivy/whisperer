// BatchGenerate.swift — Whisperer local addition: batched greedy decode.
//
// Why this exists: decode at batch 1 is memory-bandwidth bound. A single forward pass streams
// all 2.4 GB of the 4-bit weights whether it decodes one token or thirty-two, so putting more
// sequences on the batch dimension is close to free per step and multiplies *aggregate*
// throughput. It does not make any one sequence faster — per-sequence latency stays flat and
// may rise slightly at large B. That distinction matters every time someone benchmarks a
// one-sentence dictation and concludes batching does nothing.
//
// Greedy at temperature 0, so a batched run is expected to be byte-identical to the same
// prompts run serially. That is the property the correctness tests assert, and it is what lets
// the already-measured prompt-quality scores carry over untouched.
//
// Relationship to `MTPGenerate.swift`: MTP is speculative decode and buys ~1.5×; batching buys
// 8–24×. They are not combined here. Batched MTP needs per-row accept/rollback with per-row
// `KVCacheSimple.trim` and per-row `MambaCache` snapshots — high complexity for a small marginal
// gain on top of what this file already gets.

import Foundation
import MLX
import MLXLMCommon
import Tokenizers

/// Stats collected during a batched generate call.
public struct BatchStats {
    public init() {}

    /// Rows the batch started with.
    public var rowCount: Int = 0
    /// Tokens emitted across all rows.
    public var tokenCount: Int = 0
    /// Decode steps taken. One step decodes one token for every row still alive, so
    /// `tokenCount / steps` is the effective batch width averaged over the run — the number that
    /// tells you whether stragglers held a mostly-dead batch open.
    public var steps: Int = 0
    /// Prompt tokens across all rows, padding excluded.
    public var promptTokenCount: Int = 0
    /// Padding slots the ragged prefill had to add.
    public var padTokenCount: Int = 0
    /// How many times finished rows were compacted out of the batch.
    public var compactions: Int = 0
    public var prefillTime: Double = 0
    public var generateTime: Double = 0

    /// Aggregate decode throughput — the headline figure this whole file exists to raise.
    public var tokensPerSecond: Double {
        generateTime > 0 ? Double(tokenCount) / generateTime : 0
    }
    /// Steps per second. Roughly flat across B while decode stays bandwidth-bound; when it starts
    /// falling with B, the batch has become compute-bound and further widening buys nothing.
    public var stepsPerSecond: Double {
        generateTime > 0 ? Double(steps) / generateTime : 0
    }
    /// Average rows alive per step.
    public var averageWidth: Double {
        steps > 0 ? Double(tokenCount) / Double(steps) : 0
    }
    /// Fraction of prefill slots spent on padding. Rises when rows of very different lengths are
    /// batched together, which is the argument for length-bucketing in the scheduler.
    public var padWaste: Double {
        let total = promptTokenCount + padTokenCount
        return total > 0 ? Double(padTokenCount) / Double(total) : 0
    }
}

/// Greedy decode of several prompts at once, sharing one warm cache.
///
/// - Parameters:
///   - model: any `LLMModel`. Called through `callAsFunction(_:cache:)`, which returns logits.
///   - tokenizer: supplies the unknown-token id, matching `generateMTPTokens`.
///   - cache: **already broadcast to `promptSuffixes.count` rows** — see `broadcastWarmCache`.
///     Its current offset is treated as the shared warm prefix; only the per-row suffixes are
///     prefilled here.
///   - promptSuffixes: per-row continuation tokens. Ragged is fine; they are right-padded
///     internally.
///   - maxTokens: per-row cap, not a total.
///   - eosTokenIds: ids that retire a row.
///   - repetitionPenalty: 1.0 disables it. **Leave it disabled where you can**: with a penalty the
///     per-step argmax has to be taken row by row, which costs one GPU→CPU sync per row per step
///     instead of one for the whole batch, and that overhead grows with exactly the B this
///     function is trying to make large.
///   - compactionThreshold: fraction of dead rows at which the batch is physically compacted.
///   - onToken: `(row, tokenId)` in the caller's original row order, which does not change even
///     after compaction. Return false to retire that row.
@discardableResult
public func generateBatchTokens(
    model: any LLMModel,
    tokenizer: any Tokenizer,
    cache: [any KVCache],
    promptSuffixes: [[Int]],
    maxTokens: Int,
    eosTokenIds: Set<Int>,
    repetitionPenalty: Float = 1.0,
    repetitionContextSize: Int = 64,
    compactionThreshold: Double = 0.5,
    onToken: (_ row: Int, _ tokenId: Int) -> Bool
) -> BatchStats {
    var stats = BatchStats()

    let rows = promptSuffixes.count
    guard rows > 0, maxTokens > 0 else { return stats }
    let lengths = promptSuffixes.map(\.count)
    guard let maxLen = lengths.max(), maxLen > 0 else { return stats }
    precondition(lengths.allSatisfy { $0 > 0 }, "every row needs at least one prompt token")

    stats.rowCount = rows
    stats.promptTokenCount = lengths.reduce(0, +)
    stats.padTokenCount = rows * maxLen - stats.promptTokenCount

    // Penalty state is per row and must survive compaction, so it is keyed by the caller's row
    // index rather than by slot. Generated tokens only, never the prompt — a correction is
    // supposed to reuse the words of the text underneath it.
    var repetitions: [RepetitionContext]? =
        (repetitionPenalty != 1.0 && repetitionContextSize > 0)
        // Constructed one at a time, not with `Array(repeating:count:)`: the context holds a
        // token ring backed by an `MLXArray`, and a repeated value would hand every row a
        // reference to the same ring.
        ? (0 ..< rows).map { _ in
            RepetitionContext(
                repetitionPenalty: repetitionPenalty, repetitionContextSize: repetitionContextSize)
        }
        : nil

    // MARK: - Ragged prefill

    let prefillStart = Date()

    // Right-padded so every row's real tokens keep an intact causal window; the pads land after
    // them, where a causal conv1d cannot see them. See the note on `BaseKVCache.rightPadding`
    // for why left padding — what upstream mlx-lm does — is wrong for this model.
    var flat = [Int32]()
    flat.reserveCapacity(rows * maxLen)
    for (row, tokens) in promptSuffixes.enumerated() {
        flat.append(contentsOf: tokens.map(Int32.init))
        // Padded with the row's own last token rather than a dedicated pad id: it is guaranteed
        // in-vocabulary, and the pad columns are masked out of both the attention and the SSM,
        // so the value is never read. A wrong id here would fault rather than degrade.
        flat.append(contentsOf: repeatElement(Int32(tokens[tokens.count - 1]),
                                              count: maxLen - lengths[row]))
    }

    let isPadded = lengths.contains { $0 != maxLen }
    if isPadded {
        let padding = MLXArray(lengths.map { Int32(maxLen - $0) })
        for c in cache {
            guard let base = c as? BaseKVCache else { continue }
            base.rightPadding = padding
            // Absolute, and captured *before* the prefill advances the offset: the pads stay
            // physically in the full-attention caches for the rest of the generation, so every
            // later decode step needs to know where they are.
            base.rightPaddingEnd = base.offset + maxLen
        }
    }

    let prompt = MLXArray(flat).reshaped(rows, maxLen)
    let prefillLogits = model(prompt, cache: cache)

    // Row `b`'s next-token distribution lives at its own last real token, `lengths[b] - 1`, not
    // at the end of the padded chunk — reading the last column would read a pad for every row
    // that was shorter than the longest one.
    var stepLogits = stacked(
        lengths.enumerated().map { prefillLogits[$0.offset, ($0.element - 1) ..< $0.element, 0...] },
        axis: 0)   // [rows, 1, vocab]
    eval(stepLogits)

    // The recurrent caches are done with the padding the moment the prefill chunk is consumed:
    // the GatedDeltaNet kernel skips masked positions outright, so a pad leaves no trace in the
    // SSM state, and the conv state was gathered per row inside the layer. Leaving `rightPadding`
    // set on them would make `ArraysCache.makeMask` mask a decode chunk that has no padding.
    // `KVCacheSimple` is the opposite case and must keep it.
    for c in cache where c is ArraysCache {
        (c as? BaseKVCache)?.rightPadding = nil
    }

    stats.prefillTime = -prefillStart.timeIntervalSinceNow

    // MARK: - Decode

    let generateStart = Date()

    /// Slot → the caller's row index. Diverges from identity after the first compaction.
    var slotRow = Array(0 ..< rows)
    var alive = [Bool](repeating: true, count: rows)
    var current = [Int](repeating: 0, count: rows)
    var produced = [Int](repeating: 0, count: rows)

    /// Greedy pick for every slot from `[slots, 1, vocab]`.
    ///
    /// The no-penalty path is one argmax and one sync for the whole batch. The penalty path is
    /// per row because `RepetitionContext` masks a per-row set of token ids; it is correct but
    /// it is the reason the penalty is off by default here.
    func pick(_ logits: MLXArray) -> [Int] {
        if repetitions == nil {
            return argMax(logits[0..., -1, 0...], axis: -1).asArray(Int32.self).map(Int.init)
        }
        return (0 ..< slotRow.count).map { slot in
            let row = slotRow[slot]
            let rowLogits = logits[slot, -1, 0...].expandedDimensions(axes: [0])
            return repetitions![row].process(logits: rowLogits).argMax().item(Int.self)
        }
    }

    /// Deliver one token and decide whether its row continues.
    func emit(slot: Int, token: Int) {
        let row = slotRow[slot]
        current[slot] = token

        // EOS is not delivered, matching `generateMTPTokens` — the caller's text should not gain
        // a stray end marker just because it was produced in a batch.
        if token == tokenizer.unknownTokenId || eosTokenIds.contains(token) {
            alive[slot] = false
            return
        }

        repetitions?[row].didSample(token: MLXArray(Int32(token)))
        produced[row] += 1
        stats.tokenCount += 1

        if !onToken(row, token) || produced[row] >= maxTokens {
            alive[slot] = false
        }
    }

    let firstTokens = pick(stepLogits)
    for slot in 0 ..< rows { emit(slot: slot, token: firstTokens[slot]) }

    while alive.contains(true), stats.steps < maxTokens {
        // Retire finished rows. Until this happens a dead row still costs full memory bandwidth
        // on every step, so one long straggler would otherwise make the batch as slow as B=1
        // while pretending to be wide. Deferred to a threshold because the compaction itself
        // rewrites every cache tensor.
        let deadCount = alive.filter { !$0 }.count
        if deadCount > 0, Double(deadCount) / Double(alive.count) >= compactionThreshold {
            let keep = (0 ..< alive.count).filter { alive[$0] }
            let indices = MLXArray(keep.map(Int32.init))
            for c in cache {
                // Two distinct implementations, and both are needed: the full-attention caches
                // subset their keys/values *and* their pad layout, while the recurrent ones
                // subset their state and have no pads left to carry.
                if let kv = c as? KVCacheSimple {
                    kv.filter(batchIndices: indices)
                } else if let arrays = c as? ArraysCache {
                    arrays.filter(batchIndices: indices)
                }
            }
            slotRow = keep.map { slotRow[$0] }
            current = keep.map { current[$0] }
            alive = keep.map { alive[$0] }
            stats.compactions += 1
        }

        // Dead slots that survived compaction are re-fed their own last token. Their output is
        // discarded; the point is only to keep the batch rectangular until the next compaction.
        let y = MLXArray(current.map(Int32.init)).reshaped(current.count, 1)
        stepLogits = model(y, cache: cache)
        eval(stepLogits)
        stats.steps += 1

        let picked = pick(stepLogits)
        for slot in 0 ..< slotRow.count where alive[slot] {
            emit(slot: slot, token: picked[slot])
        }
    }

    stats.generateTime = -generateStart.timeIntervalSinceNow
    return stats
}

/// Whisperer local addition: tile a batch-1 warm cache across `rows`.
///
/// Reusing the warm system prefix is mandatory rather than an optimisation. The `Correct` system
/// prompt is ~800 tokens; re-prefilling it per row at B=16 is 12,800 prompt tokens against a
/// measured ~290 tok/s prefill — about 44 seconds, which is more than the entire win batching is
/// there to produce.
///
/// The source cache is left untouched so it can be broadcast again for the next batch.
public func broadcastWarmCache(_ warm: [any KVCache], to rows: Int) -> [any KVCache] {
    precondition(rows > 0)
    return warm.map { source in
        // `var` because `KVCache` is not class-constrained, so `state` cannot be set through a
        // `let` existential even though every concrete cache here is a class.
        var copy = source.copy()
        guard rows > 1 else { return copy }
        // `state` is the cache's own serialization surface, so this tiles whatever the concrete
        // cache considers its content — keys/values for the full-attention layers, conv and SSM
        // state for the recurrent ones — without this function needing to know which is which.
        let tiled = copy.state.map { tiledArray($0, repetitions: rows, axis: 0) }
        if !tiled.isEmpty { copy.state = tiled }
        return copy
    }
}

/// Repeat `array` `repetitions` times along `axis`, leaving every other axis alone.
private func tiledArray(_ array: MLXArray, repetitions: Int, axis: Int) -> MLXArray {
    precondition(array.dim(axis) == 1,
                 "warm cache must be batch 1 to broadcast, got \(array.shape)")
    var counts = [Int](repeating: 1, count: array.ndim)
    counts[axis] = repetitions
    return tiled(array, repetitions: counts)
}
