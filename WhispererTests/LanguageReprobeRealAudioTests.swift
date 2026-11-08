//
//  LanguageReprobeRealAudioTests.swift
//  WhispererTests
//
//  The live-text re-probe, run on the user's own recordings with the production probe on
//  Qwen3-ASR. Each "meeting" opens with a short English clip, as both 2026-11-08 meetings did
//  ("OK, this is Sasha and Keren"), so the start decision lands on English; the re-probe must
//  then move live text to the language actually spoken, on the same cadence and window as
//  `SystemLivePreviewBridge`. Loads Qwen3 (~2.5 GB); skips when it is not downloaded.
//

import XCTest
@testable import whisperer

final class LanguageReprobeRealAudioTests: XCTestCase {

    private static let data = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("TestData/live-preview")
    private static let allowed: [TranscriptionLanguage] = [.english, .hebrew, .russian]
    private static var bridge: Qwen3ASRBridge?
    private static var probe: LanguageProbe?

    private func loadProbe() throws -> LanguageProbe {
        if let probe = Self.probe { return probe }
        guard Qwen3ASRBridge.isModelCached() else { throw XCTSkip("Qwen3-ASR not downloaded") }
        if Self.bridge == nil { Self.bridge = try Qwen3ASRBridge.loadFromCache() }
        let probe = LanguageProbe { LanguageReprobeRealAudioTests.bridge.map { .qwen3($0) } }
        Self.probe = probe
        return probe
    }

    private func meeting(_ names: [String]) throws -> [Float] {
        try names.flatMap { try loadAudioSamples(from: Self.data.appendingPathComponent("\($0).wav")) }
    }

    /// Replays the bridge's language decisions over `audio`; returns the start language and the
    /// second at which live text switched (nil if it never did) to `expected`.
    private func simulate(_ audio: [Float], expected: TranscriptionLanguage) async throws
        -> (start: TranscriptionLanguage, switchedAt: Double?, log: [String]) {
        let probe = try loadProbe()
        var log: [String] = []
        let opening = Array(audio.prefix(SystemLivePreviewBridge.replayLimitSamples).prefix(3 * 16_000))
        let firstAnswer = await probe.identify(samples: opening, allowed: Self.allowed)
        let first = try XCTUnwrap(firstAnswer)
        var current = first.language
        log.append(String(format: "start 3.0s → %@ %.2f", current.rawValue, first.probability))

        var tracker = LanguageReprobeTracker()
        var position = 3 * 16_000
        while position + SystemLivePreviewBridge.reprobeIntervalSamples <= audio.count {
            position += SystemLivePreviewBridge.reprobeIntervalSamples
            let window = Array(audio[(position - SystemLivePreviewBridge.reprobeWindowSamples)..<position])
            guard let r = await probe.identify(samples: window, allowed: Self.allowed) else { continue }
            let seconds = Double(position) / 16_000
            let target = tracker.observe(language: r.language, probability: r.probability, current: current)
            log.append(String(format: "%5.1fs → %@ %.2f%@", seconds, r.language.rawValue, r.probability,
                              target.map { " SWITCH to \($0.rawValue)" } ?? ""))
            if let target {
                current = target
                if target == expected { return (first.language, seconds, log) }
            }
        }
        return (first.language, nil, log)
    }

    func testHebrewMeetingOpenedInEnglishSwitchesLiveText() async throws {
        let audio = try meeting(["en_1922", "he_1922", "he_2121", "he_1922", "he_2121"])
        let result = try await simulate(audio, expected: .hebrew)
        print("[Reprobe] Hebrew meeting: " + result.log.joined(separator: " | "))
        let at = try XCTUnwrap(result.switchedAt, "live text never switched to Hebrew: \(result.log)")
        XCTAssertLessThanOrEqual(at, 50, "Hebrew should take over within ~50 s: \(result.log)")
    }

    func testRussianMeetingOpenedInEnglishSwitchesLiveText() async throws {
        let audio = try meeting(["en_1922", "ru_2120", "ru_1922", "ru_2120", "ru_1922"])
        let result = try await simulate(audio, expected: .russian)
        print("[Reprobe] Russian meeting: " + result.log.joined(separator: " | "))
        let at = try XCTUnwrap(result.switchedAt, "live text never switched to Russian: \(result.log)")
        XCTAssertLessThanOrEqual(at, 50, "Russian should take over within ~50 s: \(result.log)")
    }

    /// An English meeting must stay English: no re-probe may pull it into Hebrew or Russian.
    func testEnglishMeetingStaysEnglish() async throws {
        let audio = try meeting(["en_2123", "en_2121"])
        let probe = try loadProbe()
        var tracker = LanguageReprobeTracker()
        var position = 3 * 16_000
        var log: [String] = []
        while position + SystemLivePreviewBridge.reprobeIntervalSamples <= audio.count {
            position += SystemLivePreviewBridge.reprobeIntervalSamples
            let window = Array(audio[(position - SystemLivePreviewBridge.reprobeWindowSamples)..<position])
            guard let r = await probe.identify(samples: window, allowed: Self.allowed) else { continue }
            log.append(String(format: "%@ %.2f", r.language.rawValue, r.probability))
            XCTAssertNil(tracker.observe(language: r.language, probability: r.probability, current: .english),
                         "an English meeting switched away: \(log)")
        }
        print("[Reprobe] English meeting: " + log.joined(separator: " | "))
    }
}
