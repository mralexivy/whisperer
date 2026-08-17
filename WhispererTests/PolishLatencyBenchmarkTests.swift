//
//  PolishLatencyBenchmarkTests.swift
//  WhispererTests
//
//  Verdict rule 1 — "much faster" — measured rather than argued.
//
//  Separate from `PolishBenchmarkTests` because this one loads the 3.2 GB Qwen3.5-4B MTP.
//  Mixing a multi-GB model load into the quality run would put page pressure on the very
//  measurement it informs, and `LLMModelComparisonTests` already established the pattern:
//  one model resident at a time, loaded and unloaded around the body.
//
//  **What is compared.** ASR is identical in both arms — same audio, same model, same decode —
//  so the difference in `endSpeech→output_ms` is exactly the difference in the polish stage.
//  This measures the polish stage and says so, rather than replaying 400 recordings through
//  whisper twice to re-measure a term that cancels.
//
//  Three arms, not two, because the shipping candidate is the third:
//
//  | Arm | What it is |
//  |---|---|
//  | A — control | `TranscriptPreCleaner` → `LLMPostProcessor(AIMode.correct)`. What ships today. |
//  | B — deterministic | `DeterministicPolisher` alone. The M4 end state, where the LLM is gone. |
//  | H — hybrid | B, then A only when `needsGenerativePass`. The M2 shape, and what a merge today would actually ship. |
//
//  Arm H is the honest one to quote for a merge decision now: arm B's latency is the M4
//  promise, but M4 needs trained weights, and a benchmark that quotes the endpoint while
//  shipping the midpoint is a benchmark that lies by omission.
//
//  **Interleaved per fixture — A, B, H, next fixture** — not all-A-then-all-B. The two arms
//  share one machine and one thermal budget; blocking them lets drift land entirely on
//  whichever ran second.
//
//  Local-only, like every benchmark here: it needs the user's history database and the 4B on
//  disk. It skips rather than fails when either is absent.
//

import XCTest
@testable import whisperer

@MainActor
final class PolishLatencyBenchmarkTests: XCTestCase {

    /// Enough fixtures for a stable p95 without a 40-minute run: 4B decodes dominate, at
    /// roughly a second each, so 60 fixtures × 3 repeats is ~3 minutes of arm A.
    private static let fixtureCount = 60
    private static let repeats = 3

    // MARK: - Sample

    private struct Sample {
        let id: String
        let language: String
        let armAMs: Double
        let armBMs: Double
        let hybridMs: Double
        let invokedLLM: Bool
        let prefillMs: Double
        let decodeMs: Double
        let promptTokens: Int
    }

    // MARK: - The run

    func testPolishLatencyArmAVersusArmB() async throws {
        let all = HistoryTestLoader.loadFixtures(maxCount: 400)
        try XCTSkipIf(all.isEmpty, "No transcriptions in the local history database")

        // Spread across scripts rather than taking the first N: the loader orders by duration
        // and the corpus is ~90% English, so a prefix would be an English-only latency figure.
        // Hebrew and Russian matter here beyond fairness — they tokenize at roughly half the
        // characters per token, so the same sentence is a longer prefill.
        let fixtures = Self.stratified(all, count: Self.fixtureCount)
        print("Latency corpus: \(fixtures.count) fixtures, "
              + Dictionary(grouping: fixtures, by: { Self.script(of: $0.transcript) })
                  .map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " "))

        let polisher = DeterministicPolisher.forTranscript(
            dictionaryEntries: DictionaryManager.shared.entries, formatsLists: false)
        let config = LLMEditingModel.PromptConfig.correct

        var samples: [Sample] = []
        let rssBefore = Self.footprintMB()
        var rssPeak = rssBefore

        let processor = LLMPostProcessor()
        do {
            try await processor.loadModel(.qwen3_5_4B_mtp)
        } catch {
            throw XCTSkip("Qwen3.5-4B MTP is not on disk: \(error.localizedDescription)")
        }
        defer { Task { await processor.unloadModel() } }

        let rssLoaded = Self.footprintMB()

        for repeat_ in 0..<Self.repeats {
            for fixture in fixtures {
                let text = fixture.transcript
                guard text.contains(where: \.isLetter) else { continue }

                // --- arm B: deterministic only ---
                let bStart = CFAbsoluteTimeGetCurrent()
                let polished = polisher.polish(text: text)
                let armBMs = (CFAbsoluteTimeGetCurrent() - bStart) * 1000

                // --- arm A: preclean + the 4B, as `AppState.applyLLMPostProcessing` sends it ---
                let aStart = CFAbsoluteTimeGetCurrent()
                _ = await Self.generate(processor, text: text, config: config)
                let armAMs = (CFAbsoluteTimeGetCurrent() - aStart) * 1000
                let stats = processor.lastGenerationStats

                // --- arm H: B, then A only if the gate could not finish the job ---
                // Re-uses arm B's work rather than re-running it, which is what the shipping
                // path does: `applyLLMPostProcessing` polishes once and returns early.
                var hybridMs = armBMs
                if polished.needsGenerativePass {
                    let hStart = CFAbsoluteTimeGetCurrent()
                    _ = await Self.generate(processor, text: polished.text, config: config)
                    hybridMs += (CFAbsoluteTimeGetCurrent() - hStart) * 1000
                }

                rssPeak = max(rssPeak, Self.footprintMB())
                // Every repeat contributes a row. Discarding the later two would throw away
                // exactly the thermal tail the p95 is supposed to see.
                samples.append(Sample(
                    id: fixture.id, language: Self.script(of: text),
                    armAMs: armAMs, armBMs: armBMs, hybridMs: hybridMs,
                    invokedLLM: polished.needsGenerativePass,
                    prefillMs: (stats?.promptTime ?? 0) * 1000,
                    decodeMs: (stats?.generateTime ?? 0) * 1000,
                    promptTokens: stats?.promptTokens ?? 0))
            }
            print("  repeat \(repeat_ + 1)/\(Self.repeats) done "
                  + String(format: "(arm A p50 so far %.0f ms)",
                           Self.percentile(samples.map(\.armAMs), 0.50)))
        }

        try XCTSkipIf(samples.isEmpty, "no fixture produced a measurement")
        Self.report(samples, rssBefore: rssBefore, rssLoaded: rssLoaded, rssPeak: rssPeak)

        // Verdict rule 1, asserted on the arm a merge would actually ship. Deliberately not
        // asserted on arm B: arm B is not shippable until M4 has weights, and an assertion
        // that passes on an arm nobody can ship is a green light for a claim nobody can cash.
        let armAp95 = Self.percentile(samples.map(\.armAMs), 0.95)
        let hybridP95 = Self.percentile(samples.map(\.hybridMs), 0.95)
        XCTAssertLessThan(hybridP95, armAp95 / 3,
                          "verdict rule 1: hybrid p95 must be at most a third of arm A's")
    }

    // MARK: - Generation

    /// One generative pass, composed and finished exactly as `AppState.applyLLMPostProcessing`
    /// does it — preclean, split prompt, decode, restore placeholders, validate. The one step
    /// left out is `AppState.stripStructuralTags`, which is private to `AppState`; it is a
    /// regex sweep over a short string and cannot move a millisecond figure.
    ///
    /// The tail after the decode costs microseconds against a decode that costs ~a second, so
    /// it changes no conclusion. It is here because leaving it out would make arm A a version
    /// of the shipping path rather than the shipping path, and the whole benchmark rests on
    /// that not being true.
    ///
    /// The prompt comes from `LLMEditingModel.PromptConfig.correct` rather than a literal:
    /// `EditingModelTests.testCorrectPromptIsCarriedThroughUnmodified` asserts, line by line,
    /// that it is `AIMode.correct`'s own prompt, so the control cannot silently drift into a
    /// strawman the way a copied string would. `LLMModelComparisonTests` kept a copied title
    /// prompt and went on benchmarking a prompt the app had stopped sending; not repeating that.
    private static func generate(_ processor: LLMPostProcessor,
                                 text: String,
                                 config: LLMEditingModel.PromptConfig) async -> String? {
        let precleaned = TranscriptPreCleaner.preclean(text)
        guard var processed = try? await processor.process(
            text: precleaned.text,
            systemPrompt: config.systemPrompt,
            userMessage: "[INPUT]\n\(precleaned.text)\n[/INPUT]",
            temperature: config.temperature,
            topP: config.topP,
            topK: config.topK,
            repetitionPenalty: config.repetitionPenalty,
            maxTokensCap: config.maxTokensCap,
            throwOnFallback: true)
        else { return nil }

        processed = TranscriptPreCleaner.restorePlaceholders(processed, precleaned.placeholders)
        let (valid, _) = TranscriptPostValidator.validate(
            original: precleaned.text, processed: processed,
            profile: TranscriptPostValidator.profileFor(modeId: AIMode.correctModeId))
        return valid
            ? processed
            : TranscriptPreCleaner.restorePlaceholders(precleaned.text, precleaned.placeholders)
    }

    // MARK: - Reporting

    private static func report(_ samples: [Sample],
                               rssBefore: Double, rssLoaded: Double, rssPeak: Double) {
        print("""

        ── Polish latency ────────────────────────────────────────────────────────
        \(samples.count) measurements over \(repeats) interleaved repeats (A, B, H per fixture)
        ASR is identical in both arms, so these deltas are the whole of the
        endSpeech→output difference.
        arm A = preclean + Qwen3.5-4B MTP · arm B = deterministic only ·
        arm H = B, then the 4B only when the gate could not finish (what a merge ships today)
        """)

        print("arm / n / p50 / p95 / max  — milliseconds")
        for (name, values) in [("A  control  ", samples.map(\.armAMs)),
                               ("B  determin.", samples.map(\.armBMs)),
                               ("H  hybrid   ", samples.map(\.hybridMs))] {
            print(String(format: "%@ n=%d  p50 %8.2f  p95 %8.2f  max %8.2f",
                         name, values.count, percentile(values, 0.50),
                         percentile(values, 0.95), values.max() ?? 0))
        }

        print("\nlang / n / armA p95 / armB p95 / hybrid p95 / llm_rate")
        for language in ["en", "he", "ru", "mixed"] {
            let group = samples.filter { $0.language == language }
            guard !group.isEmpty else { continue }
            print(String(format: "%@ n=%d  %8.2f  %8.2f  %8.2f  %.3f",
                         language, group.count,
                         percentile(group.map(\.armAMs), 0.95),
                         percentile(group.map(\.armBMs), 0.95),
                         percentile(group.map(\.hybridMs), 0.95),
                         Double(group.filter(\.invokedLLM).count) / Double(group.count)))
        }

        // Split out because `wallMs` spans submit-to-callback and includes queue and lock
        // time — `EagerStreamHarness` warns about exactly this. Compute is prefill + decode;
        // whatever the wall clock has on top of it is contention, and blaming arm A for
        // `ModelWorkQueue` scheduling would overstate the win.
        let compute = zip(samples.map(\.prefillMs), samples.map(\.decodeMs)).map(+)
        print(String(format: """

        arm A compute:  prefill p50 %.2f / p95 %.2f · decode p50 %.2f / p95 %.2f
        arm A queue+lock (wall − compute): p50 %.2f / p95 %.2f
        prompt tokens: p50 %d / p95 %d
        """,
                     percentile(samples.map(\.prefillMs), 0.50),
                     percentile(samples.map(\.prefillMs), 0.95),
                     percentile(samples.map(\.decodeMs), 0.50),
                     percentile(samples.map(\.decodeMs), 0.95),
                     percentile(zip(samples.map(\.armAMs), compute).map(-), 0.50),
                     percentile(zip(samples.map(\.armAMs), compute).map(-), 0.95),
                     Int(percentile(samples.map { Double($0.promptTokens) }, 0.50)),
                     Int(percentile(samples.map { Double($0.promptTokens) }, 0.95))))

        let llmRate = Double(samples.filter(\.invokedLLM).count) / Double(samples.count)
        print(String(format: """

        llm_rate: %.3f  (arm A is 1.000 by construction; arm B's M4 target is 0.000)
        peak_rss_mb: %.0f before load, %.0f loaded, %.0f peak — arm B's own footprint is the
        first figure, and the 3.2 GB between it and the second is what M4 stops paying.
        ──────────────────────────────────────────────────────────────────────────

        """, llmRate, rssBefore, rssLoaded, rssPeak))
    }

    // MARK: - Sampling

    /// Round-robin across scripts so a 90%-English corpus does not produce an English-only p95.
    private static func stratified(_ fixtures: [RecordingFixture], count: Int) -> [RecordingFixture] {
        var byScript: [String: [RecordingFixture]] = [:]
        for fixture in fixtures where fixture.transcript.contains(where: \.isLetter) {
            byScript[script(of: fixture.transcript), default: []].append(fixture)
        }
        var picked: [RecordingFixture] = []
        var round = 0
        while picked.count < count {
            let added = picked.count
            for key in byScript.keys.sorted() where round < byScript[key]!.count {
                picked.append(byScript[key]![round])
                if picked.count == count { break }
            }
            if picked.count == added { break }   // every bucket exhausted
            round += 1
        }
        return picked
    }

    /// Majority script by word, the same rule `PolishBenchmarkTests` and `ProtectionDetector`
    /// use. Not `fixture.language`, which records the model routed to rather than the speech.
    private static func script(of text: String) -> String {
        PolishBenchmarkTests.detectedLanguage(of: text)
    }

    // MARK: - Memory

    /// Phys-footprint in MB — what the memory limit is actually applied to, and what shows in
    /// Activity Monitor. `resident_size` undercounts compressed and IOKit-backed pages, which
    /// is most of a Metal-resident model.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                           / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .nan }
        return Double(info.phys_footprint) / 1_048_576
    }

    // MARK: - Statistics

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))
        return sorted[index]
    }
}
