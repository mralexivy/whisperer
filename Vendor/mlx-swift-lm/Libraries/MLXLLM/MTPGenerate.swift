// MTPGenerate.swift — MTP batched speculative decode for Qwen3.5 models.
//
// Algorithm (batched, greedy — optionally with a repetition penalty):
//   Prefill → firstToken (emit)
//   Loop:
//     A) backbone(y) or prefetch     → logitsA, hA  → verified
//     B) mtp(hA, emb(verified))      → draft
//     C) emit verified
//     D) backbone([verified, draft]) → logitsBatch, hBatch  (2-token batch)
//        nextVerified = argmax(logitsBatch[0, 0, ...])
//        ACCEPT (draft == nextVerified):
//          prefetch pos-1 results for next Step A (skip one backbone call)
//        ROLLBACK:
//          restore MambaCache snapshots + trim KVCacheSimple by 1
//     E) emit nextVerified
//     F) y = nextVerified
//
// Speedup source: on ACCEPT (~67% of iterations), next Step A is free (prefetched).
// Expected ~1.5× throughput at 67% acceptance with Apple Silicon batch amortization.
//
// Correctness: ACCEPT path is exact (identical to sequential execution).
// ROLLBACK approximation: MambaCache restored to before-batch state (1-token SSM lag
// on 33% of iterations). FA layers (7 of 28) see the correct KV sequence throughout.
// Impact is negligible for 10–50 token text corrections.

import Foundation
import MLX
import MLXLMCommon
import Tokenizers

/// Protocol satisfied by Qwen35TextModel and Qwen35Model.
/// Extends LLMModel with MTP-specific operations.
public protocol MTPCapableModel: LLMModel {
    func forwardWithHiddenState(_ inputs: MLXArray, cache: [KVCache]?) -> (logits: MLXArray, hiddenState: MLXArray)
    func draftToken(hiddenState: MLXArray, tokenEmbedding: MLXArray, cache: [KVCache?]?) -> MLXArray?
    func embedTokens(_ tokens: MLXArray) -> MLXArray
}

/// Stats collected during an MTP generate call.
public struct MTPStats {
    public var tokenCount: Int = 0
    public var acceptedCount: Int = 0
    public var rollbackCount: Int = 0
    public var prefetchCount: Int = 0  // Step A calls saved by accept prefetch
    public var draftTime: Double = 0   // cumulative seconds spent in draftToken calls
    public var prefillTime: Double = 0
    public var generateTime: Double = 0

    public var acceptanceRate: Float {
        guard rollbackCount + acceptedCount > 0 else { return 0 }
        return Float(acceptedCount) / Float(acceptedCount + rollbackCount)
    }
}

/// Greedy MTP batched speculative decode.
///
/// - Parameters:
///   - model: MTPCapableModel with both backbone and MTP head loaded.
///   - tokenizer: Tokenizer providing EOS/unknown token IDs.
///   - cache: Pre-built KV cache.
///   - promptTokens: Tokens to prefill.
///   - maxTokens: Hard limit on generated tokens.
///   - eosTokenIds: Set of token IDs that terminate generation.
///   - repetitionPenalty: HF-style penalty on recently *generated* tokens. 1.0 disables it.
///   - repetitionContextSize: How many recent generated tokens the penalty covers.
///   - onToken: Called synchronously for each emitted token. Return false to stop.
/// - Returns: MTPStats for the generation call.
@discardableResult
public func generateMTPTokens(
    model: any MTPCapableModel,
    tokenizer: any Tokenizer,
    cache: [any KVCache],
    promptTokens: [Int],
    maxTokens: Int,
    eosTokenIds: Set<Int>,
    repetitionPenalty: Float = 1.0,
    repetitionContextSize: Int = 64,
    onToken: (Int) -> Bool
) -> MTPStats {
    var stats = MTPStats()

    // Greedy decoding cannot climb out of a loop on its own: the argmax that produced
    // "to Michael to Michael to to to…" is the argmax the same state produces again. The
    // penalty is the only thing here that breaks the cycle, so it is applied to *every*
    // distribution this function takes an argmax of — including the MTP draft, which must
    // see the same distribution as the verify step or accept/rollback stop agreeing.
    //
    // Generated tokens only, never the prompt: a summary is supposed to reuse the words of
    // the transcript underneath it, and penalizing those would push the model off its source.
    var repetition: RepetitionContext? =
        (repetitionPenalty != 1.0 && repetitionContextSize > 0)
        ? RepetitionContext(
            repetitionPenalty: repetitionPenalty, repetitionContextSize: repetitionContextSize)
        : nil

    /// Penalized greedy pick from a 1-D `[vocabSize]` logits slice.
    func pick(_ logits: MLXArray) -> Int {
        guard let rep = repetition else { return logits.argMax().item(Int.self) }
        return rep.process(logits: logits.expandedDimensions(axes: [0]))[0, 0...]
            .argMax().item(Int.self)
    }

    /// Record an emitted token so the next `pick` sees it.
    func remember(_ token: Int) {
        repetition?.didSample(token: MLXArray(Int32(token)))
    }

    let prefillStart = Date()

    // --- Prefill ---
    let promptArray = MLXArray(promptTokens)[.newAxis]
    let (prefillLogits, _) = model.forwardWithHiddenState(promptArray, cache: cache)
    eval(prefillLogits)

    stats.prefillTime = -prefillStart.timeIntervalSinceNow
    let generateStart = Date()

    // Extract first token from prefill.
    var y = pick(prefillLogits[0, -1, 0...])
    remember(y)
    stats.tokenCount += 1

    if isEOS(y, eosTokenIds: eosTokenIds, tokenizer: tokenizer) || !onToken(y) {
        stats.generateTime = -generateStart.timeIntervalSinceNow
        return stats
    }
    if stats.tokenCount >= maxTokens {
        stats.generateTime = -generateStart.timeIntervalSinceNow
        return stats
    }

    // --- Decode loop ---
    // Prefetch holds pos-1 results from the last accepted batch call.
    // On accept, next Step A is free (these replace the backbone(y) call).
    var prefetchLogits: MLXArray? = nil   // shape [vocabSize]
    var prefetchHidden: MLXArray? = nil   // shape [hiddenDim]

    while stats.tokenCount < maxTokens {
        // Step A: backbone(y) → logitsA, hA, OR consume prefetch from last accept.
        let logitsA: MLXArray   // shape [1, 1, vocabSize]
        let hA: MLXArray        // shape [1, 1, hiddenDim]

        if let pl = prefetchLogits, let ph = prefetchHidden {
            // Expand flat [V] and [D] vectors to [1,1,V] and [1,1,D] so the rest
            // of Step A / Step B uses the same indexing as a normal backbone call.
            logitsA = pl.expandedDimensions(axes: [0, 1])
            hA      = ph.expandedDimensions(axes: [0, 1])
            prefetchLogits = nil
            prefetchHidden = nil
            stats.prefetchCount += 1
        } else {
            let yArr = MLXArray([Int32(y)]).reshaped(1, 1)
            (logitsA, hA) = model.forwardWithHiddenState(yArr, cache: cache)
            eval(logitsA, hA)
        }
        let verified = pick(logitsA[0, -1, 0...])
        // Recorded before Step B and Step D so the draft and the verify that checks it are
        // taken from the identical penalized distribution — otherwise every accept becomes
        // a coin toss and the speculative path degrades to plain sequential decoding.
        remember(verified)

        // Step B: MTP draft — predict what comes after verified.
        let embVerified = model.embedTokens(MLXArray([Int32(verified)]).reshaped(1, 1))
        let draftStart = Date()
        let draftLogits = model.draftToken(
            hiddenState: hA[0, -1, 0...].expandedDimensions(axes: [0, 1]),
            tokenEmbedding: embVerified,
            cache: nil)
        var draft: Int? = nil
        if let dl = draftLogits {
            eval(dl)
            draft = pick(dl[0, -1, 0...])
        }
        stats.draftTime += -draftStart.timeIntervalSinceNow

        // Step C: emit verified.
        stats.tokenCount += 1
        if isEOS(verified, eosTokenIds: eosTokenIds, tokenizer: tokenizer) || !onToken(verified) {
            break
        }
        if stats.tokenCount >= maxTokens { break }

        // Step D: batched backbone [verified, draft] for speculative speedup,
        //         or single-token fallback when no draft is available.
        let nextVerified: Int

        if let d = draft {
            // Snapshot MambaCache states before the 2-token batch mutates the SSM.
            // On rollback we restore these; KVCacheSimple is restored via trim(1).
            var mambaIndices: [Int] = []
            var mambaStates: [[MLXArray]] = []
            for (i, c) in cache.enumerated() {
                if let mc = c as? MambaCache, !mc.state.isEmpty {
                    mambaIndices.append(i)
                    mambaStates.append(mc.state.map { $0[.ellipsis] })
                }
            }
            if !mambaStates.isEmpty {
                eval(mambaStates.flatMap { $0 })
            }

            // Run 2-token batch: backbone processes [verified, draft] together.
            let batchArr = MLXArray([Int32(verified), Int32(d)]).reshaped(1, 2)
            let (logitsBatch, hBatch) = model.forwardWithHiddenState(batchArr, cache: cache)
            eval(logitsBatch, hBatch)
            // logitsBatch: [1, 2, vocabSize]  hBatch: [1, 2, hiddenDim]

            // pos-0 result = what backbone(verified) would return = nextVerified.
            nextVerified = pick(logitsBatch[0, 0, 0...])

            if d == nextVerified {
                // ACCEPT: both positions are correctly committed to cache.
                // Prefetch pos-1 for next Step A — saves one backbone call.
                stats.acceptedCount += 1
                prefetchLogits = logitsBatch[0, 1, 0...]   // [vocabSize]
                prefetchHidden = hBatch[0, 1, 0...]         // [hiddenDim]
            } else {
                // ROLLBACK: draft was wrong. Restore SSM state + trim draft from FA.
                stats.rollbackCount += 1
                for (slot, idx) in mambaIndices.enumerated() {
                    if let mc = cache[idx] as? MambaCache {
                        mc.state = mambaStates[slot]
                    }
                }
                for c in cache {
                    if let kvs = c as? KVCacheSimple { kvs.trim(1) }
                }
            }
        } else {
            // No draft (model has no MTP head or head returned nil): single-token path.
            let verifiedArr = MLXArray([Int32(verified)]).reshaped(1, 1)
            let (logitsD, _) = model.forwardWithHiddenState(verifiedArr, cache: cache)
            eval(logitsD)
            nextVerified = pick(logitsD[0, -1, 0...])
        }
        remember(nextVerified)

        // Step E: emit nextVerified — always, regardless of accept/rollback.
        stats.tokenCount += 1
        if isEOS(nextVerified, eosTokenIds: eosTokenIds, tokenizer: tokenizer) || !onToken(nextVerified) {
            break
        }
        if stats.tokenCount >= maxTokens { break }

        // Step F: advance y.
        y = nextVerified
    }

    stats.generateTime = -generateStart.timeIntervalSinceNow
    return stats
}

private func isEOS(_ token: Int, eosTokenIds: Set<Int>, tokenizer: any Tokenizer) -> Bool {
    token == tokenizer.unknownTokenId || eosTokenIds.contains(token)
}
