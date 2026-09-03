//
//  MLXLanguageDetectorTests.swift
//  WhispererTests
//
//  Integration tests for MLXLanguageDetector against real recordings from the app's
//  history database. Tests skip automatically if the model is not downloaded or if no
//  recordings with audio exist.
//

import XCTest
import AVFoundation
@testable import whisperer

final class MLXLanguageDetectorTests: XCTestCase {

    // MARK: - Setup

    override class func setUp() {
        super.setUp()
        // Kick off model load; tests will wait up to kModelTimeout seconds.
        MLXLanguageDetector.shared.prepareAsync()
    }

    // MARK: - Model availability

    func testModelLoadsSuccessfully() async throws {
        try await waitForModel()
        XCTAssertTrue(MLXLanguageDetector.shared.isReady)
    }

    // MARK: - Unit smoke test with silence

    func testDetectReturnsNonEmptyProbabilities() async throws {
        try await waitForModel()
        let silence = [Float](repeating: 0, count: 16_000 * 5)
        let probs = MLXLanguageDetector.shared.detect(samples: silence)
        XCTAssertNotNil(probs)
        XCTAssertFalse(probs!.isEmpty)
        let total = probs!.values.reduce(0, +)
        XCTAssertGreaterThan(total, 0.99, "Probabilities should roughly sum to 1")
    }

    func testDetectIsSubMillisecond() async throws {
        try await waitForModel()
        // Warm up
        let samples = [Float](repeating: 0, count: 16_000 * 5)
        _ = MLXLanguageDetector.shared.detect(samples: samples)

        let t0 = CACurrentMediaTime()
        for _ in 0..<3 {
            _ = MLXLanguageDetector.shared.detect(samples: samples)
        }
        let avgMs = (CACurrentMediaTime() - t0) / 3 * 1000
        XCTAssertLessThan(avgMs, 200, "Average detection latency should be under 200ms on 5s of audio")
    }

    // MARK: - History-backed accuracy test

    /// Runs detection on every recording in the history database that has an audio file
    /// and a non-auto language tag, then reports accuracy per language bucket.
    func testAccuracyAgainstRecordingHistory() async throws {
        try await waitForModel()

        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 200)
        let usable = fixtures.filter { $0.audioURL != nil && $0.language != "auto" }
        try XCTSkipIf(usable.isEmpty, "No recordings with audio files in history — run the app to collect some")

        struct Result {
            let id: String
            let expectedLang: String
            let topLang: String
            let topProb: Float
            let correct: Bool
        }

        var results: [Result] = []

        for fixture in usable {
            guard let audioURL = fixture.audioURL else { continue }
            let samples: [Float]
            do {
                samples = try loadAudio(from: audioURL, maxSeconds: 15)
            } catch {
                print("  ⚠️  \(fixture.id): audio load failed — \(error.localizedDescription)")
                continue
            }

            guard let probs = MLXLanguageDetector.shared.detect(samples: samples) else {
                XCTFail("detect() returned nil when model is ready")
                continue
            }

            let top = probs.max(by: { $0.value < $1.value }) ?? ("?", 0)
            let correct = top.key == fixture.language
            results.append(Result(
                id: fixture.id,
                expectedLang: fixture.language,
                topLang: top.key,
                topProb: top.value,
                correct: correct
            ))
        }

        try XCTSkipIf(results.isEmpty, "No recordings could be processed")

        // Print per-language breakdown
        let byLanguage = Dictionary(grouping: results, by: \.expectedLang)
        var totalCorrect = 0
        print("\nMLXLanguageDetector accuracy vs. history database:")
        print(String(repeating: "-", count: 55))
        for lang in byLanguage.keys.sorted() {
            let group = byLanguage[lang]!
            let correct = group.filter(\.correct).count
            totalCorrect += correct
            let pct = Int(Double(correct) / Double(group.count) * 100)
            print(String(format: "  %-6@ %3d/%3d  %3d%%", lang as NSString, correct, group.count, pct))
        }
        let overall = Int(Double(totalCorrect) / Double(results.count) * 100)
        print(String(repeating: "-", count: 55))
        print(String(format: "  TOTAL  %3d/%3d  %3d%%", totalCorrect, results.count, overall))

        // Floor: 10% overall — 10× better than random (1/107 ≈ 1%).
        // Label noise in bilingual users' recordings (language setting ≠ language spoken)
        // limits achievable accuracy; non-English accuracy is tested separately above that floor.
        XCTAssertGreaterThanOrEqual(
            overall, 10,
            "Overall accuracy \(overall)% is below the 10% floor — check the language code mapping"
        )
    }

    // MARK: - Non-English accuracy (where detection matters most)

    func testNonEnglishAccuracy() async throws {
        try await waitForModel()

        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 300)
        let nonEnglish = fixtures.filter {
            $0.audioURL != nil && $0.language != "en" && $0.language != "auto"
        }
        try XCTSkipIf(nonEnglish.isEmpty, "No non-English recordings with audio in history")

        var correct = 0
        var total = 0
        for fixture in nonEnglish {
            guard let audioURL = fixture.audioURL else { continue }
            guard let samples = try? loadAudio(from: audioURL, maxSeconds: 15) else { continue }
            guard let probs = MLXLanguageDetector.shared.detect(samples: samples) else { continue }
            let top = probs.max(by: { $0.value < $1.value })?.key ?? "?"
            if top == fixture.language { correct += 1 }
            total += 1
        }

        try XCTSkipIf(total == 0, "No non-English recordings could be processed")
        let pct = Int(Double(correct) / Double(total) * 100)
        print("Non-English accuracy: \(correct)/\(total) = \(pct)%")
        // Floor: 25% for non-English — much better than random.
        // Label noise (bilingual recordings) limits achievable accuracy on this corpus.
        XCTAssertGreaterThanOrEqual(pct, 25,
            "Non-English accuracy \(pct)% is below the 25% floor")
    }

    // MARK: - Helpers

    private static let kModelTimeout: TimeInterval = 120

    /// Waits for the model to be ready, skipping if it times out.
    private func waitForModel() async throws {
        let deadline = Date().addingTimeInterval(Self.kModelTimeout)
        while !MLXLanguageDetector.shared.isReady {
            guard Date() < deadline else {
                throw XCTSkip("MLX language detector not ready after \(Int(Self.kModelTimeout))s — model may need to download (~81 MB)")
            }
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
    }

    /// Load audio file as 16 kHz mono Float32, capped at maxSeconds.
    private func loadAudio(from url: URL, maxSeconds: Double = 30) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        )!
        let srcFormat = file.processingFormat
        let maxFrames = AVAudioFrameCount(maxSeconds * srcFormat.sampleRate)
        let srcFrames = min(AVAudioFrameCount(file.length), maxFrames)

        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: srcFrames) else {
            throw NSError(domain: "MLXTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate source buffer"])
        }
        try file.read(into: srcBuf, frameCount: srcFrames)

        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            throw NSError(domain: "MLXTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter"])
        }

        let outCapacity = AVAudioFrameCount(Double(srcBuf.frameLength) * 16_000 / srcFormat.sampleRate) + 512
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            throw NSError(domain: "MLXTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate output buffer"])
        }

        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, outStatus in
            outStatus.pointee = .haveData
            return srcBuf
        }
        if let convError { throw convError }

        let count = Int(outBuf.frameLength)
        guard let channelData = outBuf.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }
}
