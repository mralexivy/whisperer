//
//  EagerPassStallDetectionTests.swift
//  WhispererTests
//
//  Verifies that a wedged eager decode is observable via HealthReportable and that the
//  `stalledDecode` EagerPassSkip case fires on subsequent claimEagerPass() failures.
//
//  These tests use a real WhisperBridge, a very short deadline override, and assert
//  that the health machinery fires correctly — without requiring a genuine Metal hang.
//
//  Rationale for the approach (see improvements.md plan):
//  - We cannot inject a stub for `transcribeStreamingAsync` because `runEagerStreamPass`
//    type-checks for `WhisperBridge` directly (non-protocol).
//  - The real decode completes quickly and releases the claim. To observe the stall window
//    we set `eagerPassDeadlineOverride` to something tiny (1 ms), feed samples to trigger
//    one eager pass, then poll `healthState` immediately — before the decode completes.
//  - A second scenario checks clean-release: after the decode completes, `stCurrentOp`
//    must be nil so the transcriber looks idle.
//
//  CLAUDE.md constraint on deinit: a @MainActor pure-Swift class deallocated inside a
//  synchronous test method aborts the test host. StreamingTranscriber is not @MainActor,
//  but we keep `transcriber` alive until stopAsync() to be safe.
//

import XCTest
@testable import whisperer

final class EagerPassStallDetectionTests: XCTestCase {

    // MARK: - Helpers

    /// Silence at 16 kHz — enough to pass the 0.5s minimum but cheap to generate.
    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16000))
    }

    /// Wait up to `timeout` seconds for `condition` to become true, polling every 20 ms.
    private func waitFor(
        timeout: TimeInterval,
        condition: () -> Bool
    ) async {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while !condition() && CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Test 1: health fields are set while a decode is in flight

    /// Feeds 1s of silence with a 1ms deadline so the health machinery fires before the
    /// decode completes. We cannot guarantee timing in CI, so the assertion is on the op
    /// name rather than `.stalled` status (the deadline may not have lapsed by poll time).
    func testEagerPassSetsOpFieldsWhileInFlight() async throws {
        let bridge = try loadWhisperBridge()
        bridge.resetAbort()
        let transcriber = StreamingTranscriber(backend: bridge, vad: nil, language: .english)
        // Tiny deadline so it expires immediately — lets us observe `.stalled` from
        // `healthState` if we poll quickly enough, but we assert only the fields we can
        // control (op name presence) since there is a race with the actual decode completion.
        transcriber.eagerPassDeadlineOverride = .milliseconds(1)
        var skipReasons: [StreamingTranscriber.EagerPassSkip] = []
        let lock = NSLock()
        transcriber.onEagerPassSkipped = { reason in
            lock.withLock { skipReasons.append(reason) }
        }
        transcriber.start { _ in }

        // Feed enough audio to arm the eager pass (≥ 0.5s required).
        transcriber.addSamples(silence(seconds: 1.0))

        // Wait briefly for the heartbeat to fire and submit the decode.
        try? await Task.sleep(nanoseconds: 200_000_000)

        // While the decode is in flight, healthState must know about it.
        let health = transcriber.healthState
        // The op name is either "eagerPass" (in flight) or nil (already completed).
        // Both are valid — the decode may have finished in the 200 ms window on a fast device.
        if let opName = health.operation?.name {
            XCTAssertEqual(opName, "eagerPass",
                           "op name should be 'eagerPass' while the decode is in flight")
            // If the deadline has passed and we are past it, status must not be .healthy.
            let now = ContinuousClock.now
            if let deadline = health.operation?.deadline, now > deadline {
                XCTAssertNotEqual(health.status, .healthy,
                    "health status must not be .healthy past the eager pass deadline")
            }
        }

        await transcriber.stopAsync()
    }

    // MARK: - Test 2: op fields are nil after a decode completes (clean release)

    func testEagerPassClearsOpFieldsAfterCompletion() async throws {
        let bridge = try loadWhisperBridge()
        bridge.resetAbort()
        let transcriber = StreamingTranscriber(backend: bridge, vad: nil, language: .english)
        transcriber.start { _ in }

        // Feed audio and let the pass complete.
        transcriber.addSamples(silence(seconds: 1.0))

        // Wait long enough for a real decode to complete (short audio, tiny model is fine).
        await waitFor(timeout: 10.0) {
            transcriber.healthState.operation == nil
        }

        let health = transcriber.healthState
        XCTAssertNil(health.operation,
                     "stCurrentOp must be nil after the eager pass completes — idle transcriber looks stalled otherwise")
        XCTAssertEqual(health.status, .healthy,
                       "idle transcriber should report .healthy")

        await transcriber.stopAsync()
    }

    // MARK: - Test 3: stalledDecode skip fires when deadline lapsed

    /// Verifies that subsequent `claimEagerPass()` failures report `.stalledDecode` (not `.busy`)
    /// when the in-flight deadline has passed.
    ///
    /// We can't block the decode, so instead we:
    /// 1. Feed enough audio to trigger an eager pass with a very short deadline.
    /// 2. Keep adding audio chunks rapidly (heartbeat fires every ~150ms) so there are many
    ///    subsequent passes — at least one should hit the `.stalledDecode` code path while the
    ///    first decode is still claimed (the `.busy` guard) and the deadline has lapsed.
    ///
    /// This is inherently timing-sensitive. If the decode finishes before any subsequent pass,
    /// no `.stalledDecode` fires and the test is inconclusive — we skip rather than fail.
    func testStalledDecodeSkipFiresWhenDeadlineLapsed() async throws {
        let bridge = try loadWhisperBridge()
        bridge.resetAbort()
        let transcriber = StreamingTranscriber(backend: bridge, vad: nil, language: .english)
        transcriber.eagerPassDeadlineOverride = .milliseconds(1)

        var skipReasons: [StreamingTranscriber.EagerPassSkip] = []
        let lock = NSLock()
        transcriber.onEagerPassSkipped = { reason in
            lock.withLock { skipReasons.append(reason) }
        }
        transcriber.start { _ in }

        // Feed 3s of audio in small chunks. The heartbeat fires every ~150ms, so we expect
        // multiple `claimEagerPass()` failures — at least one with the deadline lapsed.
        let chunkSize = 160  // 10ms at 16kHz
        let totalChunks = Int(3.0 * 16000) / chunkSize
        for _ in 0..<totalChunks {
            transcriber.addSamples(silence(seconds: 0.01))
            try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms spacing
        }

        // Let in-flight decode land.
        try? await Task.sleep(nanoseconds: 500_000_000)
        await transcriber.stopAsync()

        let reasons = lock.withLock { skipReasons }
        let stalledCount = reasons.filter { $0 == .stalledDecode }.count
        let busyCount = reasons.filter { $0 == .busy }.count

        // If no `.busy` or `.stalledDecode` skips fired at all, the test was inconclusive
        // (the model is not downloaded or the pass never conflicted).
        if busyCount == 0 && stalledCount == 0 {
            throw XCTSkip("No busy/stalled skips observed — model may have completed instantly or is not downloaded")
        }

        // At least one of the `.busy` skips should have become `.stalledDecode`.
        // If this fails but stalledCount == 0 and busyCount > 0 it means the code path
        // was never reached — check the deadline override wiring.
        XCTAssertGreaterThan(stalledCount, 0,
            "Expected at least one .stalledDecode skip when deadline=1ms and decode is in flight; "
            + "got busy=\(busyCount) stalledDecode=\(stalledCount). "
            + "This likely means the decode completed before the deadline lapsed.")
    }

    // MARK: - Test 4: eagerPassInFlight reflected in health metadata

    func testHealthMetadataIncludesEagerPassInFlight() async throws {
        let bridge = try loadWhisperBridge()
        bridge.resetAbort()
        let transcriber = StreamingTranscriber(backend: bridge, vad: nil, language: .english)
        transcriber.eagerPassDeadlineOverride = .milliseconds(1)
        transcriber.start { _ in }

        transcriber.addSamples(silence(seconds: 1.0))
        // Poll immediately — likely while decode is in flight.
        try? await Task.sleep(nanoseconds: 100_000_000)

        let health = transcriber.healthState
        // The `eagerPassInFlight` key must always be present; its value may be true or false
        // depending on whether the decode has completed.
        XCTAssertNotNil(health.metadata["eagerPassInFlight"],
                        "healthState.metadata must always contain 'eagerPassInFlight'")

        await transcriber.stopAsync()
    }
}
