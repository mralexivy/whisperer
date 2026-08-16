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

/// A model that can finish a prefill without projecting every position to vocabulary.
///
/// Whisperer local addition. Measured on Qwen3.5-4B at B=32 with a 128-token padded suffix, the
/// prefill was 5.4 s of a 10.5 s batch — and ~99% of it was `lm_head` on positions nobody reads.
/// A model that cannot do this still works; it just pays that cost, so the batch loop treats the
/// capability as optional rather than requiring it of every `LLMModel`.
public protocol SelectivePrefillModel {
    /// Runs the forward pass over `inputs` (updating `cache`) and returns `[rows, 1, vocab]`,
    /// where row `b`'s logits come from `positions[b]`.
    func prefillLogits(_ inputs: MLXArray, cache: [KVCache]?, positions: [Int]) -> MLXArray
}

extension Qwen35TextModel: SelectivePrefillModel {}
extension Qwen35Model: SelectivePrefillModel {}

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
///   - makeCache: produces a cache already broadcast to the requested number of rows — see
///     `broadcastWarmCache`. A factory rather than a single cache because the prefill runs in
///     row groups; see `prefillRowGroup`.
///   - promptSuffixes: per-row continuation tokens. Ragged is fine; they are right-padded
///     internally.
///   - maxTokens: per-row cap, not a total.
///   - eosTokenIds: ids that retire a row.
///   - repetitionPenalty: 1.0 disables it. **Leave it disabled where you can**: with a penalty the
///     per-step argmax has to be taken row by row, which costs one GPU→CPU sync per row per step
///     instead of one for the whole batch, and that overhead grows with exactly the B this
///     function is trying to make large.
///   - compactionThreshold: fraction of dead rows at which the batch is physically compacted.
///     Measured on ragged real chunks at B=32, end to end: 55.0 tok/s never compacting, 58.8 at
///     0.5, 58.9 at 0.25, 60.0 at 0.1 — reproduced to within 0.2% on a second run. Compacting at
///     all is worth 9%; compacting eagerly is worth a further 2%, and the rewrite it costs never
///     showed up. Hence 0.1.
///   - prefillPositionBudget: the largest `rows × promptLen` any single prefill pass may cover.
///     Originally this bounded the `[rows, promptLen, 248320]` logits tensor a prefill used to
///     return — over 8 GB at B=64 with a 256-token prompt, measured driving MLX peak memory to
///     19.5 GB, the load average to 64, and the machine into a reboot. `SelectivePrefillModel`
///     removed that tensor entirely, so what is left to bound is the per-position layer
///     activations, ~0.77 MB each. Still worth bounding, an order of magnitude less urgent.
///
///     Budgeting *positions* rather than rows is the point: the allocation is proportional to
///     their product, so a fixed row group silently scales with prompt length and stops protecting
///     anything on a long prompt.
///
///     Splitting is free in output terms — rows never interact along the batch axis — but not in
///     time: each group is a separate forward pass, and the groups are merged afterwards, which
///     briefly holds two copies of the cache. `BatchMemoryPlanner` prices both.
///   - syncEvery: how many decode steps run before the sampled tokens are read back to the CPU.
///     The forward pass at B=32 costs 140 ms; the argmax and the `asArray` that follow it cost a
///     further 33 ms, and that 33 ms buys nothing except the ability to notice EOS. Sampling
///     straight into the next step's input keeps the whole loop on the GPU, and the readback then
///     amortises over `syncEvery` steps. The cost is that a row can overrun its EOS by up to
///     `syncEvery - 1` tokens, which are discarded — output is unaffected.
///   - onToken: `(row, tokenId)` in the caller's original row order, which does not change even
///     after compaction. Return false to retire that row. **Not** called in lock-step with the
///     GPU: tokens arrive in bursts of `syncEvery`.
@discardableResult
public func generateBatchTokens(
    model: any LLMModel,
    tokenizer: any Tokenizer,
    makeCache: (_ rows: Int) -> [any KVCache],
    promptSuffixes: [[Int]],
    maxTokens: Int,
    eosTokenIds: Set<Int>,
    repetitionPenalty: Float = 1.0,
    repetitionContextSize: Int = 64,
    compactionThreshold: Double = 0.10,
    prefillPositionBudget: Int = 1024,
    syncEvery: Int = 4,
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

    let isPadded = lengths.contains { $0 != maxLen }
    // Row groups, each prefilled by its own forward pass. Rows are independent along the batch
    // axis — no attention or SSM state crosses rows — so grouping changes nothing about the
    // result, only the size of the largest live intermediate.
    // Derived from the budget and the actual padded length, so a long prompt automatically gets
    // narrower groups instead of quietly allocating more.
    let groupSize = max(1, min(rows, prefillPositionBudget / max(maxLen, 1)))
    var groupCaches: [[any KVCache]] = []
    /// One `[g, 1, vocab]` per prefill group, in row order.
    var lastLogits: [MLXArray] = []

    for groupStart in stride(from: 0, to: rows, by: groupSize) {
        let group = Array(groupStart ..< min(groupStart + groupSize, rows))
        let groupCache = makeCache(group.count)

        // Right-padded so every row's real tokens keep an intact causal window; the pads land
        // after them, where a causal conv1d cannot see them. See the note on
        // `BaseKVCache.rightPadding` for why left padding — what upstream mlx-lm does — is wrong
        // for this model. Padded to the *global* `maxLen` rather than the group's own, so every
        // group leaves its cache at the same offset and the groups can be merged below.
        var flat = [Int32]()
        flat.reserveCapacity(group.count * maxLen)
        for row in group {
            let tokens = promptSuffixes[row]
            flat.append(contentsOf: tokens.map(Int32.init))
            // Padded with the row's own last token rather than a dedicated pad id: it is
            // guaranteed in-vocabulary, and the pad columns are masked out of both the attention
            // and the SSM, so the value is never read. A wrong id here would fault rather than
            // degrade.
            flat.append(contentsOf: repeatElement(Int32(tokens[tokens.count - 1]),
                                                  count: maxLen - lengths[row]))
        }

        if isPadded {
            let padding = MLXArray(group.map { Int32(maxLen - lengths[$0]) })
            for c in groupCache {
                guard let base = c as? BaseKVCache else { continue }
                base.rightPadding = padding
                // Absolute, and captured *before* the prefill advances the offset: the pads stay
                // physically in the full-attention caches for the rest of the generation, so
                // every later decode step needs to know where they are.
                base.rightPaddingEnd = base.offset + maxLen
            }
        }

        let prompt = MLXArray(flat).reshaped(group.count, maxLen)

        // Row `b`'s next-token distribution lives at its own last real token, `lengths[b] - 1`,
        // not at the end of the padded chunk — reading the last column would read a pad for every
        // row that was shorter than the longest one.
        let positions = group.map { lengths[$0] - 1 }
        let picked: MLXArray
        if let selective = model as? SelectivePrefillModel {
            // The projection happens *after* the gather, so the `[g, maxLen, vocab]` intermediate
            // is never built at all — see `SelectivePrefillModel`.
            picked = selective.prefillLogits(prompt, cache: groupCache, positions: positions)
        } else {
            let groupLogits = model(prompt, cache: groupCache)
            picked = stacked(positions.enumerated().map { slot, position in
                groupLogits[slot, position ..< (position + 1), 0...]
            }, axis: 0)
        }
        // Forced here, inside the loop, so the group's intermediates can be released before the
        // next group allocates its own. Deferring this to one `eval` after the loop would hold
        // every group's live at once and defeat the grouping.
        eval(picked)
        lastLogits.append(picked)

        // The recurrent caches are done with the padding the moment the prefill chunk is
        // consumed: the GatedDeltaNet kernel skips masked positions outright, so a pad leaves no
        // trace in the SSM state, and the conv state was gathered per row inside the layer.
        // Leaving `rightPadding` set on them would make `ArraysCache.makeMask` mask a decode
        // chunk that has no padding. `KVCacheSimple` is the opposite case and must keep it.
        for c in groupCache where c is ArraysCache {
            (c as? BaseKVCache)?.rightPadding = nil
        }
        groupCaches.append(groupCache)
    }

    let cache = mergeBatchCaches(groupCaches)
    // Each entry is one group's `[g, 1, vocab]`, in row order, so concatenating along the row axis
    // reassembles the batch.
    var stepLogits = lastLogits.count == 1
        ? lastLogits[0] : concatenated(lastLogits, axis: 0)   // [rows, 1, vocab]

    stats.prefillTime = -prefillStart.timeIntervalSinceNow

    // MARK: - Decode

    let generateStart = Date()

    /// Slot → the caller's row index. Diverges from identity after the first compaction.
    var slotRow = Array(0 ..< rows)
    var alive = [Bool](repeating: true, count: rows)
    var produced = [Int](repeating: 0, count: rows)

    /// Greedy pick for every slot from `[slots, 1, vocab]`, returned **as an `MLXArray` still on
    /// the GPU** so it can be reshaped straight into the next step's input.
    ///
    /// That is the whole point: the sampled token is the only thing the next forward pass needs,
    /// and the GPU already has it. Reading it back to the CPU every step — which is what this
    /// function used to do — costs a measured 33 ms per step at B=32 against a 140 ms forward
    /// pass, i.e. 19% of decode, purely so the loop can notice EOS a few milliseconds earlier.
    ///
    /// The penalty path is the exception and stays on the CPU, because `RepetitionContext` masks
    /// a per-row set of token ids. It is correct but it is why the penalty is off by default.
    func sample(_ logits: MLXArray) -> MLXArray {
        if repetitions == nil {
            return argMax(logits[0..., -1, 0...], axis: -1)
        }
        return MLXArray((0 ..< slotRow.count).map { slot -> Int32 in
            let row = slotRow[slot]
            let rowLogits = logits[slot, -1, 0...].expandedDimensions(axes: [0])
            return Int32(repetitions![row].process(logits: rowLogits).argMax().item(Int.self))
        })
    }

    /// Deliver one token and decide whether its row continues.
    func emit(slot: Int, token: Int) {
        let row = slotRow[slot]

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

    // The penalty path has to inspect every row's logits on the CPU anyway, so batching the
    // readback would only add latency without removing a sync.
    let burstSize = repetitions == nil ? max(1, syncEvery) : 1

    /// Tokens for the position the GPU has not been asked about yet.
    var next = sample(stepLogits)
    asyncEval(next)

    while true {
        // Run a burst of steps with no CPU involvement at all. `asyncEval` keeps the queue fed
        // rather than letting the graph pile up unevaluated.
        var burst: [MLXArray] = []
        burst.reserveCapacity(burstSize)
        while burst.count < burstSize, stats.steps < maxTokens {
            burst.append(next)
            stats.steps += 1
            guard stats.steps < maxTokens else { break }
            next = sample(model(next.reshaped(next.dim(0), 1), cache: cache))
            asyncEval(next)
        }

        // One readback for the whole burst.
        eval(burst)
        for tokens in burst {
            let ids = tokens.asArray(Int32.self)
            for slot in 0 ..< slotRow.count where alive[slot] {
                emit(slot: slot, token: Int(ids[slot]))
            }
            // Tokens a row produced after its EOS are simply not delivered. They cost GPU time —
            // up to `burstSize - 1` steps of it — but they cannot change the output.
            if !alive.contains(true) { break }
        }
        guard alive.contains(true), stats.steps < maxTokens else { break }

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
            alive = keep.map { alive[$0] }
            // The pending token vector is still full width and would no longer line up with the
            // narrowed cache.
            next = next[indices]
            stats.compactions += 1
        }
    }

    stats.generateTime = -generateStart.timeIntervalSinceNow
    return stats
}

/// Whisperer local addition: join per-row-group caches into one batch-wide cache.
///
/// The groups were prefilled independently but to the same padded length, so every group's cache
/// sits at the same offset and the only thing separating them is the batch axis. Concatenating
/// along it produces exactly the cache a single wide prefill would have produced — rows never
/// interact along that axis, which is what makes grouping a memory optimisation rather than a
/// change of behaviour.
private func mergeBatchCaches(_ groups: [[any KVCache]]) -> [any KVCache] {
    guard let first = groups.first else { return [] }
    guard groups.count > 1 else { return first }

    return (0 ..< first.count).map { layer -> any KVCache in
        let parts = groups.map { $0[layer] }
        // The first group's cache object is reused as the merged one, so anything it already
        // carries that is not part of `state` — `offset` on the recurrent caches, `rightPaddingEnd`
        // — survives untouched and correct, since every group ran to the same offset.
        var merged = parts[0]

        let stateCount = merged.state.count
        if stateCount > 0 {
            merged.state = (0 ..< stateCount).map { index in
                concatenated(parts.map { $0.state[index] }, axis: 0)
            }
        }
        // The full-attention caches keep their pads for the rest of the run, so the pad layout
        // has to be concatenated alongside the keys and values it describes. The recurrent caches
        // cleared theirs at the end of their own prefill.
        if let kv = merged as? KVCacheSimple {
            let pads = parts.compactMap { ($0 as? BaseKVCache)?.rightPadding }
            if pads.count == parts.count {
                kv.rightPadding = concatenated(pads, axis: 0)
            }
        }
        return merged
    }
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
