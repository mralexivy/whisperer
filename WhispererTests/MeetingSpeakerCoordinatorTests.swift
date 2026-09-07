//
//  MeetingSpeakerCoordinatorTests.swift
//  WhispererTests
//
//  Regression tests for the "meeting live transcript blanks every ~1.8 s" bug
//  (2026-09-07, Hebrew meeting, 148 whisper deltas wipe pending queue).
//
//  Root cause: `MeetingSpeakerCoordinator.ingestAccumulated(_:)` expects a **full
//  accumulated transcript** on every call. On the whisper.cpp+Nemotron meeting path,
//  `onChunkCompleted` used to route whisper's **per-commit delta** into `onFinalText`,
//  which called `ingestAccumulated`. The delta was far shorter than the emitted+pending
//  word count, so the diff treated it as a Nemotron tail-rewrite and dropped the entire
//  pending queue — publishing an empty tail every ~1.8 s.
//
//  Fixes applied:
//  A) AppState no longer calls `coordinator.onFinalText(chunk.text)` on the whisper.cpp
//     backend path — the primary guard.
//  B) `ingestAccumulated` rejects input with `words.count < emittedWordCount` — the
//     coordinator-level defence-in-depth.
//  C) `feed()` calls `drainPending()` unconditionally — so the 3 s age-deadline fires
//     even when Sortformer is not loaded, preventing unbounded tail growth.
//
//  These tests run without any models: the coordinator is a pure Swift actor.
//

import XCTest
@testable import whisperer

#if canImport(FluidAudio)
import FluidAudio

// MARK: - Helpers

private extension MeetingSpeakerCoordinator {
    /// Advance the audio clock; does not start the diarizer.
    func feedSilence(seconds: Double) async {
        let count = Int(seconds * 16000)
        await feed([Float](repeating: 0, count: count))
    }
}

// MARK: - Coordinator regression tests

final class MeetingSpeakerCoordinatorDeltaRegressionTests: XCTestCase {

    // MARK: 1. Drain-deadline releases stale items (fix C)

    /// Words ingested more than 3 s behind the current audio clock must drain via the
    /// age deadline, even when Sortformer is not loaded (finalizedUntil stays at 0).
    ///
    /// Pre-fix: `feed()` returned early when `diarizer == nil`, so `drainPending()` was
    /// never called and the deadline never fired. Tail grew unbounded during long monologues.
    func testDrainDeadlineReleasesStaleItems() async throws {
        let coordinator = MeetingSpeakerCoordinator()

        var attributedTexts: [String] = []
        await coordinator.setCallbacks(
            onAttributed: { text, _, _, _ in attributedTexts.append(text) },
            onPendingTail: { _ in },
            onLiveSpeaker: { _ in }
        )

        // Feed 2 s of audio — items end at ~2 s.
        await coordinator.feedSilence(seconds: 2)
        await coordinator.onPartial("first second third fourth fifth")

        // Advance 5 more seconds — items are now 5 s old, past the 3 s deadline.
        // `feed()` must call `drainPending()` even without a diarizer.
        await coordinator.feedSilence(seconds: 5)

        XCTAssertFalse(attributedTexts.isEmpty,
            "Drain deadline did not fire after 5 s of audio age — " +
            "items stuck in pending indefinitely. Check that feed() calls drainPending() unconditionally.")
    }

    // MARK: 2. Coordinator guard rejects deltas once words are emitted (fix B)

    /// After the drain deadline emits some words (`emittedWordCount > 0`), a whisper-style
    /// delta whose word count is below `emittedWordCount` must be rejected by the guard in
    /// `ingestAccumulated` without touching pending.
    ///
    /// This mirrors the "late in a meeting" scenario: speaker attribution has happened
    /// (emittedWordCount > 0) and a whisper commit with fewer words arrives.
    func testDeltaShorterThanEmittedCountIsIgnored() async throws {
        let coordinator = MeetingSpeakerCoordinator()

        var tails: [String] = []
        await coordinator.setCallbacks(
            onAttributed: { _, _, _, _ in },
            onPendingTail: { tails.append($0) },
            onLiveSpeaker: { _ in }
        )

        // Feed 2 s — items will be timestamped at ~2 s.
        await coordinator.feedSilence(seconds: 2)
        let tenWords = "one two three four five six seven eight nine ten"
        await coordinator.onPartial(tenWords)

        // Advance 5 more seconds — deadline (3 s) triggers, draining all 10 words.
        // emittedWordCount is now 10.
        await coordinator.feedSilence(seconds: 5)

        // Feed a 3-word delta — far shorter than the 10 emitted words.
        // The guard must reject it; the tail should remain unchanged (empty now, since
        // all pending was drained) and pending should not be corrupted.
        let tailBeforeDelta = tails.last ?? ""
        await coordinator.onFinalText("just three words")
        let tailAfterDelta = tails.last ?? ""

        // The tail must not change — the delta is a no-op once the guard fires.
        XCTAssertEqual(tailAfterDelta, tailBeforeDelta,
            "Short delta changed the tail after it should have been rejected by the guard. " +
            "words.count(3) < emittedWordCount(10) must return early. " +
            "Tail before: '\(tailBeforeDelta)', after: '\(tailAfterDelta)'")
    }

    // MARK: 3. Accumulated transcripts grow monotonically (baseline)

    /// The normal Nemotron path — each partial is a superset of the previous — must
    /// grow the tail monotonically. This is the behaviour the fix must not regress.
    func testAccumulatedTranscriptGrowsMonotonically() async throws {
        let coordinator = MeetingSpeakerCoordinator()

        var tails: [String] = []
        await coordinator.setCallbacks(
            onAttributed: { _, _, _, _ in },
            onPendingTail: { tails.append($0) },
            onLiveSpeaker: { _ in }
        )

        await coordinator.feedSilence(seconds: 5)

        let partials = [
            "hello",
            "hello world",
            "hello world this is a test",
            "hello world this is a test of the live transcript"
        ]

        for partial in partials {
            await coordinator.onPartial(partial)
        }

        var lastCount = 0
        for tail in tails {
            let count = tail.split(separator: " ").count
            XCTAssertGreaterThanOrEqual(count, lastCount,
                "Tail shrank from \(lastCount) to \(count) words — rewrite path misfired.")
            lastCount = count
        }
        XCTAssertGreaterThan(lastCount, 0, "No words in tail after partials")
    }

    // MARK: 4. Nemotron tail rewrite trims (not destroys) pending (baseline)

    /// When Nemotron revises its tail (not a delta from another decoder but a genuine
    /// re-decode), the pending queue should only drop words beyond the LCP — words before
    /// the LCP survive unaffected.
    func testNemotronTailRewritePreservesLCPWords() async throws {
        let coordinator = MeetingSpeakerCoordinator()

        var tails: [String] = []
        await coordinator.setCallbacks(
            onAttributed: { _, _, _, _ in },
            onPendingTail: { tails.append($0) },
            onLiveSpeaker: { _ in }
        )

        await coordinator.feedSilence(seconds: 5)

        // Partial 1: 6 words.
        await coordinator.onPartial("one two three four five six")
        // Nemotron rewrites: keeps first 3, replaces last 3 with 2 different words.
        await coordinator.onPartial("one two three alpha beta")

        let finalTail = tails.last ?? ""
        XCTAssertTrue(finalTail.contains("one") && finalTail.contains("two") && finalTail.contains("three"),
            "LCP words (one two three) were dropped by the tail-rewrite path. Tail: '\(finalTail)'")
        XCTAssertFalse(finalTail.contains("four") || finalTail.contains("five") || finalTail.contains("six"),
            "Dropped words survived the rewrite. Tail: '\(finalTail)'")
    }
}

#endif // canImport(FluidAudio)
