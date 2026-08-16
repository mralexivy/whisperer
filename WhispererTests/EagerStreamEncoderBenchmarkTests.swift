//
//  EagerStreamEncoderBenchmarkTests.swift
//  WhispererTests
//
//  Phase 0b of the eager-streaming plan: measure whether the ANE encoder or a Metal
//  encoder with a window-sized `audio_ctx` gives the lower per-pass latency on
//  `largeTurboQ5`. The eager stream re-decodes the unconfirmed window every pass, so this
//  latency IS the live-preview cadence and the floor on stop-insert delay.
//
//  The two configurations are mutually exclusive. `whisper_coreml_encode` builds a
//  fixed-shape MLMultiArray from the full 1500-frame mel and silently ignores `audio_ctx`,
//  and Core ML is loaded purely on `.mlmodelc` file presence in `whisper_init_state` with
//  no cparams opt-out. Measuring config B therefore means moving the `.mlmodelc` aside and
//  building a fresh context — which is what `withCoreMLDisabled` does, restoring it in a
//  `defer` so an aborted run cannot leave the user's install without its ANE encoder.
//
//  Throwaway harness: the numbers are the deliverable. They set
//  `EagerStreamConfig.passInterval` and the `audioCtx` argument threaded through
//  `WhisperBridge.transcribeStreamingAsync`.
//

import XCTest
@testable import whisperer

final class EagerStreamEncoderBenchmarkTests: XCTestCase {

    /// Window lengths that bracket what the eager stream actually decodes: a fresh window
    /// just after a soft-commit, a typical mid-stream window, and one that has grown to the
    /// 6s soft-commit boundary plus decode lag.
    private let windowSeconds: [Double] = [3, 6, 12]

    /// Repeats per measurement. Decoding is greedy at `temperature = 0`, so text must be
    /// identical across repeats; only latency varies.
    private let repeats = 3

    private let sampleRate: Double = 16000

    /// Crash-safe restore. A `defer` cannot run if the test process aborts — and this harness
    /// creates and destroys large whisper contexts, which is exactly when that happens. Left
    /// unrestored, the user's install silently loses its ANE encoder and every transcription
    /// gets slower with no visible cause. Sweeping at setUp means the *next* run repairs it
    /// even if the previous one died mid-measurement.
    override func setUp() {
        super.setUp()
        restoreParkedEncoders()
    }

    override func tearDown() {
        restoreParkedEncoders()
        super.tearDown()
    }

    private func restoreParkedEncoders() {
        let fm = FileManager.default
        let dir = ModelDownloader.shared.modelPath(for: .largeTurboQ5).deletingLastPathComponent()
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for parked in contents where parked.pathExtension == "benchmark-parked" {
            let original = parked.deletingPathExtension()
            try? fm.removeItem(at: original)
            try? fm.moveItem(at: parked, to: original)
            print("BENCH restored parked encoder: \(original.lastPathComponent)")
        }
    }

    // MARK: - Benchmark

    /// The two configurations are deliberately separate test methods, run as separate
    /// `xcodebuild` invocations. Creating and tearing down two `largeTurboQ5` contexts in one
    /// process reliably aborts in `whisper_free` with `pointer being freed was not allocated`
    /// — a teardown-ordering problem between the Metal backend and the Core ML encoder that is
    /// a harness concern only (the app creates its context once and keeps it). One context per
    /// process sidesteps it without pretending the numbers came from a single run.
    func testConfigA_ANEDefaultContext() throws {
        let modelPath = try modelPathOrSkip()
        let samples = try longestFixtureSamples(minimumSeconds: windowSeconds.max() ?? 12)
        let rows = try measureConfiguration(
            label: "A: ANE (audio_ctx=0)",
            modelPath: modelPath,
            samples: samples,
            audioCtxForWindow: { _ in 0 }
        )
        report(label: "A: ANE encoder, default 30s mel", rows: rows)
        XCTAssertEqual(rows.count, windowSeconds.count, "config A did not produce a full row set")
    }

    func testConfigB_MetalSizedAudioCtx() throws {
        let model = WhisperModel.largeTurboQ5
        let modelPath = try modelPathOrSkip()
        let samples = try longestFixtureSamples(minimumSeconds: windowSeconds.max() ?? 12)
        let metalOnlyPath = try coreMLFreeModelPath(model: model, modelPath: modelPath)
        let rows = try measureConfiguration(
            label: "B: Metal (audio_ctx sized)",
            modelPath: metalOnlyPath,
            samples: samples,
            audioCtxForWindow: Self.audioCtx(forWindowSeconds:)
        )
        report(label: "B: Metal encoder, window-sized audio_ctx", rows: rows)
        XCTAssertEqual(rows.count, windowSeconds.count, "config B did not produce a full row set")
    }

    private func modelPathOrSkip() throws -> URL {
        let modelPath = ModelDownloader.shared.modelPath(for: .largeTurboQ5)
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw XCTSkip("largeTurboQ5 not downloaded — run the app and fetch it first")
        }
        return modelPath
    }

    // MARK: - Measurement

    private struct BenchmarkRow {
        let windowSeconds: Double
        let audioCtx: Int32
        let medianLatency: Double
        let words: Int
        let text: String
        let deterministic: Bool
    }

    /// `audio_ctx` frames for a window: whisper's encoder runs at 1500 frames per 30s, and
    /// the value is rounded up to a multiple of 256 because the attention kernels are tiled.
    static func audioCtx(forWindowSeconds seconds: Double) -> Int32 {
        let exact = ceil(seconds / 30.0 * 1500.0)
        let padded = (ceil(exact / 256.0) * 256.0)
        return Int32(min(padded, 1500))
    }

    private func measureConfiguration(
        label: String,
        modelPath: URL,
        samples: [Float],
        audioCtxForWindow: (Double) -> Int32
    ) throws -> [BenchmarkRow] {
        // Fresh bridge per configuration — the Core ML decision is made once, in
        // whisper_init_state, so reusing a context would measure the wrong encoder.
        // Intentionally not torn down: see the note on the test methods. The process exits
        // right after this returns, so the context is reclaimed by the OS either way.
        let bridge = try WhisperBridge(modelPath: modelPath)

        var rows: [BenchmarkRow] = []
        for seconds in windowSeconds {
            let count = min(Int(seconds * sampleRate), samples.count)
            let window = Array(samples.prefix(count))
            let audioCtx = audioCtxForWindow(seconds)

            var latencies: [Double] = []
            var texts: [String] = []
            for _ in 0..<repeats {
                let started = Date()
                let result = try decodeStreaming(bridge: bridge, samples: window, audioCtx: audioCtx)
                latencies.append(Date().timeIntervalSince(started))
                texts.append(result.words.map(\.text).joined().trimmingCharacters(in: .whitespaces))
            }
            latencies.sort()
            rows.append(BenchmarkRow(
                windowSeconds: seconds,
                audioCtx: audioCtx,
                medianLatency: latencies[latencies.count / 2],
                words: texts[0].split(separator: " ").count,
                text: texts[0],
                deterministic: Set(texts).count == 1
            ))
            // Appended per row rather than printed in a summary at the end: this process
            // aborts on exit while tearing down the whisper context, which discards anything
            // still sitting in stdout's buffer — including a report printed one line too late.
            appendResult("""
                [\(label)] window=\(Int(seconds))s audio_ctx=\(audioCtx) \
                median=\(String(format: "%.3f", latencies[latencies.count / 2]))s \
                words=\(texts[0].split(separator: " ").count) \
                deterministic=\(Set(texts).count == 1)
                    text: \(texts[0])
                """)
        }
        return rows
    }

    private func decodeStreaming(
        bridge: WhisperBridge,
        samples: [Float],
        audioCtx: Int32
    ) throws -> WhisperStreamResult {
        let expectation = expectation(description: "streaming decode")
        var captured: WhisperStreamResult?
        bridge.transcribeStreamingAsync(
            samples: samples,
            language: .english,
            initialPrompt: nil,
            audioCtx: audioCtx
        ) { result in
            captured = result
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 120)
        return try XCTUnwrap(captured, "streaming decode returned nil")
    }

    // MARK: - Core ML toggle

    /// A model path in a scratch directory that whisper.cpp will load *without* the Core ML
    /// encoder, leaving the user's install completely untouched.
    ///
    /// whisper.cpp decides on Core ML purely by looking for `<model>-encoder.mlmodelc`
    /// alongside the `.bin` it was handed. So a symlink to the real weights in an otherwise
    /// empty directory gets the Metal encoder with no copy and no mutation. The earlier version
    /// of this helper moved the real `.mlmodelc` aside and restored it in a `defer` — that
    /// `defer` does not run when the test process aborts, which it did, twice, leaving the
    /// install without its ANE encoder. Never mutate the user's model directory to run a
    /// measurement.
    private func coreMLFreeModelPath(model: WhisperModel, modelPath: URL) throws -> URL {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("whisperer-bench-nocoreml", isDirectory: true)
        try? fm.removeItem(at: scratch)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let linked = scratch.appendingPathComponent(modelPath.lastPathComponent)
        try fm.createSymbolicLink(at: linked, withDestinationURL: modelPath)

        if let dirName = model.coreMLEncoderDirectoryName {
            let stray = scratch.appendingPathComponent(dirName)
            XCTAssertFalse(fm.fileExists(atPath: stray.path),
                           "scratch dir must not contain an encoder, or this measures config A again")
        }
        return linked
    }

    // MARK: - Corpus

    private func longestFixtureSamples(minimumSeconds: Double) throws -> [Float] {
        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 300)
            .filter { $0.audioURL != nil }
        guard !fixtures.isEmpty else {
            throw XCTSkip("No history recordings with audio on disk")
        }
        for fixture in fixtures {
            guard let url = fixture.audioURL,
                  let samples = try? loadAudioSamples(from: url),
                  Double(samples.count) / sampleRate >= minimumSeconds else { continue }
            return samples
        }
        throw XCTSkip("No history recording is at least \(Int(minimumSeconds))s long")
    }

    // MARK: - Report

    /// Results file, appended to as each measurement lands. Survives the teardown abort.
    static let resultsURL = URL(fileURLWithPath: "/tmp/whisperer-encoder-bench.txt")

    private func appendResult(_ line: String) {
        print(line)
        let payload = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: Self.resultsURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: Self.resultsURL)
        }
    }

    private func report(label: String, rows: [BenchmarkRow]) {
        print("\n=== BENCH \(label) (largeTurboQ5) ===")
        print("BENCH window | median  | audio_ctx | words | deterministic")
        for row in rows {
            print(String(
                format: "BENCH %5.0fs | %6.3fs | %9d | %5d | %@",
                row.windowSeconds, row.medianLatency, row.audioCtx, row.words,
                row.deterministic ? "yes" : "NO"
            ))
        }
        for row in rows {
            print("BENCH TEXT \(Int(row.windowSeconds))s: \(row.text)")
        }
        print("")
    }
}
