//
//  BatchedLLMScheduler.swift
//  Whisperer
//
//  Turns independent correction requests that happen to be in flight at the same moment into one
//  batched generation, and gets out of the way otherwise.
//
//  The firing policy is the part worth reading, because the obvious one is wrong here. A classic
//  batching scheduler waits a deadline — "hold the first request up to 50 ms in case a second
//  arrives" — and that is exactly what this one must not do. Round 0a measured real chunk arrivals
//  from 58 recordings: median inter-arrival is **6.84 s** and only 18% of gaps are under 2 s,
//  against a correction that takes ~0.7 s. A deadline would add latency to almost every chunk and
//  coalesce almost nothing.
//
//  So: **greedy, next-tick**. A request fires on the next main-actor turn, which costs nothing and
//  still lets a synchronous burst of submissions land in the same batch. Everything that arrives
//  while a batch is generating joins the following one for free, because it was going to wait for
//  the serial `ModelContainer` regardless. That covers the three populations that actually batch —
//  the drain at key release (p90 = 11 chunks outstanding, max 22), the whole-text splitter, and
//  meeting segments — and leaves the sparse mid-stream case at its current latency instead of
//  making it worse.
//
//  A batch of one is handed to `single` rather than to `batch`: at B=1 the single-stream MTP path
//  is about 1.5× faster than batched greedy, so the lone-chunk case must keep it.
//

import Foundation

/// Coalesces `submit` calls into batched generations. `@MainActor` because everything it
/// coordinates — `LLMPostProcessor`, `ChunkLLMCoordinator`, `AppState` — already lives there, and
/// the queue is touched once per chunk, not once per token.
@MainActor
final class BatchedLLMScheduler {

    /// Runs one request on the single-stream path. Used whenever a batch would have width 1.
    typealias SingleRunner = (_ request: LLMBatchRequest, _ instructions: String) async -> String
    /// Runs several requests sharing one system prompt, returning results in the same order.
    typealias BatchRunner = (_ requests: [LLMBatchRequest], _ instructions: String) async -> [String]

    /// Largest batch to hand the runner in one call. The runner clamps further against memory via
    /// `BatchMemoryPlanner`; this is the scheduling bound, so that one pathological drain cannot
    /// hold a hundred rows' worth of continuations open behind a single generation.
    private let maxBatch: Int
    private let single: SingleRunner
    private let batch: BatchRunner

    private struct Pending {
        let request: LLMBatchRequest
        let instructions: String
        let resume: (String) -> Void
    }

    private var queue: [Pending] = []
    /// Non-nil while a flush is scheduled or running. Its existence is what stops every submission
    /// from starting its own drain loop.
    private var flush: Task<Void, Never>?

    /// Widths of the batches actually run, newest last. Kept because "did this ever batch?" is the
    /// first question of any regression here, and the logs alone make it tedious to answer.
    private(set) var recentWidths: [Int] = []

    init(maxBatch: Int = 16, single: @escaping SingleRunner, batch: @escaping BatchRunner) {
        self.maxBatch = max(1, maxBatch)
        self.single = single
        self.batch = batch
    }

    // MARK: - Submitting

    /// Enqueues one correction and suspends until it comes back.
    ///
    /// Never throws and never returns nil: on cancellation or runner failure the caller gets its
    /// own input text back, which is the same contract `LLMPostProcessor.process` has. A caller
    /// that has to branch on failure would push that branch into the injection path, where an
    /// empty string becomes lost dictation.
    func submit(_ request: LLMBatchRequest, instructions: String) async -> String {
        await withCheckedContinuation { continuation in
            var resumed = false
            queue.append(Pending(request: request, instructions: instructions, resume: { text in
                // Belt and braces: `cancelAll` racing a completing flush would otherwise resume
                // twice, which traps.
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: text)
            }))
            scheduleFlush()
        }
    }

    /// Resumes everything still queued with its own input text and forgets it.
    ///
    /// Called when the session is abandoned — `ChunkLLMCoordinator.reset()` on a watchdog
    /// force-idle. A generation already inside the runner is left to finish; stopping it mid-batch
    /// would need a stop flag threaded through the token callback, and it costs at most one batch
    /// of GPU time that nothing is waiting on.
    func cancelAll() {
        let abandoned = queue
        queue.removeAll()
        for pending in abandoned { pending.resume(pending.request.text) }
        if !abandoned.isEmpty {
            Logger.debug("batch scheduler: cancelled \(abandoned.count) queued request(s)",
                         subsystem: .transcription)
        }
    }

    /// Queued but not yet running. Exposed for tests and for the drain path, which wants to know
    /// whether waiting is worth anything.
    var queueDepth: Int { queue.count }

    // MARK: - Flushing

    private func scheduleFlush() {
        guard flush == nil else { return }
        flush = Task { [weak self] in
            // One hop, deliberately. It hands the main actor back so a caller submitting several
            // chunks in a row — the drain at key release does exactly this — gets them all into
            // the same batch, without imposing a wall-clock deadline on the lone-chunk case.
            await Task.yield()
            await self?.drainQueue()
            self?.flush = nil
            // A submission that landed between the last take and clearing `flush` would otherwise
            // sit in the queue with nobody scheduled to run it.
            if let self, !self.queue.isEmpty { self.scheduleFlush() }
        }
    }

    private func drainQueue() async {
        while !queue.isEmpty {
            // Group on the system prompt: it is the warm-cache key, and rows in one batch must
            // share it. Taking the *first* request's prompt keeps the queue in arrival order, so a
            // minority prompt cannot be starved by a steady stream of the majority one.
            let instructions = queue[0].instructions
            var taken: [Pending] = []
            var rest: [Pending] = []
            for pending in queue {
                if pending.instructions == instructions, taken.count < maxBatch {
                    taken.append(pending)
                } else {
                    rest.append(pending)
                }
            }
            queue = rest
            guard !taken.isEmpty else { return }

            recentWidths.append(taken.count)
            if recentWidths.count > 32 { recentWidths.removeFirst() }

            let results: [String]
            if taken.count == 1 {
                results = [await single(taken[0].request, instructions)]
            } else {
                results = await batch(taken.map(\.request), instructions)
            }

            // A runner that returned the wrong number of results would otherwise strand
            // continuations forever, hanging the drain and with it the injection.
            if results.count != taken.count {
                Logger.warning(
                    "batch scheduler: runner returned \(results.count) results for "
                    + "\(taken.count) requests — falling back to inputs",
                    subsystem: .transcription)
                for pending in taken { pending.resume(pending.request.text) }
                continue
            }
            for (pending, result) in zip(taken, results) { pending.resume(result) }
        }
    }
}

extension BatchedLLMScheduler {
    /// The production wiring: single-stream through `process`, batched through `processBatch`,
    /// both on the same `LLMPostProcessor` so they share one loaded model and one warm prefix.
    static func forProcessor(
        _ processor: LLMPostProcessor,
        maxBatch: Int = 16,
        repetitionPenalty: Float = 1.05
    ) -> BatchedLLMScheduler {
        BatchedLLMScheduler(
            maxBatch: maxBatch,
            single: { [weak processor] request, instructions in
                guard let processor else { return request.text }
                // `outputTokensHint` passes the batch path's own estimate through, so a request
                // corrected alone gets the same budget it would have had inside a batch.
                return (try? await processor.process(
                    text: request.text,
                    systemPrompt: instructions,
                    userMessage: request.userMessage,
                    repetitionPenalty: repetitionPenalty,
                    outputTokensHint: request.maxTokens)) ?? request.text
            },
            batch: { [weak processor] requests, instructions in
                guard let processor else { return requests.map(\.text) }
                return await processor.processBatch(
                    requests: requests,
                    instructions: instructions,
                    repetitionPenalty: repetitionPenalty)
            })
    }
}
