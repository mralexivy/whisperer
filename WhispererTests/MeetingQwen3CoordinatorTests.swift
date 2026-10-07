//
//  MeetingQwen3CoordinatorTests.swift
//  WhispererTests
//
//  End-to-end for the Qwen3 meeting feed, without any models.
//
//  The 2026-09-07 Hebrew bug came from routing the wrong callback into
//  `MeetingSpeakerCoordinator`: whisper's per-commit deltas hit a diff that requires the full
//  accumulated transcript, and the pending queue was destroyed ~148 times in one session.
//  Qwen3 reintroduces exactly that hazard — its preview tail is window-local and its chunk
//  callback is a delta — so these tests pin the route chosen for it:
//
//      StreamingTranscriber.onTranscription → MeetingTranscriptAccumulator → coordinator.onPartial
//
//  `MeetingSpeakerCoordinatorDeltaRegressionTests` covers the coordinator's own defences.
//  This file covers the wiring: which feed each backend gets, and that the accumulator in
//  front of the coordinator makes a hostile stream safe.
//

import XCTest
@testable import whisperer

#if canImport(FluidAudio)
import FluidAudio

final class MeetingQwen3CoordinatorTests: XCTestCase {

    // MARK: - Feed selection

    /// Qwen3 must take the transcriber's accumulated string. Picking `.accumulatedPartials`
    /// would hand the coordinator a window-local tail that shrinks on every chunk commit.
    func testQwen3UsesTheTranscriberAccumulatedFeed() {
        XCTAssertEqual(
            MeetingCoordinatorFeed(inAppBackend: .qwen3asr, previewOwnsNemotron: false),
            .transcriberAccumulated)
        // Independent of Nemotron's presence — Qwen3 never reads Nemotron's callbacks.
        XCTAssertEqual(
            MeetingCoordinatorFeed(inAppBackend: .qwen3asr, previewOwnsNemotron: true),
            .transcriberAccumulated)
    }

    /// The pre-existing paths must be byte-for-byte the same decision as before the change.
    func testNemotronPathsAreUnchanged() {
        XCTAssertEqual(
            MeetingCoordinatorFeed(inAppBackend: .nemotron, previewOwnsNemotron: false),
            .accumulatedFinal)
        XCTAssertEqual(
            MeetingCoordinatorFeed(inAppBackend: .nemotronHebrew, previewOwnsNemotron: false),
            .accumulatedFinal)
        XCTAssertEqual(
            MeetingCoordinatorFeed(inAppBackend: .whisperCpp, previewOwnsNemotron: true),
            .accumulatedPartials)
    }

    /// whisper.cpp alone has no accumulated source at all. Returning a feed here is what would
    /// send its deltas to the coordinator — the original bug.
    func testWhisperWithoutNemotronHasNoFeed() {
        XCTAssertNil(MeetingCoordinatorFeed(inAppBackend: .whisperCpp, previewOwnsNemotron: false))
    }

    func testBackendsThatCannotDriveAttributionGetNoFeed() {
        for backend in [BackendType.parakeet, .whisperKit, .speechAnalyzer] {
            XCTAssertNil(MeetingCoordinatorFeed(inAppBackend: backend, previewOwnsNemotron: false),
                         "\(backend.rawValue) has no accumulated source")
            XCTAssertNil(MeetingCoordinatorFeed(inAppBackend: backend, previewOwnsNemotron: true),
                         "a resident Nemotron preview does not change \(backend.rawValue)'s own output")
        }
    }

    // MARK: - The accumulator in front of the coordinator

    /// The integration the wiring depends on: replaying a realistic Qwen3 `onTranscription`
    /// stream — which grows, retracts when a chunk commits, then grows again — through the
    /// accumulator must never make the coordinator reject input as a delta.
    ///
    /// `ingestAccumulated` logs an error and drops the pending queue on rejection, and the
    /// visible symptom is a blanked live tail. So the assertion is on the tail: it must never
    /// go from non-empty back to empty.
    func testHostileQwen3StreamNeverBlanksTheTail() async throws {
        let coordinator = MeetingSpeakerCoordinator()

        final class Box: @unchecked Sendable {
            var tails: [String] = []
            var attributed: [String] = []
        }
        let box = Box()
        await coordinator.setCallbacks(
            onAttributed: { text, _, _, _ in box.attributed.append(text) },
            onPendingTail: { box.tails.append($0) },
            onLiveSpeaker: { _ in }
        )

        // A real shape: the preview tail extends the committed text, then a chunk commits and
        // the next `onTranscription` arrives before the following preview pass — momentarily
        // shorter. Without the accumulator, that snapshot reaches the coordinator as a delta.
        let stream = [
            "the algorithm",
            "the algorithm proposed",
            "the algorithm proposed the solver",
            "the algorithm proposed",                                   // retraction
            "the algorithm proposed the solver keeps",
            "the algorithm proposed the solver keeps failing",
            "the solver keeps failing",                                 // divergent window
            "the algorithm proposed the solver keeps failing us",
        ]

        var accumulator = MeetingTranscriptAccumulator()
        for snapshot in stream {
            guard let accumulated = accumulator.accept(snapshot) else { continue }
            await coordinator.onPartial(accumulated)
        }

        XCTAssertEqual(accumulator.published, "the algorithm proposed the solver keeps failing us")
        XCTAssertEqual(accumulator.rejectedCount, 2, "one retraction and one divergence")

        var sawText = false
        for tail in box.tails {
            if !tail.isEmpty { sawText = true; continue }
            XCTAssertFalse(sawText, "the live tail blanked after showing text — the 2026-09-07 bug")
        }
    }

    /// The negative control. Feeding the same stream straight to the coordinator — no
    /// accumulator — must trip its delta guard, proving the guard in front of it is load-bearing
    /// rather than decorative.
    func testRawStreamWithoutTheAccumulatorIsRejected() async throws {
        let coordinator = MeetingSpeakerCoordinator()
        await coordinator.setCallbacks(
            onAttributed: { _, _, _, _ in },
            onPendingTail: { _ in },
            onLiveSpeaker: { _ in }
        )

        // Push enough audio that the age deadline attributes the early words, so
        // `emittedWordCount` is above zero and a shrink can actually be detected as one.
        await coordinator.onPartial("one two three four five six")
        await coordinator.feed([Float](repeating: 0, count: 16_000 * 5))

        let emittedBefore = await coordinator.emittedWordCountForTesting
        XCTAssertGreaterThan(emittedBefore, 0,
                             "the guard only engages once words have been attributed")

        await coordinator.onPartial("one two")   // the shrink the accumulator would have dropped
        let emittedAfter = await coordinator.emittedWordCountForTesting
        XCTAssertEqual(emittedAfter, emittedBefore,
                       "a delta must not advance attribution — it is rejected outright")
    }
}
#endif
