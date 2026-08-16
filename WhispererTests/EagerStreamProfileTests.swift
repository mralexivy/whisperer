//
//  EagerStreamProfileTests.swift
//  WhispererTests
//
//  Profiles the eager streaming path at the shipping window cap against real recordings from the
//  app's own history, stratified short / medium / long / very-long.
//
//  This exists because the previous two changes to this path were made from a synthetic benchmark
//  and a read of the console log, and both were wrong. Nothing here is extrapolated: every number
//  comes from feeding a real recording through the real transcriber at wall-clock real time.
//  Sweeping the cap itself is `EagerStreamWindowSweepTests`; this file measures the value that
//  ships, across a broader corpus than the sweep can afford.
//
//  What it reports per fixture, and in aggregate bucketed by window length:
//
//   - pass latency (p50/p90/max) — the live-preview cadence and the floor on stop-insert delay
//   - window lag — how far behind live audio each decode ran
//   - published-display count, cadence, and time to the first live word
//   - monotonicity violations — a display string that is not an extension of its predecessor
//   - adjacent duplicate runs ("one one", "Let Let") — the failure the user keeps reporting
//   - WER against the transcript the shipping app stored for that same audio
//   - stop latency — key release to final text
//   - skip reasons — which guard declined a pass, and how often
//
//  A full run takes about as long as the corpus takes to speak, roughly 20 minutes.
//
//  Read-only with respect to the user's install: it opens the history DB and the .wav files, and
//  writes its report to /tmp. It never touches the model directory (see the note in
//  EagerStreamEncoderBenchmarkTests about the two times that went wrong).
//

import XCTest
@testable import whisperer

final class EagerStreamProfileTests: XCTestCase {

    /// Fixtures per duration bucket. Enough to see a distribution without the suite taking an
    /// hour — every fixture is decoded by the full large-v3-turbo model in real time.
    /// Halved from 3 when the run started doing two arms per fixture — the wall clock is
    /// (fixtures × duration × 2) and the corpus is fed at real time.
    private let perBucket = 2

    /// The shipping value, read from the app rather than restated here, so this profile cannot
    /// silently describe a cap the app no longer uses.
    private var shippingCap: Double { StreamingTranscriber.defaultEagerMaxWindowSeconds }

    private static let reportURL = URL(fileURLWithPath: "/tmp/whisperer-eager-profile.txt")

    // MARK: - The test

    func testEagerStreamProfileAcrossDurations() async throws {
        let bridge = try loadWhisperBridge()
        let cap = shippingCap

        try? FileManager.default.removeItem(at: Self.reportURL)
        let fixtures = try stratifiedFixtures()
        report("=== Eager stream profile — \(fixtures.count) real recordings, cap=\(cap)s, real-time feed ===")

        // Each fixture runs twice, on the one question that is still open: whether the engine
        // should refuse to confirm a phrase it has already confirmed twice in a row. Same audio,
        // same cap, so the difference between the two rows is that guard and nothing else.
        // Interleaved per fixture rather than run as two separate sweeps, so a machine that gets
        // busy half way through skews both arms equally instead of making one look better.
        //
        // Two axes have been closed here, and both are pinned to their defaults in both arms:
        //
        //  - `eagerPublishesSpeculativeTail` — WER a tie (0.367 vs 0.364, inside the noise
        //    floor) with the tail 3.4s faster to the first live word. Stays on.
        //  - `skipsAnchorCheckAfterBoundaryMove` — halved held passes exactly as predicted (40%
        //    to 20%) and was still decisively wrong: WER 0.364 to 0.739, duplicate runs 4.8 to
        //    17.2 per fixture, 0 fixtures improved and 7 regressed. The check earns its wasted
        //    decodes; the recovered passes are spent producing text that has to be thrown away.
        //    Stays off.
        var results: [EagerRunResult] = []
        for (fixture, samples) in fixtures {
            report(Self.header)
            for suppressesLoops in [false, true] {
                let result = await runEagerFixture(fixture, samples: samples, bridge: bridge,
                                                   capSeconds: cap,
                                                   suppressesRepetitionLoops: suppressesLoops)
                results.append(result)
                report(row(for: result))
            }
        }

        try XCTSkipIf(results.isEmpty, "No fixtures with readable audio — record something first")

        reportWindowBuckets(results)
        reportArmComparison(results)
        reportFailures(results)

        let totalDupes = results.reduce(0) { $0 + $1.duplicateRuns.count }
        let totalMono = results.reduce(0) { $0 + $1.monotonicityViolations }
        report("\nTOTAL duplicate runs: \(totalDupes)   monotonicity violations: \(totalMono)")
        report("Report written to \(Self.reportURL.path)")

        // Two hard assertions. The rest of the report is numbers to read, and a tightening
        // accuracy gate belongs in EagerStreamRegressionTests, which A/Bs against the VAD path.
        XCTAssertFalse(results.contains { $0.passes.count == 0 },
                       "some fixture produced zero eager passes — the eager path did not engage")
        let stalled = results.filter(\.stalled)
        XCTAssertTrue(stalled.isEmpty,
                      "stalled (≤1 pass over a long recording): " +
                      stalled.map { "\($0.id) [\($0.dominantSkip)]" }.joined(separator: ", "))
    }

    // MARK: - Corpus

    /// Up to `perBucket` fixtures from each duration bucket, so the report covers short dictation
    /// and long-form alike rather than whatever happens to be most recent.
    ///
    /// Corpus selection, audio loading, and the truncated-fixture check all live in
    /// `loadEagerCorpus` so this file and the sweep cannot end up measuring different recordings.
    private func stratifiedFixtures() throws -> [EagerFixture] {
        let buckets = Dictionary(uniqueKeysWithValues:
            ["short", "medium", "long", "very-long"].map { ($0, perBucket) })
        let (fixtures, rejected) = loadEagerCorpus(perBucket: buckets)
        for line in rejected { report("skipped fixture: \(line)") }
        try XCTSkipIf(fixtures.isEmpty, "No history recordings with usable audio on disk")
        return fixtures
    }

    // MARK: - Report

    private static let header =
        "id          bucket     arm    dur    passes  p50ms  p90ms  maxms  gap_ms  held%  win_s  meanLag  maxLag  " +
        "disp  first_ms  cad_ms  mono  retract  worst  chunks  cwords  dupes  rpt  WER    stop_ms  holds  skip"

    private func row(for r: EagerRunResult) -> String {
        let numbers = String(
            format: "%5.1f  %6d  %5.0f  %5.0f  %5.0f  %6.0f  %4.0f%%  %5.2f  %7.1f  %6.1f  %4d  %8.0f  %6.0f  %4d  %7d  %5d  %6d  %6d  %5d  %4d  %5.3f  %7.0f",
            r.durationSec, r.passes.count,
            r.passes.p50, r.passes.p90, r.passes.maxLatency,
            r.passes.meanGap, r.heldFraction * 100,
            r.passes.meanWindow, r.passes.meanLag, r.passes.maxLag,
            r.displayCount, r.firstDisplayMs, r.displayCadenceMs,
            r.monotonicityViolations, r.retractedChars, r.maxRetractedChars,
            r.chunkCount, r.chunkWords,
            r.duplicateRuns.count, r.repeatedConfirmedTails, r.wer, r.stopLatencyMs
        )
        let arm = r.suppressesRepetitionLoops ? "dedup" : "raw  "
        // Abbreviated to keep the row on one line; the reasons are long because telling the two
        // anchor failures apart is the point of splitting them.
        let short = ["unanchoredSameStart": "sameStart", "unanchoredAfterBoundaryMove": "afterMove",
                     "largeRetraction": "retract"]
        let holds = r.holds.isEmpty ? "-"
            : r.holds.sorted { $0.key < $1.key }.map { "\(short[$0.key] ?? $0.key)=\($0.value)" }.joined(separator: ",")
        return "\(eagerPad(r.id, 10))  \(eagerPad(r.bucket, 9))  \(arm)  \(numbers)  \(holds)  \(r.dominantSkip)"
    }

    /// The open question, paired per fixture so both arms see identical audio: does refusing a
    /// third consecutive copy of the same phrase cut the duplicate runs without eating speech?
    ///
    /// `dupes` and `WER` are the columns that should move if the hypothesis is right. The risk
    /// runs the other way for genuinely repetitive speech, where the guard would delete words
    /// the speaker said — that shows up as `WER` rising on fixtures whose `dupes` did not fall,
    /// which is why the per-fixture table below matters more than the mean.
    ///
    /// A per-fixture WER delta as well as the mean, because the mean hides a bimodal split — and
    /// because a single run cannot resolve a WER difference below about 0.1 on this corpus, so a
    /// small mean gap is noise unless most fixtures move the same way.
    private func reportArmComparison(_ results: [EagerRunResult]) {
        report("\n=== Repetition-loop guard: off vs on (paired) ===")
        // Median WER as well as the mean, because one fixture can pin the mean on its own.
        // `004a0565` scores 1.000 in every arm of every run: its audio is English, but the
        // transcript the app stored for it is English transliterated into Cyrillic ("Тудей из
        // Бьютифул Дэй"), so a perfect decode still misses every word. The recording is not
        // broken — only its reference is — and it is not the truncation case `loadEagerCorpus`
        // rejects, so it stays in the corpus and the median is what to read instead.
        report("arm    passes  held%  p50ms  chunks  mono  retractChars  dupes  WER    medWER  first_ms  stop_ms")
        for suppresses in [false, true] {
            let arm = results.filter { $0.suppressesRepetitionLoops == suppresses }
            guard !arm.isEmpty else { continue }
            let n = Double(arm.count)
            let sortedWER = arm.map(\.wer).sorted()
            let medianWER = sortedWER[sortedWER.count / 2]
            report((suppresses ? "dedup" : "raw  ") + String(
                format: "  %6.1f  %4.0f%%  %5.0f  %6.1f  %4.1f  %12.0f  %5.1f  %5.3f  %6.3f  %8.0f  %7.0f",
                arm.reduce(0.0) { $0 + Double($1.passes.count) } / n,
                arm.reduce(0.0) { $0 + $1.heldFraction * 100 } / n,
                arm.reduce(0.0) { $0 + $1.passes.p50 } / n,
                arm.reduce(0.0) { $0 + Double($1.chunkCount) } / n,
                arm.reduce(0.0) { $0 + Double($1.monotonicityViolations) } / n,
                arm.reduce(0.0) { $0 + Double($1.retractedChars) } / n,
                arm.reduce(0.0) { $0 + Double($1.duplicateRuns.count) } / n,
                arm.reduce(0.0) { $0 + $1.wer } / n, medianWER,
                arm.reduce(0.0) { $0 + $1.firstDisplayMs } / n,
                arm.reduce(0.0) { $0 + $1.stopLatencyMs } / n))
        }

        report("\nPer fixture (negative delta = the guard is better):")
        report("id          WER raw    WER dedup  delta    dupes raw   dupes dedup")
        var better = 0, worse = 0
        for id in Set(results.map(\.id)).sorted() {
            guard let guarded = results.first(where: { $0.id == id && !$0.suppressesRepetitionLoops }),
                  let skipped = results.first(where: { $0.id == id && $0.suppressesRepetitionLoops })
            else { continue }
            let delta = skipped.wer - guarded.wer
            if delta < -0.005 { better += 1 } else if delta > 0.005 { worse += 1 }
            report(eagerPad(id, 10) + String(
                format: "  %9.3f  %8.3f  %+6.3f  %10d  %11d",
                guarded.wer, skipped.wer, delta,
                guarded.duplicateRuns.count, skipped.duplicateRuns.count))
        }
        report("Fixtures improved: \(better)   regressed: \(worse)   " +
               "(unchanged fixtures are within ±0.005 WER)")
    }

    /// Pass latency bucketed by the window length that produced it. This is the table that would
    /// have prevented the `audio_ctx` mistake: it shows what window sizes the path actually
    /// decodes, next to what they cost.
    private func reportWindowBuckets(_ results: [EagerRunResult]) {
        var buckets: [String: [Double]] = [:]
        for r in results {
            for (window, latency) in zip(r.passes.windows, r.passes.latencies) {
                let label: String
                switch window {
                case ..<1.0:  label = "0.5–1s"
                case ..<2.0:  label = "1–2s"
                case ..<4.0:  label = "2–4s"
                case ..<6.0:  label = "4–6s"
                case ..<7.99: label = "6–8s"
                default:      label = "at cap"
                }
                buckets[label, default: []].append(latency)
            }
        }
        report("\n=== Pass latency by window length (this is the real distribution) ===")
        report("window    n     p50ms   p90ms   maxms")
        for label in ["0.5–1s", "1–2s", "2–4s", "4–6s", "6–8s", "at cap"] {
            guard let values = buckets[label], !values.isEmpty else { continue }
            let sorted = values.sorted()
            report(eagerPad(label, 8) + "  " + String(
                format: "%4d  %6.0f  %6.0f  %6.0f",
                sorted.count,
                sorted[Int(Double(sorted.count - 1) * 0.5)],
                sorted[Int(Double(sorted.count - 1) * 0.9)],
                sorted.last ?? 0))
        }
    }

    /// The actual text for anything that produced duplicates, flicker, or a stall — a count alone
    /// does not tell you which bug you are looking at.
    private func reportFailures(_ results: [EagerRunResult]) {
        let bad = results.filter {
            !$0.duplicateRuns.isEmpty || $0.monotonicityViolations > 0 || $0.wer > 0.25 || $0.stalled
        }
        guard !bad.isEmpty else {
            report("\nNo fixture showed duplicates, flicker, stalls, or WER > 0.25.")
            return
        }
        report("\n=== Fixtures needing attention ===")
        for r in bad {
            report("\n[\(r.id)] \(r.bucket) \(String(format: "%.1f", r.durationSec))s  " +
                   "WER=\(String(format: "%.3f", r.wer))  dupes=\(r.duplicateRuns)  mono=\(r.monotonicityViolations)")
            report("  chunks=\(r.chunkCount) (\(r.chunkWords) words)  passes=\(r.passes.count)  " +
                   "held=\(r.holds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))  " +
                   "skips=\(r.skips.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
            report("  got: \(r.finalText)")
            report("  ref: \(r.reference)")
        }
    }

    private func report(_ line: String) { eagerAppend(line, to: Self.reportURL) }
}
