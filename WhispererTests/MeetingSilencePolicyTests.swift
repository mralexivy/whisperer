//
//  MeetingSilencePolicyTests.swift
//  WhispererTests
//
//  Silent-meeting handling: "started by mistake" counts down to a discard, "went quiet" never
//  does. Pure — the tracker is a value type driven on a fake session clock.
//

import XCTest
@testable import whisperer

final class MeetingSilencePolicyTests: XCTestCase {

    private typealias T = MeetingQuietTracker

    /// Advances `tracker` one second at a time to `end`, like the watcher's 1 Hz tick.
    private func run(_ tracker: inout T, from start: Double = 1, to end: Double, paused: Bool = false) {
        var t = start
        while t <= end {
            tracker.update(elapsed: t, capturePaused: paused)
            t += 1
        }
    }

    // MARK: - Started by mistake

    func testNothingShownBeforeFifteenSeconds() {
        var tracker = T()
        run(&tracker, to: T.mistakePromptAfter - 1)
        XCTAssertEqual(tracker.prompt, .none)
    }

    func testEmptyMeetingCountsDownThirtySecondsThenDiscards() {
        var tracker = T()
        run(&tracker, to: T.mistakePromptAfter)
        XCTAssertEqual(tracker.prompt, .startedByMistake(secondsLeft: 30, micSilent: true))
        XCTAssertFalse(tracker.autoDiscardDue)

        run(&tracker, from: T.mistakePromptAfter + 1, to: T.mistakePromptAfter + 29)
        XCTAssertEqual(tracker.prompt, .startedByMistake(secondsLeft: 1, micSilent: true))
        XCTAssertFalse(tracker.autoDiscardDue, "never before the countdown ends")

        tracker.update(elapsed: T.mistakePromptAfter + 30, capturePaused: false)
        XCTAssertTrue(tracker.autoDiscardDue)
        XCTAssertGreaterThanOrEqual(T.mistakePromptAfter + T.discardCountdown, 40,
                                    "at least 40 s from Start before anything is discarded")
    }

    /// The old card latched off for good on the first noise and vanished before anyone read it.
    func testANoiseRestartsTheCountdownButNeverHidesTheCard() {
        var tracker = T()
        run(&tracker, to: 30)
        guard case .startedByMistake(let before, _) = tracker.prompt else { return XCTFail("card should show") }
        tracker.noteVoice(at: 30)
        tracker.update(elapsed: 31, capturePaused: false)
        guard case .startedByMistake(let after, _) = tracker.prompt else {
            return XCTFail("a cough must not make the card disappear")
        }
        XCTAssertGreaterThan(after, before, "the countdown starts over")
        XCTAssertEqual(after, 29)
    }

    func testWordsEndTheQuestionForGood() {
        var tracker = T()
        run(&tracker, to: 20)
        tracker.noteContent(at: 20)
        run(&tracker, from: 21, to: 200)
        XCTAssertEqual(tracker.prompt, .none)
        XCTAssertFalse(tracker.autoDiscardDue, "a meeting with words is never discarded")
    }

    func testKeepStopsTheCountdownForTheSession() {
        var tracker = T()
        run(&tracker, to: 25)
        tracker.keep()
        run(&tracker, from: 26, to: 600)
        XCTAssertEqual(tracker.prompt, .none)
        XCTAssertFalse(tracker.autoDiscardDue)
    }

    func testMicThatProducesSoundIsNotCalledSilent() {
        var tracker = T()
        tracker.noteAudioSignal()
        run(&tracker, to: T.mistakePromptAfter)
        XCTAssertEqual(tracker.prompt, .startedByMistake(secondsLeft: 30, micSilent: false))
    }

    /// Paused, muted or dictating on top: silence is not evidence, and the clock restarts.
    func testPausedCaptureNeverCountsDown() {
        var tracker = T()
        run(&tracker, to: 40)
        XCTAssertNotEqual(tracker.prompt, .none)
        run(&tracker, from: 41, to: 200, paused: true)
        XCTAssertEqual(tracker.prompt, .none)
        XCTAssertFalse(tracker.autoDiscardDue)
        // Resumed: a fresh 15 s before asking again.
        run(&tracker, from: 201, to: 201 + T.mistakePromptAfter - 2)
        XCTAssertEqual(tracker.prompt, .none)
    }

    // MARK: - Went quiet mid-meeting

    func testRealMeetingThatGoesQuietIsAskedNotDiscarded() {
        var tracker = T()
        tracker.noteContent(at: 10)
        run(&tracker, from: 11, to: 10 + T.quietPromptAfter)
        XCTAssertEqual(tracker.prompt, .wentQuiet(minutes: 5))
        run(&tracker, from: 11 + T.quietPromptAfter, to: 4000)
        XCTAssertFalse(tracker.autoDiscardDue, "content is never discarded, however long the silence")
        if case .wentQuiet = tracker.prompt {} else { XCTFail("still asking, not acting") }
    }

    func testKeepGoingAsksAgainTenMinutesLater() {
        var tracker = T()
        tracker.noteContent(at: 0)
        run(&tracker, to: T.quietPromptAfter)
        tracker.snoozeQuiet(at: T.quietPromptAfter)
        run(&tracker, from: T.quietPromptAfter + 1, to: T.quietPromptAfter + T.quietSnooze - 1)
        XCTAssertEqual(tracker.prompt, .none)
        tracker.update(elapsed: T.quietPromptAfter + T.quietSnooze, capturePaused: false)
        if case .wentQuiet = tracker.prompt {} else { XCTFail("asks again after the snooze") }
    }

    func testTalkingAgainClearsTheQuietCard() {
        var tracker = T()
        tracker.noteContent(at: 0)
        run(&tracker, to: T.quietPromptAfter + 5)
        tracker.noteContent(at: T.quietPromptAfter + 5)
        XCTAssertEqual(tracker.prompt, .none)
    }

    // MARK: - Stop-time discard rule

    func testShortSilentMeetingIsDiscardedAtStop() {
        XCTAssertTrue(MeetingSilencePolicy.shouldDiscard(elapsed: 5, hasTranscript: false,
                                                         hasNotes: false, speechDetected: false))
        XCTAssertFalse(MeetingSilencePolicy.shouldDiscard(elapsed: MeetingSilencePolicy.discardUnder,
                                                          hasTranscript: false, hasNotes: false,
                                                          speechDetected: false))
        XCTAssertFalse(MeetingSilencePolicy.shouldDiscard(elapsed: 5, hasTranscript: false,
                                                          hasNotes: false, speechDetected: true))
    }

    /// A requested discard (countdown ran out / Discard pressed) lifts the length and noise
    /// conditions — but a word or a note that arrived with the tail still keeps the meeting.
    func testRequestedDiscardNeverDeletesContent() {
        XCTAssertTrue(MeetingSilencePolicy.shouldDiscard(elapsed: 45, hasTranscript: false, hasNotes: false,
                                                         speechDetected: true, requested: true))
        XCTAssertFalse(MeetingSilencePolicy.shouldDiscard(elapsed: 45, hasTranscript: true, hasNotes: false,
                                                          speechDetected: true, requested: true))
        XCTAssertFalse(MeetingSilencePolicy.shouldDiscard(elapsed: 45, hasTranscript: false, hasNotes: true,
                                                          speechDetected: false, requested: true))
    }
}
