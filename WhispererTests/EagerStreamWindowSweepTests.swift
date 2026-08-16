//
//  EagerStreamWindowSweepTests.swift
//  WhispererTests
//
//  Sweeps `StreamingTranscriber.eagerMaxWindowSeconds` against real recordings, reported per
//  duration bucket, with repeats.
//
//  The 8s cap was chosen from a latency-vs-window table gathered at a single cap. That is enough
//  to know the cap was needed and not enough to know 8 is the right number: the cap changes the
//  windows the decoder sees, so the curve it was read off is not the curve that exists once it
//  ships. This measures each candidate end to end instead — latency, how far behind live the
//  decode runs, how much live text reaches the screen, how much GPU time the agreement guard
//  throws away, and WER — and reports every bucket separately, because short dictation and
//  long-form have opposite failure modes.
//
//  **Why repeats.** `EagerStreamProfileTests` ran the same fixture twice under settings that
//  changed only what was *displayed*, and WER came out 0.232 and 0.122. Nothing about the audio or
//  the decode configuration differed; window-alignment timing shifts what the decoder sees and
//  greedy decoding is not stable across that. A single WER per cell therefore cannot resolve a
//  difference smaller than about 0.1, which is larger than any difference between caps is likely
//  to be. Every cell here runs `repeats` times and the report prints the spread next to the
//  median, so a cap ordering can be dismissed as noise on sight rather than believed by default.
//
//  Runs at wall-clock real time (see `runEagerFixture`), so it takes roughly
//  (corpus duration × caps × repeats). With the defaults below that is a bit over an hour.
//
//  Not swept here: `eagerPublishesSpeculativeTail`. Two paired profile runs settled it — the
//  speculative tail wins on WER and by ~2.6s on time-to-first-word — so sweeping it again would
//  double the cost of this run to re-answer a question that has an answer.
//

import XCTest
@testable import whisperer

final class EagerStreamWindowSweepTests: XCTestCase {

    /// Candidate caps, in seconds. The last is effectively "no cap" — the pre-cap behaviour,
    /// kept in the sweep so every run re-measures the thing the cap is supposed to beat rather
    /// than comparing against a number from a previous build.
    private let caps: [Double] = [4, 6, 8, 12, 100_000]

    /// Times each (fixture, cap) cell is measured. Two is the minimum that can show a spread at
    /// all; it is set here rather than higher because cost is linear in it and the corpus is fed
    /// at real time.
    private let repeats = 2

    /// Fixtures per bucket. Small on purpose: cost is (fixtures × duration × caps × repeats), and
    /// a very-long fixture alone is 3½ minutes of wall clock per cell.
    private let perBucket: [String: Int] = ["short": 2, "medium": 2, "long": 2, "very-long": 1]

    private static let reportURL = URL(fileURLWithPath: "/tmp/whisperer-eager-window-sweep.txt")

    func testWindowCapSweepPerBucket() async throws {
        let bridge = try loadWhisperBridge()
        try? FileManager.default.removeItem(at: Self.reportURL)
        let fixtures = try corpus()

        report("=== Eager window cap sweep — \(fixtures.count) recordings × \(caps.count) caps × \(repeats) repeats ===")
        report("Real-time feed. cap=100000 is the uncapped baseline.")
        report("Cap order alternates per repeat, so thermal drift over the run does not accumulate")
        report("against the caps that happen to be measured last.\n")
        report(Self.header)

        var results: [EagerRunResult] = []
        for repeatIndex in 0..<repeats {
            // Reverse the cap order on odd repeats. A sweep this long warms the machine
            // measurably, and with a fixed order that warming lands entirely on the last caps —
            // which reads as "high caps are slow" and is not about the cap at all.
            let order = repeatIndex.isMultiple(of: 2) ? caps : caps.reversed().map { $0 }
            for cap in order {
                for (fixture, samples) in fixtures {
                    let result = await runEagerFixture(fixture, samples: samples,
                                                       bridge: bridge, capSeconds: cap)
                    results.append(result)
                    report(row(result, repeatIndex: repeatIndex))
                }
            }
        }

        try XCTSkipIf(results.isEmpty, "No fixtures with readable audio")

        reportPerBucket(results)
        reportRepeatSpread(results)
        reportStalls(results)
        report("\nReport written to \(Self.reportURL.path)")

        // The one hard gate. Everything else in this file is a number to read; a stall is a
        // recording the user watched produce nothing, and no cap that causes one is shippable.
        let stalled = results.filter(\.stalled)
        XCTAssertTrue(stalled.isEmpty,
                      "stalled runs: " + stalled.map { "\($0.id)@cap\(Int($0.capSeconds))" }.joined(separator: ", "))
    }

    // MARK: - Corpus

    /// Loads each fixture's audio once, up front, so decode timings are not polluted by disk
    /// reads and every cap sees byte-identical input.
    private func corpus() throws -> [EagerFixture] {
        let (fixtures, rejected) = loadEagerCorpus(perBucket: perBucket)
        for line in rejected { report("skipped fixture: \(line)") }
        try XCTSkipIf(fixtures.isEmpty, "No history recordings with usable audio on disk")
        return fixtures
    }

    // MARK: - Report

    private static let header =
        "id          bucket     rep  cap_s   dur    passes  p50ms  p90ms  maxms  gap_ms  held%  win_s  " +
        "meanLag  maxLag  disp  first_ms  cad_ms  mono  dupes  WER    stop_ms  skip"

    private func row(_ r: EagerRunResult, repeatIndex: Int) -> String {
        // Text columns are padded by hand, never through `%@` — see `eagerPad`.
        let numbers = String(
            format: "%5.1f  %6d  %5.0f  %5.0f  %5.0f  %6.0f  %4.0f%%  %5.2f  %6.1f  %6.1f  %4d  %6.0f  %6.0f  %4d  %5d  %5.3f  %7.0f",
            r.durationSec, r.passes.count,
            r.passes.p50, r.passes.p90, r.passes.maxLatency,
            r.passes.meanGap, r.heldFraction * 100,
            r.passes.meanWindow, r.passes.meanLag, r.passes.maxLag,
            r.displayCount, r.firstDisplayMs, r.displayCadenceMs,
            r.monotonicityViolations, r.duplicateRuns.count, r.wer, r.stopLatencyMs
        )
        return "\(eagerPad(r.id, 10))  \(eagerPad(r.bucket, 9))  \(repeatIndex)    " +
               "\(eagerPad(fmtCap(r.capSeconds), 6))  \(numbers)  \(r.dominantSkip)"
    }

    /// The table the cap decision is actually made from: one line per (bucket, cap), pooled over
    /// repeats.
    ///
    /// Medians, not means, for the per-run columns. One run in the last profile recorded a 249s
    /// pass and a 17-minute stop; a mean lets a single event like that decide which cap looks
    /// best, which is exactly backwards — an outlier that severe is a bug to chase, not a
    /// property of the cap.
    private func reportPerBucket(_ results: [EagerRunResult]) {
        for bucket in ["short", "medium", "long", "very-long"] {
            let inBucket = results.filter { $0.bucket == bucket }
            guard !inBucket.isEmpty else { continue }
            report("\n=== \(bucket) === (medians over repeats)")
            report("cap_s   n   p50ms  p90ms  maxms  held%  meanLag  maxLag  first_ms  disp  mono  dupes  WER    stop_ms")
            for cap in caps {
                let runs = inBucket.filter { $0.capSeconds == cap }
                guard !runs.isEmpty else { continue }
                let latencies = runs.flatMap { $0.passes.latencies }.sorted()
                guard !latencies.isEmpty else {
                    report("\(eagerPad(fmtCap(cap), 6))  \(runs.count)   — no passes —")
                    continue
                }
                report(eagerPad(fmtCap(cap), 6) + String(
                    format: "  %2d  %5.0f  %5.0f  %5.0f  %4.0f%%  %7.1f  %6.1f  %8.0f  %4.1f  %4.1f  %5.1f  %5.3f  %7.0f",
                    runs.count,
                    latencies[Int(Double(latencies.count - 1) * 0.5)],
                    latencies[Int(Double(latencies.count - 1) * 0.9)],
                    latencies.last ?? 0,
                    median(runs.map { $0.heldFraction * 100 }),
                    median(runs.map { $0.passes.meanLag }), runs.map { $0.passes.maxLag }.max() ?? 0,
                    median(runs.map(\.firstDisplayMs)),
                    median(runs.map { Double($0.displayCount) }),
                    median(runs.map { Double($0.monotonicityViolations) }),
                    median(runs.map { Double($0.duplicateRuns.count) }),
                    median(runs.map(\.wer)), median(runs.map(\.stopLatencyMs))
                ))
            }
        }
    }

    /// The noise floor, stated explicitly: for each (fixture, cap) cell, how far apart the repeats
    /// landed. Any difference between caps that is smaller than the worst spread here is not a
    /// difference — read the cap table with this number in hand, not after it.
    private func reportRepeatSpread(_ results: [EagerRunResult]) {
        report("\n=== Repeat spread — the noise floor for every column below it ===")
        report("Same fixture, same cap, different runs. Nothing but decode nondeterminism varies.")
        report("fixture     cap_s   WER spread   p50ms spread")
        var worstWER = 0.0
        for cap in caps {
            for id in Set(results.map(\.id)).sorted() {
                let cell = results.filter { $0.id == id && $0.capSeconds == cap }
                guard cell.count > 1 else { continue }
                let wers = cell.map(\.wer)
                let p50s = cell.map { $0.passes.p50 }
                let spread = (wers.max() ?? 0) - (wers.min() ?? 0)
                worstWER = max(worstWER, spread)
                report(eagerPad(id, 10) + "  " + eagerPad(fmtCap(cap), 6) + String(
                    format: "  %10.3f   %11.0f", spread, (p50s.max() ?? 0) - (p50s.min() ?? 0)))
            }
        }
        report(String(format: "\nWorst WER spread between repeats of an identical cell: %.3f", worstWER))
        report("Treat any WER gap between caps smaller than that as unmeasured, not as a result.")
    }

    private func reportStalls(_ results: [EagerRunResult]) {
        let stalled = results.filter(\.stalled)
        guard !stalled.isEmpty else {
            report("\nNo stalled runs at any cap.")
            return
        }
        report("\n=== STALLED (long recording, ≤1 pass) ===")
        for r in stalled {
            report("[\(r.id)] cap=\(fmtCap(r.capSeconds)) \(String(format: "%.1f", r.durationSec))s  " +
                   "skips=\(r.skips.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
            report("  got: \(r.finalText.prefix(200))")
        }
    }

    private func fmtCap(_ cap: Double) -> String {
        cap >= 100_000 ? "none" : String(format: "%.0f", cap)
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func report(_ line: String) { eagerAppend(line, to: Self.reportURL) }
}
