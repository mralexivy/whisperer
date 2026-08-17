//
//  TailAudioCtxTests.swift
//  WhispererTests
//
//  Gate for sizing `audio_ctx` to the tail on the stop path.
//
//  The stop path's tail decode used to encode a fixed 30s mel window regardless of how much
//  audio it was actually given. Measured over five real stops it cost ~687ms flat — 0.60s of
//  audio cost 675ms and 3.30s cost 698ms. Sizing `audio_ctx` from the sample count should make
//  that cost proportional.
//
//  The risk this file exists to police is NOT latency, it is the truncation-induced decoder
//  looping documented above `runEagerStreamPass` in StreamingTranscriber: a fixed `audio_ctx`
//  applied to a too-long window made the decoder emit "Let me try to see it one one Let Let me".
//  So the accuracy gate is the load-bearing one and the latency gate is the payoff.
//

import XCTest
@testable import whisperer

final class TailAudioCtxTests: XCTestCase {

    // MARK: - Pure sizing arithmetic (no model, no audio, runs in microseconds)

    /// The whole safety argument rests on this: the returned context must always cover at least
    /// the audio handed in. If this can ever return less, the decoder can loop.
    func testSizingNeverCoversLessAudioThanSupplied() {
        // Sweep every tail length the stop path can plausibly produce, at 10ms resolution,
        // plus well past the 30s clamp.
        for ms in stride(from: 10, through: 45_000, by: 10) {
            let samples = Int(Double(ms) / 1000.0 * 16000.0)
            let ctx = WhisperBridge.audioCtxForSamples(samples)

            // Frames the audio genuinely occupies: 50 frames per second, rounded up.
            let required = (Double(samples) / 16000.0 * 50.0).rounded(.up)

            // Past 30s, `required` exceeds what whisper's mel context can represent at all —
            // 1500 frames is the model's hard ceiling, not a choice this function makes. So the
            // invariant is: cover the audio, *or* fall back to the full context, which is
            // exactly the behavior that shipped before this change. Anything else is a bug.
            XCTAssertTrue(
                Double(ctx) >= required || ctx == WhisperBridge.fullAudioCtx,
                "ctx=\(ctx) covers less than the \(required) frames \(ms)ms needs, "
                    + "and is not the full-context fallback"
            )
            XCTAssertLessThanOrEqual(ctx, WhisperBridge.fullAudioCtx,
                                     "ctx must never exceed the full 1500-frame context")
        }
    }

    func testSizingClampsToFullContextForLongAudio() {
        // At 30s the padded value blows past 1500, so it must fall back to today's behavior.
        XCTAssertEqual(WhisperBridge.audioCtxForSamples(30 * 16000), WhisperBridge.fullAudioCtx)
        XCTAssertEqual(WhisperBridge.audioCtxForSamples(120 * 16000), WhisperBridge.fullAudioCtx)
    }

    func testSizingRespectsFloorAndDegradesSafely() {
        // Tiny tails must not ask for a degenerate context.
        XCTAssertGreaterThanOrEqual(WhisperBridge.audioCtxForSamples(160), WhisperBridge.minimumAudioCtx)
        // Empty input is not a 0-frame encode, it is "use the default".
        XCTAssertEqual(WhisperBridge.audioCtxForSamples(0), WhisperBridge.fullAudioCtx)
    }

    func testSizingIsMonotonic() {
        // A longer tail must never ask for a smaller context.
        var previous: Int32 = 0
        for ms in stride(from: 100, through: 40_000, by: 100) {
            let ctx = WhisperBridge.audioCtxForSamples(Int(Double(ms) / 1000.0 * 16000.0))
            XCTAssertGreaterThanOrEqual(ctx, previous, "ctx went backwards at \(ms)ms")
            previous = ctx
        }
    }

    /// The measured win only exists if short tails actually get a small context.
    func testRealisticTailLengthsGetASmallContext() {
        // The five real stops measured on 2026-08-17: 0.6s, 0.8s, 0.9s, 2.3s, 3.3s.
        for seconds in [0.6, 0.8, 0.9, 2.3, 3.3] {
            let ctx = WhisperBridge.audioCtxForSamples(Int(seconds * 16000))
            XCTAssertLessThan(ctx, WhisperBridge.fullAudioCtx / 2,
                              "\(seconds)s tail got ctx=\(ctx); no latency win is possible")
        }
    }

    // MARK: - Integration: real model, real recordings

    /// **Negative result, deliberately asserted.** Sizing `audio_ctx` to the tail does not work.
    ///
    /// Run 2026-08-17 over 32 real tail segments from history on `largeTurboQ5`:
    ///
    /// ```
    /// median full=897ms  sized=938ms  saved=-41ms (-5%)  meanWER=19.09  n=32
    /// ```
    ///
    /// Two independent reasons it was reverted:
    ///
    /// 1. **No latency win.** Sized was 5% *slower*. The full-context arm ran first in every
    ///    pair, so cold-cache bias favored the sized arm and it still lost. The flat ~687ms
    ///    seen on the stop path is therefore not encoder work at all, and no amount of mel
    ///    shrinking will reclaim it.
    /// 2. **It destroys the transcript.** Mean WER 19.1 against the full-context output, with
    ///    individual tails at 147 — hypothesis vastly longer than reference, the insertion-heavy
    ///    decoder-looping signature already documented above `runEagerStreamPass`.
    ///
    /// This test asserts the negative so the idea cannot be quietly retried. If a future model
    /// or whisper.cpp version changes the picture, this test will fail — and *that* failure is
    /// the signal to revisit `prepareTailTranscription`, not a reason to weaken the gate.
    func testSizingTailAudioCtxIsNotViable() throws {
        // WhisperBridge frees its context in `deinit`; there is no explicit shutdown to call.
        let bridge = try loadWhisperBridge()

        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 300)
            .filter { $0.audioURL != nil && !$0.transcript.isEmpty }
        try XCTSkipIf(fixtures.isEmpty, "No history fixtures with audio on disk")

        // Tail lengths the stop path actually produces. Take the *end* of each recording,
        // which is what the tail decode sees.
        let tailLengths: [Double] = [0.6, 0.9, 2.3, 3.3]

        var rows: [(id: String, seconds: Double, ctx: Int32,
                    fullMs: Double, sizedMs: Double, wer: Double)] = []

        for fixture in fixtures.prefix(8) {
            guard let url = fixture.audioURL else { continue }
            guard let samples = try? loadAudioSamples(from: url), !samples.isEmpty else { continue }

            for seconds in tailLengths {
                let n = Int(seconds * 16000)
                guard samples.count > n else { continue }
                let tail = Array(samples.suffix(n))
                let ctx = WhisperBridge.audioCtxForSamples(tail.count)

                // Full 30s context — today's behavior, and the reference for correctness.
                let t0 = Date()
                let full = bridge.transcribe(samples: tail, language: .auto, audioCtx: 0)
                let fullMs = Date().timeIntervalSince(t0) * 1000

                // Sized context.
                let t1 = Date()
                let sized = bridge.transcribe(samples: tail, language: .auto, audioCtx: ctx)
                let sizedMs = Date().timeIntervalSince(t1) * 1000

                // Both empty is a legitimate outcome for a tail that lands in silence, and
                // carries no information either way — skip rather than score it.
                if full.isEmpty && sized.isEmpty { continue }

                rows.append((fixture.id, seconds, ctx, fullMs, sizedMs,
                             wordErrorRate(sized, reference: full)))
            }
        }

        try XCTSkipIf(rows.isEmpty, "No usable tail segments decoded")

        print("\n=== tail audio_ctx: sized vs full 30s context ===")
        print("fixture     tail    ctx      full     sized    saved     WER")
        for r in rows {
            let id = String(r.id.prefix(8)).padding(toLength: 8, withPad: " ", startingAt: 0)
            print(String(format: "%@ %6.1fs %6d %8.0fms %8.0fms %6.0fms %7.3f",
                         id, r.seconds, r.ctx, r.fullMs, r.sizedMs,
                         r.fullMs - r.sizedMs, r.wer))
        }

        let meanWER = rows.map(\.wer).reduce(0, +) / Double(rows.count)
        let medianFull = median(rows.map(\.fullMs))
        let medianSized = median(rows.map(\.sizedMs))
        let regressions = rows.filter { $0.wer > 0.15 }

        print(String(format: "\nmedian full=%.0fms  sized=%.0fms  saved=%.0fms (%.0f%%)  meanWER=%.3f  n=%d",
                     medianFull, medianSized, medianFull - medianSized,
                     (1 - medianSized / medianFull) * 100, meanWER, rows.count))

        // --- The negative result, asserted ---
        //
        // Either of these failing means the trade-off has genuinely changed and tail `audio_ctx`
        // deserves a fresh look. Both are deliberately loose, so only a real shift trips them.

        // 1. Sizing is not a meaningful speedup. A 15% win would be the threshold worth
        //    reopening the accuracy question for; measured was -5%.
        XCTAssertGreaterThan(
            medianSized, medianFull * 0.85,
            "Tail audio_ctx is now a real speedup (\(Int(medianFull))ms → \(Int(medianSized))ms). "
                + "The flat tail cost was previously shown NOT to be encoder work — re-measure "
                + "and reconsider wiring it into prepareTailTranscription."
        )

        // 2. Sizing corrupts the transcript. Measured mean WER was 19.1 against full context;
        //    anything still above 0.15 means it remains unusable regardless of latency.
        XCTAssertGreaterThan(
            meanWER, 0.15,
            "Sized audio_ctx now matches full-context text (meanWER=\(meanWER)). "
                + "The looping failure may be fixed — revisit with a fresh latency measurement."
        )

        // Diagnostic only, not a gate: how many tails showed the looping signature.
        print("tails diverging by >0.15 WER: \(regressions.count)/\(rows.count)")
    }

    private func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
