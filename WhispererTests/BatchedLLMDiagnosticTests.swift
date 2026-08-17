//
//  BatchedLLMDiagnosticTests.swift
//  WhispererTests
//
//  `testBatchEqualsSerialGreedy` failed with divergences that all look like near-ties — a comma
//  appearing or not, "the user" versus "user". That has two possible causes and they call for
//  opposite responses:
//
//    1. A bug in the right-padded prefill, in which case rows are genuinely being corrupted by
//       their neighbours and the whole approach is unsound until it is fixed.
//    2. Metal kernels that are not batch-invariant — the same dot product reduced in a different
//       order at B=8 than at B=1, producing float differences of ~1e-7 that flip an argmax
//       whenever the top two logits are nearly tied. That is not a bug, it is a property of the
//       hardware, and it means byte-exactness is simply not available as a gate.
//
//  Guessing between them would be guessing about the thing the whole plan rests on, so this file
//  measures instead. It also collects ms/step across B, because the same run that failed reported
//  39 tok/s aggregate at B=8 — worse than single-stream — and the timing and the divergence may
//  well have one shared cause.
//
//  Diagnostic only: prints, asserts almost nothing, and is not part of any gate.
//

import MLX
import MLXLLM
import XCTest
@testable import whisperer

@MainActor
final class BatchedLLMDiagnosticTests: XCTestCase {

    private let variant: LLMModelVariant = .qwen3_5_4B_mtp
    private let maxTokens = 128

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

    // MARK: - Is the divergence padding, or is it the batch width?

    /// Three runs that separate the two hypotheses.
    ///
    /// - **U** — B=8 of the *same* text. Every row is the same length, so nothing is padded and no
    ///   row can be corrupted by a neighbour's pads. If U's rows disagree with each other, rows
    ///   are leaking into each other and it is a real bug. If they agree with each other but
    ///   disagree with B=1, the kernels are not batch-invariant and byte-exactness is unavailable.
    /// - **A** and **B** — both B=8 and both ragged, differing only in the *last* row: B swaps in
    ///   a much longer text, which increases the pad count on rows 0…6 without changing their
    ///   content or the batch width. If rows 0…6 survive that unchanged, the padding is being
    ///   masked correctly.
    func testDivergenceIsPaddingOrBatchWidth() async throws {
        let corpus = try loadCorpus()
        let pool = realChunkTexts(count: 40, corpus: corpus)
        try XCTSkipIf(pool.count < 16, "corpus has only \(pool.count) usable chunks")

        // Shortest eight, so there is room above them for a much longer row to pad against.
        let sorted = pool.sorted { $0.count < $1.count }
        let short = Array(sorted.prefix(8))
        guard let longest = sorted.last, longest.count > short[7].count * 2 else {
            throw XCTSkip("corpus has no chunk long enough to change the padding materially")
        }

        try await withModel { processor in
            let one = try await runBatchedGeneration(
                processor, rows: rows(for: [short[0]]), maxTokens: maxTokens, warmPrefix: true)

            let uniform = try await runBatchedGeneration(
                processor, rows: rows(for: Array(repeating: short[0], count: 8)),
                maxTokens: maxTokens, warmPrefix: true)

            let raggedA = try await runBatchedGeneration(
                processor, rows: rows(for: short), maxTokens: maxTokens, warmPrefix: true)
            let raggedB = try await runBatchedGeneration(
                processor, rows: rows(for: Array(short.prefix(7)) + [longest]),
                maxTokens: maxTokens, warmPrefix: true)

            print("\n=== Divergence diagnostic ===")

            // 1. Do the eight identical rows agree with each other?
            let uniqueRows = Set(uniform.texts)
            print("U: 8 identical unpadded rows → \(uniqueRows.count) distinct output(s)")
            if uniqueRows.count > 1 {
                for (index, text) in uniform.texts.enumerated() { print("   [\(index)] \(text)") }
            }

            // 2. Do they agree with B=1?
            let matchesSerial = uniform.texts[0] == one.texts[0]
            print("U row 0 == B=1: \(matchesSerial)")
            if !matchesSerial {
                print("   B=1: \(one.texts[0])")
                print("   B=8: \(uniform.texts[0])")
            }

            // 3. Does changing only the pad count change rows 0…6?
            var padSensitive = 0
            for index in 0 ..< 7 where raggedA.texts[index] != raggedB.texts[index] {
                padSensitive += 1
                if padSensitive == 1 {
                    print("first pad-sensitive row \(index):")
                    print("   pad \(raggedA.stats.padWaste * 100)%: \(raggedA.texts[index])")
                    print("   pad \(raggedB.stats.padWaste * 100)%: \(raggedB.texts[index])")
                }
            }
            print("rows changed by pad count alone: \(padSensitive) / 7")
            print(String(format: "pad waste A %.0f%%, B %.0f%%",
                         raggedA.stats.padWaste * 100, raggedB.stats.padWaste * 100))

            // The one thing that is unambiguously a bug rather than a hardware property.
            XCTAssertEqual(uniqueRows.count, 1,
                           "identical unpadded rows produced different text — rows are leaking")
        }
    }

    // MARK: - Where is the time going?

    /// ms/step and aggregate tok/s across B, on unpadded batches of identical real chunk text.
    ///
    /// Identical rows rather than varied ones on purpose: this isolates the cost of *width* from
    /// the cost of raggedness and of stragglers, so a flat ms/step curve here means the decode
    /// really is bandwidth-bound and any disappointment in the real sweep is scheduling, not the
    /// kernel. The last row repeats the widest B with ragged text so the two can be compared.
    func testStepCostAcrossBatchWidth() async throws {
        let corpus = try loadCorpus()
        let pool = realChunkTexts(count: 32, corpus: corpus)
        try XCTSkipIf(pool.count < 16, "corpus has only \(pool.count) usable chunks")
        let probe = pool.sorted { $0.count < $1.count }[pool.count / 2]   // a median-length chunk

        try await withModel { processor in
            print("\n=== Step cost across batch width (identical unpadded rows) ===")
            print("   B   steps   ms/step   prefill_ms   agg_tok/s   per_row_tok/s")
            var baseline: Double = 0
            for width in [1, 2, 4, 8, 16] {
                let run = try await runBatchedGeneration(
                    processor, rows: rows(for: Array(repeating: probe, count: width)),
                    maxTokens: maxTokens, warmPrefix: true)
                let msPerStep = run.stats.steps > 0
                    ? run.stats.generateTime * 1000 / Double(run.stats.steps) : 0
                if width == 1 { baseline = msPerStep }
                print(String(format: "%4d  %6d  %8.2f  %11.0f  %10.1f  %14.1f",
                             width, run.stats.steps, msPerStep, run.stats.prefillTime * 1000,
                             run.stats.tokensPerSecond,
                             run.stats.tokensPerSecond / Double(width)))
            }
            print(String(format: "B=1 ms/step baseline %.2f — if ms/step at B=16 is under %.2f, "
                         + "widening is nearly free", baseline, baseline * 2))

            let ragged = try await runBatchedGeneration(
                processor, rows: rows(for: Array(pool.prefix(16))),
                maxTokens: maxTokens, warmPrefix: true)
            print(String(format: "ragged B=16: %d steps, %.2f ms/step, %.0f%% pad, %.1f agg tok/s, "
                         + "avg width %.1f, %d compactions",
                         ragged.stats.steps,
                         ragged.stats.generateTime * 1000 / Double(max(ragged.stats.steps, 1)),
                         ragged.stats.padWaste * 100, ragged.stats.tokensPerSecond,
                         ragged.stats.averageWidth, ragged.stats.compactions))
        }
    }

    // MARK: - Is the arithmetic the same?

    /// Text-level equality says only *that* a row flipped. This says by how much the arithmetic
    /// moved, which is what distinguishes float noise from a wrong answer.
    ///
    /// The reading: if `maxAbsDiff` is orders of magnitude below `top2Gap` on nearly every row,
    /// the batched path is computing the same thing and the occasional flip is a genuine near-tie
    /// that no amount of fixing will remove. If `maxAbsDiff` is comparable to or larger than the
    /// logit scale, something is actually wrong.
    func testRaggedPrefillLogitsMatchSolo() async throws {
        let corpus = try loadCorpus()
        let texts = realChunkTexts(count: 12, corpus: corpus)
        try XCTSkipIf(texts.count < 4, "corpus has only \(texts.count) usable chunks")

        try await withModel { processor in
            let deltas = try await compareRaggedPrefillLogits(processor, texts: texts)
            print("\n=== Ragged prefill logits vs solo ===")
            print(" row   maxAbsDiff     top2Gap   ratio  argmax")
            for (index, delta) in deltas.enumerated() {
                print(String(format: "%4d  %11.6f  %10.4f  %6.3f  %@",
                             index, delta.maxAbsDiff, delta.top2Gap,
                             delta.top2Gap > 0 ? delta.maxAbsDiff / delta.top2Gap : 0,
                             delta.argmaxMatches ? "same" : "FLIPPED"))
            }
            let worst = deltas.map(\.maxAbsDiff).max() ?? 0
            let flips = deltas.filter { !$0.argmaxMatches }.count
            print(String(format: "worst maxAbsDiff %.6f, %d/%d rows flipped", worst, flips, deltas.count))

            // Logit magnitudes here run to tens. A drift of more than 0.5 is not float noise.
            XCTAssertLessThan(worst, 0.5, "batched prefill logits differ materially from solo")
        }
    }

    // MARK: - Does the MLX buffer cache cap explain the step cost?

    /// The app caps the MLX buffer pool at 256 MB for this model. A B=16 step allocates ~16 MB of
    /// logits alone, plus every intermediate, so the cap may be forcing the allocator to return
    /// buffers to the system and re-fault them every step — which would look exactly like the
    /// superlinear ms/step the width sweep shows. One knob, measured both ways.
    func testCacheLimitEffectOnStepCost() async throws {
        let corpus = try loadCorpus()
        let pool = realChunkTexts(count: 32, corpus: corpus)
        try XCTSkipIf(pool.count < 16, "corpus has only \(pool.count) usable chunks")
        let probe = pool.sorted { $0.count < $1.count }[pool.count / 2]

        try await withModel { processor in
            for limitMB in [256, 4096] {
                Memory.cacheLimit = limitMB * 1024 * 1024
                Memory.clearCache()
                print("\n=== cacheLimit \(limitMB) MB ===")
                print("   B   ms/step   agg_tok/s   cache_MB")
                for width in [1, 4, 8, 16] {
                    let run = try await runBatchedGeneration(
                        processor, rows: rows(for: Array(repeating: probe, count: width)),
                        maxTokens: maxTokens, warmPrefix: true)
                    print(String(format: "%4d  %8.2f  %10.1f  %8.0f", width,
                                 run.stats.generateTime * 1000 / Double(max(run.stats.steps, 1)),
                                 run.stats.tokensPerSecond,
                                 Double(Memory.cacheMemory) / 1024 / 1024))
                }
            }
        }
    }

    // MARK: - Fixtures

    private func loadCorpus() throws -> ChunkStreamCorpus {
        guard let corpus = ChunkStreamCorpus.loadPersisted(), !corpus.streams.isEmpty else {
            throw XCTSkip("No frozen chunk corpus — run testChunkArrivalCharacterisation first")
        }
        return corpus
    }
}
