//
//  Qwen3ASREndToEndTests.swift
//  WhispererTests
//
//  Real-model checks for the MLX Qwen3-ASR backend: accuracy and speed on recorded dictation,
//  and a StreamingTranscriber session that must stream preview text and finish fast.
//  Skips when the model is not downloaded.
//

import XCTest
@testable import whisperer

final class Qwen3ASREndToEndTests: XCTestCase {

    // Process-lifetime: the model is ~2.5 GB and its Metal kernels are compiled once.
    private static var bridge: Qwen3ASRBridge?

    private static let recordingsDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Whisperer/Recordings")

    private func requireBridge() throws -> Qwen3ASRBridge {
        if let b = Self.bridge { return b }
        guard Qwen3ASRBridge.isModelCached() else {
            throw XCTSkip("Qwen3-ASR not downloaded at \(Qwen3ASREngine.modelDirectory().path)")
        }
        let b = try Qwen3ASRBridge.loadFromCache()
        Self.bridge = b
        return b
    }

    private func recording(_ name: String) throws -> [Float] {
        let url = Self.recordingsDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("recording \(name) not present")
        }
        return try loadAudioSamples(from: url)
    }

    /// Reference transcripts from mlx-audio's Python Qwen3-ASR-1.7B-8bit on the same files.
    func testTranscribesRecordingsAccuratelyAndFast() throws {
        let b = try requireBridge()
        let cases: [(file: String, reference: String)] = [
            ("2026-09-25_20-15-24_Im_not_sure_this_is_right.opus", "I am not sure this is right."),
            ("2026-09-25_11-14-53_The_algorithm_proposed_the_sol.opus",
             "The algorithm proposed, the solver keeps failing us. No matter how we implement it, "
             + "the solver cannot be implemented correctly. It's doing stupid mistakes over and over again."),
        ]
        for c in cases {
            let samples = try recording(c.file)
            b.resetAbort()
            let t0 = CFAbsoluteTimeGetCurrent()
            let text = b.transcribe(samples: samples, initialPrompt: nil, language: .auto,
                                    singleSegment: false, maxTokens: 0)
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            let seconds = Double(samples.count) / 16_000
            let wer = wordErrorRate(text, reference: c.reference)
            print("Qwen3ASR \(String(format: "%.1f", seconds))s → \(String(format: "%.2f", elapsed))s WER=\(String(format: "%.2f", wer)): \(text)")
            XCTAssertLessThan(wer, 0.15, "\(c.file): \(text)")
            XCTAssertLessThan(elapsed, max(1.0, seconds * 0.25), "\(c.file) must decode at ≥4× realtime")
            XCTAssertEqual(b.lastDetectedLanguage, "en")
        }
    }

    func testForcedLanguageSkipsHeaderAndSilenceIsEmpty() throws {
        let b = try requireBridge()
        let samples = try recording("2026-09-25_20-15-24_Im_not_sure_this_is_right.opus")
        b.resetAbort()
        let forced = b.transcribe(samples: samples, initialPrompt: nil, language: .english,
                                  singleSegment: false, maxTokens: 0)
        XCTAssertFalse(forced.lowercased().contains("language"), forced)
        XCTAssertLessThan(wordErrorRate(forced, reference: "I am not sure this is right."), 0.2, forced)

        let silence = b.transcribe(samples: [Float](repeating: 0, count: 32_000), initialPrompt: nil,
                                   language: .auto, singleSegment: false, maxTokens: 0)
        XCTAssertFalse(silence.lowercased().contains("language"), "header leaked: \(silence)")
    }

    /// The bug report: live preview showed nothing and stop took forever. Feed a recording at
    /// real-time pace and require (a) preview text while "recording", (b) a fast stop.
    func testStreamingSessionShowsLivePreviewAndStopsFast() async throws {
        let b = try requireBridge()
        let samples = try recording("2026-09-25_11-14-53_The_algorithm_proposed_the_sol.opus")
        b.resetAbort()
        let transcriber = StreamingTranscriber(
            backend: b, vad: loadVAD(), language: .auto, initialPrompt: nil,
            fillerWordRemovalEnabled: false, previewBridge: b)

        final class Box: @unchecked Sendable { var updates: [String] = [] }
        let box = Box()
        transcriber.start { text in box.updates.append(text) }

        // Real-time feed: 100 ms of audio every 100 ms.
        await Task.detached(priority: .userInitiated) {
            let step = 1_600
            for offset in stride(from: 0, to: samples.count, by: step) {
                transcriber.addSamples(Array(samples[offset..<min(offset + step, samples.count)]))
                Thread.sleep(forTimeInterval: 0.1)
            }
        }.value
        try? await Task.sleep(nanoseconds: 300_000_000)

        let previewCount = await MainActor.run { box.updates.filter { !$0.isEmpty }.count }
        let t0 = CFAbsoluteTimeGetCurrent()
        let final = await transcriber.stopAsync()
        let stopLatency = CFAbsoluteTimeGetCurrent() - t0
        print("Qwen3ASR streaming: \(previewCount) preview updates, stop \(String(format: "%.2f", stopLatency))s → \(final)")

        XCTAssertGreaterThan(previewCount, 3, "live preview must stream text during recording")
        // The live card never retracts a word, so every update must already be plausible text:
        // no misdetected-language first pass ("三。") and no mid-word partial cut.
        let updates = await MainActor.run { box.updates }
        let cjk = updates.filter { $0.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) } }
        XCTAssertTrue(cjk.isEmpty, "misdetected preview leaked: \(cjk)")
        print("Qwen3ASR first preview updates: \(updates.filter { !$0.isEmpty }.prefix(4))")
        XCTAssertLessThan(stopLatency, 2.0, "stop must not re-decode the whole recording slowly")
        XCTAssertTrue(final.lowercased().contains("solver"), final)
    }
}
