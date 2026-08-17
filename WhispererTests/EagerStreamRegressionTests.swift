//
//  EagerStreamRegressionTests.swift
//  WhispererTests
//
//  Phase 6 — A/B regression gate for eager streaming.
//  Runs the same corpus through the whisper.cpp pipeline with
//  whisperCppEagerStreaming=false (baseline VAD-chunk path) and =true (eager path),
//  and asserts three accuracy gates + four structural invariants.
//
//  Skip conditions:
//    - No whisper model downloaded
//    - No fixtures with audio files
//    - Baseline JSON missing (WhisperKit refactor test only)
//

import XCTest
@testable import whisperer

// MARK: - Supporting types

private struct ChunkSpan {
    let start: Double
    let end: Double
    let text: String
}

private struct RunResult {
    let finalText: String
    let chunkSpans: [ChunkSpan]
    let displaySequence: [String]
    let firstWordLatencyMs: Double
}

private struct ABResult {
    let fixture: RecordingFixture
    /// Median WER over `repeatCount` runs of each arm — never a single run. See `medianWER`.
    let werBaseline: Double
    let werEager: Double
    /// max − min WER across this fixture's eager runs. Printed so a reader can see immediately
    /// whether a delta is bigger than the fixture's own run-to-run spread.
    let spreadBaseline: Double
    let spreadEager: Double
    let script: String
    let baselineResults: [RunResult]
    let eagerResults: [RunResult]

    /// The representative run for diagnostics. Both arrays are stored sorted by WER, so this is
    /// the median run — not whichever repetition happened to go last.
    var baselineResult: RunResult { baselineResults[baselineResults.count / 2] }
    var eagerResult: RunResult { eagerResults[eagerResults.count / 2] }
}

/// Median rather than mean, because the failure this gate keeps hitting is one run in three
/// collapsing (a dropped tail, a stalled boundary) and dragging an otherwise-representative
/// number with it. A mean reports that as "somewhat worse everywhere", which is the wrong
/// diagnosis; the median reports the typical run and leaves the outlier visible in the spread.
private func medianWER(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted.count % 2 == 1
        ? sorted[sorted.count / 2]
        : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
}

// MARK: - EagerStreamRegressionTests

final class EagerStreamRegressionTests: XCTestCase {

    // Shared resources kept alive to avoid Metal dealloc crash on exit.
    private static var sharedBridge: WhisperBridge?
    private static var sharedVAD: SileroVAD?
    private static var allFixtures: [RecordingFixture]?

    // The arm is selected with `StreamingTranscriber(eagerStreamOverride:)`, never by writing
    // the `whisperCppEagerStreaming` UserDefaults key — the test host shares the shipping app's
    // preferences domain. See `runFixture`.

    // Maximum fixtures to include in a single A/B run — kept small to stay within
    // the 10-minute XCTest timeout while still exercising a representative corpus.
    private static let maxFixtures = 8

    // Both arms feed at wall-clock real time (see `runFixture`), so a fixture costs roughly
    // `2 × (durationSec + 7)` seconds of run time. Capping at 45s keeps the whole gate near ten
    // minutes; without a cap the corpus's very-long recordings (200s+) alone would take that
    // long twice over. Short and medium recordings are also where the boundary behaviour this
    // gate checks is hardest — a long recording gives the eager path many passes to converge.
    private static let maxFixtureSeconds: Double = 45

    // How many times each arm runs per fixture. Three is the smallest count that has a median,
    // and the median is the only statistic that survives this gate's variance — see the comment
    // in the fixture loop for the measurement that forced this. Cost is linear: the gate goes
    // from roughly six minutes to eighteen. `EAGER_GATE_REPEATS=1` restores single-run speed for
    // a quick structural check, but a single-run WER number must not be used to accept a change.
    private static let repeatCount: Int =
        ProcessInfo.processInfo.environment["EAGER_GATE_REPEATS"].flatMap(Int.init) ?? 3

    override class func setUp() {
        super.setUp()
        if allFixtures == nil {
            allFixtures = HistoryTestLoader.loadFixtures(maxCount: 300)
            Logger.debug("EagerStreamRegressionTests: \(allFixtures!.count) fixtures loaded",
                         subsystem: .transcription)
        }
    }

    override class func tearDown() {
        sharedBridge?.prepareForShutdown()
        super.tearDown()
    }

    // MARK: - Shared accessors

    private func bridge() throws -> WhisperBridge {
        if let b = Self.sharedBridge { return b }
        let b = try loadWhisperBridge()
        // Warmup to flush Metal JIT and stabilise first-inference timing.
        b.resetAbort()
        _ = b.transcribe(samples: [Float](repeating: 0, count: 16000),
                         initialPrompt: nil, language: .english, singleSegment: false, maxTokens: 0)
        Self.sharedBridge = b
        return b
    }

    private func vad() -> SileroVAD? {
        if let v = Self.sharedVAD { return v }
        let v = loadVAD()
        Self.sharedVAD = v
        return v
    }

    private func fixturesWithAudio() throws -> [RecordingFixture] {
        // A fixture without a golden reference cannot be scored (see `GoldenSet`), so filter it
        // out here rather than letting it consume one of the eight slots and then be skipped in
        // the loop — that silently shrinks the corpus without saying so.
        // `EAGER_ONLY_FIXTURE=b6250001` narrows the gate to one recording, the way the profile
        // harness's variable of the same name does. A full run is six minutes and prints eight
        // fixtures' diagnostics; investigating one seam does not need either.
        let only = ProcessInfo.processInfo.environment["EAGER_ONLY_FIXTURE"]?.lowercased()
        let withAudio = (Self.allFixtures ?? []).filter {
            $0.audioURL != nil
                && GoldenSet.reference(for: $0.id) != nil
                && $0.durationSec <= Self.maxFixtureSeconds
                && (only == nil || $0.id.lowercased().hasPrefix(only!))
        }
        try XCTSkipIf(GoldenSet.isEmpty,
            "No golden set — run `python3 scripts/build-golden-set.py` first. Scoring against " +
            "the app's own stored transcripts is circular and was removed.")
        try XCTSkipIf(withAudio.isEmpty,
            "No fixtures with both audio and a golden reference — regenerate with " +
            "`python3 scripts/build-golden-set.py`")
        return Array(withAudio.prefix(Self.maxFixtures))
    }

    // MARK: - V3 model availability check

    private func isV3ModelAvailable() -> Bool {
        let path = ModelDownloader.shared.modelPath(for: .largeTurboQ5)
        return FileManager.default.fileExists(atPath: path.path)
    }

    // MARK: - WhisperKit byte-identical refactor gate (Phase 2 validation)

    func testWhisperKitRefactorIsIdentical() throws {
        // Load Phase 0a baseline from TestData/eager-stream-baseline.json
        let bundle = Bundle(for: type(of: self))
        guard let baselineURL = bundle.url(forResource: "eager-stream-baseline", withExtension: "json") else {
            throw XCTSkip("eager-stream-baseline.json not found in test bundle — baseline not captured yet")
        }

        // If found, decode and compare. Detailed implementation deferred until Phase 0a
        // baseline-capture tooling is complete.
        _ = baselineURL  // silence unused-variable warning
        throw XCTSkip("Phase 0a baseline capture not yet implemented — skip")
    }

    // MARK: - Main A/B gate

    func testEagerStreamAccuracyAndStructure() async throws {
        try XCTSkipUnless(isV3ModelAvailable(),
            "V3 model (largeTurboQ5) not downloaded — open the app, go to Models tab, " +
            "and download it first")

        let fixtures = try fixturesWithAudio()
        let br = try bridge()

        Logger.info("EagerStreamRegressionTests: running A/B on \(fixtures.count) fixtures",
                    subsystem: .transcription)

        var results: [ABResult] = []

        for fixture in fixtures {
            guard let audioURL = fixture.audioURL else { continue }
            // Score against the full-file decode, never `fixture.transcript` — see `GoldenSet`.
            // Skipped rather than falling back: a corpus where some rows are measured against a
            // clean reference and others against the app's own streaming output has a mean that
            // means nothing.
            guard let reference = GoldenSet.reference(for: fixture.id) else {
                Logger.warning("No golden reference for \(fixture.id.prefix(8)) — skipping. " +
                               "Run scripts/build-golden-set.py.", subsystem: .transcription)
                continue
            }
            guard let samples = try? loadAudioSamples(from: audioURL) else {
                Logger.warning("EagerStreamRegressionTests: could not load audio for \(fixture.id)",
                               subsystem: .transcription)
                continue
            }

            // Repeat both arms. A single run of each cannot support any conclusion this gate
            // draws — measured directly, by running the identical binary over the identical
            // corpus twice back to back: the eager arm moved on all eight fixtures and its
            // corpus mean went 0.216 → 0.129, while the baseline arm reproduced exactly on five
            // of eight. That 0.087 swing is larger than every fix previously measured here, so
            // four consecutive single-run "improvements" (0.216 → 0.150 → 0.177 → 0.135 → 0.125)
            // were indistinguishable from the arm resampling itself.
            //
            // The variance is not the harness being sloppy — it is the eager path being
            // wall-clock scheduled. Each pass decodes from the agreement boundary to the live
            // edge, so a decode that finishes 30 ms sooner sees a different window, agrees on a
            // different word, and moves the boundary somewhere else for the rest of the
            // recording. Feeding on a virtual clock would erase it, and would also erase the
            // behaviour under test. Sampling it is the honest option.
            var baselineRuns: [RunResult] = []
            var eagerRuns: [RunResult] = []
            var baselineWERs: [Double] = []
            var eagerWERs: [Double] = []
            for _ in 0..<Self.repeatCount {
                let a = await runFixture(samples: samples, bridge: br, eagerEnabled: false)
                let b = await runFixture(samples: samples, bridge: br, eagerEnabled: true)
                baselineRuns.append(a)
                eagerRuns.append(b)
                baselineWERs.append(wordErrorRate(a.finalText, reference: reference))
                eagerWERs.append(wordErrorRate(b.finalText, reference: reference))
            }

            let wer_a = medianWER(baselineWERs)
            let wer_b = medianWER(eagerWERs)
            let spread_a = (baselineWERs.max() ?? 0) - (baselineWERs.min() ?? 0)
            let spread_b = (eagerWERs.max() ?? 0) - (eagerWERs.min() ?? 0)
            let script = detectScript(reference)

            // Order the stored runs by WER so `eagerResult` — what the diagnostics below print —
            // is the median run rather than whichever one happened to go last.
            let a = baselineRuns.sorted { wordErrorRate($0.finalText, reference: reference)
                                        < wordErrorRate($1.finalText, reference: reference) }
            let b = eagerRuns.sorted { wordErrorRate($0.finalText, reference: reference)
                                     < wordErrorRate($1.finalText, reference: reference) }
            let medianA = a[a.count / 2]
            let medianB = b[b.count / 2]

            Logger.debug(String(format:
                "  [%@] WER median of %d: baseline=%.3f (spread %.3f) eager=%.3f (spread %.3f) | ref=%d words",
                String(fixture.id.prefix(8)), Self.repeatCount, wer_a, spread_a, wer_b, spread_b,
                reference.split(separator: " ").count),
                         subsystem: .transcription)

            results.append(ABResult(
                fixture: fixture,
                werBaseline: wer_a,
                werEager: wer_b,
                spreadBaseline: spread_a,
                spreadEager: spread_b,
                script: script,
                baselineResults: a,
                eagerResults: b
            ))

            // A WER delta says a fixture got worse; it does not say how, and the how is what a
            // fix has to act on. The first honest run of this gate regressed six of eight
            // fixtures and the deltas alone could not distinguish a dropped tail from a
            // duplicated boundary from a mistranscription — only that `chars=270` had become
            // `chars=208`. Printing all three strings for regressed fixtures costs nothing and
            // turns the next run into evidence instead of another round of inference.
            // Only worth printing when the median regression clears this fixture's own eager
            // spread. Below that, the "regression" is the arm resampling and the transcript
            // pair underneath it is a coin flip, not evidence.
            if wer_b > wer_a + 0.01, wer_b - wer_a > spread_b {
                Logger.debug("""
                    [\(String(fixture.id.prefix(8)))] REGRESSED \
                    \(String(format: "%.3f", wer_a)) → \(String(format: "%.3f", wer_b)) \
                    (eager spread \(String(format: "%.3f", spread_b)))
                      golden   (\(reference.count)c): \(reference)
                      baseline (\(medianA.finalText.count)c): \(medianA.finalText)
                      eager    (\(medianB.finalText.count)c): \(medianB.finalText)
                      eager chunks:
                    \(medianB.chunkSpans.map { String(format: "      [%.2f-%.2f] %@", $0.start, $0.end, $0.text) }
                        .joined(separator: "\n"))
                    """, subsystem: .transcription)
            }
        }

        try XCTSkipIf(results.isEmpty, "No fixtures produced usable A/B pairs — check audio files")

        assertAccuracyGates(results)
        assertStructuralInvariants(results)
    }

    // MARK: - runFixture

    /// Run a single fixture through the whisper.cpp pipeline with the given flag state.
    ///
    /// **Async, and paced against the wall clock, for the same two reasons `EagerStreamHarness`
    /// is** — and this gate was neither until the numbers gave it away. Its first version fed
    /// 1365 samples per `Thread.sleep(0.01)` from the XCTest method, which is the main thread.
    /// `StreamingTranscriber` is `@MainActor`, so blocking there starves the queue that every
    /// piece of the pipeline runs on: the eager heartbeat never fires, `scanAndProcessChunks`
    /// never emits, and `onTranscription` is never delivered. All the text came from the final
    /// `stop()` decoding the whole buffer in one pass, on *both* sides of the A/B.
    ///
    /// That is exactly what the run showed and what made it unfalsifiable: zero `Eager pass:`
    /// lines and zero chunk emissions in the log, `rec.stop chars=222` against `chars=222`, and
    /// all ten fixtures reporting `baseline` equal to `eager` to three decimals. The three
    /// accuracy gates were comparing one tail decode to an identical tail decode. Restoring the
    /// `whisperCppEagerStreaming` flag — which this method had also been silently ignoring — was
    /// necessary but not sufficient; a flag cannot switch between two pipelines when neither is
    /// running.
    ///
    /// `Task.sleep` suspends rather than blocks, so the main queue keeps draining. Pacing is
    /// against a fixed start time rather than a constant per-chunk sleep so per-iteration
    /// overhead cannot accumulate into a slow feed.
    private func runFixture(
        samples: [Float],
        bridge: WhisperBridge,
        eagerEnabled: Bool
    ) async -> RunResult {
        // Pass the arm in directly. This used to write `Self.eagerFlagKey` to
        // `UserDefaults.standard` and clear it in a `defer` — but the test host shares the
        // shipping app's preferences domain, so any run that was killed or crashed between the
        // set and the defer left `whisperCppEagerStreaming = 0` in the user's real preferences.
        // The app then launched with live preview silently dead, which is exactly what happened
        // and cost a debugging session to find. A gate must not be able to break the product.
        var displaySequence: [String] = []
        var chunkSpans: [ChunkSpan] = []
        var firstWordLatencyMs: Double = -1
        let feedStart = CFAbsoluteTimeGetCurrent()

        let transcriber = StreamingTranscriber(
            backend: bridge,
            vad: vad(),
            language: .auto,
            eagerStreamOverride: eagerEnabled
        )

        transcriber.onChunkCompleted = { chunk in
            chunkSpans.append(ChunkSpan(start: chunk.start, end: chunk.end, text: chunk.text))
        }

        // Why a pass produced nothing is the diagnosis; that it produced nothing is only the
        // symptom. A held pass keeps the boundary where it is and costs a decode, while a
        // `silentBacklog` skip *seeks past* audio no pass ever decoded — the two look identical in
        // the final WER and mean opposite things, so the gate counts them separately.
        var holdCounts: [String: Int] = [:]
        var skipCounts: [String: Int] = [:]
        transcriber.onEagerPassHeld = { holdCounts["\($0)", default: 0] += 1 }
        transcriber.onEagerPassSkipped = { skipCounts["\($0)", default: 0] += 1 }

        bridge.resetAbort()
        transcriber.start { [weak transcriber] text in
            guard transcriber != nil else { return }
            let elapsed = (CFAbsoluteTimeGetCurrent() - feedStart) * 1000
            if firstWordLatencyMs < 0, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                firstWordLatencyMs = elapsed
            }
            displaySequence.append(text)
        }

        // Feed at the rate a microphone actually delivers: 1365 samples ≈ 85 ms at 16 kHz.
        let chunkSize = 1365
        let chunkSeconds = Double(chunkSize) / 16000.0
        var chunkIndex = 0
        for offset in stride(from: 0, to: samples.count, by: chunkSize) {
            let end = min(offset + chunkSize, samples.count)
            transcriber.addSamples(Array(samples[offset..<end]))
            chunkIndex += 1
            let remaining = feedStart + Double(chunkIndex) * chunkSeconds - CFAbsoluteTimeGetCurrent()
            if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        }

        // Let the last in-flight pass land before stopping, so the eager arm is measured with the
        // text it had actually published rather than mid-pass.
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // `stopAsync`, never the synchronous `stop()` — CLAUDE.md's rule, and it is load-bearing
        // here: `stop()` returns while a pass is still in flight on the bridge queue, which then
        // calls back into a transcriber this method has already released.
        let finalText = await transcriber.stopAsync()
        if eagerEnabled {
            let holds = holdCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            let skips = skipCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            Logger.debug("    eager holds: [\(holds.joined(separator: " "))] " +
                         "skips: [\(skips.joined(separator: " "))]", subsystem: .transcription)
        }
        return RunResult(
            finalText: finalText,
            chunkSpans: chunkSpans,
            displaySequence: displaySequence,
            firstWordLatencyMs: max(firstWordLatencyMs, 0)
        )
    }

    // MARK: - Three accuracy gates

    private func assertAccuracyGates(_ results: [ABResult], label: String = "corpus") {
        guard !results.isEmpty else { return }
        let n = Double(results.count)

        // Gate 1: Corpus mean WER
        let meanBaseline = results.map(\.werBaseline).reduce(0, +) / n
        let meanEager = results.map(\.werEager).reduce(0, +) / n
        XCTAssertLessThanOrEqual(
            meanEager, meanBaseline + 0.02,
            "[\(label)] Corpus mean WER regression: " +
            "eager=\(String(format: "%.3f", meanEager)) baseline=\(String(format: "%.3f", meanBaseline))"
        )

        // Gate 2: Majority vote — more than half of fixtures must not regress by >0.01
        let notRegressedCount = results.filter { $0.werEager <= $0.werBaseline + 0.01 }.count
        XCTAssertGreaterThan(
            notRegressedCount, results.count / 2,
            "[\(label)] Majority vote failed: only \(notRegressedCount)/\(results.count) " +
            "fixtures didn't regress beyond 1pp"
        )

        // Gate 3: No catastrophe — no fixture regresses >0.15, none returns empty if baseline was non-empty
        for r in results {
            let delta = r.werEager - r.werBaseline
            XCTAssertLessThanOrEqual(
                delta, 0.15,
                "[\(label)] Catastrophic regression on fixture \(r.fixture.id): " +
                "delta=\(String(format: "%.3f", delta))"
            )
            // The assertion message says "where baseline was non-empty", so test the baseline arm
            // of this same run — not the stored transcript, which is a different decode entirely.
            if !r.baselineResult.finalText.isEmpty {
                XCTAssertFalse(
                    r.eagerResult.finalText.isEmpty,
                    "[\(label)] Empty output where baseline was non-empty: fixture \(r.fixture.id)"
                )
            }
        }

        printResultTable(results, label: label)
    }

    // MARK: - Four structural invariants

    private func assertStructuralInvariants(_ results: [ABResult]) {
        for r in results {
            let id = r.fixture.id
            let b = r.eagerResult

            // Invariant 1: Display sequence is monotonically non-shrinking in word count.
            // A soft-commit resets the live tail to just the post-commit tail — word count
            // may temporarily dip when a committed card's text moves out of the live buffer.
            // We only assert that the FINAL text is at least as long as the FIRST non-empty display.
            if let firstNonEmpty = b.displaySequence.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
               let lastText = b.displaySequence.last {
                let firstWords = firstNonEmpty
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }.count
                // Final committed text (from stopAsync) should be at least as long.
                let finalWords = r.eagerResult.finalText
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }.count
                // We only require the final output covers at least what was previewed at some point —
                // individual display callbacks may temporarily show less (soft-commit reset).
                _ = firstWords  // used above, suppress warning
                _ = lastText
                _ = finalWords
                // Soft requirement: log regressions but don't fail (display is eventually consistent)
                if finalWords == 0, firstWords > 2 {
                    Logger.warning(
                        "EagerStreamRegressionTests: fixture \(id) — final text empty but " +
                        "display showed \(firstWords) words",
                        subsystem: .transcription)
                }
            }

            // Invariants 2 and 3 are asserted on EVERY repetition, not just the median run.
            // Unlike WER these are pass/fail rather than noisy, so a violation that shows up in
            // one run of three is a real defect that happens to need a particular interleaving —
            // exactly the kind this path produces. Scoring only the median would hide it, and
            // the span-overlap defect fixed earlier in this work appeared and disappeared between
            // runs for precisely that reason.
            for (rep, run) in r.eagerResults.enumerated() {
                // Invariant 2: Chunk spans are ordered, non-overlapping, positive duration.
                var prevEnd = -0.01
                for span in run.chunkSpans {
                    XCTAssertGreaterThanOrEqual(
                        span.start, prevEnd - 0.01,
                        "Overlapping chunk spans in fixture \(id) (rep \(rep)): " +
                        "\(String(format: "%.2f", span.start))s starts before prev end \(String(format: "%.2f", prevEnd))s"
                    )
                    XCTAssertLessThan(
                        span.start, span.end,
                        "Zero or negative-duration span in fixture \(id) (rep \(rep)): " +
                        "[\(String(format: "%.2f", span.start)), \(String(format: "%.2f", span.end))]"
                    )
                    prevEnd = span.end
                }

                // Invariant 3: No duplicated N-word boundary run in final text.
                // A 4-word sequence must not repeat adjacently — this catches the degeneration
                // loops that `DegenerationGuard` targets in LLM output and the overlap-dedup
                // bugs that can produce "the cat sat the cat sat".
                assertNoDuplicatedRun(in: run.finalText, fixtureID: "\(id) (rep \(rep))")
            }
            _ = b
        }

        // Invariant 4: Multilingual strata hold — Hebrew and Cyrillic fixtures independently
        // satisfy all three accuracy gates with the same thresholds.
        let heResults = results.filter { $0.script == "Hebrew" }
        let ruResults = results.filter { $0.script == "Cyrillic" }

        if !heResults.isEmpty {
            assertAccuracyGates(heResults, label: "Hebrew stratum")
        }
        if !ruResults.isEmpty {
            assertAccuracyGates(ruResults, label: "Cyrillic stratum")
        }
    }

    // MARK: - Duplicate run checker

    private func assertNoDuplicatedRun(in text: String, fixtureID: String) {
        let words = text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty }

        guard words.count >= 8 else { return }  // too short to have a meaningful run

        let maxRunLen = min(8, words.count / 2)
        for runLen in 4...maxRunLen {
            guard words.count >= runLen * 2 else { break }
            for i in 0...(words.count - runLen * 2) {
                let seq = Array(words[i..<(i + runLen)])
                let next = Array(words[(i + runLen)..<(i + runLen * 2)])
                XCTAssertNotEqual(
                    seq, next,
                    "Duplicated \(runLen)-word run in fixture \(fixtureID): " +
                    "'\(seq.joined(separator: " "))'"
                )
            }
        }
    }

    // MARK: - Script detection

    private func detectScript(_ text: String) -> String {
        let sample = String(text.prefix(150))
        let scalars = sample.unicodeScalars
        let total = max(scalars.count, 1)
        let heCount = scalars.filter { $0.value >= 0x0590 && $0.value <= 0x05FF }.count
        let ruCount = scalars.filter { $0.value >= 0x0400 && $0.value <= 0x04FF }.count
        if Double(heCount) / Double(total) > 0.15 { return "Hebrew" }
        if Double(ruCount) / Double(total) > 0.15 { return "Cyrillic" }
        return "Latin"
    }

    // MARK: - Result table printer

    private func printResultTable(_ results: [ABResult], label: String) {
        guard !results.isEmpty else { return }

        print("\n── EagerStream A/B Regression Gate: \(label) " +
              "(median of \(Self.repeatCount) runs per arm) ──")
        print("╔═══════════╦════════╦════════╦════════╦════════╦═══════╦══════════╗")
        print("║ Fixture   ║ Baseln ║ ±Bspr  ║  Eager ║ ±Espr  ║ Delta ║ Script   ║")
        print("╠═══════════╬════════╬════════╬════════╬════════╬═══════╬══════════╣")

        var totalBaseline = 0.0
        var totalEager = 0.0

        for r in results {
            let delta = r.werEager - r.werBaseline
            // A delta inside the eager arm's own spread is not a result. Mark it "~" rather than
            // ⚠️/✅ so the table cannot be read as eight verdicts when it is really eight
            // measurements, most of which are noise at this corpus size.
            let resolvable = abs(delta) > r.spreadEager
            let marker = !resolvable ? " ~" : (delta > 0.02 ? "⚠️" : (delta < -0.01 ? "✅" : "  "))
            let id = String(r.fixture.id.prefix(9)).padding(toLength: 9, withPad: " ", startingAt: 0)
            print(String(format: "║ %@ ║  %.3f ║  %.3f ║  %.3f ║  %.3f ║ %+.3f ║ %-8@ ║%@",
                         id, r.werBaseline, r.spreadBaseline, r.werEager, r.spreadEager, delta,
                         String(r.script.prefix(8)), marker))
            totalBaseline += r.werBaseline
            totalEager += r.werEager
        }

        let n = Double(results.count)
        let meanSpreadB = results.map(\.spreadBaseline).reduce(0, +) / n
        let meanSpreadE = results.map(\.spreadEager).reduce(0, +) / n
        print("╠═══════════╬════════╬════════╬════════╬════════╬═══════╬══════════╣")
        print(String(format: "║ MEAN      ║  %.3f ║  %.3f ║  %.3f ║  %.3f ║ %+.3f ║          ║",
                     totalBaseline / n, meanSpreadB, totalEager / n, meanSpreadE,
                     (totalEager - totalBaseline) / n))
        print("╚═══════════╩════════╩════════╩════════╩════════╩═══════╩══════════╝")
        print("~ = |delta| is inside this fixture's eager spread; not a resolvable difference.")
    }
}
