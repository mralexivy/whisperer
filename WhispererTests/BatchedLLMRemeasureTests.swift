//
//  BatchedLLMRemeasureTests.swift
//  WhispererTests
//
//  Rounds 1–3 were measured while Xcode and several editor renderers were live on the same GPU,
//  and the tables show it: ms/step jumped 58→159 between B=4 and B=8, then barely moved from
//  there to B=32. A kernel switch explains a jump; it does not explain a jump followed by a
//  plateau followed by nothing. Contention does explain all three, so the numbers are re-taken
//  here under conditions that make contamination visible rather than silent.
//
//  Three things this file does that the earlier sweep did not:
//
//  1. **Times the bare kernel.** `probeRawStepCost` puts nothing between two timer reads except
//     `model(y, cache:)` and `eval`. An aggregate tok/s figure blends the GPU, the per-step
//     GPU→CPU sync, the tokenizer and the degeneration guard; if that plateaus, any of them could
//     be the cause. Here only one thing can be.
//  2. **Separates text size from batch size.** The earlier probe used one length — three long
//     chunks joined — so every reported number was for that length. But the three production
//     populations have very different shapes: a short dictation chunk, a median streaming chunk,
//     and a whole-text or meeting segment. Prefill scales with length and decode does not, so
//     they cannot share a conclusion.
//  3. **Reports the machine's load with the table.** A benchmark whose conditions are not
//     recorded cannot be compared against the next one.
//
//  Reports; asserts almost nothing. The point is the table.
//

import Darwin
import MLX
import MLXLLM
import XCTest
@testable import whisperer

@MainActor
final class BatchedLLMRemeasureTests: XCTestCase {

    private let variant: LLMModelVariant = .qwen3_5_4B_mtp

    // MARK: - Raw decode kernel

    /// The curve that answers "why can't we do better", with nothing else mixed in.
    ///
    /// Reading it: `kernelMs` flat across B means each extra row rides along free and aggregate
    /// throughput scales linearly — the memory-bandwidth-bound regime the plan assumed. `kernelMs`
    /// rising in proportion to B means the GPU is saturated and widening buys nothing at all. The
    /// width where it turns is the entire ceiling, and everything else is scheduling.
    ///
    /// `withPickMs - kernelMs` is what the decode loop costs on top: one argmax over `[B, 248320]`
    /// and one `asArray` sync per step. If that gap grows with B it is worth attacking; if it is
    /// constant it is a fixed toll and not where the win is.
    func testRawDecodeKernelCurve() async throws {
        try await withModel { processor in
            // A deliberately short prefill. The first run of this probe used 256 tokens, and at
            // B=64 that made the prefill's `[64, 256, 248320]` logits an 8 GB allocation on a
            // 32 GB machine — MLX peak memory hit 19.5 GB and the system load average hit 64, so
            // the decode timings that followed were measuring memory pressure. Decode cost barely
            // depends on the cache offset here (8 full-attention layers against 2.4 GB of
            // weights), so shortening the prompt removes the contamination without changing what
            // is being measured.
            let points = try await probeRawStepCost(
                processor, widths: [1, 2, 4, 8, 12, 16, 24, 32, 48, 64],
                promptTokens: 16, steps: 24)

            var lines = ["\n=== Raw decode kernel (no tokenizer, no decode loop) ==="]
            lines.append(machineConditions())
            lines.append("   B   kernel_ms   pick_ms   overhead_ms   rel_to_B1   tok/s_ceiling   active_MB")
            let baseline = points.first?.kernelMs ?? 0
            for point in points {
                lines.append(String(
                    format: "%4d  %10.2f  %8.2f  %12.2f  %10.2fx  %14.0f  %10.0f",
                    point.batch, point.kernelMs, point.withPickMs,
                    point.withPickMs - point.kernelMs,
                    baseline > 0 ? point.kernelMs / baseline : 0,
                    point.kernelMs > 0 ? Double(point.batch) * 1000 / point.kernelMs : 0,
                    point.activeMB))
            }
            // Where each extra row stops being free: the last width whose per-row cost is still
            // within 25% of B=1's. Past it, aggregate throughput is bounded by arithmetic.
            let free = points.last { $0.kernelMs <= baseline * 1.25 * 1.0 }?.batch ?? 1
            let knee = points.first { baseline > 0 && $0.kernelMs > baseline * 1.5 }?.batch
            lines.append("last width within 25% of B=1 step cost: B=\(free)")
            lines.append("first width costing >1.5x a B=1 step: "
                         + (knee.map(String.init) ?? "none in range"))
            print(lines.joined(separator: "\n") + "\n")

            XCTAssertFalse(points.isEmpty, "no kernel points collected")
        }
    }

    // MARK: - Throughput by text size

    /// The same sweep as round 1, but run separately for a short, a medium and a large row.
    ///
    /// Collapsing these into one probe length was the earlier sweep's real weakness. The three
    /// sizes map onto the three production populations and they do not behave alike: a short row
    /// generates so few tokens that fixed overhead dominates, while a large row's prefill — which
    /// does not batch — grows with B until it swamps the decode saving. Reporting one number for
    /// "the workload" hides both effects.
    func testThroughputByTextSize() async throws {
        let corpus = try loadCorpus()
        let pool = realChunkTexts(count: 96, corpus: corpus)
        try XCTSkipIf(pool.count < 32, "corpus has only \(pool.count) usable chunks")
        let sizes = textSizeBuckets(from: pool)

        try await withModel { processor in
            var lines = ["\n=== Aggregate throughput by text size ==="]
            lines.append(machineConditions())

            for size in sizes {
                lines.append(String(format: "\n-- %@: %d chars --", size.name, size.text.count))
                lines.append("   B   steps   ms/step   decode_tok/s   prefill_ms   e2e_tok/s   speedup   active_MB")
                var baseline: Double = 0

                for width in [1, 2, 4, 8, 16, 32] {
                    let group = rows(for: Array(repeating: size.text, count: width))
                    _ = try? await runBatchedGeneration(
                        processor, rows: group, maxTokens: 8, warmPrefix: true)

                    var fastest: BatchStats?
                    for _ in 0 ..< 2 {
                        let run = try await runBatchedGeneration(
                            processor, rows: group, maxTokens: size.maxTokens, warmPrefix: true)
                        if fastest == nil || run.stats.tokensPerSecond > fastest!.tokensPerSecond {
                            fastest = run.stats
                        }
                    }
                    guard let stats = fastest else { continue }

                    // End-to-end is the honest figure for a user: prefill is work the app has to
                    // do before a single token appears, and it does not batch.
                    let wall = stats.prefillTime + stats.generateTime
                    let endToEnd = wall > 0 ? Double(stats.tokenCount) / wall : 0
                    if width == 1 { baseline = endToEnd }

                    lines.append(String(
                        format: "%4d  %6d  %8.2f  %13.1f  %11.0f  %10.1f  %7.2fx  %10.0f",
                        width, stats.steps,
                        stats.generateTime * 1000 / Double(max(stats.steps, 1)),
                        stats.tokensPerSecond, stats.prefillTime * 1000, endToEnd,
                        baseline > 0 ? endToEnd / baseline : 0,
                        Double(Memory.activeMemory) / 1024 / 1024))
                }
            }
            print(lines.joined(separator: "\n") + "\n")
        }
    }

    // MARK: - Text sizes

    private struct TextSize {
        let name: String
        let text: String
        /// Sized to the row: a short chunk's correction is short, and capping every size at the
        /// same number would let the large rows run to the cap while the short ones stopped on
        /// their own, which is a different measurement per row rather than one comparison.
        let maxTokens: Int
    }

    /// Short, medium and large probe rows drawn from the real corpus rather than invented.
    ///
    /// Short and medium are real single chunks at the p20 and p60 of the corpus's own length
    /// distribution — that is what the streaming path actually sends. Large is several chunks
    /// joined, which is what the whole-text splitter and a meeting segment look like; no single
    /// VAD chunk is that long, so it has to be built rather than sampled.
    private func textSizeBuckets(from pool: [String]) -> [TextSize] {
        let sorted = pool.sorted { $0.count < $1.count }
        let short = sorted[max(0, Int(Double(sorted.count - 1) * 0.20))]
        let medium = sorted[max(0, Int(Double(sorted.count - 1) * 0.60))]

        var large = ""
        for text in sorted.reversed() where large.count < 600 {
            large += (large.isEmpty ? "" : " ") + text
        }
        return [TextSize(name: "short", text: short, maxTokens: 128),
                TextSize(name: "medium", text: medium, maxTokens: 192),
                TextSize(name: "large", text: large, maxTokens: 384)]
    }

    // MARK: - Conditions

    /// Load average and free memory at the moment of the run, printed with every table.
    ///
    /// Rounds 1–3 were taken on a machine that turned out to be busy, and nothing in their output
    /// said so — which is why they had to be thrown away rather than compared against. A table
    /// that carries its own conditions can at least be judged.
    private func machineConditions() -> String {
        var loads = [Double](repeating: 0, count: 3)
        let count = getloadavg(&loads, 3)
        let load = count == 3
            ? String(format: "load %.2f %.2f %.2f", loads[0], loads[1], loads[2])
            : "load unavailable"
        return String(format: "conditions: %@, active %.0f MB, cache %.0f MB, peak %.0f MB",
                      load,
                      Double(Memory.activeMemory) / 1024 / 1024,
                      Double(Memory.cacheMemory) / 1024 / 1024,
                      Double(Memory.peakMemory) / 1024 / 1024)
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
}
