//
//  RecordingIntegrationTests.swift
//  WhispererTests
//
//  Comprehensive integration test suite that exercises all pipeline permutations
//  using real recordings from the history database.
//
//  Permutation matrix:
//    - Backend: WhisperCpp (default model), Nemotron (if available)
//    - LLM mode: none, Correct, Grammar, Translate
//    - Duration bucket: short (<15s) / medium (15–45s) / long (45–120s) / very-long (>120s)
//    - Language: auto + languages found in DB (en, he, ru, ...)
//
//  All tests auto-skip via XCTSkip when required models or audio files are absent.
//

import AVFoundation
import XCTest
@testable import whisperer

#if canImport(FluidAudio)
import FluidAudio
#endif

// MARK: - RecordingIntegrationTests

final class RecordingIntegrationTests: XCTestCase {

    // Shared resources kept alive to avoid Metal dealloc crash on exit.
    private static var sharedBridge: WhisperBridge?
    private static var sharedProcessor: LLMPostProcessor?
    private static var allFixtures: [RecordingFixture]?

    override class func setUp() {
        super.setUp()
        if allFixtures == nil {
            allFixtures = HistoryTestLoader.loadFixtures(maxCount: 300)
            print("RecordingIntegrationTests: \(allFixtures!.count) fixtures loaded from history DB")
        }
    }

    override class func tearDown() {
        sharedBridge?.prepareForShutdown()
        super.tearDown()
    }

    // MARK: - Shared resource accessors

    private func fixtures() throws -> [RecordingFixture] {
        let f = Self.allFixtures ?? []
        if f.isEmpty {
            throw XCTSkip("No history fixtures found — run the app first to build up recordings")
        }
        return f
    }

    private func bridge() throws -> WhisperBridge {
        if let b = Self.sharedBridge { return b }
        let b = try loadWhisperBridge()
        // Warmup to avoid first-inference latency skewing timing
        b.resetAbort()
        _ = b.transcribe(samples: [Float](repeating: 0, count: 16000),
                         initialPrompt: nil, language: .english, singleSegment: false, maxTokens: 0)
        Self.sharedBridge = b
        return b
    }

    @MainActor
    private func processor() async throws -> LLMPostProcessor {
        if let p = Self.sharedProcessor, p.isModelLoaded { return p }
        let p = LLMPostProcessor()
        do {
            try await p.loadModel(.qwen3_5_4B_mtp)
        } catch {
            throw XCTSkip("LLM model unavailable: \(error.localizedDescription)")
        }
        Self.sharedProcessor = p
        return p
    }

    // MARK: - Prompt helpers (mirror AppState.applyLLMPostProcessing)

    /// Extracts the system prompt portion from AIMode.prompt (same logic as splitPrompt in PerChunkLLMTests).
    private func systemPrompt(for mode: AIMode) -> String {
        let parts = mode.prompt.components(separatedBy: "{transcript}")
        var sys = parts[0]
        if let r = sys.range(of: "[INPUT]", options: .backwards) {
            sys = String(sys[..<r.lowerBound])
        }
        return sys.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Corrector closure that mirrors AppState.applyLLMPostProcessing.
    private func makeCorrector(mode: AIMode, proc: LLMPostProcessor) -> (String, String?) async -> String {
        let sys = systemPrompt(for: mode)
        return { [mode, sys] text, contextTail in
            var sysPrompt = sys
            if contextTail != nil {
                sysPrompt += "\n\nThis is a speech fragment from a continuous dictation stream — it may begin or end mid-sentence. Do NOT capitalize the first word unless the source already capitalizes it or it is a proper noun/acronym. Do NOT add terminal punctuation (.!?) at the end unless the source already contains it."
            }
            let userMsg = "[INPUT]\n\(text)\n[/INPUT]"
            let result = (try? await proc.process(
                text: text,
                systemPrompt: sysPrompt,
                userMessage: userMsg,
                temperature: mode.temperature,
                topP: mode.topP,
                topK: mode.topK,
                repetitionPenalty: mode.repetitionPenalty,
                maxTokensCap: mode.maxTokensCap
            )) ?? text
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Chunk-capable AI modes

    private var chunkModes: [AIMode] {
        AIMode.builtInModes.filter { $0.supportsChunkProcessing }
    }

    // MARK: - 1. Transcription accuracy across all recordings

    func testTranscriptionAccuracyAllRecordings() throws {
        let bridge = try bridge()
        let allF = try fixtures()
        let withAudio = allF.filter { $0.audioURL != nil }

        guard !withAudio.isEmpty else {
            throw XCTSkip("No fixtures with audio files found")
        }

        struct GroupKey: Hashable { let bucket: String; let lang: String }
        var groups: [GroupKey: (f1Sum: Double, count: Int)] = [:]

        var processed = 0
        for fixture in withAudio {
            guard let audioURL = fixture.audioURL,
                  let samples = try? loadAudioSamples(from: audioURL) else { continue }

            bridge.resetAbort()
            let text = bridge.transcribe(
                samples: samples, initialPrompt: nil, language: .auto,
                singleSegment: false, maxTokens: 0
            )

            let f1 = wordOverlapF1(text, fixture.transcript)
            let key = GroupKey(bucket: fixture.durationBucket, lang: fixture.language)
            groups[key, default: (0, 0)].f1Sum += f1
            groups[key, default: (0, 0)].count += 1
            processed += 1
        }

        print("\n── Transcription Accuracy by Bucket + Language ──")
        print("╔══════════╦══════╦═══════╦════════╗")
        print("║ Bucket   ║ Lang ║ Count ║ F1 avg ║")
        print("╠══════════╬══════╬═══════╬════════╣")
        var totalF1 = 0.0; var totalCount = 0
        for (key, val) in groups.sorted(by: { "\($0.key.bucket)\($0.key.lang)" < "\($1.key.bucket)\($1.key.lang)" }) {
            let avg = val.count > 0 ? val.f1Sum / Double(val.count) : 0
            totalF1 += val.f1Sum; totalCount += val.count
            let lbl = key.bucket.padding(toLength: 8, withPad: " ", startingAt: 0)
            print(String(format: "║ %@ ║ %-4@ ║  %3d  ║  %.2f  ║", lbl, key.lang, val.count, avg))
            // Require ≥3 fixtures to have a statistically meaningful average.
            // Single-sample groups (e.g. one German recording) have too much variance.
            if val.count >= 3 {
                XCTAssertGreaterThan(avg, 0.75,
                    "\(key.bucket)/\(key.lang): mean transcription F1=\(String(format: "%.2f", avg)) < 0.75")
            }
        }
        print("╠══════════╬══════╬═══════╬════════╣")
        let overall = totalCount > 0 ? totalF1 / Double(totalCount) : 0
        print(String(format: "║ TOTAL    ║  —   ║  %3d  ║  %.2f  ║", totalCount, overall))
        print("╚══════════╩══════╩═══════╩════════╝")
        print("Processed \(processed)/\(withAudio.count) fixtures with audio")
    }

    // MARK: - 2. Per-chunk LLM quality across all recordings × all modes

    func testPerChunkLLMAllRecordings() async throws {
        let proc = try await processor()
        let allF = try fixtures()

        struct GroupKey: Hashable { let bucket: String; let modeName: String }
        struct GroupVal { var f1Sum = 0.0; var bdrySum = 0; var count = 0; var timeSum = 0.0 }
        var groups: [GroupKey: GroupVal] = [:]
        var failureCount = 0

        for mode in chunkModes {
            let sysPrompt = systemPrompt(for: mode)
            for fixture in allF {
                // Batch: single LLM call over full transcript (reference)
                let batchUser = "[INPUT]\n\(fixture.transcript)\n[/INPUT]"
                let batchResult = (try? await proc.process(
                    text: fixture.transcript, systemPrompt: sysPrompt, userMessage: batchUser,
                    temperature: mode.temperature, topP: mode.topP, topK: mode.topK,
                    repetitionPenalty: mode.repetitionPenalty, maxTokensCap: mode.maxTokensCap
                )) ?? fixture.transcript

                // Per-chunk: ChunkLLMCoordinator
                let chunks = simulateChunks(fixture.transcript)
                let coordinator = ChunkLLMCoordinator()
                coordinator.corrector = makeCorrector(mode: mode, proc: proc)
                let chunkStart = CFAbsoluteTimeGetCurrent()
                for chunk in chunks { coordinator.enqueue(chunkText: chunk) }
                let perChunkResult = await coordinator.drain()
                let elapsed = CFAbsoluteTimeGetCurrent() - chunkStart

                let f1 = wordOverlapF1(batchResult, perChunkResult)
                let bdry = boundaryArtifactCount(
                    correctedChunks: coordinator.correctedChunks, rawChunks: chunks)

                let key = GroupKey(bucket: fixture.durationBucket, modeName: mode.name)
                groups[key, default: GroupVal()].f1Sum += f1
                groups[key, default: GroupVal()].bdrySum += bdry
                groups[key, default: GroupVal()].count += 1
                groups[key, default: GroupVal()].timeSum += elapsed

                if f1 < 0.80 { failureCount += 1 }

                // Compare vs stored ground truth when mode matches.
                // Guards: (1) Custom mode has no stable prompt definition — skip it.
                //         (2) Short texts (<20 words) cause high F1 variance between any
                //             two corrections; a single synonym drops below 0.70, so skip.
                if let storedAI = fixture.aiEnhancedText, fixture.aiModeName == mode.name,
                   mode.id != AIMode.customModeId,
                   storedAI.split(separator: " ").count >= 20,
                   perChunkResult.split(separator: " ").count >= 20 {
                    let f1vsStored = wordOverlapF1(perChunkResult, storedAI)
                    XCTAssertGreaterThan(f1vsStored, 0.70,
                        "\(fixture.durationBucket)/\(mode.name): F1 vs stored=\(String(format: "%.2f", f1vsStored)) < 0.70")
                }
            }
        }

        print("\n── Per-Chunk LLM Quality: all recordings × all modes ──")
        print("╔══════════╦══════════╦═══════╦════════╦══════════╦═════════╗")
        print("║ Bucket   ║ AI Mode  ║ Count ║ F1 avg ║ Bdr/rec  ║ Time/c  ║")
        print("╠══════════╬══════════╬═══════╬════════╬══════════╬═════════╣")
        for (key, val) in groups.sorted(by: { "\($0.key.bucket)\($0.key.modeName)" < "\($1.key.bucket)\($1.key.modeName)" }) {
            let avg = val.count > 0 ? val.f1Sum / Double(val.count) : 0
            let bdr = val.count > 0 ? Double(val.bdrySum) / Double(val.count) : 0
            let tpc = val.count > 0 ? val.timeSum / Double(val.count) : 0
            let bkt = key.bucket.padding(toLength: 8, withPad: " ", startingAt: 0)
            let mod = key.modeName.padding(toLength: 8, withPad: " ", startingAt: 0)
            print(String(format: "║ %@ ║ %@ ║  %3d  ║  %.2f  ║   %.1f    ║  %.2fs  ║",
                         bkt, mod, val.count, avg, bdr, tpc))
        }
        print("╚══════════╩══════════╩═══════╩════════╩══════════╩═════════╝")

        let total = groups.values.map { $0.count }.reduce(0, +)
        let failPct = total > 0 ? Double(failureCount) / Double(total) * 100 : 0
        if failureCount > 0 {
            print("⚠️  \(failureCount) fixture×mode pair(s) below F1=0.80 (\(String(format: "%.1f", failPct))%)")
        }
        XCTAssertLessThan(failPct, 15.0,
            "\(String(format: "%.1f", failPct))% of fixture×mode pairs have F1 < 0.80 (threshold: 15%)")
    }

    // MARK: - 3. Nemotron end-to-end with real recordings

    #if canImport(FluidAudio)
    func testNemotronEndToEnd() async throws {
        try XCTSkipUnless(BackendType.nemotron.isAvailable, "Nemotron requires Apple Silicon")
        try XCTSkipUnless(NemotronBridge.isModelCached(), "Nemotron model not downloaded — run app first")

        let allF = try fixtures()
        // Prefer medium-length recordings (5–90s). Very-long recordings (>90s)
        // make the test take several minutes each — not useful for CI.
        let withAudio = allF.filter { $0.audioURL != nil && $0.durationSec > 5 && $0.durationSec < 90 }
            .prefix(10)
        guard !withAudio.isEmpty else {
            throw XCTSkip("No fixtures with audio files found for Nemotron test (need 5–90s recordings)")
        }

        print("Loading Nemotron bridge from cache...")
        let bridge = try await NemotronBridge.loadFromCache()
        let proc = try? await processor()

        var f1Values: [Double] = []
        for fixture in withAudio {
            guard let audioURL = fixture.audioURL,
                  let samples = try? loadAudioSamples(from: audioURL) else { continue }

            await bridge.beginSession(language: .auto)
            let chunkLen = NemotronBridge.chunkMs * 16  // samples per 1120ms chunk at 16kHz
            for offset in stride(from: 0, to: samples.count, by: chunkLen) {
                let end = min(offset + chunkLen, samples.count)
                await bridge.feed(samples: Array(samples[offset..<end]))
            }
            let nemotronText = await bridge.endSession()
            guard !nemotronText.isEmpty else { continue }

            let f1 = wordOverlapF1(nemotronText, fixture.transcript)
            f1Values.append(f1)

            if let proc, let mode = chunkModes.first {
                let coordinator = ChunkLLMCoordinator()
                coordinator.corrector = makeCorrector(mode: mode, proc: proc)
                for chunk in simulateChunks(nemotronText) { coordinator.enqueue(chunkText: chunk) }
                let corrected = await coordinator.drain()
                let f1c = wordOverlapF1(corrected, fixture.transcript)
                print(String(format: "  [%@] Nemotron F1=%.2f → +LLM F1=%.2f  (%.0fs)",
                             fixture.durationBucket, f1, f1c, fixture.durationSec))
            }
        }

        bridge.prepareForShutdown()

        guard !f1Values.isEmpty else {
            throw XCTSkip("No Nemotron transcriptions produced — check audio files")
        }

        let meanF1 = f1Values.reduce(0, +) / Double(f1Values.count)
        print(String(format: "\nNemotron mean F1 vs stored transcript: %.2f  (n=%d)", meanF1, f1Values.count))
        XCTAssertGreaterThan(meanF1, 0.65,
            "Nemotron mean F1=\(String(format: "%.2f", meanF1)) < 0.65 — pipeline quality degraded")
    }
    #endif

    // MARK: - 4. All-permutations report (always passes — use for before/after comparison)

    func testAllPermutationsReport() async throws {
        let allF = (try? fixtures()) ?? []
        guard !allF.isEmpty else { print("No fixtures found — skipping report"); return }

        let proc = try? await processor()

        struct RowKey: Hashable { let bucket: String; let lang: String; let modeName: String }
        struct RowVal { var f1Sum = 0.0; var bdrySum = 0; var count = 0 }
        var table: [RowKey: RowVal] = [:]

        let modes: [AIMode?] = [nil] + chunkModes.map { Optional($0) }

        for modeOpt in modes {
            for fixture in allF {
                let langGroup = ["en", "he", "ru"].contains(fixture.language) ? fixture.language : "other"

                if let mode = modeOpt, let proc {
                    let sysPrompt = systemPrompt(for: mode)
                    let batchUser = "[INPUT]\n\(fixture.transcript)\n[/INPUT]"
                    let batchResult = (try? await proc.process(
                        text: fixture.transcript, systemPrompt: sysPrompt, userMessage: batchUser,
                        temperature: mode.temperature, topP: mode.topP, topK: mode.topK,
                        repetitionPenalty: mode.repetitionPenalty, maxTokensCap: mode.maxTokensCap
                    )) ?? fixture.transcript

                    let chunks = simulateChunks(fixture.transcript)
                    let coordinator = ChunkLLMCoordinator()
                    coordinator.corrector = makeCorrector(mode: mode, proc: proc)
                    for chunk in chunks { coordinator.enqueue(chunkText: chunk) }
                    let result = await coordinator.drain()

                    let f1 = wordOverlapF1(batchResult, result)
                    let bdry = boundaryArtifactCount(
                        correctedChunks: coordinator.correctedChunks, rawChunks: chunks)
                    let key = RowKey(bucket: fixture.durationBucket, lang: langGroup, modeName: mode.name)
                    table[key, default: RowVal()].f1Sum += f1
                    table[key, default: RowVal()].bdrySum += bdry
                    table[key, default: RowVal()].count += 1
                } else {
                    let key = RowKey(bucket: fixture.durationBucket, lang: langGroup, modeName: "none")
                    table[key, default: RowVal()].count += 1
                }
            }
        }

        print("\n╔════════════╦══════╦══════════╦═══════╦════════╦══════════╗")
        print("║ Bucket     ║ Lang ║ AI Mode  ║ Count ║ F1 avg ║ Bdr/rec  ║")
        print("╠════════════╬══════╬══════════╬═══════╬════════╬══════════╣")
        for (key, val) in table.sorted(by: {
            "\($0.key.bucket)\($0.key.lang)\($0.key.modeName)" <
            "\($1.key.bucket)\($1.key.lang)\($1.key.modeName)"
        }) {
            let hasLLM = key.modeName != "none"
            let avg = hasLLM && val.count > 0 ? val.f1Sum / Double(val.count) : 0
            let bdr = hasLLM && val.count > 0 ? Double(val.bdrySum) / Double(val.count) : 0
            let bkt = key.bucket.padding(toLength: 10, withPad: " ", startingAt: 0)
            let mod = key.modeName.padding(toLength: 8, withPad: " ", startingAt: 0)
            let f1s = hasLLM ? String(format: " %.2f ", avg) : "  —   "
            let bdrs = hasLLM ? String(format: "  %.1f   ", bdr) : "  —    "
            print("║ \(bkt) ║ \(key.lang.padding(toLength: 4, withPad: " ", startingAt: 0)) ║ \(mod) ║  \(String(format: "%3d", val.count))  ║\(f1s)║\(bdrs)║")
        }
        print("╚════════════╩══════╩══════════╩═══════╩════════╩══════════╝")
        print("F1: per-chunk vs batch | Bdr/rec: boundary artifacts per recording")
    }

    // MARK: - Boundary artifact counter

    private func boundaryArtifactCount(correctedChunks: [String], rawChunks: [String]) -> Int {
        var count = 0
        for i in 1..<min(correctedChunks.count, rawChunks.count) {
            let corrected = correctedChunks[i].trimmingCharacters(in: .whitespaces)
            let raw = rawChunks[i].trimmingCharacters(in: .whitespaces)
            guard let rFirst = raw.first, rFirst.isLowercase,
                  let cFirst = corrected.first else { continue }
            if cFirst.isUppercase { count += 1 }
        }
        return count
    }
}
