//
//  SpeakerAttributionTests.swift
//  WhispererTests
//
//  Unit tests for SpeakerAttribution — who the finalized diarizer timeline
//  puts in a window, and where the voiced audio inside it is.
//

import XCTest
@testable import whisperer

final class SpeakerAttributionTests: XCTestCase {

    private typealias Turn = SpeakerAttribution.Turn

    private func dominant(_ turns: [Turn], _ start: Double, _ end: Double) -> Int? {
        SpeakerAttribution.dominantSpeaker(in: turns, from: start, to: end)
    }

    // MARK: - The reported failure

    /// The bug: Sortformer finalizes a turn only when a slot's activity *falls*, so a slot
    /// talking continuously finalizes nothing. During a monologue the only finalized audio in a
    /// window is another slot's short blip — and naming the speaker from it renamed the talker
    /// every second, closing a transcript card each time.
    func testShortBlipFromAnIdleSlotNamesNobody() {
        // One 1.12s Nemotron partial; the timeline holds 0.4s of slot 2 and nothing else.
        let turns = [Turn(start: 10.1, end: 10.5, speaker: 1)]
        XCTAssertNil(dominant(turns, 10.0, 11.12))
    }

    func testAnEmptyTimelineNamesNobody() {
        XCTAssertNil(dominant([], 10.0, 11.12))
    }

    func testTurnsOutsideTheWindowAreIgnored() {
        let turns = [Turn(start: 0, end: 9.0, speaker: 1), Turn(start: 12.0, end: 20.0, speaker: 2)]
        XCTAssertNil(dominant(turns, 10.0, 11.12))
    }

    // MARK: - What the fix must not break

    func testFullCoverageNamesThatSpeaker() {
        let turns = [Turn(start: 9.5, end: 11.5, speaker: 2)]
        XCTAssertEqual(dominant(turns, 10.0, 11.12), 2)
    }

    func testAGenuineHandoverIsNamedForWhoeverHoldsTheWindow() {
        // Speaker 0 finishes at 10.2, speaker 1 holds the remaining 0.92s.
        let turns = [Turn(start: 9.0, end: 10.2, speaker: 0),
                     Turn(start: 10.2, end: 11.2, speaker: 1)]
        XCTAssertEqual(dominant(turns, 10.0, 11.12), 1)
    }

    func testOverlappingSpeechResolvesToWhoeverDominates() {
        // Both talk over each other; speaker 1 holds far more of the window.
        let turns = [Turn(start: 10.0, end: 10.4, speaker: 0),
                     Turn(start: 10.0, end: 11.12, speaker: 1)]
        XCTAssertEqual(dominant(turns, 10.0, 11.12), 1)
    }

    func testSeparateTurnsFromOneSpeakerAccumulate() {
        // Neither run alone clears the share floor; together they cover 0.8s of 1.12s.
        let turns = [Turn(start: 10.0, end: 10.4, speaker: 3),
                     Turn(start: 10.6, end: 11.0, speaker: 3)]
        XCTAssertEqual(dominant(turns, 10.0, 11.12), 3)
    }

    // MARK: - The floors themselves

    func testWinningTheWindowIsNotEnoughWithoutTheShare() {
        // Speaker 1 wins outright — and still only accounts for 40% of a 1.12s window.
        let turns = [Turn(start: 10.0, end: 10.45, speaker: 1)]
        XCTAssertNil(dominant(turns, 10.0, 11.12))
    }

    func testHoldingTheWholeWindowIsNotEnoughWhenTheWindowIsTiny() {
        // 100% share, but 0.1s of evidence. Too little to rename anyone on.
        let turns = [Turn(start: 10.0, end: 10.1, speaker: 1)]
        XCTAssertNil(dominant(turns, 10.0, 10.1))
    }

    func testAZeroWidthWindowFallsBackToTheSecondsFloorAlone() {
        // No span to take a share of; only `minSeconds` can decide, and nothing overlaps.
        let turns = [Turn(start: 10.0, end: 11.0, speaker: 1)]
        XCTAssertNil(dominant(turns, 10.5, 10.5))
    }

    // MARK: - Voiced runs

    func testVoicedRunsAreClippedToTheWindow() {
        let runs = SpeakerAttribution.voicedRuns(in: [Turn(start: 5.0, end: 20.0, speaker: 0)],
                                                 from: 10.0, to: 11.0)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].start, 10.0, accuracy: 0.0001)
        XCTAssertEqual(runs[0].end, 11.0, accuracy: 0.0001)
    }

    func testOverlappingTurnsMergeIntoOneRun() {
        // Two speakers talking over each other is one stretch of sound, not two.
        let turns = [Turn(start: 10.0, end: 10.6, speaker: 0),
                     Turn(start: 10.4, end: 11.0, speaker: 1)]
        let runs = SpeakerAttribution.voicedRuns(in: turns, from: 10.0, to: 11.0)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].start, 10.0, accuracy: 0.0001)
        XCTAssertEqual(runs[0].end, 11.0, accuracy: 0.0001)
    }

    func testASilentGapSplitsTheRuns() {
        let turns = [Turn(start: 10.0, end: 10.3, speaker: 0),
                     Turn(start: 12.0, end: 12.5, speaker: 0)]
        let runs = SpeakerAttribution.voicedRuns(in: turns, from: 10.0, to: 13.0)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].end, 10.3, accuracy: 0.0001)
        XCTAssertEqual(runs[1].start, 12.0, accuracy: 0.0001)
    }

    func testRunsComeBackInOrderRegardlessOfTurnOrder() {
        let turns = [Turn(start: 12.0, end: 12.5, speaker: 1),
                     Turn(start: 10.0, end: 10.3, speaker: 0)]
        let runs = SpeakerAttribution.voicedRuns(in: turns, from: 10.0, to: 13.0)
        XCTAssertEqual(runs.map { $0.start }, [10.0, 12.0])
    }

    func testNoOverlapProducesNoRuns() {
        let runs = SpeakerAttribution.voicedRuns(in: [Turn(start: 0, end: 5, speaker: 0)],
                                                 from: 10.0, to: 11.0)
        XCTAssertTrue(runs.isEmpty)
    }

    // MARK: - Voiced runs, per speaker (where the words go)

    /// The other half of the reported failure. Mid-monologue the talker's own turn has not
    /// finalized, so the only run in the window belongs to another slot. Clipping onto it would
    /// shrink a 1.12s partial to 0.4s and invent silence on both sides of it.
    func testAForeignBlipDoesNotPlaceTheSpeakersWords() {
        let turns = [Turn(start: 10.1, end: 10.5, speaker: 2)]
        XCTAssertTrue(SpeakerAttribution.voicedRuns(in: turns, by: 0, from: 10.0, to: 11.12).isEmpty)
    }

    /// …and the case that must survive it: the talker paused, so their turn closed and *did*
    /// finalize. The window spans the pause and the run exposes it.
    func testAGenuinePauseIsStillExposed() {
        // Talked 4.0–10.0, silent to 14.0, resumed 14.0–15.0 and paused again.
        let turns = [Turn(start: 4.0, end: 10.0, speaker: 0), Turn(start: 14.0, end: 15.0, speaker: 0)]
        let runs = SpeakerAttribution.voicedRuns(in: turns, by: 0, from: 10.0, to: 15.0)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].start, 14.0, accuracy: 0.0001)
        XCTAssertEqual(runs[0].end, 15.0, accuracy: 0.0001)
    }

    func testAPauseInsideTheWindowSplitsIntoTwoRuns() {
        let turns = [Turn(start: 10.0, end: 10.8, speaker: 1), Turn(start: 13.0, end: 14.0, speaker: 1)]
        let runs = SpeakerAttribution.voicedRuns(in: turns, by: 1, from: 10.0, to: 14.0)
        XCTAssertEqual(runs.count, 2)
    }

    func testOnlyTheNamedSpeakersTurnsCount() {
        let turns = [Turn(start: 10.0, end: 10.4, speaker: 0), Turn(start: 10.6, end: 11.0, speaker: 1)]
        let runs = SpeakerAttribution.voicedRuns(in: turns, by: 1, from: 10.0, to: 11.0)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].start, 10.6, accuracy: 0.0001)
    }
}
