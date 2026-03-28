//
//  LanguageDetectionTests.swift
//  WhispererTests
//
//  Integration tests for language detection with real model and real Hebrew audio.
//

import XCTest
import AVFoundation
@testable import whisperer

final class LanguageDetectionTests: XCTestCase {

    private static var _detector: WhisperLangDetector?
    private static var _detectorModelName: String?

    override class func tearDown() {
        _detector?.prepareForShutdown()
        _detector = nil
        super.tearDown()
    }

    /// Load WhisperLangDetector with the best available multilingual model
    private func loadDetector() throws -> WhisperLangDetector {
        if let detector = Self._detector { return detector }

        // Try models in order of preference for detection
        let candidates: [WhisperModel] = [.tiny, .small, .largeTurboQ5, .largeTurbo, .largeV3]
        let paths: [(WhisperModel, URL)] = [
            // Sandboxed container
            candidates.compactMap { model -> (WhisperModel, URL)? in
                let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Whisperer")
                let path = dir.appendingPathComponent(model.rawValue)
                return FileManager.default.fileExists(atPath: path.path) ? (model, path) : nil
            },
            // Non-sandboxed path
            candidates.compactMap { model -> (WhisperModel, URL)? in
                let path = ModelDownloader.shared.modelPath(for: model)
                return FileManager.default.fileExists(atPath: path.path) ? (model, path) : nil
            }
        ].flatMap { $0 }

        guard let (model, path) = paths.first else {
            throw XCTSkip("No multilingual whisper model downloaded")
        }

        let detector = try WhisperLangDetector(modelPath: path)
        Self._detector = detector
        Self._detectorModelName = model.displayName
        return detector
    }

    /// Load WAV file as 16kHz mono Float32 samples
    private func loadAudio(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

        // Read original
        guard let originalBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create buffer"])
        }
        try file.read(into: originalBuffer)

        // Convert to 16kHz mono
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create converter"])
        }

        let ratio = 16000.0 / file.processingFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(originalBuffer.frameLength) * ratio) + 100
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputCapacity) else {
            throw NSError(domain: "Test", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create output buffer"])
        }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return originalBuffer
        }
        if let error { throw error }

        let count = Int(outputBuffer.frameLength)
        guard let channelData = outputBuffer.floatChannelData else {
            throw NSError(domain: "Test", code: 4, userInfo: [NSLocalizedDescriptionKey: "No channel data"])
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }

    /// Get path to hebrew_sample.wav test fixture
    private func hebrewSampleURL() throws -> URL {
        // Look in the test bundle
        if let bundlePath = Bundle(for: type(of: self)).path(forResource: "hebrew_sample", ofType: "wav") {
            return URL(fileURLWithPath: bundlePath)
        }
        // Fallback: look in TestData directory relative to source
        let sourceDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let testDataPath = sourceDir.appendingPathComponent("TestData/hebrew_sample.wav")
        if FileManager.default.fileExists(atPath: testDataPath.path) {
            return testDataPath
        }
        throw XCTSkip("hebrew_sample.wav not found in test bundle or TestData/")
    }

    // MARK: - Tests

    func testDetectorLoadsAndIsMultilingual() throws {
        let detector = try loadDetector()
        XCTAssertTrue(detector.isContextHealthy(), "Detector context should be healthy")
        print("✅ Detector loaded with model: \(Self._detectorModelName ?? "unknown")")
    }

    /// Reproduce the bug: 2s of Hebrew audio → detection returns wrong language
    func testHebrewDetectionAt2Seconds() throws {
        let detector = try loadDetector()
        let allSamples = try loadAudio(from: hebrewSampleURL())

        let window = Array(allSamples.prefix(32000))  // 2s
        guard let probs = detector.detect(samples: window) else {
            XCTFail("Detection returned nil")
            return
        }

        let sorted = probs.sorted { $0.value > $1.value }
        print("\n🔍 Hebrew detection at 2.0s (model: \(Self._detectorModelName ?? "?")):")
        for (lang, prob) in sorted.prefix(10) {
            let marker = lang == "he" ? " ← HEBREW" : ""
            print("   \(lang): \(String(format: "%.4f", prob))\(marker)")
        }

        let hebrewProb = probs["he"] ?? 0
        print("   Hebrew probability: \(String(format: "%.4f", hebrewProb))")

        // This test documents the current behavior — Hebrew may not win at 2s
        // The key question is: what does the shortlist router do with these probs?
        let shortlist: [TranscriptionLanguage] = [.english, .hebrew, .russian]
        let router = LanguageRouter(allowed: shortlist, primary: .english)
        let decision = router.decide(allProbs: probs, transcriptText: "")

        if let decision {
            print("   Router decision: \(decision.lang.displayName) (conf=\(String(format: "%.3f", decision.confidence)))")
        } else {
            print("   Router decision: UNDECIDED (below threshold)")
        }
    }

    func testHebrewDetectionAt4Seconds() throws {
        let detector = try loadDetector()
        let allSamples = try loadAudio(from: hebrewSampleURL())

        let window = Array(allSamples.prefix(64000))  // 4s
        guard window.count >= 48000 else {
            throw XCTSkip("Audio too short for 4s window")
        }
        guard let probs = detector.detect(samples: window) else {
            XCTFail("Detection returned nil")
            return
        }

        let sorted = probs.sorted { $0.value > $1.value }
        print("\n🔍 Hebrew detection at 4.0s (model: \(Self._detectorModelName ?? "?")):")
        for (lang, prob) in sorted.prefix(10) {
            let marker = lang == "he" ? " ← HEBREW" : ""
            print("   \(lang): \(String(format: "%.4f", prob))\(marker)")
        }

        let hebrewProb = probs["he"] ?? 0
        print("   Hebrew probability: \(String(format: "%.4f", hebrewProb))")

        // At 4s, Hebrew should be stronger
        let shortlist: [TranscriptionLanguage] = [.english, .hebrew, .russian]
        let router = LanguageRouter(allowed: shortlist, primary: .english)
        let decision = router.decide(allProbs: probs, transcriptText: "")

        if let decision {
            print("   Router decision: \(decision.lang.displayName) (conf=\(String(format: "%.3f", decision.confidence)))")
            // At 4s we expect Hebrew to be detected
            XCTAssertEqual(decision.lang, .hebrew, "Expected Hebrew at 4s, got \(decision.lang.displayName)")
        } else {
            print("   Router decision: UNDECIDED")
        }
    }

    func testHebrewDetectionFullAudio() throws {
        let detector = try loadDetector()
        let allSamples = try loadAudio(from: hebrewSampleURL())

        guard let probs = detector.detect(samples: allSamples) else {
            XCTFail("Detection returned nil")
            return
        }

        let duration = Double(allSamples.count) / 16000.0
        let sorted = probs.sorted { $0.value > $1.value }
        print("\n🔍 Hebrew detection at \(String(format: "%.1f", duration))s FULL (model: \(Self._detectorModelName ?? "?")):")
        for (lang, prob) in sorted.prefix(10) {
            let marker = lang == "he" ? " ← HEBREW" : ""
            print("   \(lang): \(String(format: "%.4f", prob))\(marker)")
        }

        let hebrewProb = probs["he"] ?? 0
        print("   Hebrew probability: \(String(format: "%.4f", hebrewProb))")

        // Full audio should strongly detect Hebrew
        let shortlist: [TranscriptionLanguage] = [.english, .hebrew, .russian]
        let router = LanguageRouter(allowed: shortlist, primary: .english)
        let decision = router.decide(allProbs: probs, transcriptText: "")

        XCTAssertNotNil(decision, "Router should decide on full Hebrew audio")
        if let decision {
            print("   Router decision: \(decision.lang.displayName) (conf=\(String(format: "%.3f", decision.confidence)))")
            XCTAssertEqual(decision.lang, .hebrew, "Expected Hebrew on full audio, got \(decision.lang.displayName)")
        }
    }

    /// Test detection latency at different window sizes
    func testDetectionLatencyByWindowSize() throws {
        let detector = try loadDetector()
        let allSamples = try loadAudio(from: hebrewSampleURL())

        let windowSizes: [(String, Int)] = [
            ("1.0s", 16000),
            ("2.0s", 32000),
            ("3.0s", 48000),
            ("4.0s", 64000),
            ("full", allSamples.count)
        ]

        print("\n⏱️ Detection latency (model: \(Self._detectorModelName ?? "?")):")
        for (label, size) in windowSizes {
            guard allSamples.count >= size else { continue }
            let window = Array(allSamples.prefix(size))

            let start = CFAbsoluteTimeGetCurrent()
            let probs = detector.detect(samples: window)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

            let top = probs?.max(by: { $0.value < $1.value })
            let heProb = probs?["he"] ?? 0
            print("   \(label): \(String(format: "%.1f", ms))ms → top=\(top?.key ?? "?") (p=\(String(format: "%.3f", top?.value ?? 0))), he=\(String(format: "%.3f", heProb))")

            XCTAssertLessThan(ms, 500, "Detection at \(label) should be under 500ms")
        }
    }

    /// Test that the shortlist router correctly handles the real-world misdetection case
    func testRouterWithRealDetectionProbs() throws {
        // Simulate the exact probabilities from the production log
        // Detection: top=it (p=0.373) — Italian wins globally
        // But Hebrew, Russian, English are in the shortlist
        let simulatedProbs: [String: Float] = [
            "it": 0.373,
            "en": 0.120,
            "ru": 0.150,
            "he": 0.080,
            "fr": 0.050,
            "es": 0.040,
            "de": 0.030,
            "pt": 0.025,
            "nl": 0.020,
            "pl": 0.015,
        ]

        let shortlist: [TranscriptionLanguage] = [.english, .hebrew, .russian]
        let router = LanguageRouter(allowed: shortlist, primary: .hebrew)
        let decision = router.decide(allProbs: simulatedProbs, transcriptText: "")

        print("\n🧪 Router with simulated misdetection probs:")
        print("   Raw: it=0.373, en=0.120, ru=0.150, he=0.080")
        print("   Shortlist: [en, he, ru], primary=Hebrew")

        // After filtering to [en, he, ru] and renormalizing:
        // en: 0.120/0.350 = 0.343, ru: 0.150/0.350 = 0.429, he: 0.080/0.350 = 0.229
        // With Hebrew as primary (+0.05 prior), scores would be approximately:
        // ru: 0.875 * 0.429 = 0.375
        // en: 0.875 * 0.343 = 0.300
        // he: 0.875 * 0.229 + 0.125 * 0.05 = 0.206
        // Top is Russian at ~0.375 — below 0.75 threshold → UNDECIDED

        if let decision {
            print("   Decision: \(decision.lang.displayName) (conf=\(String(format: "%.3f", decision.confidence)))")
        } else {
            print("   Decision: UNDECIDED (all below 0.75 threshold)")
            // This is the expected behavior with these weak probs
            // The fix should be: retry detection with more audio
        }
    }

    // MARK: - Performance Tests: Dual Model Architecture

    /// Shared WhisperBridge for main model tests
    private static var _mainBridge: WhisperBridge?
    private static var _mainModelName: String?

    private func loadMainBridge() throws -> WhisperBridge {
        if let bridge = Self._mainBridge { return bridge }
        let models: [WhisperModel] = [.largeTurboQ5, .largeTurbo, .small]
        for model in models {
            let path = ModelDownloader.shared.modelPath(for: model)
            if FileManager.default.fileExists(atPath: path.path) {
                let bridge = try WhisperBridge(modelPath: path)
                Self._mainBridge = bridge
                Self._mainModelName = model.displayName
                return bridge
            }
        }
        throw XCTSkip("No main whisper model downloaded")
    }

    /// Shared tiny WhisperBridge for transcription tests (separate from detector)
    private static var _tinyBridge: WhisperBridge?

    private func loadTinyBridge() throws -> WhisperBridge {
        if let bridge = Self._tinyBridge { return bridge }
        let path = ModelDownloader.shared.modelPath(for: .tiny)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("ggml-tiny.bin not downloaded")
        }
        let bridge = try WhisperBridge(modelPath: path)
        Self._tinyBridge = bridge
        return bridge
    }

    /// Tiny model transcription latency — can it serve as live preview?
    func testTinyModelTranscriptionLatency() throws {
        let bridge = try loadTinyBridge()
        let allSamples = try loadAudio(from: hebrewSampleURL())

        // Warmup
        _ = bridge.transcribe(samples: [Float](repeating: 0, count: 16000))

        print("\n⏱️ Tiny model TRANSCRIPTION latency (simulating live preview):")

        let chunkSizes: [(String, Int)] = [
            ("1.0s", 16000),
            ("2.0s", 32000),
            ("3.0s", 48000),
            ("4.0s", 64000),
        ]

        for (label, size) in chunkSizes {
            guard allSamples.count >= size else { continue }
            let chunk = Array(allSamples.prefix(size))

            let start = CFAbsoluteTimeGetCurrent()
            let text = bridge.transcribe(
                samples: chunk,
                initialPrompt: nil,
                language: .hebrew,
                singleSegment: true,
                maxTokens: 0
            )
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000

            print("   \(label): \(String(format: "%.0f", ms))ms → \"\(text.prefix(60))\"")
        }
        print("   (Compare: Parakeet EOU does ~45ms per 320ms chunk)")
    }

    /// Tiny model transcription quality on Hebrew
    func testTinyModelTranscriptionQuality() throws {
        let bridge = try loadTinyBridge()
        let allSamples = try loadAudio(from: hebrewSampleURL())

        // Warmup
        _ = bridge.transcribe(samples: [Float](repeating: 0, count: 16000))

        print("\n📝 Tiny model Hebrew transcription quality:")

        // Full audio, auto-detect
        let autoText = bridge.transcribe(
            samples: allSamples,
            initialPrompt: nil,
            language: .auto,
            singleSegment: false,
            maxTokens: 0
        )
        print("   Auto-detect: \"\(autoText)\"")

        // Full audio, Hebrew forced
        let hebrewText = bridge.transcribe(
            samples: allSamples,
            initialPrompt: nil,
            language: .hebrew,
            singleSegment: false,
            maxTokens: 0
        )
        print("   Hebrew forced: \"\(hebrewText)\"")
    }

    /// GPU contention: run detection on tiny while transcribing on main simultaneously
    func testDualModelGPUContention() throws {
        let tinyBridge = try loadTinyBridge()
        let mainBridge = try loadMainBridge()
        let detector = try loadDetector()
        let allSamples = try loadAudio(from: hebrewSampleURL())

        // Warmup both
        _ = tinyBridge.transcribe(samples: [Float](repeating: 0, count: 16000))
        _ = mainBridge.transcribe(samples: [Float](repeating: 0, count: 16000))

        print("\n🔥 Dual model GPU contention test:")

        // Baseline: main model alone
        let baselineStart = CFAbsoluteTimeGetCurrent()
        let baselineText = mainBridge.transcribe(
            samples: allSamples,
            initialPrompt: nil,
            language: .hebrew,
            singleSegment: false,
            maxTokens: 0
        )
        let baselineMs = (CFAbsoluteTimeGetCurrent() - baselineStart) * 1000
        print("   Main model alone: \(String(format: "%.0f", baselineMs))ms (\(baselineText.count) chars)")

        // Concurrent: detection on tiny + transcription on main
        let group = DispatchGroup()
        var concurrentMainMs: Double = 0
        var concurrentDetectMs: Double = 0
        var detectResult: [String: Float]?

        group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            let start = CFAbsoluteTimeGetCurrent()
            detectResult = detector.detect(samples: Array(allSamples.prefix(64000)))
            concurrentDetectMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            let start = CFAbsoluteTimeGetCurrent()
            _ = mainBridge.transcribe(
                samples: allSamples,
                initialPrompt: nil,
                language: .hebrew,
                singleSegment: false,
                maxTokens: 0
            )
            concurrentMainMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            group.leave()
        }

        group.wait()

        let overhead = concurrentMainMs - baselineMs
        let overheadPct = (overhead / baselineMs) * 100
        let detectTop = detectResult?.max(by: { $0.value < $1.value })

        print("   Main model concurrent: \(String(format: "%.0f", concurrentMainMs))ms (overhead: \(String(format: "%+.0f", overhead))ms / \(String(format: "%.1f", overheadPct))%)")
        print("   Detection concurrent: \(String(format: "%.0f", concurrentDetectMs))ms → top=\(detectTop?.key ?? "?") (p=\(String(format: "%.3f", detectTop?.value ?? 0)))")

        if overheadPct > 50 {
            print("   ⚠️ Significant GPU contention detected!")
        } else {
            print("   ✅ Acceptable contention overhead")
        }
    }

    /// Memory impact of loading tiny + main models
    func testMemoryWithDualModels() throws {
        let beforeMemory = BenchmarkUtilities.currentMemoryMB()
        print("\n💾 Memory test:")
        print("   Before models: \(String(format: "%.0f", beforeMemory)) MB")

        let mainBridge = try loadMainBridge()
        _ = mainBridge.transcribe(samples: [Float](repeating: 0, count: 16000))
        let afterMain = BenchmarkUtilities.currentMemoryMB()
        print("   After main model (\(Self._mainModelName ?? "?")): \(String(format: "%.0f", afterMain)) MB (+\(String(format: "%.0f", afterMain - beforeMemory)) MB)")

        let tinyBridge = try loadTinyBridge()
        _ = tinyBridge.transcribe(samples: [Float](repeating: 0, count: 16000))
        let afterTiny = BenchmarkUtilities.currentMemoryMB()
        print("   After tiny model added: \(String(format: "%.0f", afterTiny)) MB (+\(String(format: "%.0f", afterTiny - afterMain)) MB for tiny)")

        let detector = try loadDetector()
        _ = detector.detect(samples: [Float](repeating: 0, count: 16000))
        let afterDetector = BenchmarkUtilities.currentMemoryMB()
        print("   After detector added: \(String(format: "%.0f", afterDetector)) MB (+\(String(format: "%.0f", afterDetector - afterTiny)) MB for detector)")
        print("   Total: \(String(format: "%.0f", afterDetector)) MB")
    }

    /// Compare detection accuracy: tiny model vs main model
    func testDetectionWithMainModel() throws {
        let mainBridge = try loadMainBridge()
        let detector = try loadDetector()
        let allSamples = try loadAudio(from: hebrewSampleURL())

        // Warmup
        _ = mainBridge.transcribe(samples: [Float](repeating: 0, count: 16000))

        print("\n🆚 Detection comparison: Tiny vs Main model (\(Self._mainModelName ?? "?")):")

        let windowSizes: [(String, Int)] = [
            ("2.0s", 32000),
            ("4.0s", 64000),
            ("full", allSamples.count)
        ]

        for (label, size) in windowSizes {
            guard allSamples.count >= size else { continue }
            let window = Array(allSamples.prefix(size))

            // Tiny detector
            let tinyStart = CFAbsoluteTimeGetCurrent()
            let tinyProbs = detector.detect(samples: window)
            let tinyMs = (CFAbsoluteTimeGetCurrent() - tinyStart) * 1000
            let tinyTop = tinyProbs?.max(by: { $0.value < $1.value })
            let tinyHe = tinyProbs?["he"] ?? 0

            // Main model — use whisper_lang_auto_detect via transcribe with auto-detect
            // We can't call whisper_lang_auto_detect directly on main bridge,
            // but we can transcribe with auto-detect and check lastDetectedLanguage
            let mainStart = CFAbsoluteTimeGetCurrent()
            _ = mainBridge.transcribe(
                samples: window,
                initialPrompt: nil,
                language: .auto,
                singleSegment: true,
                maxTokens: 1  // Minimal decoding — we just want the lang detection
            )
            let mainMs = (CFAbsoluteTimeGetCurrent() - mainStart) * 1000
            let mainDetected = mainBridge.lastDetectedLanguage ?? "?"

            print("   \(label):")
            print("      Tiny:  \(String(format: "%.0f", tinyMs))ms → top=\(tinyTop?.key ?? "?") (p=\(String(format: "%.3f", tinyTop?.value ?? 0))), he=\(String(format: "%.3f", tinyHe))")
            print("      Main:  \(String(format: "%.0f", mainMs))ms → detected=\(mainDetected)")
        }
    }
}
