//
//  LLMPostProcessor+Batch.swift
//  Whisperer
//
//  Correcting many texts in one forward pass instead of one at a time.
//
//  Decode at batch 1 is memory-bandwidth bound: a forward pass streams all 2.34 GB of the 4-bit
//  weights whether it decodes one token or thirty-two. Putting more sequences on the batch axis is
//  therefore close to free per step, and total throughput multiplies. Measured on real chunk text
//  with the real `Correct` prompt (M2 Pro / 32 GB): 26.6 tok/s end to end at B=1 against 59.5 at
//  B=32, a 2.23× reduction in wall-clock for the same work.
//
//  What it does *not* do — and this gets re-litigated every time somebody benchmarks a
//  one-sentence dictation — is make any single text faster. Per-row throughput falls monotonically
//  with batch width. Batching is worth having exactly where several texts are ready at once:
//  the drain at key release, the whole-text splitter, and meeting segments.
//
//  Everything here mirrors `processMTP`'s contract — same EOS set, same degeneration guard, same
//  char limit, same tag stripping, same fall-back-to-original on empty output — because the batched
//  and single-stream paths must be interchangeable from the caller's point of view. Greedy decode
//  at temperature 0 makes them byte-identical on unpadded rows; padded rows can differ by a comma
//  or an article from bf16 rounding, which `BatchedLLMCorrectnessTests` measures and bounds.
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// One text to correct inside a batch. Everything that varies per row; the system prompt and the
/// sampling parameters are shared by the whole batch and live on the call.
struct LLMBatchRequest {
    /// The pre-cleaned source text. Returned unchanged if the row produces nothing usable.
    let text: String
    /// The `[INPUT]`-wrapped user message, exactly as the single-stream path builds it.
    let userMessage: String
    /// Output cap for this row. Rows are independent, so a short row is not held to a long row's
    /// budget — it simply retires early and stops costing anything after the next compaction.
    let maxTokens: Int
    /// Character limit for the runaway guard, or nil to leave it off (translation and non-Latin
    /// output, where character counts across scripts are not comparable).
    let outputCharLimit: Int?

    /// Sizes a row exactly as `LLMPostProcessor.process` sizes a single-stream call.
    ///
    /// The arithmetic is duplicated rather than shared because `process` computes it inline, but it
    /// must stay the same arithmetic: a batched row given a different token budget than the serial
    /// path would produce different output for the same input, and the correctness tests assert
    /// that it does not. If `process`'s estimator changes, change this with it.
    static func make(
        text: String,
        userMessage: String,
        targetLanguage: String? = nil,
        maxTokensCap: Int = 256,
        outputTokensHint: Int? = nil
    ) -> LLMBatchRequest {
        let charCount = text.count
        let isNonLatin = LLMPostProcessor.containsNonLatinScript(text)
        let estimatedTokens = max(4, charCount / (isNonLatin ? 2 : 4))
        let maxTokens: Int
        if let hint = outputTokensHint {
            maxTokens = min(maxTokensCap, hint)
        } else if charCount < 30 {
            maxTokens = min(maxTokensCap, estimatedTokens + 8)
        } else if charCount < 200 {
            maxTokens = min(maxTokensCap, Int(ceil(Float(estimatedTokens) * 1.15)) + 4)
        } else {
            maxTokens = min(maxTokensCap, Int(ceil(Float(estimatedTokens) * 1.15)))
        }
        let charLimit: Int? = (maxTokensCap <= 256 && targetLanguage == nil && !isNonLatin)
            ? Int(Float(charCount) * 1.5) + 20
            : nil
        return LLMBatchRequest(
            text: text, userMessage: userMessage, maxTokens: maxTokens, outputCharLimit: charLimit)
    }
}

extension LLMPostProcessor {

    /// Whole-batch time budget for `rowCount` rows.
    ///
    /// A fixed 30 s was the original default and it was wrong: rows beyond what fits in the
    /// planner's slice run *after* the earlier ones, so a 100-row batch is several sequential
    /// generations sharing one deadline. Measured on real long transcripts, an 87-row batch took
    /// 45 s and a 72-row batch 31 s — both tripped the deadline, and every row still live at that
    /// moment kept a half-finished sentence. That surfaced as the segmented whole-text path
    /// returning 53–74% of the user's words, which looks like a batching correctness bug and is
    /// not one.
    ///
    /// 1.5 s/row is ~3.5× the measured 0.4 s/row, so the deadline stays what it is meant to be —
    /// a backstop against a wedged generation — rather than a cap on normal work. The 30 s floor
    /// keeps small batches at the behaviour that is already measured.
    nonisolated static func defaultTimeout(rowCount: Int) -> Double {
        max(30, 1.5 * Double(rowCount))
    }

    /// Corrects every request in one batched generation, returning results in the caller's order.
    ///
    /// Rows are split into slices no wider than `BatchMemoryPlanner` allows and the slices run one
    /// after another. The planner is not advisory: an unbounded batch on this model measured a
    /// 19.5 GB peak on a 32 GB machine and took the desktop down with it.
    ///
    /// - Parameters:
    ///   - requests: rows to correct. An empty array returns empty; a single request still goes
    ///     through this path, which is correct but slower than `process` — the scheduler is what
    ///     routes lone requests back to the MTP fast path.
    ///   - instructions: the shared system prompt. Rows in one batch **must** share it: it is the
    ///     warm-cache key, and mixing prompts would mean broadcasting the wrong prefix.
    ///   - repetitionPenalty: applied per row. Above 1.0 it forces a CPU readback per row per step
    ///     and costs most of the batching win, so callers that do not need it should leave it at 1.
    ///   - timeoutSeconds: whole-batch budget. On expiry every live row stops where it is and
    ///     keeps what it produced, matching the single-stream path's behaviour on timeout.
    ///     `nil` derives it from the row count — see `defaultTimeout(rowCount:)`, which exists
    ///     because a fixed budget silently truncated the largest batches.
    func processBatch(
        requests: [LLMBatchRequest],
        instructions: String,
        repetitionPenalty: Float = 1.0,
        timeoutSeconds: Double? = nil
    ) async -> [String] {
        guard !requests.isEmpty else { return [] }
        let timeoutSeconds = timeoutSeconds ?? Self.defaultTimeout(rowCount: requests.count)

        guard let container = modelContainer, !instructions.isEmpty else {
            return requests.map(\.text)
        }

        // Build the warm prefix first if it is missing. Doing it here, before the batch, means one
        // ~880-token prefill for the whole batch instead of one per row.
        if warmPrefixCopy(for: instructions) == nil {
            await ensureWarmPrefix(for: instructions)
        }
        let warm = warmPrefixCopy(for: instructions)

        isProcessing = true
        defer { isProcessing = false }

        let output = BatchOutputBox(rowCount: requests.count)
        for (index, request) in requests.enumerated() { output.texts[index] = request.text }

        let deadline = Task { [output] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            if !output.stop {
                Logger.warning(
                    "batch gen: timeout after \(Int(timeoutSeconds))s, stopping",
                    subsystem: .transcription)
                output.stop = true
            }
        }
        defer { deadline.cancel() }

        let planner = BatchMemoryPlanner.forQwen35_4B
        let started = Date()

        try? await container.perform { [output] context in
            let tokenizer = context.tokenizer
            guard let model = context.model as? any LLMModel else {
                Logger.warning("batch gen: model is not an LLMModel, falling back",
                               subsystem: .transcription)
                return
            }

            // Same EOS assembly as `processMTP`, including the by-name safety net. A batch that
            // missed `<|im_end|>` would run every row to `maxTokens` — not wrong output, but many
            // times the cost, and invisible without checking.
            var eosIds = context.configuration.eosTokenIds
            if let eos = tokenizer.eosTokenId { eosIds.insert(eos) }
            for token in context.configuration.extraEOSTokens {
                if let id = tokenizer.convertTokenToId(token) { eosIds.insert(id) }
            }
            for name in ["<|im_end|>", "<|endoftext|>"] {
                if let id = tokenizer.convertTokenToId(name) { eosIds.insert(id) }
            }

            let full: [[Int]]
            do {
                full = try requests.map { request in
                    try tokenizer.applyChatTemplate(
                        messages: [["role": "system", "content": instructions],
                                   ["role": "user", "content": request.userMessage]],
                        tools: nil, additionalContext: ["enable_thinking": false])
                }
            } catch {
                Logger.warning("batch gen: chat template failed: \(error)",
                               subsystem: .transcription)
                return
            }

            // The warm prefix is only usable if every row actually starts with it. A row shorter
            // than the prefix would mean the template changed under us; prefill everything rather
            // than broadcast a prefix that is not there.
            let prefixLength = warm.map(\.prefixLength) ?? 0
            let usableWarm = warm.map(\.cache).flatMap { cache in
                full.allSatisfy { $0.count > prefixLength } ? cache : nil
            }
            let suffixes = usableWarm == nil ? full : full.map { Array($0[prefixLength...]) }

            let plan = planner.plan(
                requestedRows: requests.count,
                systemPrefixTokens: usableWarm == nil ? 0 : prefixLength,
                suffixTokens: suffixes.map(\.count).max() ?? 1,
                maxOutputTokens: requests.map(\.maxTokens).max() ?? 0)
            if let reason = plan.clampReason {
                Logger.warning("batch gen: \(reason)", subsystem: .transcription)
            }
            let restoreLimits = BatchMemoryPlanner.installLimits(for: plan)
            defer { restoreLimits() }

            var aggregate = BatchStats()
            for sliceStart in stride(from: 0, to: requests.count, by: plan.rows) {
                if output.stop { break }
                let slice = Array(sliceStart ..< min(sliceStart + plan.rows, requests.count))

                let makeCache: (Int) -> [any KVCache] = usableWarm.map { cache in
                    { rows in broadcastWarmCache(cache, to: rows) }
                } ?? { _ in model.newCache(parameters: nil) }

                var pieces = [String](repeating: "", count: slice.count)
                var charCounts = [Int](repeating: 0, count: slice.count)
                // Per-row token budgets, enforced here rather than by `generateBatchTokens`, whose
                // `maxTokens` is one number for the whole batch. Without this a short row would
                // inherit the longest row's budget and could keep generating past where the serial
                // path would have cut it off — a difference in output, not just in cost.
                var emitted = [Int](repeating: 0, count: slice.count)
                // Per row, exactly as the single-stream path has it. Without it a looping row runs
                // to `maxTokens` and drags the whole batch's last steps out with it.
                var guards = slice.map { _ in DegenerationGuard<Int>() }

                let stats = generateBatchTokens(
                    model: model,
                    tokenizer: tokenizer,
                    makeCache: makeCache,
                    promptSuffixes: slice.map { suffixes[$0] },
                    // The widest row's budget: rows retire individually on their own limit below,
                    // so this only bounds how long the batch as a whole may run.
                    maxTokens: slice.map { requests[$0].maxTokens }.max() ?? 0,
                    eosTokenIds: eosIds,
                    repetitionPenalty: repetitionPenalty,
                    onToken: { row, tokenId in
                        if output.stop { return false }
                        let request = requests[slice[row]]
                        let piece = tokenizer.decode(tokens: [tokenId])
                        let before = charCounts[row]
                        emitted[row] += 1
                        pieces[row] += piece
                        charCounts[row] += piece.count
                        if let rewind = guards[row].record(tokenId, lengthBefore: before) {
                            pieces[row] = String(pieces[row].prefix(rewind))
                            charCounts[row] = rewind
                            Logger.warning(
                                "batch gen: degeneration guard on row \(slice[row]) — output "
                                + "looped, trimmed back to \(rewind) chars and stopped",
                                subsystem: .transcription)
                            return false
                        }
                        if let limit = request.outputCharLimit, charCounts[row] > limit {
                            return false
                        }
                        return emitted[row] < request.maxTokens
                    })

                for (row, requestIndex) in slice.enumerated() {
                    output.texts[requestIndex] = Self.cleanBatchOutput(
                        pieces[row], fallback: requests[requestIndex].text)
                }
                aggregate.merge(stats)
            }
            output.stats = aggregate
        }

        output.stop = true
        if Memory.cacheMemory > Memory.cacheLimit { Memory.clearCache() }

        if let stats = output.stats, stats.rowCount > 0 {
            let wall = stats.prefillTime + stats.generateTime
            Logger.debug(
                "batch gen: rows=\(stats.rowCount) tokens=\(stats.tokenCount) "
                + "steps=\(stats.steps) avgWidth=\(String(format: "%.1f", stats.averageWidth)) "
                + "prefill=\(Int(stats.prefillTime * 1000))ms gen=\(Int(stats.generateTime * 1000))ms "
                + "aggregate=\(String(format: "%.0f", wall > 0 ? Double(stats.tokenCount) / wall : 0)) tok/s "
                + "wall=\(Int(-started.timeIntervalSinceNow * 1000))ms",
                subsystem: .transcription)
        }
        return output.texts
    }

    /// The same trimming `processMTP` applies to a single result: drop chain-of-thought, drop any
    /// structural tag the model echoed, and fall back to the source text when nothing usable is
    /// left. A row that produced nothing must return its input, not an empty string — an empty
    /// string would silently delete a chunk of the user's dictation.
    /// `nonisolated` because it is called from inside the `@Sendable` container closure, which is
    /// off the main actor. It touches nothing but its arguments.
    private nonisolated static func cleanBatchOutput(_ raw: String, fallback: String) -> String {
        var result = raw
        if let thinkRange = result.range(of: "<think>[\\s\\S]*?</think>", options: .regularExpression) {
            result.removeSubrange(thinkRange)
        }
        for tag in ["[INPUT]", "[/INPUT]", "[/INPUT"] {
            result = result.replacingOccurrences(of: tag, with: "")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? fallback : result
    }
}

/// Collects per-row output from inside the `@Sendable` container closure.
///
/// `@unchecked Sendable` for the same reason `MTPOutput` is: the closure runs on one thread at a
/// time under `ModelContainer`'s own serialisation, and the only cross-thread field is `stop`,
/// which is a one-way flag written by the timeout task and read in the token callback.
private final class BatchOutputBox: @unchecked Sendable {
    var texts: [String]
    var stats: BatchStats?
    var stop = false

    init(rowCount: Int) {
        self.texts = [String](repeating: "", count: rowCount)
    }
}

extension BatchStats {
    /// Accumulates a slice's stats into a running total across the slices of one logical batch.
    /// Times add; `rowCount` adds; `steps` add, because slices run one after another.
    fileprivate mutating func merge(_ other: BatchStats) {
        rowCount += other.rowCount
        tokenCount += other.tokenCount
        steps += other.steps
        promptTokenCount += other.promptTokenCount
        padTokenCount += other.padTokenCount
        compactions += other.compactions
        prefillTime += other.prefillTime
        generateTime += other.generateTime
    }
}
