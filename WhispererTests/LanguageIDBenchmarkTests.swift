//
//  LanguageIDBenchmarkTests.swift
//  WhispererTests
//
//  The production language probe (Whisper V3, user's languages) on 3 s windows of labelled
//  clips: accuracy and cost per probe. Opt-in: TEST_RUNNER_LID_LIST=<tsv of path<TAB>he|en|ru>.
//  Compared against Apple's per-locale dictation in the same windows (scratch tool).
//

import XCTest
@testable import whisperer

final class LanguageIDBenchmarkTests: XCTestCase {

    func testWhisperV3ThreeSecondWindows() async throws {
        guard let listPath = ProcessInfo.processInfo.environment["LID_LIST"] else { throw XCTSkip("set TEST_RUNNER_LID_LIST") }
        let bridge = try loadWhisperBridge()
        let probe = LanguageProbe { .whisper(bridge) }
        let allowed: [TranscriptionLanguage] = [.hebrew, .english, .russian]
        await probe.prepare(for: allowed)
        var correct = 0, total = 0, seconds = 0.0
        for line in try String(contentsOfFile: listPath, encoding: .utf8).split(separator: "\n") {
            let f = line.split(separator: "\t"); guard f.count == 2 else { continue }
            let x = try loadAudioSamples(from: URL(fileURLWithPath: String(f[0])))
            var start = 0
            while start + 320 < x.count {
                let s = x[start..<start + 320].reduce(0) { $0 + $1 * $1 } / 320
                if s.squareRoot() > 0.01 { start = max(0, start - 1600); break }
                start += 320
            }
            var w = Array(x[start..<min(x.count, start + 48_000)])
            if ProcessInfo.processInfo.environment["LID_NORMALIZE"] == "1" {
                let peak = w.map(abs).max() ?? 0
                if peak > 0 { let g = min(30, 0.7 / peak); w = w.map { $0 * g } }
            }
            let t0 = Date()
            let r = await probe.identify(samples: w, allowed: allowed)
            seconds += Date().timeIntervalSince(t0)
            total += 1
            if r?.language.rawValue == String(f[1]) { correct += 1 }
            print(String(format: "[LID-V3] %@ truth=%@ got=%@ p=%.2f", (String(f[0]) as NSString).lastPathComponent,
                         String(f[1]), r?.language.rawValue ?? "-", r?.probability ?? 0))
        }
        print(String(format: "[LID-V3] SUMMARY %d/%d correct, %.2fs per probe", correct, total, seconds / Double(max(total, 1))))
    }
}
