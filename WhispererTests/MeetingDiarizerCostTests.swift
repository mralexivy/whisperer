//
//  MeetingDiarizerCostTests.swift
//  WhispererTests
//
//  What the speaker diarizer costs per minute of meeting audio: wall time, GPU time and process
//  energy. Opt-in: TEST_RUNNER_DIARIZER_COST=/path/to/16k-mono.wav
//

import XCTest
@testable import whisperer

#if canImport(FluidAudio)
import FluidAudio

final class MeetingDiarizerCostTests: XCTestCase {

    func testCostPerMinute() async throws {
        guard let path = ProcessInfo.processInfo.environment["DIARIZER_COST"] else { throw XCTSkip("set TEST_RUNNER_DIARIZER_COST") }
        try XCTSkipUnless(MeetingDiarizerService.isModelCached(), "Nemotron-3 not cached")
        let models = try await Nemotron3Models.loadFromHuggingFace(
            config: MeetingDiarizerService.config, cacheDirectory: MeetingDiarizerService.modelsRoot())
        let diarizer = Nemotron3Diarizer(config: MeetingDiarizerService.config, models: models)
        let audio = try loadAudioSamples(from: URL(fileURLWithPath: path))
        _ = try diarizer.processComplete(Array(audio.prefix(16_000 * 5)))   // warm

        let before = await EnergyMonitor.readTask()
        let started = Date()
        _ = try diarizer.processComplete(audio)
        let wall = Date().timeIntervalSince(started)
        let after = await EnergyMonitor.readTask()
        let minutes = Double(audio.count) / 16_000 / 60
        if let a = before, let b = after {
            print(String(format: "[DiarizerCost] %.1f min audio: %.2fs wall (%.3fs/min), GPU %.2fs, %.1f J (%.1f J/min)",
                         minutes, wall, wall / minutes, Double(b.gpu - a.gpu) / 1e9,
                         Double(b.energy - a.energy) / 1e9, Double(b.energy - a.energy) / 1e9 / minutes))
        }
    }
}
#endif
