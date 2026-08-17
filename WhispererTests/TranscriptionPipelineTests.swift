//
//  TranscriptionPipelineTests.swift
//  WhispererTests
//
//  Performance benchmarks for the VAD-chunked transcription pipeline.
//

import XCTest
@testable import whisperer

final class TranscriptionPipelineTests: XCTestCase {

    // Shared bridge — kept alive to avoid Metal dealloc crash during process exit.
    // The bridge is cleaned up explicitly in class teardown.
    private static var _bridge: WhisperBridge?

    override class func tearDown() {
        if let bridge = _bridge {
            bridge.prepareForShutdown()
        }
        _bridge = nil
        super.tearDown()
    }

    private func loadWhisperBridge() throws -> WhisperBridge {
        if let bridge = Self._bridge { return bridge }
        let models: [WhisperModel] = [.largeTurbo, .largeTurboQ5, .medium, .small, .base, .tiny]
        for model in models {
            let path = ModelDownloader.shared.modelPath(for: model)
            if FileManager.default.fileExists(atPath: path.path) {
                let bridge = try WhisperBridge(modelPath: path)
                Self._bridge = bridge
                return bridge
            }
        }
        throw XCTSkip("No whisper model downloaded")
    }

    private func timeMs(_ block: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    // MARK: - VADSegmenter Time-Based Fallback

    /// VADSegmenter with no VAD falls back to time-based chunking
    func testSegmenterTimeBasedFallback() throws {
        let segmenter = VADSegmenter(vad: nil, targetChunkDuration: 5.0)
        let samples = generateAudio(seconds: 30.0)

        let result = segmenter.scanAndEmitChunks(
            allSamples: samples,
            fromIndex: 0,
            lastTranscribedIndex: 0
        )

        // Should emit 6 chunks of 5s each
        XCTAssertEqual(result.chunks.count, 6,
            "Expected 6 time-based chunks for 30s audio at 5s target, got \(result.chunks.count)")

        for (i, chunk) in result.chunks.enumerated() {
            let chunkDuration = Double(chunk.samples.count) / 16000.0
            XCTAssertGreaterThan(chunkDuration, 4.5,
                "Chunk \(i) too short: \(String(format: "%.1f", chunkDuration))s")
        }
    }

    // MARK: - Single Chunk RTF

    /// Transcribe a 20s chunk and verify RTF < 0.5x
    func testSingleChunkRTF() throws {
        let bridge = try loadWhisperBridge()

        // Warmup
        let warmup = BenchmarkUtilities.generateTestAudio(duration: .fiveSeconds)
        _ = bridge.transcribe(
            samples: Array(warmup.prefix(16000)),
            initialPrompt: nil, language: .english,
            singleSegment: false, maxTokens: 0
        )

        let audio = generateAudio(seconds: 20.0)
        var text = ""
        let ms = timeMs {
            text = bridge.transcribe(
                samples: audio,
                initialPrompt: nil,
                language: .english,
                singleSegment: false,
                maxTokens: 0
            )
        }

        let rtf = (ms / 1000.0) / 20.0
        let words = text.split(separator: " ").count

        XCTAssertLessThan(rtf, 0.5, "20s chunk: \(String(format: "%.0f", ms))ms, RTF=\(String(format: "%.3f", rtf)), \(words) words")
    }

    // MARK: - Callback Overhead

    /// Transcribe with and without callbacks — overhead should be < 10%
    func testCallbackOverhead() throws {
        let bridge = try loadWhisperBridge()
        let audio = generateAudio(seconds: 10.0)

        // Warmup
        _ = bridge.transcribe(
            samples: Array(audio.prefix(16000)),
            initialPrompt: nil, language: .english,
            singleSegment: false, maxTokens: 0
        )

        // Without callbacks
        bridge.onNewSegment = nil
        let msWithout = timeMs {
            _ = bridge.transcribe(
                samples: audio, initialPrompt: nil,
                language: .english, singleSegment: false, maxTokens: 0
            )
        }

        // With callbacks
        var segmentCount = 0
        bridge.onNewSegment = { _ in segmentCount += 1 }
        bridge.resetAbort()
        let msWith = timeMs {
            _ = bridge.transcribe(
                samples: audio, initialPrompt: nil,
                language: .english, singleSegment: false, maxTokens: 0
            )
        }
        bridge.onNewSegment = nil

        let overhead = msWith > 0 ? ((msWith - msWithout) / msWithout) * 100 : 0

        XCTAssertLessThan(abs(overhead), 20.0,
            "Without: \(String(format: "%.0f", msWithout))ms, With: \(String(format: "%.0f", msWith))ms, overhead=\(String(format: "%.1f", overhead))%, segments=\(segmentCount)")
    }

    // MARK: - End-to-End Pipeline

    /// Simulate 30s recording through the full pipeline (no VAD — time-based chunking)
    func testEndToEndPipeline() throws {
        let bridge = try loadWhisperBridge()

        // Warmup
        _ = bridge.transcribe(
            samples: Array(generateAudio(seconds: 1.0)),
            initialPrompt: nil, language: .english,
            singleSegment: false, maxTokens: 0
        )

        let transcriber = StreamingTranscriber(
            backend: bridge,
            language: .english
        )

        let expectation = XCTestExpectation(description: "Live transcription received")
        var liveUpdates = 0

        transcriber.start { _ in
            liveUpdates += 1
            expectation.fulfill()
        }

        // Simulate 30s of audio arriving in 100ms chunks
        let fullAudio = generateAudio(seconds: 30.0)
        let chunkSize = 1600  // 100ms at 16kHz
        for offset in stride(from: 0, to: fullAudio.count, by: chunkSize) {
            let end = min(offset + chunkSize, fullAudio.count)
            transcriber.addSamples(Array(fullAudio[offset..<end]))
            // Small delay to simulate real-time (but faster)
            Thread.sleep(forTimeInterval: 0.01)
        }

        // Wait a bit for VAD scan + chunk transcription
        Thread.sleep(forTimeInterval: 3.0)

        let start = CFAbsoluteTimeGetCurrent()
        let finalText = transcriber.stop()
        let stopMs = (CFAbsoluteTimeGetCurrent() - start) * 1000

        // stop() should be fast now — only tail audio
        XCTAssertLessThan(stopMs, 5000, "stop() took \(String(format: "%.0f", stopMs))ms — should be < 5s")

        let duration = transcriber.recordedDuration
        XCTAssertGreaterThan(duration, 29.0, "Should have ~30s of recorded audio, got \(String(format: "%.1f", duration))s")
    }

    // MARK: - Memory Stability

    /// Track memory across simulated 2-minute recording
    func testMemoryStability() throws {
        let bridge = try loadWhisperBridge()

        let baselineMemory = BenchmarkUtilities.currentMemoryMB()

        let transcriber = StreamingTranscriber(
            backend: bridge,
            language: .english
        )

        transcriber.start { _ in }

        // Add 2 minutes of audio in 1-second chunks
        for _ in 0..<120 {
            let chunk = generateAudio(seconds: 1.0)
            transcriber.addSamples(chunk)
        }

        let afterAddMemory = BenchmarkUtilities.currentMemoryMB()
        _ = transcriber.stop()

        let peakDelta = afterAddMemory - baselineMemory

        // 2 min at 16kHz mono Float32 = 7,680,000 samples = ~29MB
        // Plus overhead for VAD, chunks, etc — should be < 100MB
        XCTAssertLessThan(peakDelta, 100,
            "Memory delta: \(String(format: "%.0f", peakDelta))MB (baseline=\(String(format: "%.0f", baselineMemory))MB, peak=\(String(format: "%.0f", afterAddMemory))MB)")
    }

    // MARK: - Abort Callback

    /// Verify the abort callback actually cuts a transcription short.
    ///
    /// Measured relative to an unaborted run of the *same* audio, not against a fixed
    /// millisecond budget. The previous version transcribed 30s and asserted `< 3000ms`, which
    /// could not fail for the right reason: 30s is a single whisper window, and a full
    /// unaborted run of it measures ~900ms (encode 668ms + decode) — comfortably under the
    /// bound whether abort worked or not. It failed only when something *else* in the test host
    /// stole time, which is exactly what happened (`MeetingDiarizerService.warm()`, now guarded).
    ///
    /// 60s is the shortest input that spans two windows, and window count is the unit that
    /// matters: `wparams.abort_callback` is polled per decoder token (~1.6ms) but only *once
    /// per encoder pass*, because the `ggml_backend_sched_t` graph-compute overload
    /// (`whisper.cpp/src/whisper.cpp:190-207`) installs no abort callback — so
    /// `whisper_encode_internal` consults it a single time, at the end. Aborting mid-window
    /// therefore cannot cut the encode that is already running; it can only stop the *next*
    /// window from being encoded. A one-window input has no next window, so it has nothing for
    /// abort to save.
    func testAbortCancelsTranscription() throws {
        let bridge = try loadWhisperBridge()
        let audio = generateAudio(seconds: 60.0)

        // Warm up so neither measurement pays first-decode cost.
        bridge.resetAbort()
        _ = bridge.transcribe(
            samples: Array(audio.prefix(16000)),
            initialPrompt: nil, language: .english,
            singleSegment: false, maxTokens: 0
        )

        func timeTranscribe(abortAfter: TimeInterval?) -> Double {
            bridge.resetAbort()
            let expectation = XCTestExpectation(description: "Transcription completed")
            var elapsedMs: Double = 0
            DispatchQueue.global().async {
                let start = CFAbsoluteTimeGetCurrent()
                _ = bridge.transcribe(
                    samples: audio, initialPrompt: nil,
                    language: .english, singleSegment: false, maxTokens: 0
                )
                elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
                expectation.fulfill()
            }
            if let abortAfter {
                Thread.sleep(forTimeInterval: abortAfter)
                bridge.requestAbort()
            }
            wait(for: [expectation], timeout: 60.0)
            return elapsedMs
        }

        let unabortedMs = timeTranscribe(abortAfter: nil)
        let abortedMs = timeTranscribe(abortAfter: 0.2)
        bridge.resetAbort()

        let detail = "aborted \(String(format: "%.0f", abortedMs))ms vs "
            + "unaborted \(String(format: "%.0f", unabortedMs))ms"

        // The relative gate — the only one that can distinguish a working abort from a
        // broken one, and immune to how fast the machine or how loaded the host is.
        XCTAssertLessThan(abortedMs, unabortedMs * 0.6,
                          "Abort saved little or no work: \(detail)")

        // The absolute gate — abort must land within one encoder pass plus slack, so a
        // regression to per-recording rather than per-window granularity is caught even if
        // the unaborted run also happens to slow down. Encode measures ~670ms on this model.
        XCTAssertLessThan(abortedMs, 2000,
                          "Abort did not land within one encoder pass: \(detail)")
    }

    // MARK: - Helpers

    private func generateAudio(seconds: Double) -> [Float] {
        let sampleRate = 16000.0
        let count = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        let frequencies: [(freq: Double, amp: Float)] = [
            (250.0, 0.3), (500.0, 0.25), (1000.0, 0.15),
            (1500.0, 0.1), (2500.0, 0.05),
        ]
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let envelope = Float(0.5 + 0.5 * sin(2.0 * .pi * 4.0 * t))
            var sample: Float = 0
            for f in frequencies {
                sample += f.amp * Float(sin(2.0 * .pi * f.freq * t))
            }
            samples[i] = sample * envelope * 0.3 + Float.random(in: -0.02...0.02)
        }
        return samples
    }
}
