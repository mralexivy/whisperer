//
//  AudioRecoveryPolicyTests.swift
//  WhispererTests
//
//  Pins the retry budget that lost the 2026-09-14 meeting.
//
//  Before the fix `maxRecoveryAttempts` was a flat `3` shared by a two-second push-to-talk
//  dictation and a 58-minute meeting. The meeting got ~7 seconds of recovery and then a
//  permanent surrender, with no further attempt for the remaining 68 minutes. These tests
//  assert the two session kinds now have genuinely different leashes.
//

import XCTest
@testable import whisperer

final class AudioRecoveryPolicyTests: XCTestCase {

    private typealias Policy = AudioRecorder.RecoveryPolicy

    // MARK: - Attempt budget

    func testDictationKeepsTheShortLeash() {
        // Push-to-talk: the user is holding a key and can release and retry in a second, so a
        // long silent retry loop is worse than failing fast.
        XCTAssertEqual(Policy.dictation.maxAttempts, 3)
    }

    func testLongFormRetriesWithoutABudget() {
        // The single most important assertion in this file. A meeting must keep trying for as
        // long as it is open — coreaudiod restarts, devices come back, sleep/wake resolves.
        XCTAssertNil(Policy.longForm.maxAttempts,
                     "a meeting must never permanently surrender while the session is open")
    }

    // MARK: - Backoff

    func testDictationBackoffStaysFlatAndFast() {
        for attempt in 1...5 {
            XCTAssertEqual(Policy.dictation.settleDelay(attempt: attempt), 0.3, accuracy: 0.0001,
                           "dictation must not back off — the user is waiting")
        }
    }

    func testLongFormBacksOffExponentially() {
        XCTAssertEqual(Policy.longForm.settleDelay(attempt: 1), 0.3, accuracy: 0.0001)
        XCTAssertEqual(Policy.longForm.settleDelay(attempt: 2), 0.6, accuracy: 0.0001)
        XCTAssertEqual(Policy.longForm.settleDelay(attempt: 3), 1.2, accuracy: 0.0001)
        XCTAssertEqual(Policy.longForm.settleDelay(attempt: 4), 2.4, accuracy: 0.0001)
    }

    func testLongFormBackoffIsCapped() {
        // Unbounded attempts only stay sane because the delay stops growing. An hour-long
        // outage should cost a few hundred rebuilds, not a doubling that reaches days.
        for attempt in 10...200 {
            XCTAssertEqual(Policy.longForm.settleDelay(attempt: attempt), 10.0, accuracy: 0.0001)
        }
    }

    func testBackoffIsMonotonicAndNeverNegative() {
        var previous = 0.0
        for attempt in 1...20 {
            let delay = Policy.longForm.settleDelay(attempt: attempt)
            XCTAssertGreaterThan(delay, 0)
            XCTAssertGreaterThanOrEqual(delay, previous)
            previous = delay
        }
    }

    /// `recoverAudioEngine` computes the delay from a counter; a zero or negative attempt index
    /// arriving from a reset race must not produce a nonsensical delay.
    func testDegenerateAttemptIndicesAreClamped() {
        XCTAssertEqual(Policy.longForm.settleDelay(attempt: 0), 0.3, accuracy: 0.0001)
        XCTAssertEqual(Policy.longForm.settleDelay(attempt: -5), 0.3, accuracy: 0.0001)
    }

    // MARK: - Cumulative behaviour

    /// The concrete regression: with the old flat budget, the recorder gave up 7 seconds into a
    /// 58-minute meeting. Long-form must still be trying well past that point.
    func testLongFormIsStillRetryingLongAfterDictationWouldHaveGivenUp() {
        let dictationBudget = Policy.dictation.maxAttempts ?? 0
        var elapsed = 0.0
        for attempt in 1...dictationBudget {
            elapsed += Policy.dictation.settleDelay(attempt: attempt)
        }
        XCTAssertLessThan(elapsed, 2.0, "dictation surrenders in under two seconds, by design")

        // Long-form at the same point has an unbounded budget and is only ~2 s in.
        XCTAssertNil(Policy.longForm.maxAttempts)

        // And after an hour of retrying at the capped delay it is still going.
        var longFormElapsed = 0.0
        var attempt = 1
        while longFormElapsed < 3600 {
            longFormElapsed += Policy.longForm.settleDelay(attempt: attempt)
            attempt += 1
        }
        XCTAssertGreaterThan(attempt, 300, "an hour of outage should be hundreds of attempts")
        XCTAssertLessThan(attempt, 1000, "…but not thousands — the cap must be doing its job")
    }
}
