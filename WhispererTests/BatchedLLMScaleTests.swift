//
//  BatchedLLMScaleTests.swift
//  WhispererTests
//
//  How wide the batch can usefully go, now that `BatchMemoryPlanner` decides the width instead of
//  a constant, and how repeatable the resulting throughput is.
//
//  Two questions, kept apart on purpose:
//
//  1. **Where does aggregate throughput stop improving?** The raw-kernel curve says the hardware
//     can reach ~257 tok/s at B=64 — but that probe used a 16-token prompt and fresh caches, so it
//     is an upper bound on the kernel, not a prediction for the real path. This measures the real
//     path, with the real prompt, at the widths the planner actually permits.
//  2. **Is the number reliable?** A single best-of-two reading is a claim, not a measurement. The
//     reliability test repeats a fixed configuration and reports median, p10 and p90, so the
//     headline can be quoted with a spread instead of a shrug.
//
//  Both print their conditions. Rounds 1–3 of this work were taken on a machine that turned out to
//  be busy and had to be thrown away; a table that does not carry its load average cannot be
//  compared against the next one.
//
//  Must not run concurrently with any other model test.
//

import Darwin
import MLX
import MLXLLM
import XCTest
@testable import whisperer

@MainActor
final class BatchedLLMScaleTests: XCTestCase {

    private let variant: LLMModelVariant = .qwen3_5_4B_mtp
    private let planner = BatchMemoryPlanner.forQwen35_4B

    // MARK: - 1. Where widening stops paying

    /// Aggregate throughput against batch width, with the planner clamping and grouping.
    ///
    /// The requested widths deliberately run past what the planner will grant: the point at which
    /// it starts clamping is itself a result — it is the memory ceiling expressed in rows — and a
    /// sweep that stopped just below it would never show where that is.
    func testWideBatchCeiling() async throws {
        let corpus = try loadCorpus()
        let pool = realChunkTexts(count: 96, corpus: corpus)
        try XCTSkipIf(pool.count < 32, "corpus has only \(pool.count) usable chunks")

        try await withModel { processor in
            var lines = ["\n=== Aggregate throughput vs batch width (planner-governed) ==="]
            lines.append(machineConditions())
            lines.append("   ask  granted  group   steps   ms/step   decode_tok/s   prefill_ms"
                         + "   e2e_tok/s   speedup   pad%   util%   peak_MB   proj_MB")

            var baseline: Double = 0
            var best: (width: Int, decode: Double) = (1, 0)

            for requested in [1, 8, 16, 24, 32, 48, 64, 96] {
                let texts = (0 ..< requested).map { pool[$0 % pool.count] }
                let group = rows(for: texts)
                let shape = try await measurePromptShape(processor, rows: group)
                let plan = planner.plan(
                    requestedRows: requested, systemPrefixTokens: shape.systemPrefixTokens,
                    suffixTokens: shape.maxSuffixTokens, maxOutputTokens: 192)
                let granted = Array(group.prefix(plan.rows))

                // Warm-up at this shape, outside the measurement: the first run of a width
                // compiles and specialises Metal kernels, and that would be most of the reading.
                _ = try? await runBatchedGeneration(
                    processor, rows: granted, maxTokens: 8, warmPrefix: true,
                    prefillPositionBudget: plan.prefillPositionBudget)

                Memory.clearCache()
                Memory.peakMemory = 0
                var fastest: BatchStats?
                for _ in 0 ..< 2 {
                    let run = try await runBatchedGeneration(
                        processor, rows: granted, maxTokens: 192, warmPrefix: true,
                        prefillPositionBudget: plan.prefillPositionBudget)
                    if fastest == nil || run.stats.tokensPerSecond > fastest!.tokensPerSecond {
                        fastest = run.stats
                    }
                }
                guard let stats = fastest else { continue }

                // End-to-end is the honest figure for a user: prefill is work the app must do
                // before a single token appears, and it does not batch as well as decode does.
                let wall = stats.prefillTime + stats.generateTime
                let endToEnd = wall > 0 ? Double(stats.tokenCount) / wall : 0
                if requested == 1 { baseline = endToEnd }
                if stats.tokensPerSecond > best.decode {
                    best = (plan.rows, stats.tokensPerSecond)
                }
                let peak = Double(Memory.peakMemory) / 1_048_576

                // Two efficiency terms, because the first sweep produced a curve that peaked and
                // fell without saying why. `pad%` is prefill work spent on padding slots — pure
                // waste, and it grows with how ragged the rows are. `util%` is decode slots that
                // carried a live row; the gap is stragglers holding a mostly-finished batch open.
                let padFraction = Double(stats.padTokenCount)
                    / Double(max(stats.padTokenCount + stats.promptTokenCount, 1))
                let utilisation = Double(stats.tokenCount)
                    / Double(max(stats.steps * plan.rows, 1))

                lines.append(String(
                    format: "%6d  %7d  %5d  %6d  %8.1f  %13.1f  %11.0f  %10.1f  %7.2fx  %4.0f%%"
                    + "  %5.0f%%  %8.0f  %8.0f",
                    requested, plan.rows, plan.prefillGroupRows, stats.steps,
                    stats.generateTime * 1000 / Double(max(stats.steps, 1)),
                    stats.tokensPerSecond, stats.prefillTime * 1000, endToEnd,
                    baseline > 0 ? endToEnd / baseline : 0, padFraction * 100, utilisation * 100,
                    peak, plan.projectedPeakMB))
                if let reason = plan.clampReason { lines.append("         ↳ \(reason)") }

                XCTAssertLessThanOrEqual(
                    peak, plan.projectedPeakMB,
                    "B=\(plan.rows) exceeded its own projection — the guardrail under-counts")
            }

            lines.append(String(format: "best decode throughput: %.0f tok/s at B=%d",
                                best.decode, best.width))
            print(lines.joined(separator: "\n") + "\n")
            XCTAssertGreaterThan(best.decode, 0)
        }
    }

    // MARK: - 2. The two inefficiencies the sweep exposed

    /// Straggler policy: how aggressively finished rows should be compacted out.
    ///
    /// The width sweep showed only ~44% of decode slots carrying a live row at B=32 — the batch
    /// runs 40 steps while the average row needs about 18, so more than half the memory bandwidth
    /// goes to rows that finished. Compaction reclaims that, but it rewrites every cache tensor,
    /// so compacting too eagerly trades one waste for another. The threshold is measured rather
    /// than argued.
    func testStragglerCompactionThreshold() async throws {
        let corpus = try loadCorpus()
        let pool = realChunkTexts(count: 32, corpus: corpus)
        try XCTSkipIf(pool.count < 32, "corpus has only \(pool.count) usable chunks")

        try await withModel { processor in
            var lines = ["\n=== Compaction threshold at B=32 ==="]
            lines.append(machineConditions())
            lines.append("  threshold   compactions   avg_width   decode_tok/s   e2e_tok/s")

            let group = rows(for: pool)
            _ = try? await runBatchedGeneration(processor, rows: group, maxTokens: 8,
                                                warmPrefix: true)
            var best: (threshold: Double, endToEnd: Double) = (0.5, 0)
            for threshold in [1.0, 0.5, 0.25, 0.1] {
                let run = try await runBatchedGeneration(
                    processor, rows: group, maxTokens: 192, warmPrefix: true,
                    compactionThreshold: threshold)
                let wall = run.stats.prefillTime + run.stats.generateTime
                let endToEnd = wall > 0 ? Double(run.stats.tokenCount) / wall : 0
                if endToEnd > best.endToEnd { best = (threshold, endToEnd) }
                lines.append(String(format: "%11.2f   %11d   %9.1f   %12.1f   %9.1f",
                                    threshold, run.stats.compactions, run.stats.averageWidth,
                                    run.stats.tokensPerSecond, endToEnd))
            }
            lines.append(String(format: "best e2e %.1f tok/s at threshold %.2f",
                                best.endToEnd, best.threshold))

            // Burst length, measured in the same session so it is comparable. Longer bursts remove
            // CPU readbacks (33 ms per step at B=32 against a 124 ms forward pass) but let a
            // finished row decode up to `syncEvery - 1` tokens nobody keeps, and delay the
            // compaction that would have retired it.
            lines.append("\n   syncEvery   compactions   decode_tok/s   e2e_tok/s")
            for syncEvery in [1, 4, 8, 16] {
                let run = try await runBatchedGeneration(
                    processor, rows: group, maxTokens: 192, warmPrefix: true,
                    compactionThreshold: best.threshold, syncEvery: syncEvery)
                let wall = run.stats.prefillTime + run.stats.generateTime
                lines.append(String(format: "%12d   %11d   %12.1f   %9.1f",
                                    syncEvery, run.stats.compactions, run.stats.tokensPerSecond,
                                    wall > 0 ? Double(run.stats.tokenCount) / wall : 0))
            }
            print(lines.joined(separator: "\n") + "\n")
        }
    }

    /// Length bucketing: does sorting rows by prompt length before batching pay for itself?
    ///
    /// Rows are right-padded to the batch's longest suffix, and the sweep measured 38–41% of all
    /// prefill positions as padding — prefill is compute-bound, so that is 40% of the largest
    /// single cost in the run, spent on tokens that are masked out.
    ///
    /// The fix needs no change to the batched kernel at all: sort by length and cut the sorted
    /// list into batches, and each batch pads only to its own longest row. That is a scheduler
    /// policy, so it is measured here as one — a single wide mixed batch against several
    /// length-homogeneous ones covering exactly the same rows.
    func testLengthBucketingBeatsOneMixedBatch() async throws {
        let corpus = try loadCorpus()
        let pool = realChunkTexts(count: 32, corpus: corpus)
        try XCTSkipIf(pool.count < 32, "corpus has only \(pool.count) usable chunks")

        try await withModel { processor in
            var lines = ["\n=== Length bucketing (32 identical rows either way) ==="]
            lines.append(machineConditions())

            let mixedRows = rows(for: pool)
            _ = try? await runBatchedGeneration(processor, rows: mixedRows, maxTokens: 8,
                                                warmPrefix: true)

            let mixed = try await runBatchedGeneration(
                processor, rows: mixedRows, maxTokens: 192, warmPrefix: true)
            let mixedWall = mixed.stats.prefillTime + mixed.stats.generateTime
            lines.append(String(
                format: "one mixed batch of 32:   prefill %5.0f ms  decode %5.0f ms  "
                + "pad %2.0f%%  total %5.2f s",
                mixed.stats.prefillTime * 1000, mixed.stats.generateTime * 1000,
                padPercent(mixed.stats), mixedWall))

            // Sorted by the length of the text, which is what drives the token count; the batches
            // are the same size so the comparison is bucketing alone, not bucketing plus a
            // narrower batch.
            let sorted = pool.sorted { $0.count < $1.count }
            for bucketSize in [16, 8] {
                var prefill = 0.0, decode = 0.0, pad = 0.0, tokens = 0, promptSlots = 0
                for start in stride(from: 0, to: sorted.count, by: bucketSize) {
                    let slice = Array(sorted[start ..< min(start + bucketSize, sorted.count)])
                    let run = try await runBatchedGeneration(
                        processor, rows: rows(for: slice), maxTokens: 192, warmPrefix: true)
                    prefill += run.stats.prefillTime
                    decode += run.stats.generateTime
                    pad += Double(run.stats.padTokenCount)
                    promptSlots += run.stats.padTokenCount + run.stats.promptTokenCount
                    tokens += run.stats.tokenCount
                }
                lines.append(String(
                    format: "%2d sorted buckets of %2d: prefill %5.0f ms  decode %5.0f ms  "
                    + "pad %2.0f%%  total %5.2f s  (%+.0f%% vs mixed)",
                    sorted.count / bucketSize, bucketSize, prefill * 1000, decode * 1000,
                    pad / Double(max(promptSlots, 1)) * 100, prefill + decode,
                    (mixedWall / (prefill + decode) - 1) * 100))
            }
            print(lines.joined(separator: "\n") + "\n")
        }
    }

    private func padPercent(_ stats: BatchStats) -> Double {
        Double(stats.padTokenCount)
            / Double(max(stats.padTokenCount + stats.promptTokenCount, 1)) * 100
    }

    // MARK: - 3. Is the number repeatable

    /// Five runs at one width, reported as median / p10 / p90.
    ///
    /// A speedup claim that rests on a single reading is worth nothing on a machine that also runs
    /// an editor and an indexer. The spread is asserted rather than merely printed: if the p10 and
    /// p90 straddle the median by more than a third, the configuration is not something to wire a
    /// production path to, however good the median looks.
    func testThroughputReliability() async throws {
        let corpus = try loadCorpus()
        let pool = realChunkTexts(count: 64, corpus: corpus)
        try XCTSkipIf(pool.count < 32, "corpus has only \(pool.count) usable chunks")

        try await withModel { processor in
            var lines = ["\n=== Repeatability (5 runs per width) ==="]
            lines.append(machineConditions())
            lines.append("   B   runs   median_tok/s   p10   p90   spread   median_e2e_tok/s")

            for width in [1, 16, 32] {
                let texts = (0 ..< width).map { pool[$0 % pool.count] }
                let group = rows(for: texts)
                let shape = try await measurePromptShape(processor, rows: group)
                let plan = planner.plan(
                    requestedRows: width, systemPrefixTokens: shape.systemPrefixTokens,
                    suffixTokens: shape.maxSuffixTokens, maxOutputTokens: 192)
                let granted = Array(group.prefix(plan.rows))

                _ = try? await runBatchedGeneration(
                    processor, rows: granted, maxTokens: 8, warmPrefix: true,
                    prefillPositionBudget: plan.prefillPositionBudget)

                var decode: [Double] = []
                var endToEnd: [Double] = []
                for _ in 0 ..< 5 {
                    let run = try await runBatchedGeneration(
                        processor, rows: granted, maxTokens: 192, warmPrefix: true,
                        prefillPositionBudget: plan.prefillPositionBudget)
                    decode.append(run.stats.tokensPerSecond)
                    let wall = run.stats.prefillTime + run.stats.generateTime
                    endToEnd.append(wall > 0 ? Double(run.stats.tokenCount) / wall : 0)
                }
                decode.sort()
                endToEnd.sort()
                let median = decode[decode.count / 2]
                let p10 = decode[max(0, Int(Double(decode.count - 1) * 0.1))]
                let p90 = decode[min(decode.count - 1, Int(Double(decode.count - 1) * 0.9))]
                let spread = median > 0 ? (p90 - p10) / median : 0

                lines.append(String(format: "%4d  %5d  %13.1f  %5.1f  %5.1f  %6.0f%%  %17.1f",
                                    plan.rows, decode.count, median, p10, p90, spread * 100,
                                    endToEnd[endToEnd.count / 2]))

                XCTAssertLessThan(spread, 0.33,
                                  String(format: "B=%d throughput varies by %.0f%% run to run — "
                                         + "too unstable to build on", plan.rows, spread * 100))
            }
            print(lines.joined(separator: "\n") + "\n")
        }
    }

    // MARK: - Fixtures

    private func withModel(_ body: (LLMPostProcessor) async throws -> Void) async throws {
        let processor = LLMPostProcessor()
        do {
            try await processor.loadModel(variant)
        } catch {
            throw XCTSkip("cannot load \(variant.rawValue): \(error.localizedDescription)")
        }
        do { try await body(processor) } catch {
            await processor.unloadModel()
            throw error
        }
        await processor.unloadModel()
    }

    private func rows(for texts: [String]) -> [(system: String, user: String)] {
        texts.map { correctPrompt(for: $0, fragment: true) }
    }

    private func loadCorpus() throws -> ChunkStreamCorpus {
        guard let corpus = ChunkStreamCorpus.loadPersisted(), !corpus.streams.isEmpty else {
            throw XCTSkip("No frozen chunk corpus — run testChunkArrivalCharacterisation first")
        }
        return corpus
    }

    private func machineConditions() -> String {
        var loads = [Double](repeating: 0, count: 3)
        let load = getloadavg(&loads, 3) == 3
            ? String(format: "load %.2f %.2f %.2f", loads[0], loads[1], loads[2])
            : "load unavailable"
        return String(format: "conditions: %@, active %.0f MB, available %.0f MB, ceiling %.0f MB",
                      load, Double(Memory.activeMemory) / 1_048_576,
                      BatchMemoryPlanner.availableMemoryMB() ?? -1,
                      BatchMemoryPlanner.forQwen35_4B.currentCeilingMB())
    }
}
