//
//  BatchedLLMSweepTests.swift
//  WhispererTests
//
//  Phase 0b — the batch-size sweep the whole plan turns on.
//
//  The first attempt at this measured 18-step generations once each and produced a table that
//  contradicted itself between runs (B=1 at 81 ms/step in one run and 28 ms/step in the next).
//  Eighteen steps is far too short: Metal kernel specialisation for a shape not seen before lands
//  entirely inside the measurement, and at these durations it is most of it. So this file warms
//  every shape before timing it, repeats each point, and reports the *best* of the repeats rather
//  than the mean — the fastest run is the one least contaminated by whatever else the machine was
//  doing, and the question here is what the hardware can do, not what it did on average while
//  Xcode was also running.
//
//  Rows are real chunk text from the frozen Phase 0a corpus. Identical rows per batch on purpose:
//  this measures the cost of *width*, with raggedness and stragglers held out so they can be
//  attributed separately in the ragged row at the end.
//

import MLX
import MLXLLM
import XCTest
@testable import whisperer

@MainActor
final class BatchedLLMSweepTests: XCTestCase {

    private let variant: LLMModelVariant = .qwen3_5_4B_mtp
    private let widths = [1, 2, 4, 8, 16, 24, 32]
    /// Long enough that per-step cost dominates the fixed overhead of a run. The `Correct` prompt
    /// on a real chunk stops well before this on its own, so the length is forced by the input
    /// rather than by the cap — see `probeText`.
    private let maxTokens = 192
    private let repeats = 2

    private static var table: [String] = []

    // MARK: - Sweep

    func testBatchSizeSweep() async throws {
        let corpus = try loadCorpus()
        let pool = realChunkTexts(count: 64, corpus: corpus)
        try XCTSkipIf(pool.count < 32, "corpus has only \(pool.count) usable chunks")

        // The longest real chunks, joined, so a row generates enough tokens to time. A short chunk
        // finishes in ~18 steps and the measurement is then mostly warm-up.
        let longest = pool.sorted { $0.count > $1.count }
        let probeText = longest.prefix(3).joined(separator: " ")

        try await withModel { processor in
            Self.table.append("=== Phase 0b — batch size sweep (identical unpadded rows) ===")
            Self.table.append(String(format: "probe: %d chars, %d repeats, best of",
                                     probeText.count, repeats))
            Self.table.append("   B   steps   ms/step   agg_tok/s   per_row_tok/s   speedup   prefill_ms   active_MB")

            var baselineAggregate: Double = 0
            var best: (width: Int, tokensPerSecond: Double) = (0, 0)

            for width in widths {
                let group = rows(for: Array(repeating: probeText, count: width))

                // Warm-up: this shape's kernels get specialised here, not inside the timing.
                _ = try? await runBatchedGeneration(
                    processor, rows: group, maxTokens: 8, warmPrefix: true)

                var fastest: BatchStats?
                for _ in 0 ..< repeats {
                    let run = try await runBatchedGeneration(
                        processor, rows: group, maxTokens: maxTokens, warmPrefix: true)
                    if fastest == nil || run.stats.tokensPerSecond > fastest!.tokensPerSecond {
                        fastest = run.stats
                    }
                }
                guard let stats = fastest else { continue }

                if width == 1 { baselineAggregate = stats.tokensPerSecond }
                if stats.tokensPerSecond > best.tokensPerSecond {
                    best = (width, stats.tokensPerSecond)
                }
                Self.table.append(String(
                    format: "%4d  %6d  %8.2f  %10.1f  %14.1f  %7.2fx  %11.0f  %10.0f",
                    width, stats.steps,
                    stats.generateTime * 1000 / Double(max(stats.steps, 1)),
                    stats.tokensPerSecond, stats.tokensPerSecond / Double(width),
                    baselineAggregate > 0 ? stats.tokensPerSecond / baselineAggregate : 0,
                    stats.prefillTime * 1000,
                    Double(Memory.activeMemory) / 1024 / 1024))
            }

            // Ragged, at the best width found — the difference between this and the identical-row
            // point at the same width is the entire cost of raggedness plus stragglers, which is
            // what a real scheduler would face.
            if best.width > 1, pool.count >= best.width {
                let ragged = try await runBatchedGeneration(
                    processor, rows: rows(for: Array(pool.prefix(best.width))),
                    maxTokens: maxTokens, warmPrefix: true)
                Self.table.append(String(
                    format: "ragged B=%d: %.1f agg tok/s (%.0f%% of identical-row), %.0f%% pad, "
                    + "avg width %.1f, %d compactions",
                    best.width, ragged.stats.tokensPerSecond,
                    100 * ragged.stats.tokensPerSecond / best.tokensPerSecond,
                    ragged.stats.padWaste * 100, ragged.stats.averageWidth,
                    ragged.stats.compactions))
            }

            Self.table.append(String(format: "best: %.0f tok/s at B=%d (%.1fx over B=1)",
                                     best.tokensPerSecond, best.width,
                                     baselineAggregate > 0 ? best.tokensPerSecond / baselineAggregate : 0))
            print("\n" + Self.table.joined(separator: "\n") + "\n")

            // Reported, not asserted. The plan's 1000 tok/s figure was derived from an assumption
            // — that decode stays bandwidth-bound to B≈32 — and this sweep is the measurement that
            // either confirms it or replaces it. Failing here would only hide the answer.
            XCTAssertGreaterThan(best.tokensPerSecond, baselineAggregate,
                                 "batching did not beat single-stream at any width")
        }
    }

    /// The sweep above plateaus rather than saturating: ms/step barely moves between B=8 (159) and
    /// B=32 (186) while aggregate throughput keeps climbing. That plateau is the signature of a
    /// kernel that has already switched to its wide form — MLX picks a dequantise-then-GEMM path
    /// for quantised weights above a small batch threshold, which is also what the sharp B=4→8
    /// jump looks like. Once on it, extra rows ride along nearly free, so the real ceiling is
    /// above 32 and the only way to find it is to go there.
    ///
    /// One repeat per point: each of these costs a full prefill at that width, and the widths are
    /// what is being compared, not the run-to-run noise.
    func testWideBatchCeiling() async throws {
        let corpus = try loadCorpus()
        let pool = realChunkTexts(count: 64, corpus: corpus)
        try XCTSkipIf(pool.count < 32, "corpus has only \(pool.count) usable chunks")
        let probeText = pool.sorted { $0.count > $1.count }.prefix(3).joined(separator: " ")

        try await withModel { processor in
            print("\n=== Wide-batch ceiling ===")
            print("   B   steps   ms/step   decode_tok/s   prefill_ms   e2e_tok/s   active_MB")
            for width in [32, 48, 64, 96] {
                let group = rows(for: Array(repeating: probeText, count: width))
                let run: BatchRunResult
                do {
                    run = try await runBatchedGeneration(
                        processor, rows: group, maxTokens: maxTokens, warmPrefix: true)
                } catch {
                    print("B=\(width): failed — \(error)")
                    break
                }
                let wall = run.stats.prefillTime + run.stats.generateTime
                print(String(format: "%4d  %6d  %8.2f  %13.1f  %11.0f  %10.1f  %10.0f",
                             width, run.stats.steps,
                             run.stats.generateTime * 1000 / Double(max(run.stats.steps, 1)),
                             run.stats.tokensPerSecond, run.stats.prefillTime * 1000,
                             wall > 0 ? Double(run.stats.tokenCount) / wall : 0,
                             Double(Memory.activeMemory) / 1024 / 1024))
            }
        }
    }

    /// Ragged real chunks at B=32 reached only 37% of the identical-row rate, with an average live
    /// width of 15 out of 32. That gap — not the kernel — is the largest remaining loss on any
    /// real workload, because real chunks are never the same length and never finish together.
    ///
    /// The knob is when to physically retire dead rows. Until a compaction happens a finished row
    /// still costs a full row of compute on every step, so a lax threshold means paying for
    /// B=32 while only 15 rows are doing anything. Compaction is not free either — it rewrites
    /// every cache tensor — so the right value is measured, not reasoned about.
    func testCompactionThresholdSweep() async throws {
        let corpus = try loadCorpus()
        let pool = realChunkTexts(count: 64, corpus: corpus)
        try XCTSkipIf(pool.count < 32, "corpus has only \(pool.count) usable chunks")
        let group = rows(for: Array(pool.prefix(32)))

        try await withModel { processor in
            _ = try? await runBatchedGeneration(processor, rows: group, maxTokens: 8, warmPrefix: true)
            print("\n=== Compaction threshold, ragged B=32 real chunks ===")
            print(" thresh   steps   ms/step   agg_tok/s   avg_width   compactions")
            for threshold in [1.0, 0.5, 0.25, 0.1] {
                let run = try await runBatchedGeneration(
                    processor, rows: group, maxTokens: maxTokens, warmPrefix: true,
                    compactionThreshold: threshold)
                print(String(format: "%7.2f  %6d  %8.2f  %10.1f  %11.1f  %13d",
                             threshold, run.stats.steps,
                             run.stats.generateTime * 1000 / Double(max(run.stats.steps, 1)),
                             run.stats.tokensPerSecond, run.stats.averageWidth,
                             run.stats.compactions))
            }
        }
    }

    // MARK: - Helpers

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
}
