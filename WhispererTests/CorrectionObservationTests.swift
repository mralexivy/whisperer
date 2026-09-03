//
//  CorrectionObservationTests.swift
//  WhispererTests
//
//  Pure logic tests for the post-paste observation helpers.
//
//  Everything here is value-type and synchronous — no AX, no sleeps, no model loading,
//  no dictionary store. The polling loop itself is deliberately not tested (it requires a live
//  AX target and real Task.sleep, which would be slow and flaky).
//

import XCTest
@testable import whisperer

final class CorrectionObservationAnchorByLocationTests: XCTestCase {

    // MARK: - init?(fieldValue:locating:)

    func testFindsUniqueOccurrenceInMiddle() {
        // "Hello [world] foo" — paste landed in the middle.
        let anchor = CorrectionLearningAnchor(fieldValue: "Hello world foo", locating: "world")
        XCTAssertNotNil(anchor)
        XCTAssertEqual(anchor?.prefix, "Hello ")
        XCTAssertEqual(anchor?.suffix, " foo")
    }

    func testReturnedAnchorTracksCorrectly() {
        // Confirm region(in:) works after anchor-by-location.
        let anchor = CorrectionLearningAnchor(fieldValue: "Hello world foo", locating: "world")!
        // Unchanged field
        XCTAssertEqual(anchor.region(in: "Hello world foo"), "world")
        // User changed "world" to "earth"
        XCTAssertEqual(anchor.region(in: "Hello earth foo"), "earth")
        // User changed something outside the pasted region → anchor broken
        XCTAssertNil(anchor.region(in: "Hi earth foo"))
    }

    func testReturnsNilWhenTargetAbsent() {
        // Paste silently failed — "world" not in field.
        XCTAssertNil(CorrectionLearningAnchor(fieldValue: "Hello foo", locating: "world"))
    }

    func testReturnsNilWhenTargetAppearsMoreThanOnce() {
        // "world" occurs twice → ambiguous attribution.
        XCTAssertNil(CorrectionLearningAnchor(fieldValue: "world and world", locating: "world"))
    }

    func testEmptyTargetReturnsNil() {
        XCTAssertNil(CorrectionLearningAnchor(fieldValue: "hello", locating: ""))
    }

    func testTargetAtStart() {
        let anchor = CorrectionLearningAnchor(fieldValue: "world foo", locating: "world")
        XCTAssertNotNil(anchor)
        XCTAssertEqual(anchor?.prefix, "")
        XCTAssertEqual(anchor?.suffix, " foo")
    }

    func testTargetAtEnd() {
        let anchor = CorrectionLearningAnchor(fieldValue: "foo world", locating: "world")
        XCTAssertNotNil(anchor)
        XCTAssertEqual(anchor?.prefix, "foo ")
        XCTAssertEqual(anchor?.suffix, "")
    }

    func testEntireFieldIsTarget() {
        let anchor = CorrectionLearningAnchor(fieldValue: "world", locating: "world")
        XCTAssertNotNil(anchor)
        XCTAssertEqual(anchor?.prefix, "")
        XCTAssertEqual(anchor?.suffix, "")
    }
}

final class CorrectionObservationDivergenceTests: XCTestCase {

    // MARK: - divergence(original:edited:)

    func testDivergenceTableDriven() {
        struct Case { let original, edited: String; let maxExpected: Double }
        let cases: [Case] = [
            // Identical → 0
            .init(original: "Hello world", edited: "Hello world", maxExpected: 0.001),
            // Single-word substitution (1 of 2 tokens changed)
            .init(original: "Hello Glyn", edited: "Hello Glean", maxExpected: 0.55),
            // Single substitution in a 10-word sentence: should be well under 0.35
            .init(original: "we can glyn a lot from these numbers today", edited: "we can Glean a lot from these numbers today", maxExpected: 0.20),
            // Complete rewrite → near 1.0
            .init(original: "alpha beta gamma", edited: "one two three", maxExpected: 1.001),
        ]

        for c in cases {
            let d = CorrectionLearningCandidateExtractor.divergence(original: c.original, edited: c.edited)
            XCTAssertLessThanOrEqual(d, c.maxExpected,
                "divergence('\(c.original)', '\(c.edited)') = \(d), expected ≤ \(c.maxExpected)")
            XCTAssertGreaterThanOrEqual(d, 0, "divergence must be non-negative")
        }
    }

    func testSingleSubstitutionInLongSentenceIsBelowThreshold() {
        let original = "we can glyn a lot from these numbers today and tomorrow"
        let edited   = "we can Glean a lot from these numbers today and tomorrow"
        let d = CorrectionLearningCandidateExtractor.divergence(original: original, edited: edited)
        XCTAssertLessThan(d, TextInjector.correctionDivergenceThreshold,
            "A single-word correction should not exceed the bail-out threshold; got \(d)")
    }

    func testFullRewriteExceedsThreshold() {
        let original = "alpha beta gamma delta epsilon"
        let edited   = "completely different words here now"
        let d = CorrectionLearningCandidateExtractor.divergence(original: original, edited: edited)
        XCTAssertGreaterThan(d, TextInjector.correctionDivergenceThreshold,
            "A full rewrite should exceed the bail-out threshold; got \(d)")
    }
}

final class CorrectionObservationScheduleBudgetTests: XCTestCase {

    // MARK: - Poll schedule

    #if !APP_STORE
    func testScheduleDoesNotExceedSixtySeconds() {
        let totalNs = TextInjector.correctionPollSchedule.reduce(UInt64(0), &+)
        let totalSeconds = Double(totalNs) / 1_000_000_000
        XCTAssertLessThanOrEqual(totalSeconds, 60,
            "Schedule total \(totalSeconds)s exceeds 60 s ceiling")
    }

    func testScheduleCountDoesNotExceedBudget() {
        XCTAssertLessThanOrEqual(TextInjector.correctionPollSchedule.count, 33,
            "Schedule has \(TextInjector.correctionPollSchedule.count) reads, budget is 33")
    }
    #endif
}

final class CorrectionObservationEndReasonTests: XCTestCase {

    // MARK: - End-reason rawValue contract

    func testAllEndReasonsHaveNonEmptyRawValues() {
        let reasons: [CorrectionObservationEndReason] = [
            .windowElapsed, .cancelled, .focusLost, .elementLost,
            .notVerified, .ambiguousAnchor, .anchorBroken,
            .editDistanceExceeded, .learnedAndSettled
        ]
        for reason in reasons {
            XCTAssertFalse(reason.rawValue.isEmpty, "\(reason) has empty rawValue")
        }
    }

    func testEndReasonRoundTrips() {
        // Guards log consumers that reconstruct from rawValue (e.g. analytics pipeline).
        let reason = CorrectionObservationEndReason.editDistanceExceeded
        let reconstructed = CorrectionObservationEndReason(rawValue: reason.rawValue)
        XCTAssertEqual(reconstructed, reason)
    }
}
