//
//  BatchedLLMThroughputTests.swift
//  WhispererTests
//
//  Measures the batched-decode work against the app's own history: real recordings, real audio,
//  real meetings. Nothing here runs on synthetic text — a benchmark on invented strings would
//  report a batch size that the real chunk-length distribution never produces.
//
//  Every test skips rather than fails when the model or the history database is absent, so the
//  suite stays runnable on a machine that has neither.
//
//  Benchmarks in this file must not run concurrently with each other or with any other model
//  test. Several GB of weights co-resident thrashes unified memory and corrupts the timings
//  being collected, which is the failure `LLMModelComparisonTests` already documents.
//

import XCTest
@testable import whisperer

final class BatchedLLMThroughputTests: XCTestCase {

    // MARK: - Phase 0a — what the real workload actually looks like

    /// Corpus size, chosen so a harvest is about an hour of audio. Every recording is replayed at
    /// wall-clock real time through the full model, so the run costs exactly as long as the
    /// corpus takes to speak; there is no way to make it cheaper without making it a lie.
    private let perBucket = ["short": 20, "medium": 20, "long": 15, "very-long": 3]
    private let perBucketLanguage = 8

    private static let arrivalReportURL =
        URL(fileURLWithPath: "/tmp/whisperer-chunk-arrival.txt")

    /// Replays real recordings and records when each VAD chunk committed, then freezes the result
    /// to `TestData/chunk-stream-corpus.json`.
    ///
    /// This reports; it does not gate. Its output is an *input* to the scheduler's `maxBatch` and
    /// `maxWaitMs`, which is the whole reason it runs before any of them exist. The number to read
    /// is the inter-arrival distribution: if p50 is comfortably larger than a single correction,
    /// mid-stream batching cannot help and the win has to come from the drain at key release and
    /// from the whole-text and meeting paths instead.
    ///
    /// Set `CHUNK_CORPUS_REHARVEST=1` to replay whatever audio is not in the corpus yet; otherwise
    /// an existing corpus is reported on and the model is never loaded.
    ///
    /// The harvest is longer than xcodebuild's default 600s per-test allowance, so it must be run
    /// with `-test-timeouts-enabled NO`. A first attempt without that flag was killed at recording
    /// 31 of 58 — which is why the harvest now checkpoints after every recording and resumes:
    /// losing an hour of real-time replay to a timeout once was enough.
    func testChunkArrivalCharacterisation() async throws {
        let reharvest = ProcessInfo.processInfo.environment["CHUNK_CORPUS_REHARVEST"] == "1"

        let corpus: ChunkStreamCorpus
        if !reharvest, let existing = ChunkStreamCorpus.loadPersisted() {
            report("=== Chunk arrival characterisation — reusing \(ChunkStreamCorpus.fileURL.lastPathComponent) ===")
            report("Set CHUNK_CORPUS_REHARVEST=1 to replay the audio again.")
            corpus = existing
        } else {
            corpus = try await harvestCorpus()
            report("Corpus written to \(ChunkStreamCorpus.fileURL.path)")
        }

        try XCTSkipIf(corpus.streams.isEmpty, "No recordings with usable audio on disk")
        reportCorpus(corpus)

        // The only assertion: the corpus exists and carries chunks. Asserting a particular
        // arrival rate here would be asserting a property of the user's speech.
        XCTAssertFalse(corpus.allChunkTexts.isEmpty,
                       "corpus produced no chunks — the streaming path did not soft-commit anything")
    }

    // MARK: - Harvest

    private func harvestCorpus() async throws -> ChunkStreamCorpus {
        try? FileManager.default.removeItem(at: Self.arrivalReportURL)
        report("=== Chunk arrival characterisation — real audio, real-time feed ===")

        let (fixtures, rejected) = selectChunkStreamFixtures(
            perBucketLanguage: perBucketLanguage, perBucket: perBucket)
        for line in rejected { report("skipped: \(line)") }
        try XCTSkipIf(fixtures.isEmpty, "No history recordings with usable audio on disk")

        // Resume: anything already on disk from an interrupted run is kept and not replayed.
        // The selection is deterministic, so a partial corpus lines up with the fixture list.
        var streams = ChunkStreamCorpus.loadPersisted()?.streams ?? []
        var done = Set(streams.map(\.recordingID))
        let pending = fixtures.filter { !done.contains(String($0.fixture.id.prefix(8)).lowercased()) }
        if !streams.isEmpty {
            report("resuming — \(streams.count) recordings already harvested, \(pending.count) to go")
        }
        guard !pending.isEmpty else { return ChunkStreamCorpus(streams: streams) }

        let totalAudio = pending.reduce(0.0) { $0 + $1.fixture.durationSec }
        report(String(format: "%d recordings, %.1f minutes of audio — this run takes about that long",
                      pending.count, totalAudio / 60))

        // Loaded only once there is real work to do; a pure resume-and-report costs no model.
        let bridge = try loadWhisperBridge()

        for (index, (fixture, samples)) in pending.enumerated() {
            let stream = await harvestChunkStream(fixture, samples: samples, bridge: bridge)
            streams.append(stream)
            done.insert(stream.recordingID)
            // Checkpoint every recording. Each one costs its own duration in real time, so a
            // crash or timeout must never cost more than the recording it happened during.
            try ChunkStreamCorpus(streams: streams).persist()
            // `%@` mangles a bridged Swift String here — see the note on `eagerPad`.
            let tag = eagerPad(stream.recordingID, 9) + eagerPad(stream.bucket, 11)
                    + eagerPad(stream.language, 5)
            report(String(format: "[%3d/%3d] ", index + 1, pending.count) + tag
                   + String(format: "%6.1fs → %3d chunks, feed lag %.1fs",
                            stream.durationSec, stream.chunks.count, stream.maxFeedLagSec))
        }
        return ChunkStreamCorpus(streams: streams)
    }

    // MARK: - Report

    private func reportCorpus(_ corpus: ChunkStreamCorpus) {
        let gaps = corpus.allInterArrivalsSec
        let lengths = corpus.allChunkTexts.map { Double($0.count) }

        report("\n=== Per bucket ===")
        report("bucket      recs  chunks  chunks/rec  chars_p50  chars_p90  gap_p10  gap_p50  gap_p90  maxFeedLag")
        for bucket in ["short", "medium", "long", "very-long"] {
            let inBucket = corpus.streams.filter { $0.bucket == bucket }
            guard !inBucket.isEmpty else { continue }
            let bucketChunks = inBucket.flatMap(\.chunks)
            let bucketGaps = inBucket.flatMap(\.interArrivalsSec)
            let bucketLengths = bucketChunks.map { Double($0.text.count) }
            report(eagerPad(bucket, 10) + String(
                format: "  %4d  %6d  %10.1f  %9.0f  %9.0f  %7.2f  %7.2f  %7.2f  %10.1f",
                inBucket.count, bucketChunks.count,
                Double(bucketChunks.count) / Double(inBucket.count),
                chunkPercentile(bucketLengths, 0.50), chunkPercentile(bucketLengths, 0.90),
                chunkPercentile(bucketGaps, 0.10), chunkPercentile(bucketGaps, 0.50),
                chunkPercentile(bucketGaps, 0.90),
                inBucket.map(\.maxFeedLagSec).max() ?? 0))
        }

        report("\n=== Overall ===")
        report(String(format: "recordings           %d", corpus.streams.count))
        report(String(format: "chunks               %d", corpus.allChunkTexts.count))
        report(String(format: "chunk chars  p50/p90 %.0f / %.0f",
                      chunkPercentile(lengths, 0.50), chunkPercentile(lengths, 0.90)))
        report(String(format: "inter-arrival p10    %.2fs", chunkPercentile(gaps, 0.10)))
        report(String(format: "inter-arrival p50    %.2fs", chunkPercentile(gaps, 0.50)))
        report(String(format: "inter-arrival p90    %.2fs", chunkPercentile(gaps, 0.90)))

        // The figure the scheduler is sized from. A correction at the measured single-stream rate
        // takes roughly 0.7s; how many chunks land inside that window is exactly how large a
        // mid-stream batch can ever be, before any code is written.
        for window in [0.5, 1.0, 2.0] {
            let inWindow = gaps.filter { $0 <= window }.count
            report(String(format: "gaps ≤ %.1fs         %d / %d (%.0f%%)",
                          window, inWindow, gaps.count,
                          gaps.isEmpty ? 0 : 100 * Double(inWindow) / Double(gaps.count)))
        }

        // The drain population: whatever is still outstanding at key release is batchable no
        // matter how sparse arrivals were, so the chunks-per-recording distribution bounds the
        // win available on the path that always works.
        let counts = corpus.streams.map { Double($0.chunks.count) }
        report(String(format: "chunks/recording p50/p90/max  %.0f / %.0f / %.0f",
                      chunkPercentile(counts, 0.50), chunkPercentile(counts, 0.90),
                      counts.max() ?? 0))
        report("\nReport written to \(Self.arrivalReportURL.path)")
    }

    private func report(_ line: String) {
        eagerAppend(line, to: Self.arrivalReportURL)
    }
}
