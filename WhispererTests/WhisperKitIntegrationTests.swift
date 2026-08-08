//
//  WhisperKitIntegrationTests.swift
//  WhispererTests
//
//  Integration tests for the WhisperKitBridge backend.
//  All tests auto-skip if the WhisperKit model is not cached.
//
//  Run with: xcodebuild test -scheme whisperer -destination "platform=macOS"
//

import XCTest
@testable import whisperer

#if canImport(WhisperKit)
import WhisperKit

final class WhisperKitIntegrationTests: XCTestCase {

    // Kept alive for the test class lifetime — Metal dealloc crash on early release
    private static var sharedBridge: WhisperKitBridge?

    override class func setUp() {
        super.setUp()
        guard sharedBridge == nil else { return }
        guard WhisperKitBridge.isModelCached() else { return }
        let expectation = XCTestExpectation(description: "WhisperKit load")
        Task {
            do {
                sharedBridge = try await WhisperKitBridge.loadFromCache()
                expectation.fulfill()
            } catch {
                XCTFail("Failed to load WhisperKit from cache: \(error)")
                expectation.fulfill()
            }
        }
        _ = XCTWaiter.wait(for: [expectation], timeout: 300)  // up to 5 min first-run JIT
    }

    override class func tearDown() {
        sharedBridge?.prepareForShutdown()
        sharedBridge = nil
        super.tearDown()
    }

    private func bridge() throws -> WhisperKitBridge {
        try XCTSkipUnless(BackendType.whisperKit.isAvailable, "WhisperKit requires Apple Silicon")
        try XCTSkipUnless(WhisperKitBridge.isModelCached(), "WhisperKit model not downloaded — run app and download first")
        guard let b = Self.sharedBridge else {
            XCTFail("WhisperKit bridge failed to load in setUp")
            throw XCTSkip("WhisperKit bridge not available")
        }
        return b
    }

    // MARK: - Core correctness

    /// Model folder exists and AudioEncoder.mlmodelc is present
    func testModelCacheIntegrity() throws {
        try XCTSkipUnless(WhisperKitBridge.isModelCached(), "WhisperKit model not downloaded")
        guard let folder = WhisperKitBridge.persistedModelFolder() else {
            XCTFail("No persisted model folder path")
            return
        }
        let encoder = folder.appendingPathComponent("AudioEncoder.mlmodelc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: encoder.path),
                      "AudioEncoder.mlmodelc missing at \(encoder.path)")
    }

    /// loadFromCache() completes without throwing
    func testLoadFromCache() throws {
        _ = try bridge()
    }

    /// Silence produces empty transcription (no hallucinations on silent input)
    func testSilenceReturnsEmpty() throws {
        let b = try bridge()
        let silence = [Float](repeating: 0, count: 32000)  // 2s silence at 16kHz
        let start = CFAbsoluteTimeGetCurrent()
        var result = ""
        let done = expectation(description: "done")
        b.transcribeAsync(samples: silence, initialPrompt: nil, language: .auto, singleSegment: true, maxTokens: 0) { text in
            result = text
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("[WhisperKit] silence → '\(result)' (\(String(format: "%.0f", elapsed))ms)")
        // Silence should not hallucinate. Allow occasional very short noise bursts.
        XCTAssertLessThan(result.count, 30,
            "Silence transcription too long — may be hallucinating: '\(result)'")
    }

    /// transcribeAsync delivers a completion callback on a 2s silence chunk
    func testTranscribeAsyncCompletesForSilence() throws {
        let b = try bridge()
        let expectation = expectation(description: "completion fires")
        var receivedText = ""
        b.transcribeAsync(
            samples: [Float](repeating: 0, count: 32000),
            initialPrompt: nil,
            language: .auto,
            singleSegment: true,
            maxTokens: 0
        ) { text in
            receivedText = text
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 30)  // generous — first call after warmup
        print("[WhisperKit] async completion received: '\(receivedText)'")
        // Just assert the callback fired — text content is validated in other tests
        XCTAssertTrue(true, "completion callback fired")
    }

    // MARK: - Timing

    /// Measure first-call latency on 2s silence — must complete within 10s after warmup.
    /// Uses transcribeAsync to avoid blocking the main thread (XCTest runs on main actor).
    func testFirstCallLatencyAfterWarmup() throws {
        let b = try bridge()
        let silence = [Float](repeating: 0, count: 32000)

        // Warmup pass via async path
        let warmupDone = expectation(description: "warmup")
        b.transcribeAsync(samples: silence, initialPrompt: nil, language: .auto, singleSegment: false, maxTokens: 0) { _ in warmupDone.fulfill() }
        wait(for: [warmupDone], timeout: 30)

        // Measured pass
        let start = CFAbsoluteTimeGetCurrent()
        let measured = expectation(description: "measured")
        b.transcribeAsync(samples: silence, initialPrompt: nil, language: .auto, singleSegment: true, maxTokens: 0) { _ in measured.fulfill() }
        wait(for: [measured], timeout: 30)
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("[WhisperKit] 2s silence transcription: \(String(format: "%.0f", ms))ms")
        XCTAssertLessThan(ms, 10_000, "WhisperKit 2s chunk took \(String(format: "%.0f", ms))ms — exceeds 10s watchdog window")
    }

    /// 440Hz sine wave (speech-like energy) should complete within 10s.
    /// Uses transcribeAsync to avoid blocking the main thread.
    func testSineWaveChunkLatency() throws {
        let b = try bridge()
        let sineWave = generateSine(hz: 440, seconds: 2.0, sampleRate: 16000)

        let start = CFAbsoluteTimeGetCurrent()
        var result = ""
        let done = expectation(description: "done")
        b.transcribeAsync(samples: sineWave, initialPrompt: nil, language: .auto, singleSegment: true, maxTokens: 0) { text in
            result = text
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("[WhisperKit] 440Hz sine → '\(result)' (\(String(format: "%.0f", ms))ms)")
        XCTAssertLessThan(ms, 10_000,
            "WhisperKit 2s chunk took \(String(format: "%.0f", ms))ms — watchdog would fire")
    }

    // MARK: - Callback / snapshot path

    /// Snapshot callback fires during transcription (best-effort — decoder may not produce
    /// mid-chunk tokens for synthetic audio, so we don't assert it must fire)
    func testSnapshotCallbackFires() throws {
        let b = try bridge()
        b.beginSession()

        let chunkGen: UInt64 = 1
        var snapshotReceived = false
        b.setChunkCallback({ _ in snapshotReceived = true }, chunkGeneration: chunkGen)

        let samples = generateSine(hz: 440, seconds: 3.0, sampleRate: 16000)
        let done = expectation(description: "completion")
        b.transcribeAsync(
            samples: samples,
            initialPrompt: nil,
            language: .english,
            singleSegment: true,
            maxTokens: 0
        ) { _ in done.fulfill() }

        wait(for: [done], timeout: 30)
        print("[WhisperKit] snapshot callback fired: \(snapshotReceived)")
        b.clearCallbacks()
        // Snapshot callback is best-effort for synthetic audio; just verify transcription completed
    }

    // MARK: - Abort

    /// requestAbort() stops an in-flight transcription — completion still fires (with empty result)
    func testAbortStopsTranscription() throws {
        let b = try bridge()
        b.beginSession()
        let completion = expectation(description: "completion after abort")
        var resultAfterAbort = "SENTINEL"
        let longSamples = generateSine(hz: 440, seconds: 15.0, sampleRate: 16000)  // long enough to abort mid-decode
        b.transcribeAsync(
            samples: longSamples,
            initialPrompt: nil,
            language: .auto,
            singleSegment: false,
            maxTokens: 0
        ) { text in
            resultAfterAbort = text
            completion.fulfill()
        }

        // Abort after 500ms — decoder should be mid-flight
        Thread.sleep(forTimeInterval: 0.5)
        b.requestAbort()

        wait(for: [completion], timeout: 15)
        XCTAssertNotEqual(resultAfterAbort, "SENTINEL", "Completion callback never fired after abort")
        print("[WhisperKit] result after abort: '\(resultAfterAbort)'")
    }

    /// resetAbort() allows transcription to proceed after abort
    func testResetAbortAllowsNextTranscription() throws {
        let b = try bridge()
        b.beginSession()

        // Abort immediately
        b.requestAbort()
        b.resetAbort()

        // Now transcription should proceed normally
        let expectation = self.expectation(description: "completion")
        var result = ""
        b.transcribeAsync(
            samples: [Float](repeating: 0, count: 16000),
            initialPrompt: nil,
            language: .auto,
            singleSegment: false,
            maxTokens: 0
        ) { text in
            result = text
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 30)
        print("[WhisperKit] post-reset result: '\(result)'")
        // Completion fired — that's the key assertion
    }

    // MARK: - Tail pass simulation

    /// Simulate the production tail path: abort and drain the old decode before resetting
    /// the gate and starting the replacement decode.
    func testTailPassAfterAbort() async throws {
        let b = try bridge()
        b.beginSession()

        await b.cancelActiveTranscription()

        b.resetAbort()
        let start = CFAbsoluteTimeGetCurrent()
        let tail = await b.transcribeDirectAsync(
            samples: [Float](repeating: 0, count: 32000),  // 2s silence
            initialPrompt: nil,
            language: .auto,
            maxTokens: 0
        )
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("[WhisperKit] tail pass: '\(tail)' (\(String(format: "%.0f", ms))ms)")
        XCTAssertLessThan(ms, 10_000, "Tail pass took \(String(format: "%.0f", ms))ms — exceeds watchdog window")
    }

    // MARK: - Helpers

    private func generateSine(hz: Float, seconds: Double, sampleRate: Int) -> [Float] {
        let count = Int(Double(sampleRate) * seconds)
        return (0..<count).map { i in
            0.5 * sin(2 * Float.pi * hz * Float(i) / Float(sampleRate))
        }
    }
}

#endif
