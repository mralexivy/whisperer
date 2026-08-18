//
//  PolishBenchmarkTests.swift
//  WhispererTests
//
//  Milestone B: the merge gate. Two arms over the same 400 recordings.
//
//  - **Arm A — control.** What shipped: `ZAIENHANCEDTEXT`, the Qwen3.5-4B's own output for these
//    very recordings, read out of the app's history database. Not a reconstruction and not a
//    re-run, so no prompt drift, no decode-param drift, and no way for the candidate to be
//    measured against a strawman.
//  - **Arm B — candidate.** `DeterministicPolisher` over the same raw transcript.
//
//  Both scored against `goldenTranscript` — the same model's whole-file decode of the same audio.
//  That reference is not human truth and must not be reported as such: where the model mishears,
//  it mishears identically on both sides. Holding model error constant is the point. WER against
//  it therefore **bounds pipeline damage**; it does not prove correctness. A tie means "no new
//  damage", which is exactly what verdict rule 3 asks.
//
//  **This benchmark is only runnable on this machine.** The corpus is the user's own recordings,
//  at absolute paths inside `~/Library/Containers/com.ivy.whisperer/`. Every test here skips
//  rather than fails when the history database or the golden set is absent.
//

import XCTest
@testable import whisperer

final class PolishBenchmarkTests: XCTestCase {

    // MARK: - Row

    private struct Row {
        let id: String
        let language: String
        let bucket: String
        /// The reference is written in a different script than the input.
        ///
        /// Not a polishing result and not scoreable: `goldenTranscript` is a whole-file decode
        /// and the input is a streaming decode of the same audio, and on 22 of these 400
        /// recordings the two landed in **different languages** — 21 English utterances whose
        /// whole-file decode came back Russian, one the other way. WER against a translation of
        /// yourself is ~1.0 by construction, on both arms, however good the polishing was.
        let crossLanguageReference: Bool
        let werA: Double?
        let werB: Double
        let driftB: Bool
        let preservedB: Bool
        let invokedLLM: Bool
        let polishMs: Double
    }

    // MARK: - Corpus

    /// Loud, not silent. `GoldenSet.load()` returns `[:]` on a missing or unparseable file and
    /// every caller then skips, so a corpus that failed to load would print a clean, meaningless
    /// pass over zero fixtures.
    private func loadCorpus() throws -> [RecordingFixture] {
        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 400)
        try XCTSkipIf(fixtures.isEmpty, "No transcriptions in the local history database")

        print("Golden set resolved from: \(GoldenSet.resolvedSource)")
        XCTAssertFalse(GoldenSet.isEmpty, "golden set failed to load — every row would be skipped")
        XCTAssertGreaterThan(GoldenSet.entries.count, 350,
                             "golden set is smaller than the checked-in 400 entries")
        return fixtures
    }

    // MARK: - Quality

    func testQualityArmAVersusArmB() throws {
        let fixtures = try loadCorpus()
        let polisher = DeterministicPolisher()

        var rows: [Row] = []
        var skippedNoGolden = 0
        var skippedNoArmA = 0

        for fixture in fixtures {
            guard let golden = GoldenSet.reference(for: fixture.id), !golden.isEmpty else {
                skippedNoGolden += 1
                continue
            }

            let start = CFAbsoluteTimeGetCurrent()
            let polished = polisher.polish(text: fixture.transcript)
            let polishMs = (CFAbsoluteTimeGetCurrent() - start) * 1000

            // Arm A is only defined where the shipped LLM actually produced something. Fixtures
            // recorded with AI post-processing off have no control output and are counted, not
            // silently scored against their own input.
            let armA = fixture.aiEnhancedText.flatMap { $0.isEmpty ? nil : $0 }
            if armA == nil { skippedNoArmA += 1 }

            rows.append(Row(id: fixture.id,
                            language: Self.detectedLanguage(of: golden),
                            bucket: fixture.durationBucket,
                            crossLanguageReference:
                                Self.detectedLanguage(of: golden)
                                    != Self.detectedLanguage(of: fixture.transcript),
                            werA: armA.map { Self.wordErrorRate(reference: golden, hypothesis: $0) },
                            werB: Self.wordErrorRate(reference: golden, hypothesis: polished.text),
                            driftB: Self.drifted(from: fixture.transcript, to: polished.text),
                            preservedB: Self.preservesTokens(of: fixture.transcript, in: polished.text),
                            invokedLLM: polished.needsGenerativePass,
                            polishMs: polishMs))
        }

        try XCTSkipIf(rows.isEmpty, "no fixture had a golden reference")
        report(rows, skippedNoGolden: skippedNoGolden, skippedNoArmA: skippedNoArmA,
               total: fixtures.count)

        // Verdict rule 2 — the flat disqualifiers. Any non-zero means no merge, whatever else
        // the numbers say.
        XCTAssertEqual(rows.filter(\.driftB).count, 0, "arm B changed the script of an output")
        XCTAssertEqual(rows.filter { !$0.preservedB }.count, 0,
                       "arm B dropped a number or an identifier")
    }

    /// Verdict rule 6 — engine independence. Every quality figure must hold at
    /// `ASRCapabilities = []`, which is the Nemotron and meetings case.
    func testQualityIsIdenticalAtZeroCapability() throws {
        let fixtures = try loadCorpus()
        let polisher = DeterministicPolisher()

        var divergences = 0
        for fixture in fixtures {
            let bare = polisher.polish(text: fixture.transcript).text
            let rich = polisher.polish(words: Self.syntheticWords(for: fixture.transcript)).text
            if bare != rich { divergences += 1 }
        }
        print("Capability tiers: \(divergences)/\(fixtures.count) divergences between "
            + "ASRCapabilities = [] and .whisperCpp")
        XCTAssertEqual(divergences, 0)
    }

    // MARK: - Latency

    /// Arm B's own cost, three interleaved repeats. Arm A's `llm_ms` is not measured here — it
    /// needs the 3.2 GB model resident, and mixing a model load into this test would put page
    /// pressure on the very measurement it is meant to inform. It is a separate run.
    func testDeterministicLatency() throws {
        let fixtures = try loadCorpus()
        let polisher = DeterministicPolisher()

        var samples: [Double] = []
        for _ in 0..<3 {
            for fixture in fixtures {
                let start = CFAbsoluteTimeGetCurrent()
                _ = polisher.polish(text: fixture.transcript)
                samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
        }

        let p50 = Self.percentile(samples, 0.50)
        let p95 = Self.percentile(samples, 0.95)
        print(String(format: "polish_ms over %d samples: p50 %.2f, p95 %.2f, max %.2f",
                     samples.count, p50, p95, samples.max() ?? 0))
        // The plan's target for the M2 passes.
        XCTAssertLessThan(p95, 10.0, "deterministic passes exceeded their 10 ms p95 budget")
    }

    /// The trained editor over the whole corpus: what it costs, and what it would change.
    ///
    /// Separate from arm B because it is not part of arm B. `Calibration.uncalibrated`'s
    /// `maximumConfidence` (0.98) sits below `ConfidenceGate.floor(for: .editorModel)` (0.99), so
    /// every proposal this makes is discarded and arm B's text is identical with the editor and
    /// without it. That is the intended state until per-language precision is measured at ≥99%,
    /// and it is asserted here rather than assumed — a proposal that survived would mean an edit
    /// class went auto-applying without the measurement that authorises it.
    ///
    /// What the run is *for* is the two numbers that decide whether M4 is affordable at all: the
    /// real per-utterance cost of the encoder on this corpus, and the proposal rate it would
    /// bring if calibrated. Both are measured on real transcripts of real length rather than on
    /// the worked example.
    func testEditorOverCorpus() async throws {
        let fixtures = try loadCorpus()
        guard let runtime = MMBERTCoreMLRuntime.makeIfAvailable() else {
            throw XCTSkip("mmBERT artifacts absent — run Tools/mmbert/export_coreml.py")
        }
        try await runtime.load()
        defer { Task { await runtime.unload() } }

        let model = MMBERTEditingModel(runtime: runtime)
        let gate = ConfidenceGate()
        let context = EditContext(capabilities: [], pass: .authoritative)

        var samples: [Double] = []
        var tokens = 0
        var proposals = 0
        var survivors = 0
        var byOperation: [String: Int] = [:]
        var byLanguage: [String: (tokens: Int, proposals: Int)] = [:]

        // Warm: the first prediction pays program load, and folding that into the p50 of a
        // 400-sample distribution would misreport the steady-state cost by roughly its own value.
        _ = await model.propose(TokenGraph.from(text: fixtures[0].transcript,
                                                capabilities: []).tokens, context: context)

        for fixture in fixtures {
            var graph = TokenGraph.from(text: fixture.transcript, capabilities: [])
            let counted = graph.tokens.filter { $0.kind != .whitespace }.count
            guard counted > 0 else { continue }

            let start = CFAbsoluteTimeGetCurrent()
            let edits = await model.propose(graph.tokens, context: context)
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)

            let language = Self.detectedLanguage(of: fixture.transcript)
            tokens += counted
            proposals += edits.count
            byLanguage[language, default: (0, 0)].tokens += counted
            byLanguage[language, default: (0, 0)].proposals += edits.count
            for edit in edits {
                switch edit.operation {
                case .keep:        byOperation["keep", default: 0] += 1
                case .delete:      byOperation["delete", default: 0] += 1
                case .replace:     byOperation["replace", default: 0] += 1
                case .insertAfter: byOperation["insertAfter", default: 0] += 1
                }
            }
            survivors += gate.apply(edits, to: &graph).count
        }

        print("""

        ── mmBERT editor over the corpus ─────────────────────────────────────────
        \(samples.count) utterances, \(tokens) non-whitespace tokens
        editor_ms: p50 \(String(format: "%.2f", Self.percentile(samples, 0.50))), \
        p95 \(String(format: "%.2f", Self.percentile(samples, 0.95))), \
        max \(String(format: "%.2f", samples.max() ?? 0))
        proposals: \(proposals) (\(String(format: "%.2f", 1000 * Double(proposals) / Double(tokens))) \
        per 1000 tokens) — \(byOperation.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        survived the gate: \(survivors) — 0 is the correct number until precision is measured
        """)
        for (language, counts) in byLanguage.sorted(by: { $0.key < $1.key }) {
            print(String(format: "  %@ n=%d tokens, %d proposals (%.2f per 1000)",
                         language, counts.tokens, counts.proposals,
                         1000 * Double(counts.proposals) / Double(counts.tokens)))
        }
        print("──────────────────────────────────────────────────────────────────────────\n")

        XCTAssertEqual(survivors, 0,
                       "a model-sourced edit passed the gate; per-language precision has not "
                        + "been measured at ≥0.99, so none may apply")
        // The plan's M4 budget, measured on the shipping path rather than on `MLModel.prediction`
        // alone — the Swift tokenizer is part of the cost.
        XCTAssertLessThan(Self.percentile(samples, 0.95), 100.0,
                          "editor p95 exceeds the plan's 100 ms budget")
    }

    // MARK: - Reporting

    private func report(_ allRows: [Row], skippedNoGolden: Int, skippedNoArmA: Int, total: Int) {
        // WER is reported over the rows whose reference is in the input's own language. Drift and
        // preservation stay over every row — they compare input to output and never touch the
        // reference, so a mistranslated reference cannot excuse damage.
        let crossLanguage = allRows.filter(\.crossLanguageReference)
        let rows = allRows.filter { !$0.crossLanguageReference }

        print("""

        ── Polish benchmark ──────────────────────────────────────────────────────
        corpus: \(total) fixtures, \(allRows.count) with a reference, \
        \(skippedNoGolden) without a golden reference, \(skippedNoArmA) without an arm-A output
        reference: goldenTranscript — same model, whole-file decode. Bounds damage, not accuracy.
        WER over \(rows.count) rows; \(crossLanguage.count) excluded — the whole-file decode landed
        in a different language than the streaming decode of the same audio, so the reference is a
        translation of the input and scores ~1.0 on both arms regardless of polishing.
        """)

        // Verdict rule 3 is a *paired* comparison. Scoring arm A over the fixtures that have an
        // arm-A output and arm B over all of them would compare two different corpora and read
        // as a win or a loss depending only on which recordings happened to have AI enabled.
        print("lang / n / werA mean/median / werB mean/median  — paired subset only")
        for language in ["en", "he", "ru", "mixed", "ALL"] {
            let group = (language == "ALL" ? rows : rows.filter { $0.language == language })
                .filter { $0.werA != nil }
            guard !group.isEmpty else { continue }
            print(String(format: "%@ n=%d  werA %.4f/%.4f  werB %.4f/%.4f",
                         language, group.count,
                         Self.mean(group.compactMap(\.werA)), Self.median(group.compactMap(\.werA)),
                         Self.mean(group.map(\.werB)), Self.median(group.map(\.werB))))
        }

        print("lang / n / werB mean/median / llm_rate  — full scored corpus")
        for language in ["en", "he", "ru", "mixed", "ALL"] {
            let group = language == "ALL" ? rows : rows.filter { $0.language == language }
            guard !group.isEmpty else { continue }
            print(String(format: "%@ n=%d  werB %.4f/%.4f  llm_rate %.3f",
                         language, group.count,
                         Self.mean(group.map(\.werB)), Self.median(group.map(\.werB)),
                         Double(group.filter(\.invokedLLM).count) / Double(group.count)))
        }

        // `HistoryTestLoader` orders by `ABS(ZDURATION - 20.0)`, so a 400-fixture corpus is
        // almost entirely 15–45 s. The duration dimension is degenerate here and the plan's
        // per-bucket table cannot be filled from this loader without changing its ordering.
        for bucket in ["short", "medium", "long", "very-long"] {
            let group = rows.filter { $0.bucket == bucket }
            guard !group.isEmpty else { continue }
            print(String(format: "  %@ n=%d  werB %.4f  llm_rate %.3f  polish_ms p95 %.2f",
                         bucket, group.count, Self.mean(group.map(\.werB)),
                         Double(group.filter(\.invokedLLM).count) / Double(group.count),
                         Self.percentile(group.map(\.polishMs), 0.95)))
        }

        // Over every row, including the excluded ones: these two never read the reference.
        print("""
        drift: \(allRows.filter(\.driftB).count)   \
        preservation: \(String(format: "%.3f",
                               Double(allRows.filter(\.preservedB).count) / Double(allRows.count)))\
         (over all \(allRows.count) rows — neither metric reads the reference)
        NOTE: languages above are by DETECTED SCRIPT, not by the stored language field,\
        which records the model routed to rather than the speech. Read the n on every row:\
        real Hebrew and Russian are a small fraction of this corpus and are directional only.
        ──────────────────────────────────────────────────────────────────────────

        """)
    }

    // MARK: - Metrics

    /// Word error rate, Levenshtein over whitespace-split words, case- and punctuation-folded.
    ///
    /// Folded because casing and punctuation are precisely what arm A adds and arm B does not
    /// yet: scoring them unfolded would measure the *presence* of a full stop rather than whether
    /// either arm damaged the words, and rule 3 is about damage.
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let ref = normalizedWords(reference)
        let hyp = normalizedWords(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }

        var previous = Array(0...hyp.count)
        var current = [Int](repeating: 0, count: hyp.count + 1)
        for i in 1...ref.count {
            current[0] = i
            for j in 1...hyp.count {
                let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return Double(previous[hyp.count]) / Double(ref.count)
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0.filter { $0.isLetter || $0.isNumber }) }
            .filter { !$0.isEmpty }
    }

    /// The language of a fixture, by the script its words are actually written in.
    ///
    /// **Not `fixture.language`.** That field is `ZLANGUAGE`, which records the model the audio
    /// was routed to, not the speech it contains: it declares 151 Hebrew recordings of which only
    /// 10 hold any Hebrew, and the golden set's `he = 93` is likewise ~10 real Hebrew and ~83
    /// English or Russian speech that happened to go through the Hebrew model. Grouping by it
    /// produces a "Hebrew" column measuring mostly English, which is worse than no column —
    /// the per-language release gates bind to these figures.
    ///
    /// Majority by word, matching `ProtectionDetector.dominantFamily`, so one borrowed Latin
    /// technical term cannot relabel a Hebrew utterance. `mixed` when nothing holds a majority.
    static func detectedLanguage(of text: String) -> String {
        var counts: [ScriptFamily: Int] = [:]
        for word in text.split(whereSeparator: \.isWhitespace) {
            let families = ScriptAnalyzer.scriptFamilies(in: String(word))
            guard families.count == 1, let family = families.first else { continue }
            counts[family, default: 0] += 1
        }
        let total = counts.values.reduce(0, +)
        guard total > 0, let (family, count) = counts.max(by: { $0.value < $1.value }),
              count * 2 > total else { return "mixed" }
        switch family {
        case .latin:    return "en"
        case .cyrillic: return "ru"
        case .hebrew:   return "he"
        default:        return family.rawValue
        }
    }

    /// A flat −1.0 disqualifier: the output must not be written in a script the input was not.
    static func drifted(from input: String, to output: String) -> Bool {
        !ScriptAnalyzer.scriptFamilies(in: output)
            .isSubset(of: ScriptAnalyzer.scriptFamilies(in: input))
    }

    /// Every digit run and every URL in the input survives into the output.
    static func preservesTokens(of input: String, in output: String) -> Bool {
        let digits = input.split(whereSeparator: { !$0.isNumber }).map(String.init)
        for run in digits where !output.contains(run) { return false }
        for word in input.split(whereSeparator: \.isWhitespace)
        where word.hasPrefix("http") && !output.contains(word) { return false }
        return true
    }

    /// Full whisper.cpp evidence over identical text, so the only difference between the two
    /// graphs is the evidence. Probabilities alternate near-zero and near-one: a gate that read
    /// them would diverge on nearly every fixture rather than subtly.
    static func syntheticWords(for text: String) -> [WhisperStreamWord] {
        var words: [WhisperStreamWord] = []
        var start = 0.0
        for (offset, piece) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            let chunk = offset == 0 ? String(piece) : " " + piece
            guard !chunk.isEmpty else { continue }
            words.append(WhisperStreamWord(text: chunk, tokens: [offset], start: start,
                                           end: start + 0.3,
                                           probability: offset.isMultiple(of: 2) ? 0.02 : 0.98))
            start += 0.3
        }
        return words
    }

    // MARK: - Statistics

    /// Mean and median both, always. One fixture can pin a mean — `EagerStreamProfileTests`
    /// learned this the expensive way.
    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
    }

    private static func median(_ values: [Double]) -> Double {
        percentile(values, 0.50)
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))
        return sorted[index]
    }
}
