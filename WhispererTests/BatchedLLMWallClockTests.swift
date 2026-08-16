//
//  BatchedLLMWallClockTests.swift
//  WhispererTests
//
//  The user-visible gate: how long the app makes you wait, on real recordings, with chunks
//  arriving when they really arrived.
//
//  Every other benchmark in this work measures throughput — tokens per second at some batch
//  width. Throughput is not what a user experiences. What they experience is the pause between
//  releasing the key and the text appearing, and that pause is whatever correction work is still
//  outstanding at release. Mid-stream corrections overlap with speech and cost nothing; the tail
//  does not overlap with anything.
//
//  So the number reported here is **release → text ready**: the coordinator is fed each chunk at
//  its real audio-time offset (from `TestData/chunk-stream-corpus.json`, harvested by replaying
//  real `.wav` files through whisper at real time), and the clock that matters starts at the last
//  chunk and stops when `drain()` returns. The same stream is run twice on one loaded model —
//  once with corrections going straight to the single-stream path, once through
//  `BatchedLLMScheduler` — so the only difference between the two runs is whether concurrent
//  requests coalesce.
//
//  Replay is real-time by construction: a 90-second recording takes 90 seconds per mode. That is
//  the cost of measuring the thing that was asked about rather than a proxy for it.
//
//  Must not run concurrently with any other model test.
//

import XCTest
@testable import whisperer

@MainActor
final class BatchedLLMWallClockTests: XCTestCase {

    private let variant: LLMModelVariant = .qwen3_5_4B_mtp

    /// How many streams to replay. Each one costs its own duration twice, so this is a
    /// wall-clock budget, not a statistical choice: 6 long recordings is roughly 20 minutes.
    private let streamBudget = 6

    /// The population the plan gates on — enough chunks that some can still be outstanding at
    /// release. A two-chunk recording has nothing to batch and would dilute the measurement.
    private let minChunks = 6

    // MARK: - Types

    private struct Run {
        let text: String
        /// Last chunk enqueued → `drain()` returned. The pause the user sees.
        let tailSeconds: Double
        /// First chunk enqueued → `drain()` returned, minus the replay's own sleeping. Reported
        /// so a tail that looks good only because the work moved earlier is visible.
        let correctionSeconds: Double
        let batchWidths: [Int]
    }

    // MARK: - Helpers

    private func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

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

    /// Feeds one recording's chunks to a coordinator at their real audio-time offsets and drains.
    ///
    /// The pacing is the point. Enqueuing everything at once would measure a drain that never
    /// happens in production; sleeping to each chunk's own offset reproduces the queue depth the
    /// scheduler actually sees, which round 0a measured at a median 6.84 s inter-arrival.
    private func replay(_ stream: ChunkStream,
                        corrector: @escaping (String, Bool) async -> String,
                        widths: @escaping () -> [Int]) async -> Run {
        let coordinator = ChunkLLMCoordinator()
        coordinator.corrector = corrector

        let start = Date()
        var sleptSeconds = 0.0
        let base = stream.chunks.first?.audioOffsetSec ?? 0
        for chunk in stream.chunks {
            let due = chunk.audioOffsetSec - base
            let elapsed = -start.timeIntervalSinceNow
            if due > elapsed {
                let nap = due - elapsed
                sleptSeconds += nap
                try? await Task.sleep(nanoseconds: UInt64(nap * 1_000_000_000))
            }
            coordinator.enqueue(chunkText: chunk.text)
        }
        let released = Date()
        let text = await coordinator.drain()
        let now = Date()
        return Run(text: text,
                   tailSeconds: now.timeIntervalSince(released),
                   correctionSeconds: now.timeIntervalSince(start) - sleptSeconds,
                   batchWidths: widths())
    }

    // MARK: - The gate

    /// Real recordings, real arrival timing, serial correction versus the batched scheduler.
    ///
    /// What this can and cannot show was settled by measurement before it was written. Round 0a
    /// found a median 6.84 s between chunks against a ~0.7 s correction, so most chunks are long
    /// finished before the next one arrives and mid-stream batching has nothing to coalesce. The
    /// win therefore has to come from the drain — whatever is outstanding at release — and the
    /// plan says in that case the gate is re-derived from the measurement rather than asserted
    /// blind at the original 3×. It is asserted here as "the batched path is never slower",
    /// because on sparse arrivals parity *is* the correct result: `BatchedLLMScheduler` routes a
    /// width-1 batch to the single-stream MTP path precisely so the sparse case loses nothing.
    ///
    /// Output is compared on words, not bytes. Batched greedy and single-stream MTP are different
    /// decoders — `BatchedLLMCorrectnessTests` bounds their divergence on identical inputs — so a
    /// byte assertion here would fail on a comma.
    func testRealRecordingWallClock() async throws {
        let corpus = try XCTUnwrap(ChunkStreamCorpus.loadPersisted(),
                                   "no chunk-stream corpus — run testChunkArrivalCharacterisation")
        let streams = corpus.streams
            .filter { $0.chunks.count >= minChunks }
            .sorted { $0.chunks.count > $1.chunks.count }
            .prefix(streamBudget)
        try XCTSkipIf(streams.isEmpty, "no recordings with ≥\(minChunks) chunks in the corpus")

        try await withModel { processor in
            // One warm prefix for both modes, built before the clock starts on either. Fragment
            // mode is what every mid-stream chunk gets, so that is the prompt to warm.
            let fragmentSystem = correctPrompt(for: "x", fragment: true).system
            await processor.ensureWarmPrefix(for: fragmentSystem)

            var rows: [String] = []
            var serialTailTotal = 0.0
            var batchedTailTotal = 0.0
            var serialCorrectionTotal = 0.0
            var batchedCorrectionTotal = 0.0

            for stream in streams {
                let serial = await replay(stream, corrector: { text, fragment in
                    let prompt = correctPrompt(for: text, fragment: fragment)
                    return (try? await processor.process(
                        text: text, systemPrompt: prompt.system, userMessage: prompt.user,
                        repetitionPenalty: correctAIMode.repetitionPenalty,
                        maxTokensCap: correctAIMode.maxTokensCap)) ?? text
                }, widths: { [] })

                let scheduler = BatchedLLMScheduler.forProcessor(
                    processor, repetitionPenalty: correctAIMode.repetitionPenalty)
                let batched = await replay(stream, corrector: { text, fragment in
                    let prompt = correctPrompt(for: text, fragment: fragment)
                    let request = LLMBatchRequest.make(
                        text: text, userMessage: prompt.user,
                        maxTokensCap: correctAIMode.maxTokensCap)
                    return await scheduler.submit(request, instructions: prompt.system)
                }, widths: { scheduler.recentWidths })

                serialTailTotal += serial.tailSeconds
                batchedTailTotal += batched.tailSeconds
                serialCorrectionTotal += serial.correctionSeconds
                batchedCorrectionTotal += batched.correctionSeconds

                let serialWords = words(serial.text).count
                let batchedWords = words(batched.text).count
                let maxWidth = batched.batchWidths.max() ?? 1
                rows.append(String(
                    format: "  %3d chunks %6.0fs audio   tail: serial %5.2fs → batched %5.2fs"
                    + "   widths max %2d   words %d vs %d",
                    stream.chunks.count, stream.durationSec,
                    serial.tailSeconds, batched.tailSeconds, maxWidth,
                    serialWords, batchedWords))

                XCTAssertFalse(batched.text.isEmpty, "batched path returned nothing")
                // Same input, same prompts, same per-row budgets — a batched run that lost a
                // tenth of the user's words relative to serial would be a real defect, not
                // decoder divergence.
                XCTAssertGreaterThan(Double(batchedWords), Double(serialWords) * 0.90,
                                     "batched path lost words the serial path kept "
                                     + "for \(stream.recordingID)")
            }

            let tailSpeedup = serialTailTotal / max(batchedTailTotal, .ulpOfOne)
            let correctionSpeedup = serialCorrectionTotal / max(batchedCorrectionTotal, .ulpOfOne)
            print("""
                  real-recording wall clock — \(streams.count) recordings, real arrival timing
                  \(rows.joined(separator: "\n"))
                  \(String(format: "  release→ready: serial %.1fs · batched %.1fs · %.2fx",
                           serialTailTotal, batchedTailTotal, tailSpeedup))
                  \(String(format: "  correction time (sleep excluded): serial %.1fs · batched "
                           + "%.1fs · %.2fx",
                           serialCorrectionTotal, batchedCorrectionTotal, correctionSpeedup))
                  """)

            // Parity, not a multiple. See the doc comment: on this corpus's arrival rate the
            // honest claim is that batching never costs anything on the streaming path, and the
            // measured wins live in the whole-text and drain populations.
            XCTAssertGreaterThan(tailSpeedup, 0.95,
                                 "the batched scheduler made the post-release pause worse")
        }
    }
}
