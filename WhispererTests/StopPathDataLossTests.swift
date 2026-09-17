//
//  StopPathDataLossTests.swift
//  WhispererTests
//
//  Regression cover for the 2026-09-16 data loss: a two-minute dictation whose stop path
//  blocked ~29s draining a Nemotron preview backlog it then discarded, tripping the stop
//  watchdog, which finalized the history row with a `Sessions/` filename that no consumer
//  could resolve — leaving a row with a duration, a dead play button, and no audio on disk.
//
//  Fast by design: no models are loaded. The fakes below stand in for the backend and the
//  Nemotron bridge so the queueing, shedding and abandon behaviour can be driven directly.
//

import XCTest
@testable import whisperer

// MARK: - Fakes

/// Minimal eager-capable backend. Decodes nothing; exists so `StreamingTranscriber` can be
/// constructed on the whisper.cpp-shaped path (`usesEagerStream == true`).
private final class SilentEagerBackend: TranscriptionBackend, @unchecked Sendable {
    func transcribe(samples: [Float], initialPrompt: String?, language: TranscriptionLanguage,
                    singleSegment: Bool, maxTokens: Int32) -> String { "" }

    func transcribeAsync(samples: [Float], initialPrompt: String?, language: TranscriptionLanguage,
                         singleSegment: Bool, maxTokens: Int32, completion: @escaping (String) -> Void) {
        completion("")
    }

    func isContextHealthy() -> Bool { true }
    func prepareForShutdown() {}

    var streamingPolicy: BackendStreamingPolicy {
        BackendStreamingPolicy(
            supportsEagerWordStream: true,
            requiresEagerEngine: true,
            suppressesVADChunking: false,
            maxVADChunkDuration: 12.0,
            previewPollInterval: 0.15,
            previewSharesDecodeQueue: true,
            serializesInferenceWithPreview: true
        )
    }
}

#if canImport(FluidAudio)
/// A Nemotron bridge whose `feed()` is deliberately slower than real time — the condition that
/// produced the unbounded backlog in the field.
private actor SlowNemotronBridge: NemotronBridging {
    let feedDelayNanos: UInt64
    private(set) var feedCount = 0
    private(set) var fedSamples = 0
    private(set) var endSessionCount = 0

    init(feedDelayNanos: UInt64) { self.feedDelayNanos = feedDelayNanos }

    func forcedLanguageSupport(for language: TranscriptionLanguage) async -> (code: String, isSupported: Bool)? { nil }
    func beginSession(language: TranscriptionLanguage) async {}
    func setPreviewCallback(_ callback: @escaping @Sendable (String) -> Void) async {}

    func feed(samples: [Float]) async {
        feedCount += 1
        fedSamples += samples.count
        try? await Task.sleep(nanoseconds: feedDelayNanos)
    }

    func endSession() async -> String {
        endSessionCount += 1
        return "final"
    }

    func detectedLanguageCode() async -> String? { nil }
    func pinLanguage(_ code: String?) async {}
}
#endif

// MARK: - Feed chain

@MainActor
final class NemotronFeedChainTests: XCTestCase {

    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` synthesizes an isolated `deinit`, which aborts
    /// the test host when a pure-Swift `@MainActor` class is deallocated from a synchronous test
    /// method. Keeping every transcriber alive for the process sidesteps it — see `CLAUDE.md`.
    private static var keepAlive: [AnyObject] = []

    private func makeTranscriber(nemotron: AnyObject?) -> StreamingTranscriber {
        let t = StreamingTranscriber(
            backend: SilentEagerBackend(),
            language: .english,
            nemotronBridge: nemotron,
            eagerStreamOverride: true
        )
        Self.keepAlive.append(t)
        return t
    }

    #if canImport(FluidAudio)

    /// The defect: `feed()` slower than real time grew the serial chain without limit, staling
    /// the HUD and — because `stopAsync` awaited the whole chain — freezing the stop path.
    /// Preview feeds are droppable, so the backlog must stay bounded no matter how much is
    /// pushed at it.
    func testPreviewFeedBacklogStaysBounded() async throws {
        let bridge = SlowNemotronBridge(feedDelayNanos: 50_000_000)  // 50ms per feed
        let transcriber = makeTranscriber(nemotron: bridge)
        transcriber.start(onTranscription: { _ in })
        // `start()` opens the Nemotron session on a Task; feeds are dropped until it completes.
        try await Task.sleep(nanoseconds: 200_000_000)

        // 30s of audio in 100ms buffers, pushed far faster than 50ms-per-feed can absorb.
        let buffer = [Float](repeating: 0, count: 1600)
        for _ in 0..<300 {
            transcriber.addSamples(buffer)
        }

        // 3.0s cap + one in-flight buffer. Without the bound this would be the full 30s.
        let pending = Double(transcriber.pendingNemotronFeedSamplesForTesting) / 16000.0
        XCTAssertLessThanOrEqual(pending, 3.2, "Preview feed backlog is unbounded: \(pending)s queued")

        // Whisper still sees every sample — shedding must not touch the authoritative audio.
        XCTAssertEqual(transcriber.recordedDuration, 30.0, accuracy: 0.01)
    }

    /// The fix. Preview-only Nemotron output is discarded at stop, so the stop path must abandon
    /// the backlog rather than wait for it. Field measurement before the fix: 29s.
    func testPreviewOnlyStopDoesNotWaitForBacklog() async throws {
        let bridge = SlowNemotronBridge(feedDelayNanos: 200_000_000)  // 200ms per feed
        let transcriber = makeTranscriber(nemotron: bridge)
        transcriber.start(onTranscription: { _ in })
        try await Task.sleep(nanoseconds: 200_000_000)

        let buffer = [Float](repeating: 0, count: 1600)
        for _ in 0..<200 { transcriber.addSamples(buffer) }

        let started = Date()
        await transcriber.prepareForStopAsync()
        _ = await transcriber.stopAsync()
        let elapsed = Date().timeIntervalSince(started)

        // One in-flight feed (200ms) plus teardown. Generous ceiling; the regression it guards
        // against is measured in tens of seconds.
        XCTAssertLessThan(elapsed, 3.0, "Stop blocked \(elapsed)s on a backlog whose result is discarded")
    }

    /// `prepareForStopAsync` must not silence a bridge whose transcript is the actual output.
    /// Only the preview-only path may abandon feeds.
    func testFinalDecoderPathStillReceivesEverySample() async throws {
        let bridge = SlowNemotronBridge(feedDelayNanos: 1_000_000)
        // eagerStreamOverride: false → nemotronIsPreviewOnly == false → Nemotron is final.
        let transcriber = StreamingTranscriber(
            backend: SilentEagerBackend(),
            language: .english,
            nemotronBridge: bridge,
            eagerStreamOverride: false
        )
        Self.keepAlive.append(transcriber)
        transcriber.start(onTranscription: { _ in })
        try await Task.sleep(nanoseconds: 200_000_000)

        let buffer = [Float](repeating: 0, count: 1600)
        for _ in 0..<50 { transcriber.addSamples(buffer) }

        await transcriber.prepareForStopAsync()
        let text = await transcriber.stopAsync()

        let fed = await bridge.fedSamples
        XCTAssertEqual(fed, 50 * 1600, "Final-decoder feeds were shed or abandoned — audio lost")
        XCTAssertFalse(text.isEmpty, "Final-decoder transcript was discarded")
    }

    #endif
}

// MARK: - Stop ceiling

final class StopCeilingTests: XCTestCase {

    /// The flat 10s ceiling contradicted `StreamingTranscriber.maxTailSeconds = 600` and
    /// discarded finished tail decodes on long recordings (`asr.done fallback=true`).
    func testCeilingScalesWithRecordingButKeepsAFloorAndACap() {
        XCTAssertEqual(AppState.stopCeilingSeconds(forRecordedDuration: 0), 10.0)
        XCTAssertEqual(AppState.stopCeilingSeconds(forRecordedDuration: 5), 10.0)
        // The recording that lost data: 127s → 63.5s, comfortably past the ~29s stall.
        XCTAssertEqual(AppState.stopCeilingSeconds(forRecordedDuration: 127), 63.5)
        XCTAssertEqual(AppState.stopCeilingSeconds(forRecordedDuration: 3600), 600.0)
    }
}

// MARK: - Damaged history rows

final class MissingAudioRecordTests: XCTestCase {

    private func makeRecord(audioFileURL: String?) -> TranscriptionRecord {
        TranscriptionRecord(
            id: UUID(),
            transcription: "some text",
            audioFileURL: audioFileURL,
            duration: 127,
            language: "en",
            modelUsed: "test"
        )
    }

    /// A row naming a file that is not in `Recordings/` gave the user a play button that failed
    /// with CoreAudio 2003334207 and a Re-transcribe that did nothing.
    func testAudioURLIsNilWhenTheFileIsGone() {
        let record = makeRecord(audioFileURL: "B071CD1A-C990-4E69-907A-2300DD2A9BEE.opus")
        XCTAssertNil(record.audioURL)
        XCTAssertTrue(record.audioIsMissing, "UI needs this to explain the gap instead of hiding the card")
    }

    func testRecordWithNoAudioAtAllIsNotReportedAsMissing() {
        let record = makeRecord(audioFileURL: nil)
        XCTAssertNil(record.audioURL)
        XCTAssertFalse(record.audioIsMissing)
    }

    func testAudioURLResolvesWhenTheFileExists() throws {
        let recordingsDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whisperer/Recordings")
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let name = "stop-path-test-\(UUID().uuidString).opus"
        let url = recordingsDir.appendingPathComponent(name)
        try Data([0x4F, 0x67, 0x67, 0x53]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let record = makeRecord(audioFileURL: name)
        XCTAssertEqual(record.audioURL?.lastPathComponent, name)
        XCTAssertFalse(record.audioIsMissing)
    }
}
