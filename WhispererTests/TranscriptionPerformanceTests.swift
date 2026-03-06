//
//  TranscriptionPerformanceTests.swift
//  WhispererTests
//
//  Performance tests for transcription backends (whisper.cpp, Parakeet)
//

import XCTest
@testable import whisperer

final class TranscriptionPerformanceTests: XCTestCase {

    // MARK: - whisper.cpp Latency

    /// Measures end-to-end transcription latency for whisper.cpp on 5s synthetic audio.
    /// Uses Xcode's built-in clock metric for stable wall-clock measurements.
    func testWhisperCppTranscriptionLatency() async throws {
        let bridge = try loadWhisperBridge()
        let samples = BenchmarkUtilities.generateTestAudio(duration: .fiveSeconds)

        // Warmup — prime Metal/GPU caches
        _ = bridge.transcribe(
            samples: Array(samples.prefix(16000)),
            initialPrompt: nil,
            language: .auto,
            singleSegment: false,
            maxTokens: 0
        )

        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric()], options: options) {
            let text = bridge.transcribe(
                samples: samples,
                initialPrompt: nil,
                language: .auto,
                singleSegment: false,
                maxTokens: 0
            )
            // Verify transcription produces output (synthetic audio may or may not produce words)
            XCTAssertNotNil(text)
        }
    }

    // MARK: - whisper.cpp Real-Time Factor

    /// Transcribes 10s of audio and asserts RTF < 1.0 (faster than real-time).
    func testWhisperCppRealTimeFactor() async throws {
        let bridge = try loadWhisperBridge()
        let duration = BenchmarkDuration.tenSeconds
        let samples = BenchmarkUtilities.generateTestAudio(duration: duration)

        // Warmup
        _ = bridge.transcribe(
            samples: Array(samples.prefix(16000)),
            initialPrompt: nil,
            language: .auto,
            singleSegment: false,
            maxTokens: 0
        )

        var rtfs: [Double] = []

        for _ in 1...3 {
            let start = CFAbsoluteTimeGetCurrent()
            let text = bridge.transcribe(
                samples: samples,
                initialPrompt: nil,
                language: .auto,
                singleSegment: false,
                maxTokens: 0
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let rtf = elapsed / duration.seconds

            rtfs.append(rtf)
            NSLog("RTF: \(String(format: "%.3f", rtf))x, latency: \(BenchmarkUtilities.formattedLatency(elapsed * 1000)), words: \(text.split(separator: " ").count)")
        }

        let avgRTF = rtfs.reduce(0, +) / Double(rtfs.count)
        NSLog("Average RTF: \(String(format: "%.3f", avgRTF))x over \(rtfs.count) iterations")

        XCTAssertLessThan(avgRTF, 1.0, "whisper.cpp should transcribe faster than real-time (RTF < 1.0), got \(String(format: "%.3f", avgRTF))x")
    }

    // MARK: - whisper.cpp Memory

    /// Measures memory delta during transcription.
    func testWhisperCppMemoryDelta() async throws {
        let bridge = try loadWhisperBridge()
        let samples = BenchmarkUtilities.generateTestAudio(duration: .tenSeconds)

        // Warmup
        _ = bridge.transcribe(
            samples: Array(samples.prefix(16000)),
            initialPrompt: nil,
            language: .auto,
            singleSegment: false,
            maxTokens: 0
        )

        let baselineMemory = BenchmarkUtilities.currentMemoryMB()

        let text = bridge.transcribe(
            samples: samples,
            initialPrompt: nil,
            language: .auto,
            singleSegment: false,
            maxTokens: 0
        )

        let peakMemory = BenchmarkUtilities.currentMemoryMB()
        let delta = peakMemory - baselineMemory

        NSLog("Memory: baseline=\(BenchmarkUtilities.formattedMemory(baselineMemory)), peak=\(BenchmarkUtilities.formattedMemory(peakMemory)), delta=\(BenchmarkUtilities.formattedMemory(delta)), words=\(text.split(separator: " ").count)")

        // Transcription of 10s audio should not allocate more than 500MB on top of model
        XCTAssertLessThan(delta, 500, "Memory delta during transcription should be < 500MB, got \(BenchmarkUtilities.formattedMemory(delta))")
    }

    // MARK: - whisper.cpp Consistency

    /// Runs multiple iterations and checks latency consistency (stddev within 50% of mean).
    func testWhisperCppLatencyConsistency() async throws {
        let bridge = try loadWhisperBridge()
        let samples = BenchmarkUtilities.generateTestAudio(duration: .fiveSeconds)

        // Warmup
        _ = bridge.transcribe(
            samples: Array(samples.prefix(16000)),
            initialPrompt: nil,
            language: .auto,
            singleSegment: false,
            maxTokens: 0
        )

        var latencies: [Double] = []

        for i in 1...5 {
            let start = CFAbsoluteTimeGetCurrent()
            let text = bridge.transcribe(
                samples: samples,
                initialPrompt: nil,
                language: .auto,
                singleSegment: false,
                maxTokens: 0
            )
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

            latencies.append(elapsed)
            NSLog("Iteration \(i): \(BenchmarkUtilities.formattedLatency(elapsed)), words: \(text.split(separator: " ").count)")
        }

        let mean = latencies.reduce(0, +) / Double(latencies.count)
        let variance = latencies.map { pow($0 - mean, 2) }.reduce(0, +) / Double(latencies.count)
        let stddev = sqrt(variance)
        let cv = stddev / mean // coefficient of variation

        NSLog("Latency stats: mean=\(BenchmarkUtilities.formattedLatency(mean)), stddev=\(String(format: "%.0f", stddev))ms, CV=\(String(format: "%.1f%%", cv * 100))")

        XCTAssertLessThan(cv, 0.5, "Latency coefficient of variation should be < 50%, got \(String(format: "%.1f%%", cv * 100))")
    }

    // MARK: - whisper.cpp Streaming Chunks

    /// Measures single-segment mode performance used during streaming transcription.
    func testWhisperCppStreamingChunkLatency() async throws {
        let bridge = try loadWhisperBridge()
        // 2-second chunk = streaming chunk size
        let samples = BenchmarkUtilities.generateTestAudio(duration: .fiveSeconds)
        let chunkSamples = Array(samples.prefix(32000)) // 2s at 16kHz

        // Warmup
        _ = bridge.transcribe(
            samples: chunkSamples,
            initialPrompt: nil,
            language: .auto,
            singleSegment: true,
            maxTokens: 0
        )

        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric()], options: options) {
            _ = bridge.transcribe(
                samples: chunkSamples,
                initialPrompt: nil,
                language: .auto,
                singleSegment: true,
                maxTokens: 0
            )
        }
    }

    // MARK: - Parakeet Latency

    /// Measures Parakeet transcription latency (Apple Silicon only).
    func testParakeetTranscriptionLatency() async throws {
        try XCTSkipUnless(BackendType.parakeet.isAvailable, "Parakeet requires Apple Silicon")

        let variant = AppState.shared.selectedParakeetModel
        guard FluidAudioBridge.isModelCached(variant: variant) else {
            throw XCTSkip("Parakeet model \(variant.displayName) not cached locally")
        }

        let bridge = try await FluidAudioBridge.loadFromCache(variant: variant)
        let samples = BenchmarkUtilities.generateTestAudio(duration: .fiveSeconds)

        // Warmup
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            bridge.transcribeAsync(
                samples: Array(samples.prefix(16000)),
                initialPrompt: nil,
                language: .auto,
                singleSegment: false,
                maxTokens: 0
            ) { _ in continuation.resume() }
        }

        var latencies: [Double] = []

        for i in 1...3 {
            let start = CFAbsoluteTimeGetCurrent()
            let text: String = await withCheckedContinuation { continuation in
                bridge.transcribeAsync(
                    samples: samples,
                    initialPrompt: nil,
                    language: .auto,
                    singleSegment: false,
                    maxTokens: 0
                ) { result in continuation.resume(returning: result) }
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

            latencies.append(elapsed)
            NSLog("Parakeet iter \(i): \(BenchmarkUtilities.formattedLatency(elapsed)), words: \(text.split(separator: " ").count)")
        }

        let mean = latencies.reduce(0, +) / Double(latencies.count)
        NSLog("Parakeet avg latency: \(BenchmarkUtilities.formattedLatency(mean))")

        bridge.prepareForShutdown()
    }

    // MARK: - Recorded Audio

    /// Transcribes a real WAV recording if one exists in the recordings directory.
    func testTranscriptionWithRecordedAudio() async throws {
        let bridge = try loadWhisperBridge()

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let recordingsDir = appSupport.appendingPathComponent("Whisperer/Recordings")

        guard FileManager.default.fileExists(atPath: recordingsDir.path) else {
            throw XCTSkip("No recordings directory found")
        }

        let files = try FileManager.default.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: nil)
        guard let wavFile = files.first(where: { $0.pathExtension.lowercased() == "wav" }) else {
            throw XCTSkip("No WAV recordings found")
        }

        guard let samples = BenchmarkUtilities.loadSamplesFromRecording(at: wavFile) else {
            throw XCTSkip("Failed to load recording")
        }

        let audioDuration = Double(samples.count) / 16000.0
        NSLog("Testing with recording: \(wavFile.lastPathComponent) (\(String(format: "%.1f", audioDuration))s)")

        let start = CFAbsoluteTimeGetCurrent()
        let text = bridge.transcribe(
            samples: samples,
            initialPrompt: nil,
            language: .auto,
            singleSegment: false,
            maxTokens: 0
        )
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let rtf = (elapsed / 1000.0) / audioDuration

        NSLog("Recorded audio result: \(BenchmarkUtilities.formattedLatency(elapsed)), RTF=\(BenchmarkUtilities.formattedRTF(rtf)), words=\(text.split(separator: " ").count)")
        NSLog("Transcription: \(text.prefix(200))")

        XCTAssertFalse(text.isEmpty, "Transcription of real audio should produce text")
        XCTAssertLessThan(rtf, 1.0, "Should transcribe recorded audio faster than real-time")
    }

    // MARK: - Audio Duration Scaling

    /// Tests how latency scales with audio duration (5s, 10s, 30s).
    func testWhisperCppDurationScaling() async throws {
        let bridge = try loadWhisperBridge()

        // Warmup
        let warmup = BenchmarkUtilities.generateTestAudio(duration: .fiveSeconds)
        _ = bridge.transcribe(
            samples: Array(warmup.prefix(16000)),
            initialPrompt: nil,
            language: .auto,
            singleSegment: false,
            maxTokens: 0
        )

        let durations: [BenchmarkDuration] = [.fiveSeconds, .tenSeconds, .thirtySeconds]
        var results: [(duration: Double, latency: Double, rtf: Double)] = []

        for duration in durations {
            let samples = BenchmarkUtilities.generateTestAudio(duration: duration)

            let start = CFAbsoluteTimeGetCurrent()
            let text = bridge.transcribe(
                samples: samples,
                initialPrompt: nil,
                language: .auto,
                singleSegment: false,
                maxTokens: 0
            )
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let rtf = (elapsed / 1000.0) / duration.seconds

            results.append((duration: duration.seconds, latency: elapsed, rtf: rtf))
            NSLog("\(duration.rawValue): \(BenchmarkUtilities.formattedLatency(elapsed)), RTF=\(BenchmarkUtilities.formattedRTF(rtf)), words=\(text.split(separator: " ").count)")
        }

        // All durations should be faster than real-time
        for result in results {
            XCTAssertLessThan(result.rtf, 1.0, "\(result.duration)s audio should transcribe faster than real-time, got RTF=\(String(format: "%.3f", result.rtf))")
        }
    }

    // MARK: - Helpers

    private func loadWhisperBridge() throws -> WhisperBridge {
        let model = AppState.shared.selectedModel
        let path = ModelDownloader.shared.modelPath(for: model)

        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("whisper.cpp model \(model.displayName) not downloaded at \(path.path)")
        }

        return try WhisperBridge(modelPath: path)
    }
}
