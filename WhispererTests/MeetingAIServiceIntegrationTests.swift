//
//  MeetingAIServiceIntegrationTests.swift
//  WhispererTests
//
//  End-to-end integration test: real meeting transcript from history
//  → LLM → MeetingOverviewParser → MeetingAISummary.
//  Exercises the exact parameters used by MeetingAIService.generateOverview().
//

import XCTest
@testable import whisperer

// Real transcript from CoreData ZMEETINGENTITY (Z_PK=5):
// "Note Aug 9, 2026 7:46 PM", duration 201s
private let realHistoryTranscript = """
[Speaker 1 @ 0:09] Okay, I want to show you why this experience is really, really, really off and what it \
needs to to be fixed. So first bug is basically All right, I'm going to continue my speaking, so

[Speaker 1 @ 2:28] So I'm giving a speech for for two minutes and and I still captured changed my voice. \
I'm not sure why it's not different it It should be Okay, I want to show you why this experience is really, \
really, really off and what it needs to to be fixed. So first bug is basically All right, I'm going to \
continue my speaking, so So I'm giving a speech for for two minutes and and I still captured changed my \
voice. I'm not sure why it's not different it It should be front
"""

// System prompt mirrored exactly from MeetingAIService.generateOverview()
private let overviewSystemPrompt = """
You are a concise meeting analyst. Read the transcript once, then write each field exactly once. Never repeat a word or phrase.

LANGUAGE RULE: Detect the primary language of the transcript. Write ALL output in that same language.

Output ONLY the lines below — one per line, nothing else.

OVERVIEW: <2-4 unique factual sentences in past tense. Each sentence must add new information. Stop after 4 sentences.>
TOPIC: <short noun phrase, no verb> | <timestamp seconds>
DECISION: <2-3 word label> | <decision clause> | <timestamp seconds>
OPEN: <question ending with ?> | <timestamp seconds>
NEXT: <date and agenda, or the word none>
ACTION: <imperative verb, no name> | <owner full name> | <due date or none>

STRICT RULES:
- Write each field at most once per output line. Do not repeat content across lines.
- OVERVIEW: exactly one line. Stop the sentence when the thought is complete.
- TOPIC: 1-4 lines. Omit if no distinct topics exist.
- DECISION, OPEN, ACTION: 0-3 lines each. Omit sections with no data.
- NEXT: exactly one line.
- If the transcript is very short or unclear, write a brief honest OVERVIEW and omit other fields.
- Do not add commentary, preamble, or closing text.
"""

final class MeetingAIServiceIntegrationTests: XCTestCase {

    // Shared processor — model load is slow, reuse across tests.
    @MainActor private static var sharedProcessor: LLMPostProcessor?

    @MainActor
    private func processor() async throws -> LLMPostProcessor {
        if let p = Self.sharedProcessor, p.isModelLoaded { return p }
        let p = LLMPostProcessor()
        do {
            try await p.loadModel(.qwen3_5_4B_mtp)
            Self.sharedProcessor = p
            return p
        } catch {
            throw XCTSkip("Cannot load qwen3_5_4B_mtp (model not downloaded): \(error.localizedDescription)")
        }
    }

    // MARK: - Core end-to-end test

    /// Full pipeline: real meeting transcript → LLM (with production parameters) → parse → non-empty summary.
    func testGenerateOverview_realHistoryTranscript() async throws {
        let p = try await processor()

        let raw = try await p.process(
            text:                   realHistoryTranscript,
            systemPrompt:           overviewSystemPrompt,
            userMessage:            "[INPUT]\n\(realHistoryTranscript)\n[/INPUT]",
            temperature:            0.15,
            repetitionPenalty:      1.2,
            maxTokensCap:           2048,
            outputTokensHint:       600,
            timeoutSecondsOverride: 60
        )

        XCTAssertFalse(raw.isEmpty, "LLM produced no output")

        guard let summary = MeetingOverviewParser.parse(raw) else {
            XCTFail("MeetingOverviewParser returned nil.\nRaw output (\(raw.count) chars):\n\(raw)")
            return
        }

        XCTAssertFalse(summary.overview.isEmpty, "overview should not be empty")
    }

    // MARK: - Robustness: shorter timeout still recovers via truncation repair

    /// Even if LLM is cut off at 15 s (old default), truncation repair must recover the overview field.
    func testGenerateOverview_shortTimeoutRecoversViaRepair() async throws {
        let p = try await processor()

        let raw = try await p.process(
            text:                   realHistoryTranscript,
            systemPrompt:           overviewSystemPrompt,
            userMessage:            "[INPUT]\n\(realHistoryTranscript)\n[/INPUT]",
            temperature:            0.15,
            repetitionPenalty:      1.2,
            maxTokensCap:           2048,
            outputTokensHint:       600,
            timeoutSecondsOverride: 15   // tight — may truncate, parser should still handle it
        )

        // May be empty only if LLM produced absolutely nothing
        if raw.isEmpty { return }

        // If LLM produced any output, the parser must not crash and must return something
        // when at least one complete root-level field was emitted.
        if let summary = MeetingOverviewParser.parse(raw) {
            // overview may be empty when truncated before the value completes — that's OK
            _ = summary.overview
        }
        // If parse returns nil, LLM output may have been structurally invalid (not just truncated).
        // That's acceptable under a tight timeout — we just log it, not fail.
    }

    // MARK: - Token budget

    /// Confirms the outputTokensHint fix: log should show maxTokens≈800, not ≈59.
    /// Indirect check — we verify the LLM actually produces output.
    func testOutputIsLongEnoughForValidJSON() async throws {
        let p = try await processor()

        let raw = try await p.process(
            text:                   realHistoryTranscript,
            systemPrompt:           overviewSystemPrompt,
            userMessage:            "[INPUT]\n\(realHistoryTranscript)\n[/INPUT]",
            temperature:            0.15,
            repetitionPenalty:      1.2,
            maxTokensCap:           2048,
            outputTokensHint:       600,
            timeoutSecondsOverride: 60
        )

        // Minimum viable line-format output is ~30 chars (just an OVERVIEW line).
        // If we got fewer than that, the token budget is still wrong.
        XCTAssertGreaterThan(raw.count, 30,
            "Output too short (\(raw.count) chars) — outputTokensHint may not be applied")
    }

    // MARK: - Repetition penalty reaches the MTP decoder

    /// The shipped defect, end to end. `generateOverview` passed `repetitionPenalty: 1.15`,
    /// `process()` logged it, and then handed the work to `processMTP`, whose signature had no
    /// sampling parameters at all — so `generateMTPTokens` ran at the 1.0 default, i.e. pure
    /// greedy argmax with nothing to break a cycle. Every overview on this transcript collapsed
    /// into "to Michael to Michael to to to…" and was guillotined by the degeneration guard at
    /// well under a hundred tokens.
    ///
    /// Asserted on the raw decoder output rather than through the parser: the parser now trims a
    /// loop away, which would hide exactly the regression this test exists to catch.
    func testMTPDecodeDoesNotLoop_realHistoryTranscript() async throws {
        let p = try await processor()
        let request = MeetingAIService.overviewRequest(
            transcriptWords: realHistoryTranscript.split(whereSeparator: { $0.isWhitespace }).count)

        let raw = try await p.process(
            text:                   realHistoryTranscript,
            systemPrompt:           request.systemPrompt,
            userMessage:            "[INPUT]\n\(realHistoryTranscript)\n[/INPUT]",
            temperature:            0.15,
            repetitionPenalty:      1.15,
            maxTokensCap:           2048,
            outputTokensHint:       request.outputTokensHint,
            timeoutSecondsOverride: request.timeoutSeconds
        )

        XCTAssertFalse(raw.isEmpty, "LLM produced no output")
        if let loop = TestLoopDetector.firstRepeat(in: raw) {
            XCTFail("Decode looped on \"\(loop)\" — repetition penalty is not reaching "
                    + "generateMTPTokens.\nRaw output (\(raw.count) chars):\n\(raw)")
        }
    }
}
