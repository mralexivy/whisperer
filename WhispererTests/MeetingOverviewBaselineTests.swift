//
//  MeetingOverviewBaselineTests.swift
//  WhispererTests
//
//  Runs the production overview path over every real meeting in the library and
//  reports what came back. The measurement a prompt search is scored against.
//

import XCTest
@testable import whisperer

/// Baseline for `MeetingAIService.generateOverview` on `.qwen3_5_4B_mtp`.
///
/// Not an A/B — `LLMModelComparisonTests` already covers two models against each other, and to
/// keep a two-model run inside a reasonable wall-clock its `pickMeetings` narrows the library to
/// three fixtures. That is the wrong shape for this question. What has to be known before any
/// prompt optimization starts is how the *shipping* prompt behaves across the *whole* corpus:
/// which lengths degenerate, which languages parse, how much of the token budget is actually
/// used. Three meetings cannot answer that, and an average over a hand-picked three is worse
/// than no number at all.
///
/// Every case is scored on the raw decoder output before the parser touches it. The parser now
/// trims a loop away, so measuring through it would report a clean summary for exactly the
/// decode this run exists to count.
@MainActor
final class MeetingOverviewBaselineTests: XCTestCase {

    /// The model the meeting `.intelligence` engine actually uses.
    private static let variant: LLMModelVariant = .qwen3_5_4B_mtp

    /// Above this the transcript is truncated by `MeetingAIService` anyway, so a fixture past
    /// it would measure the prompt against text the app never sends.
    private static let maxTranscriptChars = 12_000

    private struct Case {
        let title: String
        let language: String
        let words: Int
        let isNote: Bool
        let promptTokens: Int
        let genTokens: Int
        let tokenHint: Int
        let wallMs: Int
        let acceptRate: Double?
        let chars: Int
        let loop: String?
        let parsed: Bool
        let overviewWords: Int
        let topics: Int
        let badTimestamp: Bool
        let raw: String

        var ok: Bool { loop == nil && parsed && overviewWords > 0 && !badTimestamp }
    }

    // MARK: - The run

    func testOverviewBaselineAcrossEveryMeeting() async throws {
        let fixtures = HistoryTestLoader.loadMeetingFixtures(maxCount: 100)
            .filter { !$0.segments.isEmpty }
            .filter { MeetingAIService.narrativeTranscript($0.segments).count <= Self.maxTranscriptChars }
        try XCTSkipIf(fixtures.isEmpty, "No meeting fixtures in the local history database")

        let processor = LLMPostProcessor()
        do {
            try await processor.loadModel(Self.variant)
        } catch {
            throw XCTSkip("Cannot load \(Self.variant): \(error.localizedDescription)")
        }
        print("\n🎯 Overview baseline — \(Self.variant) over \(fixtures.count) real meetings\n")

        var cases = [Case]()
        for (i, fixture) in fixtures.enumerated() {
            print("  [\(i + 1)/\(fixtures.count)] \(fixture.title.prefix(40)) — \(fixture.wordCount)w \(fixture.language)")
            if let c = await run(fixture, on: processor) { cases.append(c) }
        }

        await processor.unloadModel()
        report(cases)

        // The one hard assertion. Everything else in this file is a measurement, but a decode
        // that loops is the defect this baseline was written to close out, and it must stay at
        // zero — the repetition penalty reaching `generateMTPTokens` is what keeps it there.
        let looped = cases.filter { $0.loop != nil }
        XCTAssertTrue(looped.isEmpty,
            "\(looped.count) of \(cases.count) meetings degenerated:\n"
            + looped.map { "  • \($0.title): \"\($0.loop!)\"" }.joined(separator: "\n"))
    }

    // MARK: - One meeting through the production path

    private func run(_ fixture: MeetingFixture, on processor: LLMPostProcessor) async -> Case? {
        // Mirrors `MeetingAIService.generateOverview` exactly, including which transcript
        // rendering each tier gets — a note is summarized from flat text, everything else from
        // the `[Ns]` narrative it cites timestamps out of.
        let plain      = MeetingAIService.plainTranscript(fixture.segments)
        let words      = plain.split(whereSeparator: { $0 == " " || $0.isNewline }).count
        let request    = MeetingAIService.overviewRequest(transcriptWords: words)
        let transcript = request.isNote ? plain : MeetingAIService.narrativeTranscript(fixture.segments)

        let started = Date()
        let raw: String
        do {
            raw = try await processor.process(
                text:                   transcript,
                systemPrompt:           request.systemPrompt,
                userMessage:            "TRANSCRIPT:\n\(transcript)",
                temperature:            0.15,
                repetitionPenalty:      1.15,
                maxTokensCap:           2048,
                outputTokensHint:       request.outputTokensHint,
                timeoutSecondsOverride: request.timeoutSeconds,
                throwOnFallback:        true,
                reuseWarmCache:         false
            )
        } catch {
            print("      ✗ generation failed: \(error.localizedDescription)")
            return nil
        }
        let wallMs = Int(Date().timeIntervalSince(started) * 1000)
        let stats  = processor.lastGenerationStats

        let summary = MeetingOverviewParser.parse(raw)
        // A cited timestamp outside the recording is the model inventing a seconds field, and
        // it is the one hallucination this format makes cheap to detect.
        let limit = fixture.durationSec + 30
        let stamps = (summary?.keyTopics.map(\.timestampSeconds) ?? [])
            + (summary?.decisions.map(\.timestampSeconds) ?? [])
            + (summary?.openQuestions.map(\.timestampSeconds) ?? [])

        let c = Case(
            title:         fixture.title,
            language:      fixture.language,
            words:         words,
            isNote:        request.isNote,
            promptTokens:  stats?.promptTokens ?? 0,
            genTokens:     stats?.genTokens ?? 0,
            tokenHint:     request.outputTokensHint,
            wallMs:        wallMs,
            acceptRate:    stats?.acceptRate,
            chars:         raw.count,
            loop:          TestLoopDetector.firstRepeat(in: raw),
            parsed:        summary != nil,
            overviewWords: summary?.overview.split(whereSeparator: { $0.isWhitespace }).count ?? 0,
            topics:        summary?.keyTopics.count ?? 0,
            badTimestamp:  stamps.contains { $0 < 0 || $0 > limit },
            raw:           raw
        )
        print("      \(c.ok ? "✓" : "✗") \(c.genTokens)/\(c.tokenHint) tok, "
              + "\(c.overviewWords)w overview, \(c.wallMs)ms"
              + (c.loop.map { " — LOOP \"\($0)\"" } ?? "")
              + (c.parsed ? "" : " — PARSE FAILED")
              + (c.badTimestamp ? " — TIMESTAMP OUT OF RANGE" : ""))
        return c
    }

    // MARK: - Report

    private func report(_ cases: [Case]) {
        guard !cases.isEmpty else { return }

        print("\n┌─ Overview baseline: \(Self.variant) ─────────────────────────────")
        print("│ \(pad("meeting", 30)) \(pad("lang", 5)) \(pad("words", 6)) "
              + "\(pad("gen", 6)) \(pad("ovrvw", 7)) \(pad("top", 6)) \(pad("ms", 7))")
        for c in cases.sorted(by: { $0.words < $1.words }) {
            let flags = [c.loop != nil ? "LOOP" : nil,
                         c.parsed ? nil : "NOPARSE",
                         c.badTimestamp ? "TS" : nil].compactMap { $0 }.joined(separator: ",")
            print("│ \(pad(c.title, 30)) \(pad(c.language, 5)) \(rpad(c.words, 6)) "
                  + "\(rpad(c.genTokens, 6)) \(rpad(c.overviewWords, 7)) \(rpad(c.topics, 6)) "
                  + "\(rpad(c.wallMs, 7))  \(flags)")
        }
        print("└──────────────────────────────────────────────────────────────────")

        let ok = cases.filter(\.ok).count
        print("\n  clean            \(ok)/\(cases.count)")
        print("  looped           \(cases.filter { $0.loop != nil }.count)")
        print("  parse failed     \(cases.filter { !$0.parsed }.count)")
        print("  empty overview   \(cases.filter { $0.overviewWords == 0 }.count)")
        print("  bad timestamp    \(cases.filter(\.badTimestamp).count)")
        print("  no topics        \(cases.filter { $0.topics == 0 && !$0.isNote }.count) of "
              + "\(cases.filter { !$0.isNote }.count) non-notes")

        // Budget use is the tell for a truncated generation: the pre-fix runs sat near 10% of
        // hint because the guard cut them off, not because the model had finished.
        let budget = cases.map { Double($0.genTokens) / Double(max(1, $0.tokenHint)) }
        print(String(format: "  budget used      %.0f%% median, %.0f%% max",
                     median(budget) * 100, (budget.max() ?? 0) * 100))
        print(String(format: "  wall             %.1fs median, %.1fs max",
                     median(cases.map { Double($0.wallMs) / 1000 }),
                     (cases.map { Double($0.wallMs) / 1000 }.max() ?? 0)))

        // Per language, because a mean over a corpus that is 80% one language reports that
        // language's score and calls it the model's.
        for lang in Set(cases.map(\.language)).sorted() {
            let group = cases.filter { $0.language == lang }
            print("  \(pad(lang, 6)) clean \(group.filter(\.ok).count)/\(group.count), "
                  + "median overview \(Int(median(group.map { Double($0.overviewWords) })))w")
        }

        for c in cases where !c.ok {
            print("\n  ── \(c.title) (\(c.language), \(c.words)w) ──\n  \(c.raw.prefix(600))")
        }
        print("")
    }

    private func pad(_ s: String, _ n: Int) -> String {
        let t = s.count > n ? String(s.prefix(n - 1)) + "…" : s
        return t.padding(toLength: n, withPad: " ", startingAt: 0)
    }

    private func rpad(_ v: Int, _ n: Int) -> String {
        String(repeating: " ", count: max(0, n - String(v).count)) + String(v)
    }

    private func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
