//
//  NemotronPaddingWERTests.swift
//  WhispererTests
//
//  Measures whether 100ms pre-pad + 160ms post-pad silence improves Nemotron
//  WER on real short recordings from the app's history database.
//
//  Gate rule: bridge padding is only applied (in NemotronBridge.swift) if
//  meanWER(with) <= meanWER(without) + 0.02 across the corpus.
//
//  Run:
//    xcodebuild test -project Whisperer.xcodeproj -scheme whisperer \
//      -only-testing WhispererTests/NemotronPaddingWERTests/testPaddingImprovesWER \
//      -destination "platform=macOS" 2>&1 | grep -E "\[|===|SKIP|error:"
//

#if canImport(FluidAudio)
import XCTest
@testable import whisperer

final class NemotronPaddingWERTests: XCTestCase {

    // 100 ms @ 16 kHz — pre-pad fed before real audio
    private static let prePadSamples  = 1600
    // 160 ms @ 16 kHz — post-pad fed before finish()
    private static let postPadSamples = 2560

    func testPaddingImprovesWER() async throws {
        // Requires the Nemotron model to be downloaded in the app first.
        guard NemotronBridge.isModelCached() else {
            throw XCTSkip("Nemotron model not downloaded — open the app, go to Models tab, and download Nemotron first")
        }

        // Load real recordings; keep only short ones (≤5s) with audio files on disk.
        // HistoryTestLoader orders by nearest-to-20s, so we must load many to reach ≤5s recordings.
        let all = HistoryTestLoader.loadFixtures(maxCount: 5000)
        let fixtures = Array(all.filter {
            $0.audioURL != nil &&
            $0.durationSec <= 5.0 &&
            $0.wordCount >= 2 &&
            // Reference is the whisper.cpp full-file decode, not the app's stored output — see
            // `GoldenSet`. On a ≤5s corpus a single dropped word moves WER by ~0.2, so a reference
            // that itself dropped one would swamp the padding effect this test is measuring.
            GoldenSet.reference(for: $0.id) != nil
        }.prefix(30))  // cap at 30 to keep test under ~5 minutes
        guard fixtures.count >= 5 else {
            throw XCTSkip(
                "Need ≥5 short recordings (≤5s with audio) in app history. " +
                "Make some short recordings with Nemotron, then re-run. " +
                "Found \(fixtures.count) qualifying fixtures."
            )
        }
        print("\n[WER] Testing \(fixtures.count) short recordings against Whisper reference transcripts\n")

        let bridge = try await NemotronBridge.loadFromCache()

        var werWithout: [Double] = []
        var werWith:    [Double] = []

        for fixture in fixtures {
            let url = fixture.audioURL!
            let samples = try loadAudioSamples(from: url)
            let language = TranscriptionLanguage(rawValue: fixture.language) ?? .auto

            // --- WITHOUT padding (current production behaviour) ---
            await bridge.beginSession(language: language)
            await bridge.feed(samples: samples)
            let resultWithout = await bridge.endSession()

            // --- WITH padding (manually applied — bridge code is unchanged here) ---
            await bridge.beginSession(language: language)
            let prePad  = [Float](repeating: 0, count: Self.prePadSamples)
            let postPad = [Float](repeating: 0, count: Self.postPadSamples)
            await bridge.feed(samples: prePad)
            await bridge.feed(samples: samples)
            await bridge.feed(samples: postPad)
            let resultWith = await bridge.endSession()

            let reference = GoldenSet.reference(for: fixture.id) ?? fixture.transcript
            let wer0 = wordErrorRate(resultWithout, reference: reference)
            let wer1 = wordErrorRate(resultWith,    reference: reference)
            werWithout.append(wer0)
            werWith.append(wer1)

            print(String(format: "  [%.1fs lang=%@] ref: \"%@\"",
                         fixture.durationSec, fixture.language, reference))
            print(String(format: "           without(WER=%.2f): \"%@\"", wer0, resultWithout))
            print(String(format: "           with   (WER=%.2f): \"%@\"", wer1, resultWith))
            print()
        }

        let meanWithout = werWithout.reduce(0, +) / Double(werWithout.count)
        let meanWith    = werWith.reduce(0, +)    / Double(werWith.count)
        let delta       = meanWith - meanWithout

        print(String(format: "=== WER summary: without=%.3f  with=%.3f  delta=%+.3f (%d recordings) ===\n",
                     meanWithout, meanWith, delta, fixtures.count))

        if delta < 0 {
            print("✅ Padding IMPROVED WER by \(String(format: "%.1f", abs(delta) * 100))pp — safe to apply bridge change.")
        } else if delta <= 0.02 {
            print("➖ Padding had negligible effect (delta within 2pp tolerance).")
        } else {
            print("❌ Padding HURT WER by \(String(format: "%.1f", delta * 100))pp — do NOT apply bridge change.")
        }

        // Fail only if padding actively harms quality beyond a 2pp tolerance.
        XCTAssertLessThanOrEqual(
            meanWith,
            meanWithout + 0.02,
            "Padding raised mean WER by >\(String(format: "%.1f", delta * 100))pp — do not apply bridge change"
        )
    }
}
#endif
