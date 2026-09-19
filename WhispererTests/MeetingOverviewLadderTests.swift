//
//  MeetingOverviewLadderTests.swift
//  WhispererTests
//
//  Fast deterministic tests for the four-rung overview ladder in MeetingAIService.
//  No model is loaded — LLM calls are intercepted by _testProcessHook / _testBatchHook.
//
//  Each test completes in < 5 s (no GPU, no tokenizer).
//

import XCTest
@testable import whisperer

@MainActor
final class MeetingOverviewLadderTests: XCTestCase {

    // MARK: - Fixtures

    /// A compact Hebrew transcript that would normally trigger map-reduce (>700 words
    /// total, so we set wordCount high in the request). For the ladder we just need
    /// non-empty segments — the exact text does not matter.
    private func makeHebrewSegments(count: Int = 30) -> [MeetingSegment] {
        (0..<count).map { i in
            MeetingSegment(
                id: UUID(),
                timestamp: Double(i) * 15,
                endTimestamp: Double(i) * 15 + 14,
                text: "פגישה על רגרסיות ופילטרים נושא \(i) כלשהו עם תוכן",
                language: "he"
            )
        }
    }

    // MARK: - Helpers

    /// Shared injected processor (no model; just the hooks below do the work).
    private var processor: LLMPostProcessor!

    override func setUp() async throws {
        try await super.setUp()
        processor = LLMPostProcessor()
        MeetingAIService._testInjectedLLM = processor
    }

    override func tearDown() async throws {
        MeetingAIService._testInjectedLLM = nil
        LLMPostProcessor._testProcessHook = nil
        LLMPostProcessor._testBatchHook = nil
        processor = nil
        try await super.tearDown()
    }

    /// Runs `generateOverview` and waits for either success or failure notification.
    /// Returns true if the success notification arrived first.
    private func runOverview(
        segments: [MeetingSegment],
        meetingID: UUID = UUID(),
        timeout: TimeInterval = 30
    ) async -> Bool {
        let service = MeetingAIService.shared
        var success = false
        await withCheckedContinuation { continuation in
            var token: NSObjectProtocol?
            var failToken: NSObjectProtocol?
            var resumed = false
            let resume = { (ok: Bool) in
                guard !resumed else { return }
                resumed = true
                success = ok
                if let t = token { NotificationCenter.default.removeObserver(t) }
                if let t = failToken { NotificationCenter.default.removeObserver(t) }
                continuation.resume()
            }
            token = NotificationCenter.default.addObserver(
                forName: .meetingOverviewDidGenerate, object: nil, queue: .main
            ) { _ in resume(true) }
            failToken = NotificationCenter.default.addObserver(
                forName: .meetingOverviewDidFail, object: nil, queue: .main
            ) { _ in resume(false) }
            Task {
                await service.generateOverview(segments: segments, meetingID: meetingID)
                // If the method returned without posting (shouldn't happen), resume anyway.
                try? await Task.sleep(nanoseconds: 500_000_000)
                resume(false)
            }
        }
        return success
    }

    // MARK: - Production failure replay

    /// Replays the exact whisperer-2026-09-19 2.log failure mode:
    ///   map step → Hebrew key points → reduce returns only title line → EOS
    /// The ladder must still produce a non-empty summary.
    func testProductionFailureReplay() async throws {
        let segments = makeHebrewSegments()
        let hebrewKeyPoints = (0..<5).map { i in
            "נקודה עיקרית \(i): דיון על רגרסיות ופילטרים בפגישה"
        }.joined(separator: "\n")

        // Map step returns compressed key points (5 "rows").
        LLMPostProcessor._testBatchHook = { _, requests in
            // Return one key-point line per chunk, total much shorter than input.
            requests.map { _ in "נקודה עיקרית: דיון על רגרסיות ופילטרים" }
        }

        // Call counter so we know which rung is active.
        actor Counter { var value = 0; func increment() -> Int { value += 1; return value } }
        let counter = Counter()

        // Reduce and subsequent calls: return title-only on first two calls, full artifact on third.
        LLMPostProcessor._testProcessHook = { systemPrompt, userMessage, prefill in
            let n = await counter.increment()
            if let prefill, !prefill.isEmpty {
                // Rung 1: model was pre-seeded with title + "3| " — return the full continuation.
                return prefill + "זוהי סקירה של הפגישה שעסקה ברגרסיות ובפילטרים. " +
                       "הצוות זיהה שני גורמי שורש וקיבל החלטות לגבי שינויים נדרשים."
            }
            // Rungs 0 and 2: return just the title, triggering escalation.
            return "1| פגישת טכנולוגיה על רגרסיות ופילטרים"
        }

        let ok = await runOverview(segments: segments)
        XCTAssertTrue(ok, "Production failure replay must produce a summary (not post .didFail)")
    }

    // MARK: - Rung 0 succeeds on corrected prompt

    func testRung0SucceedsWithFullArtifact() async throws {
        let segments = makeHebrewSegments()
        LLMPostProcessor._testBatchHook = { _, requests in
            requests.map { _ in "נקודה: רגרסיות זוהו ותוקנו" }
        }
        LLMPostProcessor._testProcessHook = { _, _, _ in
            """
            1| פגישה על רגרסיות
            3| הצוות דן בבעיות הרגרסיה שנמצאו בשבוע האחרון ובפתרונות אפשריים.
            """
        }
        let ok = await runOverview(segments: segments)
        XCTAssertTrue(ok, "Full artifact on rung0 should succeed immediately")
    }

    // MARK: - Rung 1: prefill continuation

    func testRung1PrefillContinuationIsUsed() async throws {
        let segments = makeHebrewSegments()
        var receivedPrefill: String? = nil

        LLMPostProcessor._testBatchHook = { _, requests in
            requests.map { _ in "נקודה: דיון על פילטרים" }
        }
        LLMPostProcessor._testProcessHook = { _, _, prefill in
            if let prefill, !prefill.isEmpty {
                receivedPrefill = prefill
                return prefill + "הפגישה עסקה בפילטרים ובאופטימיזציות של מנוע החיפוש."
            }
            return "1| פגישת פילטרים"  // rung 0: title-only
        }

        let ok = await runOverview(segments: segments)
        XCTAssertTrue(ok, "Rung 1 should rescue a title-only rung-0 output")
        XCTAssertNotNil(receivedPrefill, "Rung 1 must pass a prefill string to process()")
        XCTAssertTrue(receivedPrefill?.hasPrefix("1| ") ?? false,
                      "Prefill must start with '1| <title>'")
        XCTAssertTrue(receivedPrefill?.contains("3| ") ?? false,
                      "Prefill must contain '3| ' to seed the overview line")
    }

    // MARK: - Rung 2: narrow prose call

    func testRung2NarrowCallProducesOverview() async throws {
        let segments = makeHebrewSegments()

        LLMPostProcessor._testBatchHook = { _, requests in
            requests.map { _ in "נקודה: דיון" }
        }

        actor Counter { var value = 0; func increment() -> Int { value += 1; return value } }
        let counter = Counter()

        LLMPostProcessor._testProcessHook = { systemPrompt, _, prefill in
            let n = await counter.increment()
            if let prefill, !prefill.isEmpty { return "1| כותרת\n" }  // rung 1 still fails
            // Rung 2 uses a narrow prompt (no numbered format). Detect it by absence of "3|".
            if !systemPrompt.contains("3|") {
                return "הפגישה עסקה בנושאים טכניים ובאתגרים שונים."
            }
            return "1| כותרת פגישה"  // rungs 0 title-only
        }

        let ok = await runOverview(segments: segments)
        XCTAssertTrue(ok, "Rung 2 narrow prose call should produce a valid summary")
    }

    // MARK: - Rung 3: extractive floor (LLM always fails)

    func testRung3ExtractiveFloorNeverFails() async throws {
        let segments = makeHebrewSegments(count: 20)

        LLMPostProcessor._testBatchHook = { _, requests in
            // Return something very short so the map sanity guard rejects it — force single-pass.
            [""]
        }
        LLMPostProcessor._testProcessHook = { _, _, _ in
            throw CancellationError()  // Every LLM call fails.
        }

        let ok = await runOverview(segments: segments)
        XCTAssertTrue(ok, "Rung 3 extractive floor must produce a summary even when LLM always throws")
    }

    // MARK: - Engine unavailable → rung 3

    func testRung3WhenEngineUnavailable() async throws {
        let segments = makeHebrewSegments(count: 15)

        // Inject a processor that has no model loaded — acquireLLM() returns it,
        // but every process() call will fail via throwOnFallback, so rungs 0-2
        // are all skipped and rung 3 must produce the summary.
        // (We also clear _testProcessHook so the hook guard doesn't intercept.)
        LLMPostProcessor._testProcessHook = { _, _, _ in
            throw LLMFallbackError.noModelLoaded
        }
        LLMPostProcessor._testBatchHook = { _, requests in
            // Return same-length output (sanity guard will reject it → single-pass).
            requests.map { req in req.text }
        }

        let ok = await runOverview(segments: segments)
        XCTAssertTrue(ok, "Engine unavailable must still yield a summary via rung 3")
    }

    // MARK: - Empty transcript → only case that may fail

    func testEmptyTranscriptPostsDidFail() async throws {
        // No segments → transcript is empty → .meetingOverviewDidFail is the only legal outcome.
        let ok = await runOverview(segments: [])
        XCTAssertFalse(ok, "Empty transcript must post .meetingOverviewDidFail")
    }

    // MARK: - Determinism of rung 3

    func testRung3IsDeterministic() async throws {
        let segments = makeHebrewSegments(count: 25)

        LLMPostProcessor._testBatchHook = { _, _ in [""] }
        LLMPostProcessor._testProcessHook = { _, _, _ in throw CancellationError() }

        // EvidenceSelector is pure: same segments → same lines → same joined prose.
        let evidence1 = EvidenceSelector.select(segments)
        let evidence2 = EvidenceSelector.select(segments)
        let prose1 = evidence1.lines.map { $0.text }.joined(separator: " ")
        let prose2 = evidence2.lines.map { $0.text }.joined(separator: " ")
        XCTAssertEqual(prose1, prose2, "Rung 3 evidence selection must be byte-identical across runs")
    }
}
