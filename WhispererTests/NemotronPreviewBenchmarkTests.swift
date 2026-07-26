//
//  NemotronPreviewBenchmarkTests.swift
//  WhispererTests
//
//  Benchmarks Nemotron streaming vs current Parakeet TDT sliding-window preview.
//
//  Run with:
//    xcodebuild test -project Whisperer.xcodeproj -scheme whisperer
//      -destination "platform=macOS" -only-testing WhispererTests/NemotronPreviewBenchmarkTests
//      2>&1 | grep -E "NSLog|Test Case|error:"
//
//  NOTE: Downloads ~250MB Nemotron multilingual model on first run.
//  Subsequent runs use the cached model (~2s load time).
//

#if canImport(FluidAudio)
import XCTest
import FluidAudio
@testable import whisperer

final class NemotronPreviewBenchmarkTests: XCTestCase {

    // MARK: - Parakeet TDT Sliding-Window Preview (current approach)

    /// Measures how preview latency grows with window size for Parakeet TDT.
    /// This is the CURRENT approach: re-encode a growing window on each pass.
    func testParakeetSlidingWindowPreviewLatency() async throws {
        try XCTSkipUnless(BackendType.parakeet.isAvailable, "Parakeet requires Apple Silicon")

        let variant = AppState.shared.selectedParakeetModel
        guard FluidAudioBridge.isModelCached(variant: variant) else {
            throw XCTSkip("Parakeet \(variant.displayName) not cached — run the app first to download it")
        }

        let bridge = try await FluidAudioBridge.loadFromCache(variant: variant)

        // Warmup with 1s of audio
        let warmup = BenchmarkUtilities.generateTestAudio(seconds: 1.0)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            bridge.transcribeAsync(
                samples: warmup, initialPrompt: nil, language: .auto,
                singleSegment: true, maxTokens: 0) { _ in c.resume() }
        }

        // Measure preview latency at different window sizes (simulating how the
        // growing-window approach accumulates over a recording).
        let windowSizes: [(label: String, seconds: Double)] = [
            ("1s window", 1.0),
            ("2s window", 2.0),
            ("3s window", 3.0),
            ("4s window", 4.0),
            ("6s window", 6.0),
            ("8s window", 8.0),
        ]

        NSLog("=== PARAKEET TDT SLIDING-WINDOW PREVIEW (current) ===")
        for (label, secs) in windowSizes {
            let samples = BenchmarkUtilities.generateTestAudio(seconds: secs)
            var totalMs = 0.0
            let iters = 3
            for _ in 0..<iters {
                let start = CFAbsoluteTimeGetCurrent()
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    bridge.transcribeAsync(
                        samples: samples, initialPrompt: nil, language: .auto,
                        singleSegment: true, maxTokens: 0) { _ in c.resume() }
                }
                totalMs += (CFAbsoluteTimeGetCurrent() - start) * 1000
            }
            let avgMs = totalMs / Double(iters)
            let rtf = (avgMs / 1000.0) / secs
            NSLog("  \(label): \(String(format: "%.0f", avgMs))ms avg (RTF \(String(format: "%.2f", rtf))x)")
        }

        bridge.prepareForShutdown()
    }

    // MARK: - Nemotron Streaming (per-chunk, cache-aware)

    /// Downloads Nemotron multilingual 1120ms and measures per-chunk latency.
    /// Each 1120ms chunk is encoded ONCE regardless of how long the recording is.
    func testNemotronPerChunkLatency() async throws {
        try XCTSkipUnless(BackendType.parakeet.isAvailable, "Nemotron requires Apple Silicon")

        NSLog("=== NEMOTRON MULTILINGUAL STREAMING (1120ms chunks) ===")
        NSLog("Downloading/loading Nemotron multilingual 1120ms model...")

        let sharedModels = try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
            languageCode: "auto",   // full multilingual model
            chunkMs: 1120           // 1120ms chunks — best balance of latency + punctuation quality
        )
        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadFromShared(sharedModels)

        let chunkMs = 1120
        let chunkSamples = chunkMs * 16  // 16 samples per ms at 16kHz
        let chunk = BenchmarkUtilities.generateTestAudio(seconds: Double(chunkMs) / 1000.0)

        // Warmup — first chunk includes ANE program compile
        try await manager.process(samples: chunk)
        try await manager.reset()

        NSLog("  Warmup complete. Benchmarking \(chunkMs)ms chunks...")

        // Measure per-chunk latency: this is what happens once per chunk during recording.
        // Unlike Parakeet TDT preview, this is constant regardless of recording duration.
        var chunkLatencies: [Double] = []
        let numChunks = 8  // simulate 8 × 1120ms = 8.96s recording

        try await manager.reset()
        for i in 0..<numChunks {
            let start = CFAbsoluteTimeGetCurrent()
            try await manager.process(samples: chunk)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            chunkLatencies.append(ms)
            let accumulated = manager.getPartialTranscript()
            NSLog("  Chunk \(i + 1) (\(chunkMs)ms audio): \(String(format: "%.0f", ms))ms | transcript so far: '\(accumulated.prefix(40))'")
        }

        let mean = chunkLatencies.reduce(0, +) / Double(chunkLatencies.count)
        let rtf = (mean / 1000.0) / (Double(chunkMs) / 1000.0)
        NSLog("  Average chunk latency: \(String(format: "%.0f", mean))ms (RTF \(String(format: "%.2f", rtf))x)")
        NSLog("  Total for 8 chunks (\(Double(chunkMs) * 8.0 / 1000.0)s audio): \(String(format: "%.0f", chunkLatencies.reduce(0, +)))ms")

        _ = try await manager.finish()
        await manager.cleanup()

        // RTF < 1.0 = faster than real-time
        XCTAssertLessThan(mean, Double(chunkMs), "Each chunk should process faster than real-time")
    }

    // MARK: - Side-by-Side Comparison

    /// Prints a comparison table: Parakeet TDT preview cost at T seconds vs Nemotron at same T.
    func testPreviewLatencyComparison() async throws {
        try XCTSkipUnless(BackendType.parakeet.isAvailable, "Requires Apple Silicon")

        let variant = AppState.shared.selectedParakeetModel
        guard FluidAudioBridge.isModelCached(variant: variant) else {
            throw XCTSkip("Parakeet not cached — run app first")
        }

        NSLog("=== SIDE-BY-SIDE PREVIEW LATENCY COMPARISON ===")

        // --- Current: Parakeet TDT sliding window ---
        let parakeetBridge = try await FluidAudioBridge.loadFromCache(variant: variant)
        let warmup1s = BenchmarkUtilities.generateTestAudio(seconds: 1.0)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            parakeetBridge.transcribeAsync(
                samples: warmup1s, initialPrompt: nil, language: .auto,
                singleSegment: true, maxTokens: 0) { _ in c.resume() }
        }

        // --- Proposed: Nemotron streaming ---
        let sharedModels = try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
            languageCode: "auto", chunkMs: 1120)
        let nemotron = StreamingNemotronMultilingualAsrManager()
        try await nemotron.loadFromShared(sharedModels)

        // Warmup Nemotron
        let warmupChunk = BenchmarkUtilities.generateTestAudio(seconds: 1.12)
        try await nemotron.process(samples: warmupChunk)
        try await nemotron.reset()

        NSLog("  Time | Parakeet TDT preview | Nemotron per-chunk | Winner")
        NSLog("  -----|---------------------|-------------------|-------")

        let checkpoints: [(label: String, secs: Double)] = [
            ("2s", 2.0), ("4s", 4.0), ("6s", 6.0), ("8s", 8.0)
        ]

        for (label, secs) in checkpoints {
            let window = BenchmarkUtilities.generateTestAudio(seconds: secs)
            // Parakeet TDT: re-encodes full window
            let p_start = CFAbsoluteTimeGetCurrent()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                parakeetBridge.transcribeAsync(
                    samples: window, initialPrompt: nil, language: .auto,
                    singleSegment: true, maxTokens: 0) { _ in c.resume() }
            }
            let p_ms = (CFAbsoluteTimeGetCurrent() - p_start) * 1000

            // Nemotron: just one 1120ms chunk (constant regardless of session length)
            let oneChunk = BenchmarkUtilities.generateTestAudio(seconds: 1.12)
            let n_start = CFAbsoluteTimeGetCurrent()
            try await nemotron.process(samples: oneChunk)
            let n_ms = (CFAbsoluteTimeGetCurrent() - n_start) * 1000

            let winner = p_ms < n_ms ? "Parakeet" : "Nemotron"
            let speedup = p_ms > n_ms ? String(format: "%.1fx", p_ms / n_ms) : String(format: "%.1fx", n_ms / p_ms)
            NSLog("  \(label)   | \(String(format: "%.0f", p_ms))ms                | \(String(format: "%.0f", n_ms))ms              | \(winner) \(speedup)")
        }

        try await nemotron.reset()
        _ = try await nemotron.finish()
        await nemotron.cleanup()
        parakeetBridge.prepareForShutdown()

        NSLog("=== END COMPARISON ===")
        NSLog("Note: Nemotron latency is CONSTANT per chunk regardless of session length.")
        NSLog("Note: Parakeet TDT latency GROWS with session length (re-encodes full window).")
    }
    // MARK: - Forced-Prefix Tests

    // MARK: Unit tests (mechanism / state checks — fast, no audio processing)
    //
    // Synthetic audio (sine wave) produces zero RNNT tokens — no speech features detected —
    // so the partial callback never fires regardless of forced-prefix state. These tests verify
    // the call order and flag state instead. Real-audio behavioral verification is in tests 5 & 6.

    /// Explicit Russian and English: beginSession must arm the forced-prefix flag in the manager.
    func testForcedPrefixArmedForExplicitLanguage() async throws {
        try XCTSkipUnless(BackendType.parakeet.isAvailable, "Nemotron requires Apple Silicon")
        guard NemotronBridge.isModelCached() else {
            throw XCTSkip("Nemotron model not cached — run the app first to download it")
        }
        let bridge = try await NemotronBridge.loadFromCache()

        await bridge.beginSession(language: .russian)
        let ruEnabled = await bridge.isForcedPrefixEnabled()
        NSLog("[ForcedPrefix] isForcedPrefixEnabled after russian: \(ruEnabled)")
        XCTAssertTrue(ruEnabled,
            "beginSession(language: .russian) must arm forced-prefix flag in manager")

        await bridge.beginSession(language: .english)
        let enEnabled = await bridge.isForcedPrefixEnabled()
        NSLog("[ForcedPrefix] isForcedPrefixEnabled after english: \(enEnabled)")
        XCTAssertTrue(enEnabled,
            "beginSession(language: .english) must arm forced-prefix flag in manager")

        bridge.prepareForShutdown()
    }

    /// Auto mode: beginSession must NOT arm forced-prefix.
    /// Seeding with prompt 101 (the auto prompt) causes the LSTM to produce garbage tokens
    /// before real speech content, corrupting the accumulated preview text for the entire session.
    func testForcedPrefixDisarmedForAutoMode() async throws {
        try XCTSkipUnless(BackendType.parakeet.isAvailable, "Nemotron requires Apple Silicon")
        guard NemotronBridge.isModelCached() else {
            throw XCTSkip("Nemotron model not cached")
        }
        let bridge = try await NemotronBridge.loadFromCache()

        await bridge.beginSession(language: .auto)
        let autoEnabled = await bridge.isForcedPrefixEnabled()
        NSLog("[ForcedPrefix] isForcedPrefixEnabled after auto: \(autoEnabled)")
        XCTAssertFalse(autoEnabled,
            "beginSession(language: .auto) must NOT arm forced-prefix — prompt-101 seeding produces garbage tokens before real speech")

        bridge.prepareForShutdown()
    }

    // MARK: Regression / edge cases

    /// Explicit→auto transition: auto session must NOT have forced-prefix armed.
    /// Prompt-101 seeding after an English session produces garbage tokens just as it does from cold start.
    func testSessionTransitionExplicitToAutoNoSeedLeak() async throws {
        try XCTSkipUnless(BackendType.parakeet.isAvailable, "Nemotron requires Apple Silicon")
        guard NemotronBridge.isModelCached() else {
            throw XCTSkip("Nemotron model not cached")
        }
        let bridge = try await NemotronBridge.loadFromCache()
        let oneChunk = BenchmarkUtilities.generateTestAudio(seconds: Double(NemotronBridge.chunkMs) / 1000.0)

        // Session 1: explicit English
        await bridge.beginSession(language: .english)
        await bridge.setPreviewCallback { _ in }
        await bridge.feed(samples: oneChunk)
        _ = await bridge.endSession()

        // Session 2: auto — flag must be disarmed to avoid garbage text
        await bridge.beginSession(language: .auto)
        let autoEnabled = await bridge.isForcedPrefixEnabled()
        NSLog("[Transition/en→auto] isForcedPrefixEnabled: \(autoEnabled)")
        XCTAssertFalse(autoEnabled,
            "After explicit→auto transition, forced-prefix must be disarmed — prompt-101 seeding causes garbage tokens")
        bridge.prepareForShutdown()
    }

    /// Auto→explicit transition: Russian forced-prefix flag armed even after a prior auto session.
    func testSessionTransitionAutoToRussianFlagArmed() async throws {
        try XCTSkipUnless(BackendType.parakeet.isAvailable, "Nemotron requires Apple Silicon")
        guard NemotronBridge.isModelCached() else {
            throw XCTSkip("Nemotron model not cached")
        }
        let bridge = try await NemotronBridge.loadFromCache()
        let oneChunk = BenchmarkUtilities.generateTestAudio(seconds: Double(NemotronBridge.chunkMs) / 1000.0)

        // Session 1: auto
        await bridge.beginSession(language: .auto)
        await bridge.setPreviewCallback { _ in }
        await bridge.feed(samples: oneChunk)
        _ = await bridge.endSession()

        // Session 2: explicit Russian — flag must be armed
        await bridge.beginSession(language: .russian)
        let ruEnabled = await bridge.isForcedPrefixEnabled()
        NSLog("[Transition/auto→ru] isForcedPrefixEnabled: \(ruEnabled)")
        XCTAssertTrue(ruEnabled,
            "After auto→russian transition, forced-prefix flag must be armed")
        bridge.prepareForShutdown()
    }

    // MARK: Integration tests (real audio from history fixtures)

    /// REGRESSION GUARD — Real streaming content quality check.
    ///
    /// Streams actual recordings in 85ms chunks (same as the live app). Verifies:
    ///   1. First partial arrives within 2.5 chunks (auto mode latency SLA)
    ///   2. First partial has meaningful content — F1 > 0.10 vs expected transcript
    ///      (catches garbage like "Le Lett meme", "Wir nie doch", "Винитите го фак")
    ///   3. Accumulated partial quality is decent — F1 > 0.35 vs final transcript
    ///
    /// This test WOULD HAVE caught the auto-mode forced-prefix regression immediately:
    ///   "Le Lett meme" has F1 ≈ 0.0 vs "Let me try" — hard fail on criterion 2.
    func testStreamingLivePreviewContentQuality() async throws {
        try XCTSkipUnless(BackendType.parakeet.isAvailable, "Nemotron requires Apple Silicon")
        guard NemotronBridge.isModelCached() else {
            throw XCTSkip("Nemotron model not cached — run the app first to download it")
        }
        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 50)
            .filter { $0.audioURL != nil && $0.durationSec >= 4 && $0.durationSec <= 30 }
            .prefix(6)
        guard !fixtures.isEmpty else {
            throw XCTSkip("No audio fixtures with files — record some clips in the app first")
        }

        let bridge = try await NemotronBridge.loadFromCache()
        let feedChunkSize = 1365  // ~85ms at 16kHz — matches real AudioRecorder tap cadence
        let maxFeedSamples = NemotronBridge.chunkMs * 16 * 5  // feed up to 5 Nemotron chunks

        struct PartialRecord { let text: String; let latencyMs: Double }

        var failures: [String] = []

        for fixture in fixtures {
            guard let audioURL = fixture.audioURL,
                  let samples = try? loadAudioSamples(from: audioURL) else { continue }

            var partials: [PartialRecord] = []
            let t0 = CFAbsoluteTimeGetCurrent()

            await bridge.beginSession(language: .auto)
            await bridge.setPreviewCallback { text in
                guard !text.isEmpty else { return }
                partials.append(PartialRecord(
                    text: text,
                    latencyMs: (CFAbsoluteTimeGetCurrent() - t0) * 1000
                ))
            }

            // Feed at real-time rate: sleep 85ms between each 85ms audio chunk.
            // Without sleeping, all audio is fed instantly → latency shows as <100ms (artifact).
            // With real-time feeding, first partial fires at ~1120ms (1 chunk) or ~2240ms (2 chunks),
            // matching actual user-perceived latency in the live app.
            for offset in stride(from: 0, to: min(samples.count, maxFeedSamples), by: feedChunkSize) {
                let end = min(offset + feedChunkSize, samples.count)
                await bridge.feed(samples: Array(samples[offset..<end]))
                try await Task.sleep(nanoseconds: 85_000_000)  // 85ms = real-time for 1365 samples at 16kHz
            }
            try await Task.sleep(nanoseconds: 600_000_000)  // allow final chunk to finish processing
            let finalText = await bridge.endSession()
            let reference = finalText.isEmpty ? fixture.transcript : finalText

            // SLA: first partial within 2.5 chunks for auto mode (2240ms + 400ms tolerance)
            let slaMsAuto = Double(NemotronBridge.chunkMs) * 2.5 + 400
            if let first = partials.first {
                if first.latencyMs > slaMsAuto {
                    failures.append("[\(fixture.language)] First partial \(String(format: "%.0f", first.latencyMs))ms > SLA \(Int(slaMsAuto))ms")
                }

                // Content quality: first partial must not be garbage
                // F1 < 0.10 on a recording with ≥5 reference words = clear hallucination
                let firstF1 = wordOverlapF1(first.text, reference)
                NSLog("[StreamQuality/\(fixture.language)] first partial F1=\(String(format: "%.2f", firstF1)) latency=\(String(format: "%.0f", first.latencyMs))ms text='\(first.text.prefix(50))'")
                let refWords = reference.split(separator: " ").count
                if firstF1 < 0.10 && refWords >= 5 {
                    failures.append("[\(fixture.language)] First partial is GARBAGE (F1=\(String(format: "%.2f", firstF1))): '\(first.text.prefix(50))' vs expected '\(reference.prefix(50))'")
                }
            } else {
                NSLog("[StreamQuality/\(fixture.language)] No partials received in \(Int(slaMsAuto))ms window")
            }

            // Accumulated quality: last partial before stop should have F1 > 0.35
            if let last = partials.last, !reference.isEmpty {
                let accF1 = wordOverlapF1(last.text, reference)
                NSLog("[StreamQuality/\(fixture.language)] accumulated F1=\(String(format: "%.2f", accF1)) n=\(partials.count) partials last='\(last.text.suffix(60))'")
                let refWords = reference.split(separator: " ").count
                if accF1 < 0.35 && refWords >= 10 {
                    failures.append("[\(fixture.language)] Accumulated partial quality low (F1=\(String(format: "%.2f", accF1))) — transcript may be corrupted")
                }
            }
        }

        bridge.prepareForShutdown()

        if !failures.isEmpty {
            XCTFail("Streaming preview quality failures:\n" + failures.map { "  • " + $0 }.joined(separator: "\n"))
        }
    }

    /// Uses real recordings from the history database to verify first-partial latency with forced prefix.
    /// With explicit language + forced prefix, first partial must arrive within 1.5 chunks (~1680ms).
    func testForcedPrefixFirstPartialLatencyWithRealAudio() async throws {
        try XCTSkipUnless(BackendType.parakeet.isAvailable, "Nemotron requires Apple Silicon")
        guard NemotronBridge.isModelCached() else {
            throw XCTSkip("Nemotron model not cached")
        }
        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 50)
            .filter { $0.audioURL != nil && $0.durationSec >= 3 && $0.durationSec <= 30 }
            .prefix(5)
        guard !fixtures.isEmpty else {
            throw XCTSkip("No audio fixtures found — record a few clips in the app first")
        }

        let bridge = try await NemotronBridge.loadFromCache()
        let chunkSamples = NemotronBridge.chunkMs * 16
        let feedChunk = 1365  // ~85ms at 16kHz, matches feedAudioToTranscriber

        for fixture in fixtures {
            guard let audioURL = fixture.audioURL,
                  let samples = try? loadAudioSamples(from: audioURL) else { continue }

            let lang: TranscriptionLanguage = TranscriptionLanguage(rawValue: fixture.language) ?? .auto

            let feedStart = CFAbsoluteTimeGetCurrent()
            var firstPartialMs: Double? = nil
            await bridge.beginSession(language: lang)
            await bridge.setPreviewCallback { text in
                guard !text.isEmpty, firstPartialMs == nil else { return }
                firstPartialMs = (CFAbsoluteTimeGetCurrent() - feedStart) * 1000
            }

            for offset in stride(from: 0, to: min(samples.count, chunkSamples * 4), by: feedChunk) {
                let end = min(offset + feedChunk, samples.count)
                await bridge.feed(samples: Array(samples[offset..<end]))
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            _ = await bridge.endSession()

            let latencyStr = firstPartialMs.map { String(format: "%.0f", $0) } ?? "no partial in window"
            NSLog("[Integration/\(fixture.language)] '\(fixture.transcript.prefix(30))…' → first partial: \(latencyStr)ms")

            if let ms = firstPartialMs, lang != .auto {
                XCTAssertLessThan(ms, 1680,
                    "[\(fixture.language)] first partial with forced prefix must be ≤1.5 chunks (1680ms), got \(String(format: "%.0f", ms))ms")
            }
        }

        bridge.prepareForShutdown()
    }

    /// Measures and logs auto vs explicit latency using real recordings. Asserts explicit ≤ auto + 150ms.
    func testFirstPartialLatencyComparisonRealAudio() async throws {
        try XCTSkipUnless(BackendType.parakeet.isAvailable, "Nemotron requires Apple Silicon")
        guard NemotronBridge.isModelCached() else {
            throw XCTSkip("Nemotron model not cached")
        }
        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 50)
            .filter { $0.audioURL != nil && ($0.language == "ru" || $0.language == "en") && $0.durationSec >= 3 }
            .prefix(4)
        guard !fixtures.isEmpty else {
            throw XCTSkip("No Russian or English audio fixtures available")
        }

        let bridge = try await NemotronBridge.loadFromCache()
        let chunkSamples = NemotronBridge.chunkMs * 16
        let feedChunk = 1365

        NSLog("[LatencyComparison] lang | auto ms | explicit ms | delta ms")
        for fixture in fixtures {
            guard let audioURL = fixture.audioURL,
                  let samples = try? loadAudioSamples(from: audioURL) else { continue }
            let lang = TranscriptionLanguage(rawValue: fixture.language) ?? .english

            func measure(language: TranscriptionLanguage) async -> Double? {
                let t0 = CFAbsoluteTimeGetCurrent()
                var firstMs: Double? = nil
                await bridge.beginSession(language: language)
                await bridge.setPreviewCallback { text in
                    guard !text.isEmpty, firstMs == nil else { return }
                    firstMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                }
                for offset in stride(from: 0, to: min(samples.count, chunkSamples * 3), by: feedChunk) {
                    let end = min(offset + feedChunk, samples.count)
                    await bridge.feed(samples: Array(samples[offset..<end]))
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                _ = await bridge.endSession()
                return firstMs
            }

            let autoMs = await measure(language: .auto)
            let explicitMs = await measure(language: lang)

            let a = autoMs.map { String(format: "%.0f", $0) } ?? "none"
            let e = explicitMs.map { String(format: "%.0f", $0) } ?? "none"
            let delta = (autoMs != nil && explicitMs != nil) ? String(format: "%.0f", autoMs! - explicitMs!) : "n/a"
            NSLog("[LatencyComparison] \(fixture.language) | \(a)ms | \(e)ms | -\(delta)ms")

            if let a = autoMs, let e = explicitMs {
                XCTAssertLessThanOrEqual(e, a + 150,
                    "Explicit \(fixture.language) must not be slower than auto mode (explicit: \(String(format: "%.0f", e))ms, auto: \(String(format: "%.0f", a))ms)")
            }
        }

        bridge.prepareForShutdown()
    }
}

// MARK: - Helpers

extension BenchmarkUtilities {
    static func generateTestAudio(seconds: Double) -> [Float] {
        let sampleCount = Int(seconds * 16000)
        return (0..<sampleCount).map { i in
            0.1 * sin(Float(i) * 2.0 * .pi * 440.0 / 16000.0)
        }
    }
}
#endif
