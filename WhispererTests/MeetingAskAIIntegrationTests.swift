//
//  MeetingAskAIIntegrationTests.swift
//  WhispererTests
//
//  Integration test for MeetingAIService.ask() on a real Hebrew meeting.
//  Exercises the full stack: BM25 prefilter, token budget, timeout, and answer language.
//
//  Fixture: WhispererTests/TestData/hebrew-meeting-segments.json — 121 segments, 4932 words,
//  Hebrew (he), from the Google Meet recording that exposed the 15-token truncation bug.
//
//  The question is in English so the cross-script retrieval path is exercised AND the
//  "answer in the language the user typed" rule is verified simultaneously.
//
//  Requires the Qwen3.5-4B model on disk (~3 GB). Skips automatically if the model is absent.
//

import XCTest
@testable import whisperer

@MainActor
final class MeetingAskAIIntegrationTests: XCTestCase {

    // MARK: - Fixtures

    private var segments: [MeetingSegment] = []
    private let meetingID = UUID()

    override func setUp() async throws {
        try await super.setUp()
        segments = try Self.loadHebrewSegments()
        XCTAssertFalse(segments.isEmpty, "Hebrew segments fixture must not be empty")
    }

    private static func loadHebrewSegments() throws -> [MeetingSegment] {
        // Try bundle resource first, then fall back to source-tree-relative path.
        if let url = Bundle(for: MeetingAskAIIntegrationTests.self)
            .url(forResource: "hebrew-meeting-segments", withExtension: "json",
                 subdirectory: "TestData") {
            return try JSONDecoder().decode([MeetingSegment].self, from: Data(contentsOf: url))
        }
        let sourceDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let fallback = sourceDir.appendingPathComponent("TestData/hebrew-meeting-segments.json")
        return try JSONDecoder().decode([MeetingSegment].self, from: Data(contentsOf: fallback))
    }

    // MARK: - Model lifecycle

    /// Loads Qwen3.5-4B, injects it into MeetingAIService, runs `body`, then cleans up.
    /// Skips gracefully when the model is not on disk.
    private func withMeetingLLM(_ body: () async throws -> Void) async throws {
        let processor = LLMPostProcessor()
        do {
            try await processor.loadModel(.qwen3_5_4B_mtp)
        } catch {
            throw XCTSkip("Qwen3.5-4B not on disk — \(error.localizedDescription)")
        }
        MeetingAIService._testInjectedLLM = processor
        do {
            try await body()
        } catch {
            MeetingAIService._testInjectedLLM = nil
            await processor.unloadModel()
            throw error
        }
        MeetingAIService._testInjectedLLM = nil
        await processor.unloadModel()
    }

    // MARK: - Primary regression

    /// The bug: English question on a Hebrew meeting returned 15 tokens and stopped mid-bullet.
    /// Validates token budget, answer language, and completion without timeout.
    func testEnglishQuestionOnHebrewMeeting() async throws {
        let question = "what we have been discussed?"

        // This meeting's transcript must exceed the prefilter threshold so the cross-script
        // retrieval path is actually exercised (coverage fallback, not keyword match).
        let transcript = MeetingAIService.timestampedTranscript(segments)
        let isNonLatin = LLMPostProcessor.containsNonLatinScript(transcript)
        let limit = MeetingAIService.askContextTokens * (isNonLatin ? 2 : 4)
        XCTAssertGreaterThan(transcript.count, limit,
            "Hebrew meeting transcript (\(transcript.count) chars) must exceed prefilter threshold (\(limit))")

        try await withMeetingLLM {
            let start = Date()
            let answer = await MeetingAIService.shared.ask(
                question: question, meetingID: self.meetingID, segments: self.segments)
            let elapsed = Date().timeIntervalSince(start)

            XCTAssertFalse(answer.text.isEmpty, "Answer must not be empty")
            XCTAssertNotEqual(
                answer.text.trimmingCharacters(in: .whitespacesAndNewlines), question,
                "Answer must not echo the question back (throwOnFallback failure)")
            XCTAssertNotEqual(answer.text, "Sorry, I couldn't answer that. Please try again.",
                "LLM failed to produce any output — check model load and timeout")

            // ≥30 words rules out the pre-fix 15-token fragment ("In the meeting … *")
            let wordCount = answer.text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.count
            XCTAssertGreaterThanOrEqual(wordCount, 30,
                "Answer is too short (\(wordCount) words) — token budget or timeout still truncating.\n"
                + "Full answer:\n\(answer.text)")

            // Answer must be in English (question language), not Hebrew.
            // A Hebrew answer has high density of Hebrew Unicode scalars.
            let hebrewScalars = answer.text.unicodeScalars
                .filter { $0.value >= 0x0590 && $0.value <= 0x05FF }.count
            let hebrewRatio = Double(hebrewScalars) / Double(max(1, answer.text.unicodeScalars.count))
            XCTAssertLessThan(hebrewRatio, 0.10,
                "Answer appears to be in Hebrew (\(Int(hebrewRatio * 100))% Hebrew scalars) "
                + "— language-follows-question fix did not apply.\nAnswer:\n\(answer.text)")

            // 3 minutes is generous even on a slow machine (no GPU).
            XCTAssertLessThan(elapsed, 180,
                "Ask AI exceeded 3-minute wall-clock budget (\(Int(elapsed))s)")

            print("✅ English Q on Hebrew meeting — \(wordCount) words in \(Int(elapsed))s:\n\(answer.text)")
        }
    }

    // MARK: - Hebrew question → Hebrew answer

    func testHebrewQuestionOnHebrewMeeting() async throws {
        let question = "על מה דיברנו?"

        try await withMeetingLLM {
            let answer = await MeetingAIService.shared.ask(
                question: question, meetingID: self.meetingID, segments: self.segments)

            XCTAssertFalse(answer.text.isEmpty, "Answer must not be empty")
            XCTAssertNotEqual(answer.text, "Sorry, I couldn't answer that. Please try again.",
                "LLM failed on Hebrew question")

            let wordCount = answer.text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.count
            XCTAssertGreaterThanOrEqual(wordCount, 10,
                "Hebrew answer too short (\(wordCount) words): \(answer.text)")

            let hebrewScalars = answer.text.unicodeScalars
                .filter { $0.value >= 0x0590 && $0.value <= 0x05FF }.count
            XCTAssertGreaterThan(hebrewScalars, 0,
                "Hebrew question should produce a Hebrew answer. Got: \(answer.text)")

            print("✅ Hebrew Q — \(wordCount) words:\n\(answer.text)")
        }
    }

    // MARK: - Cache reuse

    /// Two identical questions on the same short meeting. Both must return substantive answers.
    /// (Speed assertion omitted — too hardware-dependent for a reliable CI gate.)
    func testRepeatedQuestionDoesNotBreak() async throws {
        let question = "What were the main topics?"
        let shortSegments = Array(segments.prefix(10))

        try await withMeetingLLM {
            let first = await MeetingAIService.shared.ask(
                question: question, meetingID: self.meetingID, segments: shortSegments)
            let second = await MeetingAIService.shared.ask(
                question: question, meetingID: self.meetingID, segments: shortSegments)

            for (label, a) in [("First", first), ("Second", second)] {
                XCTAssertFalse(a.text.isEmpty, "\(label) answer must not be empty")
                XCTAssertNotEqual(a.text, "Sorry, I couldn't answer that. Please try again.",
                    "\(label) answer failed")
            }
            print("✅ First:  \(first.text.prefix(120))")
            print("✅ Second: \(second.text.prefix(120))")
        }
    }

    // MARK: - Timeout formula (no model needed)

    func testAskTimeoutBudgetsGeneration() {
        // Old formula gave 20s on a tiny transcript. With 600 output tokens at ~20 tok/s
        // generation alone needs 30s — the timeout must be at least that.
        let t = MeetingAIService.askTimeout(promptChars: 1_000, outputTokens: 600, isNonLatin: false)
        XCTAssertGreaterThanOrEqual(t, 30,
            "Timeout must budget for 600 output tokens at ~20 tok/s even on a tiny transcript")
    }

    func testAskTimeoutHebrewTranscript() {
        // 24,077-char Hebrew transcript: prefill ~40s + generation ~30s → expect ≥60s timeout.
        let t = MeetingAIService.askTimeout(promptChars: 24_077, outputTokens: 600, isNonLatin: true)
        XCTAssertGreaterThanOrEqual(t, 60,
            "Hebrew transcript timeout should cover both prefill and generation phases")
        XCTAssertLessThanOrEqual(t, 180, "Timeout should not exceed 3 minutes")
    }

    func testOutputTokenConstantIsSufficient() {
        XCTAssertGreaterThanOrEqual(MeetingAIService.askOutputTokens, 300,
            "askOutputTokens must be large enough for a multi-bullet answer")
    }
}
