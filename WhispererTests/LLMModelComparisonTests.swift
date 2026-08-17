//
//  LLMModelComparisonTests.swift
//  WhispererTests
//
//  Head-to-head benchmark for the shared post-processing LLM: Qwen2.5-1.5B (the new
//  default) against Qwen3.5-4B MTP (meetings) and Whisperer V3 (dictation).
//
//  Both workloads are decided independently — they have different output lengths and
//  different deadlines. Meetings generate ~1200 tokens off the latency path; dictation
//  generates a sentence on the visible stop→injection path against a 5/10/15s timeout
//  ladder that, when it trips, silently returns the uncorrected text.
//
//  The 4B is not assumed to be slower: it runs speculative decoding (generateMTPTokens),
//  so parameter count alone does not predict tok/s. That is what the accept% column is for.
//

import XCTest
@testable import whisperer

/// Test-side counterpart of `MeetingAIService.StreamingTitleWatcher`: lifts the first
/// complete TITLE line out of the artifact stream and records how long it took to appear.
///
/// `@unchecked Sendable` for the reason the production watcher gives: both fields are
/// written only from the MTP token callback, which runs on the model container's single
/// serial queue, and read only after `process()` has returned and that queue is quiescent.
///
/// File scope rather than nested in the test class: a type nested inside a `@MainActor` type
/// inherits that isolation, and `observe` is called from the token callback, which is not on
/// the main actor.
private final class StreamedTitleProbe: @unchecked Sendable {
    private let started = Date()
    private(set) var title: String?
    private(set) var elapsedMs: Double?

    func observe(_ partial: String) {
        guard title == nil,
              let raw = MeetingOverviewParser.firstCompleteTitle(in: partial) else { return }
        title = raw
        elapsedMs = Date().timeIntervalSince(started) * 1000
    }
}

/// `@MainActor` on the class, not per method: `LLMPostProcessor` is main-actor isolated,
/// so every call here would hop anyway, and hopping mid-measurement would land in the
/// wall-clock numbers.
@MainActor
final class LLMModelComparisonTests: XCTestCase {

    /// Accumulated across both workloads so the roll-up survives individual case failures.
    private static var rows: [BenchRow] = []

    // Meetings: the current model vs the proposed one.
    private static let meetingModels: [LLMModelVariant] = [.qwen2_5_1_5B, .qwen3_5_4B_mtp]
    // Dictation adds today's default as the low-water mark and the 4B as the quality ceiling.
    private static let dictationModels: [LLMModelVariant] = [.whispererV3, .qwen2_5_1_5B, .qwen3_5_4B_mtp]

    // MARK: - Model lifecycle

    /// Loads one variant, runs `body`, and unloads before returning. Sequential by
    /// construction — several GB of weights co-resident thrashes unified memory and
    /// would corrupt the very timings this suite exists to collect.
    private func withModel(
        _ variant: LLMModelVariant,
        _ body: (LLMPostProcessor) async throws -> Void
    ) async throws {
        let processor = LLMPostProcessor()
        do {
            try await processor.loadModel(variant)
        } catch {
            // Not a failure: a model that isn't on disk just doesn't appear in the table.
            print("⏭  Skipping \(variant.rawValue) — cannot load: \(error.localizedDescription)")
            return
        }
        do {
            try await body(processor)
        } catch {
            await processor.unloadModel()
            throw error
        }
        await processor.unloadModel()
    }

    /// Runs one generation and records it. Returns nil when `process` threw, which is
    /// itself a quality failure — `throwOnFallback: true` means the model produced
    /// nothing usable within its timeout.
    @discardableResult
    private func measure(
        _ processor: LLMPostProcessor,
        workload: String,
        model: LLMModelVariant,
        caseName: String,
        run: () async throws -> String,
        judge: (String) -> (ok: Bool, note: String)
    ) async -> String? {
        let started = Date()
        let output: String
        do {
            output = try await run()
        } catch {
            Self.rows.append(BenchRow(
                workload: workload, model: model.rawValue, caseName: caseName,
                promptTokens: 0, genTokens: 0, prefillMs: 0, decodeMs: 0,
                wallMs: Date().timeIntervalSince(started) * 1000,
                acceptRate: nil, qualityOK: false, note: "threw: \(error.localizedDescription)"
            ))
            return nil
        }
        let wallMs = Date().timeIntervalSince(started) * 1000
        let stats = processor.lastGenerationStats
        let verdict = judge(output)

        Self.rows.append(BenchRow(
            workload: workload, model: model.rawValue, caseName: caseName,
            promptTokens: stats?.promptTokens ?? 0,
            genTokens: stats?.genTokens ?? 0,
            prefillMs: (stats?.promptTime ?? 0) * 1000,
            decodeMs: (stats?.generateTime ?? 0) * 1000,
            wallMs: wallMs,
            acceptRate: stats?.acceptRate,
            qualityOK: verdict.ok, note: verdict.note
        ))
        return output
    }

    // MARK: - Meeting notes A/B

    func testMeetingWorkloadComparison() async throws {
        let fixtures = Self.pickMeetings(HistoryTestLoader.loadMeetingFixtures(maxCount: 25))
        try XCTSkipIf(fixtures.isEmpty, "No meetings in the local history database")
        print("Meeting fixtures: " + fixtures.map { "\($0.id.prefix(6))(\($0.wordCount)w)" }.joined(separator: ", "))

        for model in Self.meetingModels {
            try await withModel(model) { processor in
                for fixture in fixtures {
                    await runMeetingCases(processor, model: model, fixture: fixture)
                }
            }
        }

        BenchTable.report("meeting", rows: Self.rows)
        let winner = BenchTable.winner("meeting", rows: Self.rows)
        print("MEETING WINNER: \(winner ?? "none — no model produced rows")\n")
        assertDefaultPassesQuality(workload: "meeting")
    }

    /// Both prompt branches, bounded runtime. `notePrompt` and `overviewPrompt` are
    /// different prompts producing different output lengths, so a benchmark that saw only
    /// one of them would describe half the workload. The 12 000-char ceiling is the app's
    /// own `MeetingAIService.maxTranscriptChars` — above it Ask AI prefilters rather than
    /// sending the transcript whole, so those meetings are not what either prompt receives.
    private static func pickMeetings(_ all: [MeetingFixture]) -> [MeetingFixture] {
        let usable = all
            .filter { MeetingAIService.timestampedTranscript($0.segments).count <= 12_000 }
            .sorted { $0.wordCount < $1.wordCount }
        guard !usable.isEmpty else { return [] }
        var picked: [MeetingFixture] = []
        if let note = usable.first(where: \.isNote) { picked.append(note) }
        picked += usable.suffix(2).filter { f in !picked.contains { $0.id == f.id } }
        return picked
    }

    private func runMeetingCases(_ processor: LLMPostProcessor, model: LLMModelVariant, fixture: MeetingFixture) async {
        let transcript = MeetingAIService.timestampedTranscript(fixture.segments)
        guard !transcript.isEmpty else { return }
        let tag = String(fixture.id.prefix(6))
        // The stored ZDURATION can be 0 on a crash-recovered row; the segments always know.
        let duration = max(fixture.durationSec, fixture.segments.map(\.endTimestamp).max() ?? 0)

        // --- Artifact: TITLE + TOPIC + OVERVIEW + DECISION / OPEN / NEXT / ACTION, one call ---
        //
        // Everything about this call is resolved through `MeetingAIService` rather than
        // restated here: `overviewRequest` picks the prompt, the token hint and the timeout
        // exactly as `generateOverview` does, so a prompt edit lands in the benchmark by
        // itself. That indirection is not stylistic. The title used to be benchmarked against
        // a verbatim copy of the old standalone title prompt kept in this file, and when
        // Milestone 5 folded the title into this artifact the copy stayed — the suite went on
        // reporting numbers for a prompt the app no longer sent. A literal cannot be kept in
        // sync by anything except somebody noticing.
        //
        // There is no separate title case any more because there is no separate call: the
        // title is the artifact's first line, judged with the rest of it in `judgeOverview`.
        let request = MeetingAIService.overviewRequest(transcriptWords: fixture.wordCount)
        let isNote = request.isNote
        let titleProbe = StreamedTitleProbe()
        await measure(
            processor, workload: "meeting", model: model,
            caseName: "artifact-\(isNote ? "note" : "full")-\(tag)",
            run: {
                try await processor.process(
                    text:                   transcript,
                    systemPrompt:           request.systemPrompt,
                    userMessage:            "TRANSCRIPT:\n\(transcript)",
                    temperature:            0.15,
                    repetitionPenalty:      1.15,
                    maxTokensCap:           2048,
                    outputTokensHint:       request.outputTokensHint,
                    timeoutSecondsOverride: request.timeoutSeconds,
                    throwOnFallback:        true,
                    reuseWarmCache:         false,
                    onPartialText:          { titleProbe.observe($0) }
                )
            },
            judge: { raw in judgeOverview(raw, isNote: isNote, duration: duration) }
        )

        // Reported, not a row of its own: the title shares one generation with the summary, so
        // giving it a row would add its wall time to a total that already contains it and hand
        // the roll-up a 0 tok/s entry. What is worth reporting is *when* it arrived — the merge
        // is only a win if the title still lands seconds before the summary finishes, which is
        // the property `generateOverview`'s streaming path exists for. Non-MTP models never
        // drive `onPartialText`, so "not streamed" there is expected, not a failure.
        if let ms = titleProbe.elapsedMs, let title = titleProbe.title {
            print("   title-\(tag) [\(model.rawValue)]: \"\(title)\" streamed at \(Int(ms))ms")
        } else {
            print("   title-\(tag) [\(model.rawValue)]: not streamed — read from the finished artifact")
        }

        // --- Ask AI (skip the BM25 branch: it builds a different, question-specific prompt) ---
        if transcript.count <= 12_000 {
            let system = MeetingAIService.askSystemPrompt(transcript: transcript)
            let question = "What was this recording about, and when was the most important point made?"
            let answer = await measure(
                processor, workload: "meeting", model: model, caseName: "ask-\(tag)",
                run: {
                    try await processor.process(
                        text:           question,
                        systemPrompt:   system,
                        userMessage:    question,
                        temperature:    0.3,
                        maxTokensCap:   512,
                        timeoutSecondsOverride: MeetingAIService.askTimeout(promptChars: system.count),
                        throwOnFallback: true,
                        reuseWarmCache: true
                    )
                },
                judge: { raw in (raw.count >= 20, raw.isEmpty ? "empty answer" : "answer too short") }
            )
            if let answer {
                let citations = await MeetingAIService.shared.parseCitations(from: answer, segments: fixture.segments)
                // Reported, not asserted: a correct answer to a short note can legitimately
                // cite nothing, and failing the model for that would be measuring the question.
                print("   ask-\(tag) [\(model.rawValue)]: \(citations.count) citation(s) parsed")
            }
        }
    }

    // MARK: - Dictation A/B

    func testDictationWorkloadComparison() async throws {
        let all = HistoryTestLoader.loadFixtures(maxCount: 300)
        try XCTSkipIf(all.isEmpty, "No transcriptions in the local history database")

        // Two real chunks per script. Hebrew and Russian are the whole reason for leaving
        // Whisperer V3, and they also exercise the non-Latin token estimate.
        //
        // Grouped by the script actually in the transcript, NOT by the stored `language`
        // column: in this history a purely Hebrew recording is tagged "en". The column
        // records what the router decided, which for a mid-recording switch is not what
        // was ultimately transcribed — trusting it ran the whole "multilingual" benchmark
        // on four English chunks and one each of Hebrew and Russian, mislabelled.
        var byScript: [TranscriptionLanguage: [RecordingFixture]] = [:]
        for fixture in all where fixture.transcript.count > 60 {
            guard let script = Self.script(of: fixture.transcript) else { continue }
            byScript[script, default: []].append(fixture)
        }
        let picked: [(fixture: RecordingFixture, script: TranscriptionLanguage)] =
            [TranscriptionLanguage.english, .hebrew, .russian].flatMap { script in
                (byScript[script] ?? []).prefix(2).map { (fixture: $0, script: script) }
            }
        try XCTSkipIf(picked.isEmpty, "No usable dictation fixtures")
        print("Dictation fixtures by script: " + [TranscriptionLanguage.english, .hebrew, .russian]
            .map { "\($0.rawValue)=\(min(2, byScript[$0]?.count ?? 0))" }.joined(separator: " "))

        let modes = ["Correct", "Grammar", "Translate"].map { TestPrompts.mode(named: $0) }

        for model in Self.dictationModels {
            try await withModel(model) { processor in
                for (fixture, script) in picked {
                    for mode in modes {
                        let (system, user) = TestPrompts.split(mode, text: fixture.transcript)
                        let budget = Self.timeoutBudget(for: fixture.transcript)
                        let out = await measure(
                            processor, workload: "dictation", model: model,
                            caseName: "\(mode.name)-\(script.rawValue)-\(fixture.transcript.count)ch",
                            run: {
                                try await processor.process(
                                    text:              fixture.transcript,
                                    systemPrompt:      system,
                                    userMessage:       user,
                                    targetLanguage:    mode.targetLanguage,
                                    temperature:       mode.temperature,
                                    topP:              mode.topP,
                                    topK:              mode.topK,
                                    repetitionPenalty: mode.repetitionPenalty,
                                    maxTokensCap:      mode.maxTokensCap,
                                    throwOnFallback:   true
                                )
                            },
                            judge: { out in
                                judgeDictation(out, input: fixture.transcript, isTranslation: mode.targetLanguage != nil)
                            }
                        )
                        // In *and* out. The judge below is structural — a length ratio cannot tell a
                        // correct Hebrew sentence from a mangled one, and multilingual quality is the
                        // entire reason for leaving an EN-only model. That verdict is a human's to make,
                        // so the text has to be in the report.
                        print("   [\(model.rawValue)] \(mode.name)/\(script.rawValue) "
                            + "budget=\(Int(budget))s"
                            + "\n     in : \(Self.oneLine(fixture.transcript))"
                            + "\n     out: \(Self.oneLine(out ?? "‹threw›"))")
                    }
                }
            }
        }

        BenchTable.report("dictation", rows: Self.rows)
        reportTimeoutHeadroom()
        let winner = BenchTable.winner("dictation", rows: Self.rows)
        print("DICTATION WINNER: \(winner ?? "none — no model produced rows")\n")
        assertDefaultPassesQuality(workload: "dictation")
    }

    // MARK: - Gates

    /// The suite's only hard assertion. Speed differences are reported for a human to
    /// decide on; a default that produces unusable output is a regression to block on.
    private func assertDefaultPassesQuality(workload: String) {
        let mine = Self.rows.filter { $0.workload == workload && $0.model == LLMModelVariant.qwen2_5_1_5B.rawValue }
        guard !mine.isEmpty else { return }   // model absent — nothing measured, nothing to claim
        let failures = mine.filter { !$0.qualityOK }
        XCTAssertTrue(
            failures.isEmpty,
            "\(LLMModelVariant.qwen2_5_1_5B.rawValue) failed \(failures.count)/\(mine.count) \(workload) quality "
                + "checks: " + failures.map { "\($0.caseName): \($0.note)" }.joined(separator: "; ")
        )
    }

    /// Dictation runs on the visible stop→injection path. `process()` returns the
    /// *uncorrected* text when its charCount timeout trips, so exceeding the budget is
    /// a silent quality loss in production, not just a slow test.
    private func reportTimeoutHeadroom() {
        let rows = Self.rows.filter { $0.workload == "dictation" }
        guard !rows.isEmpty else { return }
        print("=== DICTATION — timeout headroom (ladder: <30ch 5s, <200ch 10s, else 15s) ===")
        for model in Set(rows.map(\.model)).sorted() {
            let m = rows.filter { $0.model == model }
            let worst = m.max { $0.wallMs < $1.wallMs }
            print("| \(model) | worst \(String(format: "%.1f", (worst?.wallMs ?? 0) / 1000))s "
                + "on \(worst?.caseName ?? "–") | budget 15s |")
        }
        print("")
    }

    /// Flattens to one line so a case occupies one row of the report. Truncation is
    /// generous: these are dictation chunks of a few hundred chars, and a correction
    /// judged on its first 80 characters is not judged at all.
    private static func oneLine(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: "⏎")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= 300 ? flat : String(flat.prefix(300)) + "…"
    }

    private static func timeoutBudget(for text: String) -> Double {
        let n = text.count
        return n < 30 ? 5 : (n < 200 ? 10 : 15)
    }

    // MARK: - Judges

    /// Structural, never string-equality: two models never produce the same words, and
    /// what actually matters is whether `MeetingOverviewParser` can consume the output.
    private func judgeOverview(_ raw: String, isNote: Bool, duration: Double) -> (ok: Bool, note: String) {
        // A parse failure is a formatting failure, and "parse failed" alone doesn't say
        // which one — a missing label, a markdown-decorated label, or refusal text all
        // land here. Carry the head of the output so the table names the actual cause.
        let head = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "⏎")
            .prefix(140)
        guard let summary = MeetingOverviewParser.parse(raw) else {
            return (false, "parse failed — raw: \"\(head)\"")
        }
        guard !summary.overview.isEmpty else { return (false, "empty overview — raw: \"\(head)\"") }

        // The same artifact names the recording, so an unusable TITLE is an artifact failure:
        // since Milestone 5 there is no second call left to recover the name from, and the
        // library row keeps its placeholder. Both parser rules are checked the way production
        // checks them — `title(in:)` accepts only a *leading* TITLE, and `sanitizeTitle` is the
        // gate `applyTitle` puts every candidate through before it reaches CoreData.
        guard let rawTitle = MeetingOverviewParser.title(in: raw) else {
            return (false, "artifact did not lead with a TITLE line — raw: \"\(head)\"")
        }
        guard let title = MeetingAIService.sanitizeTitle(rawTitle) else {
            return (false, "unusable title \"\(rawTitle.prefix(40))\"")
        }
        guard title.count <= 70 else { return (false, "title > 70 chars: \"\(title)\"") }

        // Fabricated seconds are the failure the timestamped-transcript format exists to
        // prevent, so a citation outside the recording is a hard fail rather than a warning.
        let slack = duration + 30
        let stamps = summary.keyTopics.map(\.timestampSeconds)
            + summary.decisions.map(\.timestampSeconds)
            + summary.openQuestions.map(\.timestampSeconds)
        if let bad = stamps.first(where: { $0 < 0 || $0 > slack }) {
            return (false, "timestamp \(Int(bad))s outside 0…\(Int(duration))s")
        }

        if !isNote {
            // Warn, don't fail: the prompt asks for 250-350 words, but a genuinely short
            // meeting has less to say and truncating the model for obeying is wrong.
            let words = summary.overview.split(whereSeparator: { $0 == " " || $0.isNewline }).count
            if words < 150 {
                // Print the text, not just the count: a short overview that summarizes is a
                // model being terse, and a short overview that is a stray preamble is the
                // parser's unlabeled-prose fallback firing when it shouldn't.
                print("   ⚠️  full overview only \(words) words (prompt asks 250-350): "
                    + "\"\(summary.overview.replacingOccurrences(of: "\n", with: "⏎").prefix(220))\"")
            }
        }
        return (true, "")
    }

    /// Mirrors `MeetingTranscriptRefiner`'s plausibility guard: catches the two things a
    /// cleanup pass actually does wrong — dropping the utterance, or spiralling.
    private func judgeDictation(_ out: String, input: String, isTranslation: Bool) -> (ok: Bool, note: String) {
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (false, "empty output") }
        guard !trimmed.contains("[INPUT]"), !trimmed.contains("[/INPUT]") else {
            return (false, "echoed the input delimiters")
        }
        // Translation legitimately changes length far more than a cleanup does.
        let lower = isTranslation ? 0.3 : 0.4
        let upper = isTranslation ? 3.0 : 2.5
        let ratio = Double(trimmed.count) / Double(max(1, input.count))
        guard ratio >= lower && ratio <= upper else {
            return (false, String(format: "length ratio %.2f outside %.1f…%.1f", ratio, lower, upper))
        }

        // Language preservation. Correct and Grammar both carry "Keep the same language. Do
        // not translate." in their own prompts, so answering a Russian chunk in English fails
        // the mode however fluent the answer — the user dictated Russian and would get English
        // injected into their document. Every length- and content-based check passes it, which
        // is exactly why it survived a full 18/18 run before the outputs were printed.
        let inScript  = Self.script(of: input)
        let outScript = Self.script(of: trimmed)
        if isTranslation {
            if let outScript, outScript != .english {
                return (false, "translate target is English, got \(outScript.rawValue)")
            }
        } else if let inScript, let outScript, inScript != outScript {
            return (false, "language changed \(inScript.rawValue) → \(outScript.rawValue)")
        }
        return (true, "")
    }

    /// Dominant script of a piece of text, as one of the three languages this history
    /// contains. Reuses the production classifier rather than a second copy of the Unicode
    /// ranges — `dominantScript` filtered to a three-language shortlist collapses to exactly
    /// the script question being asked (Latin→en, Cyrillic→ru, Hebrew→he), and a stray
    /// English technical term inside a Hebrew sentence loses on character count as it should.
    private static func script(of text: String) -> TranscriptionLanguage? {
        ScriptAnalyzer
            .dominantScript(in: text, allowedLanguages: [.english, .hebrew, .russian])
            .max { $0.value < $1.value }?
            .key
    }
}
