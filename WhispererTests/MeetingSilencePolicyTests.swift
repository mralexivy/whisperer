//
//  MeetingSilencePolicyTests.swift
//  WhispererTests
//

import XCTest
@testable import whisperer

final class MeetingSilencePolicyTests: XCTestCase {

    // MARK: - Stage transitions

    func testHiddenBeforeWarnThreshold() {
        XCTAssertEqual(
            MeetingSilencePolicy.stage(elapsed: 5.9, speechDetected: false, dismissed: false),
            .hidden
        )
    }

    func testWarningAtWarnThreshold() {
        XCTAssertEqual(
            MeetingSilencePolicy.stage(elapsed: MeetingSilencePolicy.warnAfter, speechDetected: false, dismissed: false),
            .warning
        )
    }

    func testWarningBetweenThresholds() {
        XCTAssertEqual(
            MeetingSilencePolicy.stage(elapsed: 9.0, speechDetected: false, dismissed: false),
            .warning
        )
    }

    func testConfidentJustBeforeThreshold() {
        XCTAssertEqual(
            MeetingSilencePolicy.stage(elapsed: 11.9, speechDetected: false, dismissed: false),
            .warning
        )
    }

    func testConfidentAtThreshold() {
        XCTAssertEqual(
            MeetingSilencePolicy.stage(elapsed: MeetingSilencePolicy.confidentAfter, speechDetected: false, dismissed: false),
            .confident
        )
    }

    func testConfidentAboveThreshold() {
        XCTAssertEqual(
            MeetingSilencePolicy.stage(elapsed: 60.0, speechDetected: false, dismissed: false),
            .confident
        )
    }

    // MARK: - Speech latch

    func testSpeechDetectedForcesHidden() {
        XCTAssertEqual(
            MeetingSilencePolicy.stage(elapsed: 30.0, speechDetected: true, dismissed: false),
            .hidden
        )
    }

    func testSpeechDetectedForcesHiddenEvenWhenDismissed() {
        XCTAssertEqual(
            MeetingSilencePolicy.stage(elapsed: 30.0, speechDetected: true, dismissed: true),
            .hidden
        )
    }

    // MARK: - Dismiss

    func testDismissedForcesHidden() {
        XCTAssertEqual(
            MeetingSilencePolicy.stage(elapsed: 30.0, speechDetected: false, dismissed: true),
            .hidden
        )
    }

    // MARK: - Progress

    func testProgressZeroBeforeWarnThreshold() {
        XCTAssertEqual(MeetingSilencePolicy.progress(elapsed: 5.0), 0.0, accuracy: 0.001)
    }

    func testProgressZeroAtWarnThreshold() {
        XCTAssertEqual(MeetingSilencePolicy.progress(elapsed: MeetingSilencePolicy.warnAfter), 0.0, accuracy: 0.001)
    }

    func testProgressHalfway() {
        let midpoint = (MeetingSilencePolicy.warnAfter + MeetingSilencePolicy.confidentAfter) / 2
        XCTAssertEqual(MeetingSilencePolicy.progress(elapsed: midpoint), 0.5, accuracy: 0.001)
    }

    func testProgressOneAtConfidentThreshold() {
        XCTAssertEqual(MeetingSilencePolicy.progress(elapsed: MeetingSilencePolicy.confidentAfter), 1.0, accuracy: 0.001)
    }

    func testProgressClampedAboveOne() {
        XCTAssertEqual(MeetingSilencePolicy.progress(elapsed: 999.0), 1.0, accuracy: 0.001)
    }

    // MARK: - shouldDiscard truth table

    func testDiscardAllConditionsMet() {
        XCTAssertTrue(MeetingSilencePolicy.shouldDiscard(
            elapsed: 5.0,
            hasTranscript: false,
            hasNotes: false,
            speechDetected: false
        ))
    }

    func testNoDiscardWhenTranscriptExists() {
        XCTAssertFalse(MeetingSilencePolicy.shouldDiscard(
            elapsed: 5.0,
            hasTranscript: true,
            hasNotes: false,
            speechDetected: false
        ))
    }

    func testNoDiscardWhenNotesExist() {
        XCTAssertFalse(MeetingSilencePolicy.shouldDiscard(
            elapsed: 5.0,
            hasTranscript: false,
            hasNotes: true,
            speechDetected: false
        ))
    }

    func testNoDiscardWhenSpeechDetected() {
        XCTAssertFalse(MeetingSilencePolicy.shouldDiscard(
            elapsed: 5.0,
            hasTranscript: false,
            hasNotes: false,
            speechDetected: true
        ))
    }

    func testNoDiscardWhenElapsedAtOrAboveCeiling() {
        XCTAssertFalse(MeetingSilencePolicy.shouldDiscard(
            elapsed: MeetingSilencePolicy.discardUnder,
            hasTranscript: false,
            hasNotes: false,
            speechDetected: false
        ))
    }

    func testNoDiscardWhenElapsedWellAboveCeiling() {
        XCTAssertFalse(MeetingSilencePolicy.shouldDiscard(
            elapsed: 60.0,
            hasTranscript: false,
            hasNotes: false,
            speechDetected: false
        ))
    }

    func testDiscardJustBelowCeiling() {
        XCTAssertTrue(MeetingSilencePolicy.shouldDiscard(
            elapsed: MeetingSilencePolicy.discardUnder - 0.1,
            hasTranscript: false,
            hasNotes: false,
            speechDetected: false
        ))
    }
}
