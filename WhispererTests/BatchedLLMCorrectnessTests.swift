//
//  BatchedLLMCorrectnessTests.swift
//  WhispererTests
//
//  The gate that has to be green before any throughput number from `BatchedLLMThroughputTests`
//  means anything. Greedy decode at temperature 0 is deterministic, so putting a prompt on row 5
//  of a batch of 8 must produce the *same bytes* as running it alone. If that ever stops being
//  true, batching has changed the model's output and the 100-case prompt-quality corpus in
//  `docs/knowledge/llm/criteria.md` has to be re-measured from scratch — which is the expensive
//  outcome these three tests exist to detect cheaply.
//
//  Every test skips rather than fails when the model or the frozen chunk corpus is absent, so the
//  suite stays runnable on a machine that has neither.
//
//  Must not run concurrently with any other model test — see the note in
//  `BatchedLLMThroughputTests`.
//

import MLXLLM
import XCTest
@testable import whisperer

@MainActor
final class BatchedLLMCorrectnessTests: XCTestCase {

    /// The model the batched path is being built for. The 4B MTP variant, because that is what
    /// the app runs for correction today; batching bypasses MTP but shares its weights.
    private let variant: LLMModelVariant = .qwen3_5_4B_mtp

    /// Per-row output cap. A `Correct` pass rewrites a chunk, so its output is about the length of
    /// its input; 256 is generous for the p90 chunk and keeps a degenerate row from holding the
    /// whole batch open for minutes.
    private let maxTokens = 256

    /// Rows per batch. Deliberately not the largest B the hardware allows: this test is about
    /// equality, and a modest B exercises the padded prefill, the per-row logit gather, and at
    /// least one compaction without costing an hour.
    private let batchWidth = 8

    // MARK: - Fixtures

    private func loadCorpus() throws -> ChunkStreamCorpus {
        guard let corpus = ChunkStreamCorpus.loadPersisted(), !corpus.streams.isEmpty else {
            throw XCTSkip("No \(ChunkStreamCorpus.fileURL.lastPathComponent) — run "
                          + "testChunkArrivalCharacterisation with CHUNK_CORPUS_REHARVEST=1 first")
        }
        return corpus
    }

    /// Loads the model, runs `body`, unloads. Skips rather than fails when the weights are not on
    /// disk — the same contract `LLMModelComparisonTests.withModel` uses.
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

    /// Real chunk text wrapped in the real `Correct` prompt, fragment mode on — that is how the
    /// streaming path sends a chunk, and the prompt is part of what is being held constant.
    private func rows(for texts: [String]) -> [(system: String, user: String)] {
        texts.map { correctPrompt(for: $0, fragment: true) }
    }

    /// Reports the first difference rather than dumping two 64-element arrays. A byte-level
    /// mismatch is almost always one row diverging at one token, and the useful thing to see is
    /// the common prefix and what came after it.
    private func assertIdentical(
        _ batched: [String], _ serial: [String], inputs: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(batched.count, serial.count, "row count changed", file: file, line: line)
        for index in 0 ..< min(batched.count, serial.count) where batched[index] != serial[index] {
            let common = zip(batched[index], serial[index]).prefix { $0 == $1 }.count
            XCTFail("""
                row \(index) diverged after \(common) characters
                input:   \(inputs[index])
                batched: \(batched[index])
                serial:  \(serial[index])
                """, file: file, line: line)
            return
        }
    }

    // MARK: - 1. Batched greedy == serial greedy

    /// The headline correctness property: 64 real chunks across every language in the corpus,
    /// decoded in batches of 8 and decoded one at a time, must come out byte-identical.
    func testBatchEqualsSerialGreedy() async throws {
        let corpus = try loadCorpus()
        let texts = realChunkTexts(count: 64, corpus: corpus)
        try XCTSkipIf(texts.count < batchWidth, "corpus has only \(texts.count) usable chunks")

        try await withModel { processor in
            var batched: [String] = []
            var serial: [String] = []
            var stats = BatchStats()

            for start in stride(from: 0, to: texts.count, by: batchWidth) {
                let slice = Array(texts[start ..< min(start + batchWidth, texts.count)])
                let group = rows(for: slice)

                let batchRun = try await runBatchedGeneration(
                    processor, rows: group, maxTokens: maxTokens, warmPrefix: true)
                let serialRun = try await runSerialGeneration(
                    processor, rows: group, maxTokens: maxTokens, warmPrefix: true)

                assertIdentical(batchRun.texts, serialRun.texts, inputs: slice)
                batched += batchRun.texts
                serial += serialRun.texts
                stats.tokenCount += batchRun.stats.tokenCount
                stats.generateTime += batchRun.stats.generateTime
            }

            // Not a gate — the gate lives in the sweep. Printed because a "correct but 1.0×"
            // result and a "correct and 8×" result need very different follow-up.
            print(String(format: "batch==serial over %d chunks — batched aggregate %.0f tok/s",
                         batched.count, stats.tokensPerSecond))
            XCTAssertEqual(batched.count, texts.count)
            XCTAssertFalse(batched.contains { $0.isEmpty }, "a row produced no text at all")
        }
    }

    // MARK: - 2. Warm-prefix broadcast == cold prefill

    /// A mis-tiled warm cache does not crash; it produces subtly wrong text, which is far worse.
    /// Broadcasting the batch-1 system prefix across B rows must be indistinguishable from every
    /// row prefilling the whole prompt itself.
    func testWarmPrefixBroadcastIsExact() async throws {
        let corpus = try loadCorpus()
        let texts = realChunkTexts(count: batchWidth, corpus: corpus)
        try XCTSkipIf(texts.count < 2, "corpus has only \(texts.count) usable chunks")
        let group = rows(for: texts)

        try await withModel { processor in
            let warm = try await runBatchedGeneration(
                processor, rows: group, maxTokens: maxTokens, warmPrefix: true)
            let cold = try await runBatchedGeneration(
                processor, rows: group, maxTokens: maxTokens, warmPrefix: false)

            XCTAssertGreaterThan(warm.warmPrefixTokens, 0, "no shared system prefix was found")
            assertIdentical(warm.texts, cold.texts, inputs: texts)
        }
    }

    // MARK: - 3. Hebrew and Russian survive batching

    /// The non-Latin rows are the known-fragile population — `docs/knowledge/llm/knowledge.md`
    /// records a 7-case Hebrew data-loss bug from a prompt/model mismatch. Right-padding a batch
    /// mixes scripts on adjacent rows, so this asserts the script of each output still matches the
    /// script of its input, independently of the equality tests above.
    func testHebrewAndRussianSurviveBatching() async throws {
        let corpus = try loadCorpus()
        let nonLatin = corpus.streams
            .filter { $0.language == "he" || $0.language == "ru" }
            .flatMap { stream in stream.chunks.map { (stream.language, $0.text) } }
            .filter { $0.1.trimmingCharacters(in: .whitespacesAndNewlines).count >= 12 }
            .prefix(batchWidth * 2)
        try XCTSkipIf(nonLatin.count < 2, "corpus has \(nonLatin.count) he/ru chunks")

        try await withModel { processor in
            for start in stride(from: 0, to: nonLatin.count, by: batchWidth) {
                let slice = Array(nonLatin[start ..< min(start + batchWidth, nonLatin.count)])
                let run = try await runBatchedGeneration(
                    processor, rows: rows(for: slice.map(\.1)),
                    maxTokens: maxTokens, warmPrefix: true)

                for (index, (language, input)) in slice.enumerated() {
                    let output = run.texts[index]
                    XCTAssertFalse(output.isEmpty, "\(language) row \(start + index) came back empty")
                    XCTAssertEqual(
                        dominantScript(output), dominantScript(input),
                        "\(language) row \(start + index) changed script\n"
                        + "in:  \(input)\nout: \(output)")
                }
            }
        }
    }

    /// Which script most of the letters belong to. Only the three that matter here — anything else
    /// collapses to "other", because this is a data-loss detector, not a classifier.
    private func dominantScript(_ text: String) -> String {
        var counts: [String: Int] = [:]
        for scalar in text.unicodeScalars {
            let script: String
            switch scalar.value {
            case 0x0590...0x05FF: script = "hebrew"
            case 0x0400...0x04FF: script = "cyrillic"
            case 0x0041...0x005A, 0x0061...0x007A: script = "latin"
            default: continue
            }
            counts[script, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key ?? "other"
    }
}
