//
//  EnergyMonitorTests.swift
//  WhispererTests
//

import XCTest
@testable import whisperer

@MainActor
final class EnergyMonitorTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    func testDescribeIsTimeWeighted() {
        let now = Date()
        let samples = [
            EnergyMonitor.Sample(at: now, seconds: 60, appWatts: 20, gpuBusy: 1, systemWatts: 80, phase: .meeting),
            EnergyMonitor.Sample(at: now, seconds: 180, appWatts: 4, gpuBusy: 0, systemWatts: nil, phase: .meeting),
        ]
        // (20·60 + 4·180) / 240 = 8 W; 1920 J = 0.53 Wh; GPU 25%; battery only over its own minute.
        XCTAssertEqual(EnergyMonitor.describe(samples), "8.0 W (0.5 Wh), GPU 25%, Mac 80 W on battery")
    }

    /// The counters are live and in the units the monitor assumes: GPU nanoseconds no larger than
    /// wall time, energy that grows with work.
    func testTaskCountersAdvanceWithGPUWork() throws {
        let bridge = try loadWhisperBridge()
        Self.keepAlive.append(bridge)
        _ = bridge.transcribe(samples: [Float](repeating: 0, count: 16_000), initialPrompt: nil, language: .english)
        let before = try XCTUnwrap(EnergyMonitor.readTask())
        let started = Date()
        let speech = (0..<(16_000 * 5)).map { Float(sin(Double($0) * 0.05)) * 0.1 }
        _ = bridge.transcribe(samples: speech, initialPrompt: nil, language: .english)
        let wall = Date().timeIntervalSince(started)
        let after = try XCTUnwrap(EnergyMonitor.readTask())
        let gpuSeconds = Double(after.gpu - before.gpu) / 1e9
        let joules = Double(after.energy - before.energy) / 1e9
        print(String(format: "[Energy] decode %.2fs wall, GPU %.2fs, %.1f J (%.1f W)", wall, gpuSeconds, joules, joules / wall))
        XCTAssertGreaterThan(gpuSeconds, 0, "a Metal decode must show GPU time")
        XCTAssertLessThanOrEqual(gpuSeconds, wall * 1.05)
        XCTAssertGreaterThan(joules, 0)
    }
}
