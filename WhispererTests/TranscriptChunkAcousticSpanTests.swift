//
//  TranscriptChunkAcousticSpanTests.swift
//  WhispererTests
//
//  The join between "the pipeline inserts periods at pauses" and "the app has pauses to give it".
//
//  `SentenceTerminatorTests` proves the first half against hand-built chunk spans and has passed
//  the whole time. The second half was false for every real recording: the eager path stamps a
//  soft-commit's `start` at the previous commit's `end` exactly, so `next.start - prev.end` was
//  identically 0 and the interior rule could not fire however long the speaker paused. It was
//  measured — 0 of 439 joins carried a gap (`PolishInteriorBoundaryTests`) — and read as a fact
//  about the corpus rather than about the clock.
//
//  So these tests are deliberately not about punctuation. They pin the one arithmetic property the
//  rest depends on: that the span `AppState.retainForPolish` hands the polisher can be narrower
//  than the decode span, and that a contiguous pair of chunks therefore still yields a real gap. A
//  refactor that drops `voicedStart`/`voicedEnd` — or that wires `retainForPolish` back to
//  `start`/`end` — puts every dictation back to one run-on sentence and breaks nothing else.
//

import XCTest
@testable import whisperer

final class TranscriptChunkAcousticSpanTests: XCTestCase {

    /// A pair of chunks shaped like a real eager commit: contiguous decode spans, voiced content
    /// sitting inside them with silence at the seam.
    private func contiguousPair(voicedEnd: Double, voicedStart: Double)
        -> (TranscriptChunk, TranscriptChunk) {
        let first = TranscriptChunk(text: "item number one", start: 0.15, end: 6.32,
                                    recordedDuration: 12.4,
                                    voicedStart: 0.2, voicedEnd: voicedEnd)
        let second = TranscriptChunk(text: "polish the document", start: 6.32, end: 12.4,
                                     recordedDuration: 12.4,
                                     voicedStart: voicedStart, voicedEnd: 12.1)
        return (first, second)
    }

    func testDecodeSpansAreContiguousAndCarryNoGap() {
        let (first, second) = contiguousPair(voicedEnd: 5.9, voicedStart: 7.1)
        XCTAssertEqual(second.start - first.end, 0, accuracy: 1e-9,
                       "the eager path stamps next.start == prev.end; if this ever stops being "
                       + "true the voiced span is no longer the only source of a gap")
    }

    func testVoicedSpansRecoverThePauseInsideThem() {
        let (first, second) = contiguousPair(voicedEnd: 5.9, voicedStart: 7.1)
        let gap = second.acousticStart - first.acousticEnd
        XCTAssertEqual(gap, 1.2, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(gap, SentenceTerminator.minimumPause,
                                    "a 1.2s pause has to clear the floor or the fix is cosmetic")
    }

    /// The 0.2s that `SileroVAD.speechPadMs` costs is real and the floor has to be cleared *after*
    /// paying it. Documented on `voicedSpanSeconds`; asserted here so the two cannot drift.
    func testPaddingErodesTheGapTowardTheFloor() {
        // A 0.85s true pause, dilated by 100ms of padding at each edge, measures as 0.65s.
        let (first, second) = contiguousPair(voicedEnd: 5.9 + 0.1, voicedStart: 6.75 - 0.1)
        let gap = second.acousticStart - first.acousticEnd
        XCTAssertEqual(gap, 0.65, accuracy: 1e-9)
        XCTAssertLessThan(gap, SentenceTerminator.minimumPause,
                          "under-reporting is the intended direction: a pause that is only just "
                          + "long enough loses its period rather than a mid-sentence one gaining "
                          + "a full stop")
    }

    /// No VAD is a user setting, not an error. Without it the chunk must behave exactly as it did
    /// before this field existed.
    func testAbsentVoicedSpanFallsBackToTheDecodeSpan() {
        let chunk = TranscriptChunk(text: "item number one", start: 0.15, end: 6.32,
                                    recordedDuration: 12.4)
        XCTAssertEqual(chunk.acousticStart, chunk.start)
        XCTAssertEqual(chunk.acousticEnd, chunk.end)
    }

    /// A gap the polisher can read has to survive the trip through `DeterministicPolisher.Chunk`,
    /// which is the type `retainForPolish` actually builds.
    func testAcousticSpansProduceAnInteriorPeriod() {
        let (first, second) = contiguousPair(voicedEnd: 5.9, voicedStart: 7.1)
        let polisher = DeterministicPolisher.forTranscript(dictionaryEntries: [],
                                                           formatsLists: false)
        let onDecodeSpans = polisher.polish(chunks: [
            DeterministicPolisher.Chunk(text: first.text, start: first.start, end: first.end),
            DeterministicPolisher.Chunk(text: second.text, start: second.start, end: second.end),
        ]).text
        let onAcousticSpans = polisher.polish(chunks: [
            DeterministicPolisher.Chunk(text: first.text,
                                        start: first.acousticStart, end: first.acousticEnd),
            DeterministicPolisher.Chunk(text: second.text,
                                        start: second.acousticStart, end: second.acousticEnd),
        ]).text

        XCTAssertFalse(onDecodeSpans.contains("one. Polish"), onDecodeSpans)
        XCTAssertTrue(onAcousticSpans.contains("one. Polish"), onAcousticSpans)
    }
}
