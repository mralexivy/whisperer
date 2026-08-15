//
//  EagerStreamBaselineTests.swift
//  WhispererTests
//
//  Phase 0a — one-shot baseline capture.
//  Run ONCE on main before Phase 1 changes; output committed to TestData/eager-stream-baseline.json.
//  Subsequent runs verify determinism against the committed file.
//

import AVFoundation
import XCTest
@testable import whisperer

#if canImport(WhisperKit)
import WhisperKit
#endif

// MARK: - EagerStreamBaselineTests

final class EagerStreamBaselineTests: XCTestCase {

    // MARK: - Data Model

    struct ChunkSpan: Codable {
        let start: Double
        let end: Double
        let text: String
    }

    struct BaselineRecord: Codable {
        let fixtureID: String
        let durationSeconds: Double
        let scriptFamily: String
        let storedLanguage: String
        // V3 (largeTurboQ5 / Whisperer V3) backend results
        let v3FinalText: String
        let v3ChunkSpans: [ChunkSpan]
        let v3DisplaySequence: [String]
        let v3FirstWordLatencyMs: Double
        // WhisperKit backend results (nil when WhisperKit model not downloaded)
        let wkFinalText: String?
        let wkChunkSpans: [ChunkSpan]?
        let wkDisplaySequence: [String]?
        let wkFirstWordLatencyMs: Double?
    }

    private struct BaselineFile: Codable {
        let capturedAt: String
        let records: [BaselineRecord]
    }

    // MARK: - Shared Resources

    /// Shared V3 bridge. Kept alive for the class lifetime — Metal contexts survive between tests.
    private static var sharedV3Bridge: WhisperBridge?
    #if canImport(WhisperKit)
    private static var sharedWKBridge: WhisperKitBridge?
    #endif

    override class func setUp() {
        super.setUp()

        // V3 bridge
        if sharedV3Bridge == nil {
            let modelPath = ModelDownloader.shared.modelPath(for: .largeTurboQ5)
            if FileManager.default.fileExists(atPath: modelPath.path) {
                sharedV3Bridge = try? WhisperBridge(modelPath: modelPath)
                if sharedV3Bridge != nil {
                    Logger.info("EagerStreamBaseline: V3 bridge loaded", subsystem: .transcription)
                }
            }
        }

        // WhisperKit bridge — async load inside a sync setUp via expectation
        #if canImport(WhisperKit)
        if sharedWKBridge == nil && BackendType.whisperKit.isAvailable && WhisperKitBridge.isModelCached() {
            let expectation = XCTestExpectation(description: "WhisperKit load for baseline")
            Task {
                sharedWKBridge = try? await WhisperKitBridge.loadFromCache()
                if sharedWKBridge != nil {
                    Logger.info("EagerStreamBaseline: WhisperKit bridge loaded", subsystem: .transcription)
                }
                expectation.fulfill()
            }
            _ = XCTWaiter.wait(for: [expectation], timeout: 300)
        }
        #endif
    }

    override class func tearDown() {
        sharedV3Bridge?.prepareForShutdown()
        sharedV3Bridge = nil
        #if canImport(WhisperKit)
        sharedWKBridge?.prepareForShutdown()
        sharedWKBridge = nil
        #endif
        super.tearDown()
    }

    // MARK: - Baseline File Path

    /// Resolves to `WhispererTests/TestData/eager-stream-baseline.json` relative to the source tree.
    /// `#file` is a compile-time absolute path, so this works regardless of the Xcode build dir.
    private var baselineURL: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()          // WhispererTests/
            .appendingPathComponent("TestData")
            .appendingPathComponent("eager-stream-baseline.json")
    }

    // MARK: - Main Test

    /// Run once to write the baseline. Subsequent runs verify determinism against the committed file.
    func testCaptureBaseline() async throws {
        guard let v3Bridge = Self.sharedV3Bridge else {
            throw XCTSkip("Whisperer V3 model (largeTurboQ5) not downloaded — run the app first")
        }

        // Fixtures with audio files on disk
        let allFixtures = HistoryTestLoader.loadFixtures(maxCount: 300)
            .filter { $0.audioURL != nil }
        try XCTSkipIf(allFixtures.isEmpty, "No fixtures with audio on disk — skip baseline capture")

        let url = baselineURL

        // If baseline exists: determinism check. Otherwise: capture.
        if FileManager.default.fileExists(atPath: url.path) {
            try await runDeterminismCheck(v3Bridge: v3Bridge, fixtures: allFixtures, baselineURL: url)
            return
        }

        // ── Capture mode ────────────────────────────────────────────────────────
        Logger.info("EagerStreamBaseline: capturing baseline for \(allFixtures.count) fixture(s)", subsystem: .transcription)
        print("\n📸 EagerStream baseline — capturing \(allFixtures.count) fixture(s)…\n")

        var records: [BaselineRecord] = []
        for (i, fixture) in allFixtures.enumerated() {
            guard let audioURL = fixture.audioURL else { continue }
            Logger.info("EagerStreamBaseline: [\(i+1)/\(allFixtures.count)] \(fixture.id) (\(fixture.durationBucket))", subsystem: .transcription)
            print("  [\(i+1)/\(allFixtures.count)] \(fixture.id.prefix(12))… \(fixture.durationBucket) (\(String(format: "%.1f", fixture.durationSec))s)")

            guard let record = await captureRecord(
                fixture: fixture,
                audioURL: audioURL,
                v3Bridge: v3Bridge
            ) else {
                Logger.warning("EagerStreamBaseline: skipped \(fixture.id) — audio load failed", subsystem: .transcription)
                continue
            }
            records.append(record)
        }

        // Write JSON
        let formatter = ISO8601DateFormatter()
        let file = BaselineFile(capturedAt: formatter.string(from: Date()), records: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url)

        Logger.info("EagerStreamBaseline: wrote \(records.count) records to \(url.path)", subsystem: .transcription)
        print("""

Eager stream baseline captured:
   \(url.path)
   Records: \(records.count)

   Commit this file:
     git add WhispererTests/TestData/eager-stream-baseline.json

""")
        XCTAssertGreaterThan(records.count, 0, "Should have captured at least one baseline record")
    }

    // MARK: - Per-fixture Capture

    private func captureRecord(
        fixture: RecordingFixture,
        audioURL: URL,
        v3Bridge: WhisperBridge
    ) async -> BaselineRecord? {
        // Load audio without propagating XCTSkip (we are inside a loop)
        guard let samples = loadAudioSamplesOrNil(from: audioURL) else {
            Logger.warning("EagerStreamBaseline: could not load audio from \(audioURL.lastPathComponent)", subsystem: .transcription)
            return nil
        }

        let scriptFamily = dominantScriptFamily(for: fixture.transcript)

        // V3 run
        let v3 = await runV3(bridge: v3Bridge, samples: samples, fixture: fixture)

        // WhisperKit run (optional)
        var wkFinalText: String?
        var wkChunkSpans: [ChunkSpan]?
        var wkDisplaySequence: [String]?
        var wkFirstWordLatencyMs: Double?

        #if canImport(WhisperKit)
        if let wkBridge = Self.sharedWKBridge {
            let wk = await runWhisperKit(bridge: wkBridge, samples: samples, fixture: fixture)
            wkFinalText = wk.finalText
            wkChunkSpans = wk.chunkSpans
            wkDisplaySequence = wk.displaySequence
            wkFirstWordLatencyMs = wk.firstWordLatencyMs
        }
        #endif

        return BaselineRecord(
            fixtureID: fixture.id,
            durationSeconds: fixture.durationSec,
            scriptFamily: scriptFamily,
            storedLanguage: fixture.language,
            v3FinalText: v3.finalText,
            v3ChunkSpans: v3.chunkSpans,
            v3DisplaySequence: v3.displaySequence,
            v3FirstWordLatencyMs: v3.firstWordLatencyMs,
            wkFinalText: wkFinalText,
            wkChunkSpans: wkChunkSpans,
            wkDisplaySequence: wkDisplaySequence,
            wkFirstWordLatencyMs: wkFirstWordLatencyMs
        )
    }

    // MARK: - Backend Runs

    private struct BackendResult {
        let finalText: String
        let chunkSpans: [ChunkSpan]
        let displaySequence: [String]
        let firstWordLatencyMs: Double
    }

    /// Run the V3 (largeTurboQ5) backend via StreamingTranscriber, recording all callbacks.
    private func runV3(
        bridge: WhisperBridge,
        samples: [Float],
        fixture: RecordingFixture
    ) async -> BackendResult {
        bridge.resetAbort()
        let vad = loadVAD()
        let chunkCapture = SpanCapture()
        var displaySequence: [String] = []
        var firstWordLatencyMs: Double = -1
        let startWall = CFAbsoluteTimeGetCurrent()

        let transcriber = StreamingTranscriber(
            backend: bridge,
            vad: vad,
            language: .auto,
            initialPrompt: nil,
            fillerWordRemovalEnabled: false
        )

        transcriber.onChunkCompleted = { [weak chunkCapture] chunk in
            chunkCapture?.append(ChunkSpan(start: chunk.start, end: chunk.end, text: chunk.text))
        }

        transcriber.start { text in
            guard !text.isEmpty else { return }
            if firstWordLatencyMs < 0 {
                firstWordLatencyMs = (CFAbsoluteTimeGetCurrent() - startWall) * 1000
            }
            displaySequence.append(text)
        }

        await feedAudioAsync(to: transcriber, samples: samples)

        let finalText = await transcriber.stopAsync()

        // If no callback ever fired (e.g. pure silence), record total elapsed
        if firstWordLatencyMs < 0 {
            firstWordLatencyMs = (CFAbsoluteTimeGetCurrent() - startWall) * 1000
        }

        return BackendResult(
            finalText: finalText,
            chunkSpans: chunkCapture.spans,
            displaySequence: displaySequence,
            firstWordLatencyMs: firstWordLatencyMs
        )
    }

    #if canImport(WhisperKit)
    /// Run the WhisperKit backend via StreamingTranscriber, recording all callbacks.
    private func runWhisperKit(
        bridge: WhisperKitBridge,
        samples: [Float],
        fixture: RecordingFixture
    ) async -> BackendResult {
        bridge.resetAbort()
        let vad = loadVAD()
        let chunkCapture = SpanCapture()
        var displaySequence: [String] = []
        var firstWordLatencyMs: Double = -1
        let startWall = CFAbsoluteTimeGetCurrent()

        let transcriber = StreamingTranscriber(
            backend: bridge,
            vad: vad,
            language: .auto,
            initialPrompt: nil,
            fillerWordRemovalEnabled: false
        )

        transcriber.onChunkCompleted = { [weak chunkCapture] chunk in
            chunkCapture?.append(ChunkSpan(start: chunk.start, end: chunk.end, text: chunk.text))
        }

        transcriber.start { text in
            guard !text.isEmpty else { return }
            if firstWordLatencyMs < 0 {
                firstWordLatencyMs = (CFAbsoluteTimeGetCurrent() - startWall) * 1000
            }
            displaySequence.append(text)
        }

        await feedAudioAsync(to: transcriber, samples: samples)

        let finalText = await transcriber.stopAsync()

        if firstWordLatencyMs < 0 {
            firstWordLatencyMs = (CFAbsoluteTimeGetCurrent() - startWall) * 1000
        }

        return BackendResult(
            finalText: finalText,
            chunkSpans: chunkCapture.spans,
            displaySequence: displaySequence,
            firstWordLatencyMs: firstWordLatencyMs
        )
    }
    #endif

    // MARK: - Determinism Check

    /// When the baseline file already exists: pick 3 random fixtures, run each 3x,
    /// assert identical V3 output across all runs.
    private func runDeterminismCheck(
        v3Bridge: WhisperBridge,
        fixtures: [RecordingFixture],
        baselineURL: URL
    ) async throws {
        Logger.info("EagerStreamBaseline: determinism check against \(baselineURL.lastPathComponent)", subsystem: .transcription)
        print("\n   EagerStream baseline found — running determinism check…\n")

        let data = try Data(contentsOf: baselineURL)
        let baseline = try JSONDecoder().decode(BaselineFile.self, from: data)

        guard !baseline.records.isEmpty else {
            throw XCTSkip("Baseline file exists but is empty — delete it and re-run to capture")
        }

        // Index fixtures by ID for quick lookup
        let fixtureMap = Dictionary(uniqueKeysWithValues:
            fixtures.compactMap { f -> (String, RecordingFixture)? in
                guard f.audioURL != nil else { return nil }
                return (f.id, f)
            }
        )

        // Candidates: baseline records whose audio is on disk
        var candidates = baseline.records.filter { fixtureMap[$0.fixtureID] != nil }
        candidates.shuffle()
        let sample = Array(candidates.prefix(3))

        guard !sample.isEmpty else {
            throw XCTSkip("No baseline fixtures have audio on disk — determinism check skipped")
        }

        print("  Checking \(sample.count) fixture(s) x 3 runs each for V3 determinism…\n")

        for record in sample {
            guard let fixture = fixtureMap[record.fixtureID],
                  let audioURL = fixture.audioURL,
                  let samples = loadAudioSamplesOrNil(from: audioURL) else {
                Logger.warning("EagerStreamBaseline: cannot load audio for \(record.fixtureID)", subsystem: .transcription)
                continue
            }

            Logger.info("EagerStreamBaseline: determinism fixture \(record.fixtureID)", subsystem: .transcription)
            var runs: [String] = []
            for run in 1...3 {
                Logger.info("EagerStreamBaseline: run \(run)/3 for \(record.fixtureID.prefix(12))", subsystem: .transcription)
                let result = await runV3(bridge: v3Bridge, samples: samples, fixture: fixture)
                runs.append(result.finalText)
            }

            let allMatch = runs.dropFirst().allSatisfy { $0 == runs[0] }
            if allMatch {
                print("  pass \(record.fixtureID.prefix(8))… — 3/3 runs identical")
            } else {
                print("  FAIL \(record.fixtureID.prefix(8))… — MISMATCH across runs!")
                XCTFail("Non-deterministic V3 output for fixture \(record.fixtureID)")
            }
        }

        print("")
    }

    // MARK: - Audio Feeding

    /// Feed samples to the transcriber in 85ms chunks, yielding to the cooperative scheduler
    /// between each chunk. At 1ms yield this runs ~85x faster than real-time, which lets
    /// the VAD scan task interleave without paying the full audio duration in wall-clock.
    private func feedAudioAsync(to transcriber: StreamingTranscriber, samples: [Float]) async {
        let chunkSize = 1365  // ~85ms at 16kHz
        for offset in stride(from: 0, to: samples.count, by: chunkSize) {
            guard !Task.isCancelled else { break }
            let end = min(offset + chunkSize, samples.count)
            transcriber.addSamples(Array(samples[offset..<end]))
            // 1ms yield — gives VAD scan task CPU time without real-time cost
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: - Script Family

    /// Returns a human-readable script family name for the transcript text.
    /// Uses ScriptAnalyzer with no language filter so all scripts are considered.
    /// Falls back to "latin" when the transcript is empty or entirely punctuation.
    private func dominantScriptFamily(for text: String) -> String {
        let scores = ScriptAnalyzer.dominantScript(in: text, allowedLanguages: [])
        guard let dominant = scores.max(by: { $0.value < $1.value })?.key else {
            return "latin"
        }
        switch dominant {
        case .hebrew, .yiddish:
            return "hebrew"
        case .arabic, .persian, .urdu, .pashto, .sindhi:
            return "arabic"
        case .russian, .ukrainian, .bulgarian, .serbian, .belarusian,
             .macedonian, .kazakh, .mongolian, .tajik, .bashkir, .tatar, .turkmen, .uzbek:
            return "cyrillic"
        case .chinese:
            return "cjk-chinese"
        case .japanese:
            return "cjk-japanese"
        case .korean:
            return "cjk-korean"
        case .hindi, .marathi, .nepali, .sanskrit:
            return "devanagari"
        case .greek:
            return "greek"
        case .armenian:
            return "armenian"
        case .georgian:
            return "georgian"
        case .thai:
            return "thai"
        default:
            return "latin"
        }
    }

    // MARK: - Audio Loading (non-throwing)

    /// Loads audio samples as 16kHz mono Float32. Returns nil on any failure rather than
    /// throwing XCTSkip, so callers inside a loop can `continue` without aborting the run.
    private func loadAudioSamplesOrNil(from url: URL) -> [Float]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }
        let inputFormat = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0 else { return nil }
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount),
              (try? audioFile.read(into: inputBuffer)) != nil else { return nil }

        // Already 16kHz mono — return directly
        if inputFormat.sampleRate == 16_000.0 && inputFormat.channelCount == 1 {
            guard let channelData = inputBuffer.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(inputBuffer.frameLength)))
        }

        // Resample to 16kHz mono
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000.0,
            channels: 1,
            interleaved: false
        ) else { return nil }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }

        let ratio = 16_000.0 / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else { return nil }

        var inputConsumed = false
        var convError: NSError?
        converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            inputConsumed = true
            return inputBuffer
        }
        guard convError == nil else { return nil }
        guard let channelData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}

// MARK: - SpanCapture (thread-safe chunk span collector)

/// Thread-safe collector for ChunkSpan values fired from onChunkCompleted callbacks.
/// Uses a class so @Sendable closures can capture it without mutation warnings.
private final class SpanCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _spans: [EagerStreamBaselineTests.ChunkSpan] = []

    func append(_ span: EagerStreamBaselineTests.ChunkSpan) {
        lock.lock(); defer { lock.unlock() }
        _spans.append(span)
    }

    var spans: [EagerStreamBaselineTests.ChunkSpan] {
        lock.lock(); defer { lock.unlock() }
        return _spans
    }
}
