//
//  PolishChunkCorpusDumpTests.swift
//  WhispererTests
//
//  Re-decodes a language-balanced sample of real recordings and writes their **chunk spans** to
//  `Tools/llm-eval/chunk-corpus.json`, so the polish benchmarks can finally call the entry point
//  that ships.
//
//  **Why this exists.** `DeterministicPolisher.polish(chunks:)` is what `AppState` and
//  `MeetingSession` call. Every benchmark until now could only call `polish(text:)`, because the
//  history persists chunk *texts* and throws the timings away (`HistoryManager.appendChunk`). With
//  no pause map, `SentenceTerminator`'s interior rule cannot fire even once — so the dominant edit
//  class in the shipping pipeline has never been scored by anything. Verdict rule 5's 96 measured
//  insertions were all `endOfUtterance`. That is the gap this closes, and it cannot be closed with
//  a proxy: the pauses have to come from a real decode of real audio.
//
//  **Why a cached JSON rather than decoding in the benchmark.** The decode is the expensive part —
//  real-time feed, tens of minutes of GPU — and it does not change between polish runs. Paying it
//  once and committing the result makes every later measurement instant and, more importantly,
//  makes them comparable: two polish arms scored on the same chunk spans differ only in the
//  polisher. The header records the model and decode arguments so a stale corpus is visible
//  rather than silent.
//
//  Opt-in, so a targeted run of the polish suites never accidentally starts an hour of GPU work.
//  The opt-in is a **file**, not an environment variable: this project has no test plan and its
//  scheme forwards no environment, so neither `DUMP_CHUNK_CORPUS=1 xcodebuild …` nor the
//  `TEST_RUNNER_`-prefixed form reaches the test host — both were tried and both silently skipped,
//  which is the worst possible failure mode for a switch that guards an hour of work. A sentinel
//  file crosses the process boundary unconditionally. `EAGER_ONLY_FIXTURE` and the other env-var
//  switches in this suite work only when run from Xcode's UI.
//
//  **The run is resumable, and that is not a nicety.** The first full attempt died at recording 78
//  of 187 on a double free in `SileroVAD`'s teardown (`malloc: pointer being freed was not
//  allocated`, immediately after `Silero VAD context freed`) — a pre-existing fault in the VAD, not
//  in this test, but one that a 187-recording sequential decode is far more likely to hit than any
//  normal run. xcodebuild relaunched the host, the test found nothing to do, and seventeen minutes
//  of GPU work went in the bin. So: every record is flushed to `chunk-corpus.json` as soon as it is
//  decoded, and a run that finds records already there skips those ids and continues. A crash now
//  costs one recording, and xcodebuild's own relaunch finishes the job.
//
//  The sentinel is therefore consumed at the **end**, not the start — deleting it up front is what
//  turned that crash-restart into a silent skip. A completed run removes it so the corpus is not
//  silently rebuilt; an incomplete one leaves it so the next launch resumes.
//
//      touch Tools/llm-eval/.dump-chunk-corpus
//      xcodebuild test-without-building -project Whisperer.xcodeproj -scheme whisperer \
//        -destination "platform=macOS" -only-testing:WhispererTests/PolishChunkCorpusDumpTests
//

import XCTest
@testable import whisperer

final class PolishChunkCorpusDumpTests: XCTestCase {

    /// Quotas per `script/bucket`. Balanced by **script of the stored transcript**, never by
    /// `fixture.language`, which is decoder state: the history's first row is tagged `en` and is
    /// Russian. Hebrew and Russian are over-sampled relative to their share of the corpus (they
    /// are 116 and 156 of 2,621) because a per-script bar needs a per-script n, and en would
    /// otherwise supply 90% of the joins and hide both.
    ///
    /// Spread across duration buckets on purpose. Short dictations hold one or two joins each and
    /// long recordings hold dozens, so sampling by recording rather than by bucket would let a
    /// handful of long en recordings dominate the interior class the corpus exists to measure.
    private let quotas: [String: Int] = [
        "en/short": 30, "en/medium": 35, "en/long": 35, "en/very-long": 20,
        "he/short": 25, "he/medium": 25, "he/long": 25, "he/very-long": 15,
        "ru/short": 25, "ru/medium": 25, "ru/long": 25, "ru/very-long": 15,
    ]

    /// Matches the cap the app ships with, because the cap changes the windows the decoder sees
    /// and therefore where chunks commit. A corpus decoded at a different cap would measure a
    /// pipeline nobody runs.
    private let capSeconds: Double = 8

    func testDumpChunkCorpus() async throws {
        let sentinel = AuthoredGold.evalDirectory.appendingPathComponent(".dump-chunk-corpus")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sentinel.path),
                          "touch Tools/llm-eval/.dump-chunk-corpus — this re-decodes ~300 "
                          + "recordings at real time")

        let bridge = try loadWhisperBridge()

        // Either reference qualifies a recording. Requiring `GoldenSet` alone — the default, and
        // right for the WER sweeps — caps the corpus at 9 Hebrew and 11 Russian recordings, which
        // is not a language-balanced corpus however the quotas are written. The authored gold
        // covers he 55 / ru 47, and rule 5 scores against both references anyway.
        let authored = Set(AuthoredGold.punctuationCases().map(\.id))

        let (fixtures, rejected) = loadEagerCorpus(
            perBucket: quotas,
            quotaKey: { fixture in
                "\(PolishBenchmarkTests.detectedLanguage(of: fixture.transcript))/\(fixture.durationBucket)"
            },
            isEligible: { GoldenSet.reference(for: $0.id) != nil || authored.contains($0.id) })
        for line in rejected { print("skipped fixture: \(line)") }
        try XCTSkipIf(fixtures.isEmpty, "No history recordings with usable audio on disk")

        let url = AuthoredGold.evalDirectory.appendingPathComponent("chunk-corpus.json")

        // Resume: whatever a previous launch got through is kept verbatim and its ids are skipped.
        // Keyed by id rather than appended blindly, so a half-written record from a crash mid-flush
        // is replaced rather than duplicated.
        var records: [[String: Any]] = Self.existingRecords(at: url)
        var done = Set(records.compactMap { $0["id"] as? String })
        let pending = fixtures.filter { !done.contains($0.fixture.id) }

        print("=== chunk corpus dump — \(fixtures.count) recordings, \(done.count) already done, "
              + "\(pending.count) to decode, cap \(capSeconds)s, real time ===")

        for (index, (fixture, samples)) in pending.enumerated() {
            let result = await runEagerFixture(fixture, samples: samples,
                                               bridge: bridge, capSeconds: capSeconds)
            let script = PolishBenchmarkTests.detectedLanguage(of: fixture.transcript)
            records.append([
                "id": fixture.id,
                "script": script,
                "bucket": fixture.durationBucket,
                "durationSec": fixture.durationSec,
                "chunks": result.chunks.map { ["text": $0.text, "start": $0.start, "end": $0.end] },
                "storedTranscript": fixture.transcript,
                // Empty when only the authored gold covers this row. Recorded as empty rather than
                // omitted so a consumer counts it as one reference short instead of failing to
                // decode the record.
                "goldenTranscript": GoldenSet.reference(for: fixture.id) ?? "",
                "hasAuthoredGold": authored.contains(fixture.id),
            ])
            done.insert(fixture.id)
            try Self.write(records, capSeconds: capSeconds, to: url)
            print(String(format: "%3d/%3d  %@  %@  %5.1fs  %2d chunks",
                         index + 1, pending.count, String(fixture.id.prefix(8)).lowercased(),
                         script, fixture.durationSec, result.chunks.count))
        }

        // Only a run that decoded everything it set out to decode retires the sentinel. Leaving it
        // in place after a partial run is what makes xcodebuild's post-crash relaunch resume
        // instead of skipping.
        try? FileManager.default.removeItem(at: sentinel)

        let joins = records.reduce(0) { $0 + max(0, (($1["chunks"] as? [Any])?.count ?? 0) - 1) }
        print("wrote \(records.count) records, \(joins) chunk joins → \(url.path)")
        XCTAssertGreaterThan(joins, 0, "a corpus with no joins cannot measure the interior rule")
    }

    // MARK: - Incremental persistence

    private static func existingRecords(at url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = payload["records"] as? [[String: Any]] else { return [] }
        return records
    }

    /// Rewrites the whole file after every recording. Wasteful in principle and free in practice —
    /// the corpus is a couple of megabytes and the decode it follows took seconds of GPU time.
    /// Written to a sibling and moved into place so a crash during the write cannot leave the
    /// corpus truncated, which would silently discard every record before it too.
    private static func write(_ records: [[String: Any]], capSeconds: Double, to url: URL) throws {
        let payload: [String: Any] = [
            "note": "Chunk spans from a real streaming decode, for DeterministicPolisher"
                  + ".polish(chunks:). Generated by PolishChunkCorpusDumpTests — do not hand-edit.",
            "capSeconds": capSeconds,
            "sampleRate": 16000,
            "spansFrom": "sample counts (sampleIndex / sampleRate), not ASR word timings — which "
                       + "is why the pause signal survives at ASRCapabilities = []",
            "records": records,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys,
                                                        .withoutEscapingSlashes])
        // `replaceItemAt` requires something to replace, so the first flush is a plain write.
        guard FileManager.default.fileExists(atPath: url.path) else { return try data.write(to: url) }
        let temporary = url.appendingPathExtension("partial")
        try data.write(to: temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
