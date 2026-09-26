//
//  LanguageSwitchGateTests.swift
//  WhispererTests
//
//  Real-recording regression tests for the non-primary language switch gate, run with the
//  user's actual routing config (allowed en+ru, primary en). The three English recordings below
//  were decoded and stored as Russian before the gate; Qwen3-ASR transcribes all three as English.
//

import XCTest
@testable import whisperer

final class LanguageSwitchGateTests: XCTestCase {

    private static var bridge: WhisperBridge?
    // Process-lifetime: freeing a SileroVAD or a MainActor-isolated transcriber inside a test
    // method aborts the host (`pointer being freed was not allocated`, see CLAUDE.md).
    private static let vad = loadVAD()
    private static var keepAlive: [AnyObject] = []

    private static let recordingsDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Whisperer/Recordings")

    private func requireBridge() throws -> WhisperBridge {
        if let b = Self.bridge { return b }
        let path = ModelDownloader.shared.modelPath(for: .largeTurboQ5)
        guard FileManager.default.fileExists(atPath: path.path) else { throw XCTSkip("Whisperer V3 missing") }
        let b = try WhisperBridge(modelPath: path)
        _ = b.transcribe(samples: [Float](repeating: 0, count: 16_000), initialPrompt: nil, language: .auto)
        Self.bridge = b
        return b
    }

    private func run(_ samples: [Float]) async throws -> (text: String, locked: TranscriptionLanguage?) {
        let b = try requireBridge()
        b.resetAbort()
        let profile = ModelProfile(model: .largeTurboQ5, backend: .whisperCpp, language: .auto, isSpecialized: false)
        let pool = ModelPool()
        try? pool.loadFallback(profile: profile, backend: b)
        let router = LanguageRouter(allowed: [.english, .russian], primary: .english)
        let modelRouter = ModelRouter(languageModelMap: [:], fallbackProfile: profile)
        let transcriber = StreamingTranscriber(
            backend: b, vad: Self.vad, language: .auto, initialPrompt: nil,
            fillerWordRemovalEnabled: false, modelPool: pool, languageRouter: router,
            modelRouter: modelRouter)
        Self.keepAlive += [transcriber, pool, router, modelRouter]
        transcriber.start { _ in }
        await Task.detached(priority: .userInitiated) {
            feedAudioToTranscriber(transcriber, samples: samples)
        }.value
        try? await Task.sleep(nanoseconds: 3_000_000_000)  // let in-flight passes and probes land
        let text = await transcriber.stopAsync()
        if case .locked(let lang) = router.state { return (text, lang) }
        return (text, nil)
    }

    private func cyrillicShare(_ text: String) -> Double {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return 0 }
        return Double(letters.filter { (0x0400...0x04FF).contains($0.value) }.count) / Double(letters.count)
    }

    private func assertStaysEnglish(_ file: String, _ label: String) async throws {
        let url = Self.recordingsDir.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("\(label) missing") }
        let (text, locked) = try await run(try loadAudioSamples(from: url))
        print("SWITCHGATE \(label): locked=\(locked?.rawValue ?? "nil") cyr=\(String(format: "%.2f", cyrillicShare(text))) → \(text.prefix(120))")
        XCTAssertNotEqual(locked, .russian, "\(label) is English speech")
        XCTAssertLessThan(cyrillicShare(text), 0.05, "\(label) came out in Cyrillic: \(text)")
    }

    func testR3EnglishNotDecodedAsRussian() async throws {
        try await assertStaysEnglish("2026-09-20_09-23-02.opus", "R3")
    }

    func testR5EnglishNotDecodedAsRussian() async throws {
        try await assertStaysEnglish("2026-09-20_11-55-41.opus", "R5")
    }

    func testR135EnglishNotDecodedAsRussian() async throws {
        try await assertStaysEnglish("2026-09-21_17-21-35.opus", "R135")
    }

    /// Non-regression: genuine Russian must still switch. Picks history recordings whose stored
    /// transcript is itself mostly Cyrillic and long enough to probe.
    func testGenuineRussianStillSwitches() async throws {
        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 400).filter {
            $0.language == "ru" && $0.durationSec >= 12 && $0.audioURL != nil
                && cyrillicShare($0.transcript) > 0.8
        }.prefix(3)
        guard !fixtures.isEmpty else { throw XCTSkip("no genuine Russian fixture") }
        for f in fixtures {
            let (text, locked) = try await run(try loadAudioSamples(from: f.audioURL!))
            print("SWITCHGATE ru \(f.audioURL!.lastPathComponent): locked=\(locked?.rawValue ?? "nil") cyr=\(String(format: "%.2f", cyrillicShare(text))) → \(text.prefix(80))")
            XCTAssertGreaterThan(cyrillicShare(text), 0.8, "\(f.audioURL!.lastPathComponent): \(text)")
        }
    }
}
