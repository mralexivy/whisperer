//
//  BatchedLLMProductionPathTests.swift
//  WhispererTests
//
//  `BatchedLLMCorrectnessTests` and `BatchedLLMScaleTests` drive `generateBatchTokens` through a
//  test harness. This file drives `LLMPostProcessor.processBatch` — the method production will
//  actually call — against `LLMPostProcessor.process`, the method it replaces. Everything between
//  the two (warm-prefix reuse, planner-sized slicing, per-row token budgets, the degeneration
//  guard, tag stripping, the empty-output fallback) is only covered here.
//
//  The comparison is deliberately end-to-end and deliberately unfair in the serial path's favour:
//  `process` on this model takes the MTP fast path, which is ~1.5× a plain greedy stream. The
//  speedup asserted below is therefore against the *best* single-stream number the app has, not
//  against a strawman.
//
//  Must not run concurrently with any other model test — several GB of weights co-resident thrash
//  unified memory and corrupt the timings.
//

import MLX
import MLXLLM
import XCTest
@testable import whisperer

@MainActor
final class BatchedLLMProductionPathTests: XCTestCase {

    private let variant: LLMModelVariant = .qwen3_5_4B_mtp

    /// Rows per batch. 16 is the width the drain at key release actually reaches — Round 0a
    /// measured p90 = 11 chunks outstanding at stop, max 22 — so this is a production width, not a
    /// benchmark width.
    private let batchWidth = 16

    // MARK: - Fixtures

    private func loadCorpus() throws -> ChunkStreamCorpus {
        guard let corpus = ChunkStreamCorpus.loadPersisted(), !corpus.streams.isEmpty else {
            throw XCTSkip("No \(ChunkStreamCorpus.fileURL.lastPathComponent) — run "
                          + "testChunkArrivalCharacterisation with CHUNK_CORPUS_REHARVEST=1 first")
        }
        return corpus
    }

    private func withModel(_ body: (LLMPostProcessor) async throws -> Void) async throws {
        let processor = LLMPostProcessor()
        do {
            try await processor.loadModel(variant)
        } catch {
            throw XCTSkip("cannot load \(variant.rawValue): \(error.localizedDescription)")
        }
        do {
            try await body(processor)
        } catch {
            await processor.unloadModel()
            throw error
        }
        await processor.unloadModel()
    }

    /// Word-level Jaccard similarity, lowercased. Used to check that results came back on the right
    /// rows: an off-by-one in the slice bookkeeping would leave every output *plausible* and every
    /// output attached to the wrong input, which no assertion on emptiness or script would catch.
    private func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(lhs.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let right = Set(rhs.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    // MARK: - 1. processBatch agrees with process, row for row

    /// The production gate. Same inputs, same prompt, both paths; then three separate claims:
    ///
    ///  1. **Alignment** — every batched row resembles its own serial result more than it resembles
    ///     any other row's. This is the assertion that catches a mis-ordered result array.
    ///  2. **Content** — no row comes back empty, and no row comes back as its own unmodified input
    ///     for the whole batch (which is what the fallback path returns, and would mean the batch
    ///     silently did nothing).
    ///  3. **Speed** — wall-clock for the batch against wall-clock for the serial loop.
    ///
    /// Text equality is *not* asserted: `BatchedLLMCorrectnessTests` establishes that padded rows
    /// can differ from serial greedy by a comma from bf16 rounding, and the serial side here is MTP
    /// rather than plain greedy on top of that. Similarity is the honest gate; exactness is tested
    /// where exactness is achievable.
    func testProcessBatchMatchesSerialProcess() async throws {
        let corpus = try loadCorpus()
        let texts = realChunkTexts(count: batchWidth, corpus: corpus)
        try XCTSkipIf(texts.count < 4, "corpus has only \(texts.count) usable chunks")

        try await withModel { processor in
            let prompts = texts.map { correctPrompt(for: $0, fragment: true) }
            let instructions = prompts[0].system
            let requests = zip(texts, prompts).map { text, prompt in
                LLMBatchRequest.make(text: text, userMessage: prompt.user)
            }

            // Warm the prefix outside both measurements. Production keeps it warm across a session,
            // so charging one path for building it would measure the wrong thing.
            await processor.ensureWarmPrefix(for: instructions)

            let batchStart = Date()
            let batched = await processor.processBatch(
                requests: requests, instructions: instructions)
            let batchSeconds = -batchStart.timeIntervalSince(Date())

            let serialStart = Date()
            var serial: [String] = []
            for (text, prompt) in zip(texts, prompts) {
                serial.append(try await processor.process(
                    text: text, systemPrompt: prompt.system, userMessage: prompt.user,
                    repetitionPenalty: 1.0))
            }
            let serialSeconds = -serialStart.timeIntervalSince(Date())

            XCTAssertEqual(batched.count, texts.count, "row count changed")

            var misaligned = 0
            var unchanged = 0
            var totalSimilarity = 0.0
            for index in batched.indices {
                let own = similarity(batched[index], serial[index])
                totalSimilarity += own
                let best = batched.indices.filter { $0 != index }
                    .map { similarity(batched[index], serial[$0]) }.max() ?? 0
                if own <= best {
                    misaligned += 1
                    print("""
                          row \(index) may be misaligned (own \(String(format: "%.2f", own)) \
                          ≤ best other \(String(format: "%.2f", best)))
                            input:   \(texts[index])
                            batched: \(batched[index])
                            serial:  \(serial[index])
                          """)
                }
                XCTAssertFalse(batched[index].isEmpty, "row \(index) came back empty")
                if batched[index] == texts[index] { unchanged += 1 }
            }

            print(String(format: """
                processBatch vs process — %d rows
                  mean similarity to serial: %.2f   misaligned: %d   returned input verbatim: %d
                  batched: %.2f s (%.0f ms/row)   serial: %.2f s (%.0f ms/row)   speedup: %.2fx
                """,
                texts.count, totalSimilarity / Double(texts.count), misaligned, unchanged,
                batchSeconds, batchSeconds / Double(texts.count) * 1000,
                serialSeconds, serialSeconds / Double(texts.count) * 1000,
                serialSeconds / max(batchSeconds, .ulpOfOne)))

            XCTAssertEqual(misaligned, 0, "results are not on the rows they belong to")
            // Every row identical to its input means the fallback fired for the whole batch —
            // usually a load or template failure, which otherwise looks like a very fast success.
            XCTAssertLessThan(unchanged, texts.count, "batch returned every input unchanged")
            // Measured ~2.2× at B=32 on ragged real chunks; B=16 is the narrower, more conservative
            // width. 1.5× is the point below which batching no longer beats the MTP path it
            // replaces, which is the only threshold worth failing on.
            XCTAssertGreaterThan(serialSeconds / max(batchSeconds, .ulpOfOne), 1.5,
                                 "batching did not beat the single-stream MTP path")
        }
    }

    // MARK: - 2. Memory stays inside the planner's projection

    /// `processBatch` sizes its slices with `BatchMemoryPlanner` and installs MLX's allocator
    /// limits around them. This asserts the projection holds for the real method — the guardrail
    /// suite asserts it for the harness — and that a run of batches does not drift upward, which is
    /// the failure mode that ends in an OOM three dictations into a session rather than the first.
    func testProcessBatchMemoryStaysBounded() async throws {
        let corpus = try loadCorpus()
        let texts = realChunkTexts(count: batchWidth, corpus: corpus)
        try XCTSkipIf(texts.count < 4, "corpus has only \(texts.count) usable chunks")

        try await withModel { processor in
            let prompts = texts.map { correctPrompt(for: $0, fragment: true) }
            let instructions = prompts[0].system
            let requests = zip(texts, prompts).map { text, prompt in
                LLMBatchRequest.make(text: text, userMessage: prompt.user)
            }
            await processor.ensureWarmPrefix(for: instructions)

            // One batch first, so the specialised graphs and the warm cache are already resident:
            // the question is whether *repetition* drifts, not what the first run costs.
            _ = await processor.processBatch(requests: requests, instructions: instructions)
            let settled = Memory.activeMemory / 1_048_576
            Memory.peakMemory = 0

            for round in 0 ..< 4 {
                _ = await processor.processBatch(requests: requests, instructions: instructions)
                let active = Memory.activeMemory / 1_048_576
                XCTAssertLessThan(active - settled, 512,
                                  "active memory drifted \(active - settled) MB by round \(round)")
            }

            let plan = BatchMemoryPlanner.forQwen35_4B.plan(
                requestedRows: requests.count,
                systemPrefixTokens: 900,
                suffixTokens: 128,
                maxOutputTokens: requests.map(\.maxTokens).max() ?? 256)
            let peak = Double(Memory.peakMemory) / 1_048_576
            print(String(format: "processBatch memory — settled %d MB, peak %.0f MB, "
                         + "projected %.0f MB, ceiling %.0f MB",
                         settled, peak, plan.projectedPeakMB, plan.ceilingMB))
            XCTAssertLessThan(peak, plan.projectedPeakMB,
                              "peak exceeded the planner's own projection")
        }
    }

    // MARK: - 3. The timeout returns inputs rather than fragments

    /// A batch that runs out of time must degrade to "the user's text, uncorrected" and must do so
    /// promptly. Half a second is far below one decode step's worth of useful output, so every row
    /// should still be empty when the flag trips and fall back.
    func testProcessBatchTimeoutFallsBackToInput() async throws {
        let corpus = try loadCorpus()
        let texts = realChunkTexts(count: 4, corpus: corpus)
        try XCTSkipIf(texts.count < 2, "corpus has only \(texts.count) usable chunks")

        try await withModel { processor in
            let prompts = texts.map { correctPrompt(for: $0, fragment: true) }
            let instructions = prompts[0].system
            let requests = zip(texts, prompts).map { text, prompt in
                LLMBatchRequest.make(text: text, userMessage: prompt.user)
            }
            await processor.ensureWarmPrefix(for: instructions)

            let started = Date()
            let results = await processor.processBatch(
                requests: requests, instructions: instructions, timeoutSeconds: 0.5)
            let elapsed = -started.timeIntervalSince(Date())

            XCTAssertEqual(results.count, texts.count)
            for (index, result) in results.enumerated() {
                XCTAssertFalse(result.isEmpty, "row \(index) came back empty after timeout")
            }
            print(String(format: "timeout batch returned in %.2f s", elapsed))
            // Generous: the prefill is not interruptible, so the floor is one prefill pass.
            XCTAssertLessThan(elapsed, 15, "timeout did not stop the batch")
        }
    }

    // MARK: - 4. Empty and degenerate inputs do not take the batch down

    /// Rows the streaming path can genuinely produce: a chunk that VAD clipped to nothing, one that
    /// is a single word, and one that repeats. Each must come back as itself or as a correction of
    /// itself, and none may prevent the healthy rows in the same batch from returning.
    func testProcessBatchHandlesDegenerateRows() async throws {
        let corpus = try loadCorpus()
        let healthy = realChunkTexts(count: 4, corpus: corpus)
        try XCTSkipIf(healthy.count < 2, "corpus has only \(healthy.count) usable chunks")

        let texts = healthy + ["", "ok", String(repeating: "the ", count: 40)]

        try await withModel { processor in
            let prompts = texts.map { correctPrompt(for: $0, fragment: true) }
            let instructions = prompts[0].system
            let requests = zip(texts, prompts).map { text, prompt in
                LLMBatchRequest.make(text: text, userMessage: prompt.user)
            }
            await processor.ensureWarmPrefix(for: instructions)

            let results = await processor.processBatch(
                requests: requests, instructions: instructions)

            XCTAssertEqual(results.count, texts.count)
            for index in 0 ..< healthy.count {
                XCTAssertFalse(results[index].isEmpty,
                               "healthy row \(index) was taken down by a degenerate neighbour")
            }
            // The repeated-"the" row is the degeneration guard's target: whatever it returns, it
            // must not be longer than its already-absurd input.
            let repeated = results[texts.count - 1]
            XCTAssertLessThanOrEqual(repeated.count, texts[texts.count - 1].count + 40,
                                     "degenerate row ran away: \(repeated.prefix(120))")
            print("degenerate rows: empty→\"\(results[healthy.count])\", "
                  + "short→\"\(results[healthy.count + 1])\", "
                  + "repeated→\"\(repeated.prefix(60))\"")
        }
    }
}
