//
//  MeetingTranscriptAccumulatorTests.swift
//  WhispererTests
//
//  `MeetingSpeakerCoordinator` rejects any text shorter than it has already attributed, and a
//  rejection does not degrade attribution — it stops it. The accumulator is the one thing
//  standing between Qwen3's live output and that cliff, so every way a snapshot can fail to be
//  an extension of the last one is pinned here.
//
//  Pure and fast. Safe to run on every edit.
//

import XCTest
@testable import whisperer

final class MeetingTranscriptAccumulatorTests: XCTestCase {

    // MARK: - The happy path

    func testForwardsGrowingSnapshots() {
        var accumulator = MeetingTranscriptAccumulator()
        XCTAssertEqual(accumulator.accept("hello"), "hello")
        XCTAssertEqual(accumulator.accept("hello there"), "hello there")
        XCTAssertEqual(accumulator.accept("hello there world"), "hello there world")
        XCTAssertEqual(accumulator.published, "hello there world")
        XCTAssertEqual(accumulator.rejectedCount, 0)
    }

    func testTrimsWhitespaceBeforeComparing() {
        var accumulator = MeetingTranscriptAccumulator()
        XCTAssertEqual(accumulator.accept("  hello  "), "hello")
        // Same words, different padding — not new text, so nothing is forwarded.
        XCTAssertNil(accumulator.accept("\nhello\n"))
        XCTAssertEqual(accumulator.rejectedCount, 0, "identical text is a no-op, not a rejection")
    }

    // MARK: - What must never reach the coordinator

    /// The exact failure this type exists to prevent. The preview tail shrinks when a chunk
    /// commits before the next preview pass lands; forwarding that shrink makes the coordinator
    /// treat it as a delta and destroy its pending queue.
    func testDropsShrinks() {
        var accumulator = MeetingTranscriptAccumulator()
        _ = accumulator.accept("one two three four")
        XCTAssertNil(accumulator.accept("one two"))
        XCTAssertEqual(accumulator.published, "one two three four",
                       "a shrink must not move the published watermark backwards")
        XCTAssertEqual(accumulator.rejectedCount, 1)
    }

    /// Longer, but the decoder rewrote an earlier word. The coordinator has already attributed
    /// that word to a speaker and cannot take it back, so the snapshot is unusable.
    func testDropsDivergentPrefix() {
        var accumulator = MeetingTranscriptAccumulator()
        _ = accumulator.accept("the solver keeps failing")
        XCTAssertNil(accumulator.accept("the solvent keeps failing us"))
        XCTAssertEqual(accumulator.published, "the solver keeps failing")
        XCTAssertEqual(accumulator.rejectedCount, 1)
    }

    /// Equal word count with different words is not growth, even though the strings differ.
    func testDropsSameLengthRewrite() {
        var accumulator = MeetingTranscriptAccumulator()
        _ = accumulator.accept("alpha beta gamma")
        XCTAssertNil(accumulator.accept("alpha beta delta"))
        XCTAssertEqual(accumulator.published, "alpha beta gamma")
    }

    func testDropsEmptyAndWhitespaceOnly() {
        var accumulator = MeetingTranscriptAccumulator()
        XCTAssertNil(accumulator.accept(""))
        XCTAssertNil(accumulator.accept("   \n  "))
        _ = accumulator.accept("real text")
        XCTAssertNil(accumulator.accept(""), "an empty snapshot must never retract real text")
        XCTAssertEqual(accumulator.published, "real text")
    }

    // MARK: - Recovery

    /// After a shrink, the next genuinely longer snapshot must be forwarded. Rejecting one bad
    /// update must not latch the accumulator shut for the rest of the meeting.
    func testResumesAfterARejection() {
        var accumulator = MeetingTranscriptAccumulator()
        _ = accumulator.accept("one two three")
        XCTAssertNil(accumulator.accept("one two"))
        XCTAssertEqual(accumulator.accept("one two three four"), "one two three four")
        XCTAssertEqual(accumulator.rejectedCount, 1)
    }

    /// A carried-over watermark would make the next meeting's first update look like a shrink
    /// and silence attribution for the whole recording.
    func testResetClearsTheWatermark() {
        var accumulator = MeetingTranscriptAccumulator()
        _ = accumulator.accept("previous meeting text that ran long")
        accumulator.reset()
        XCTAssertEqual(accumulator.published, "")
        XCTAssertEqual(accumulator.rejectedCount, 0)
        XCTAssertEqual(accumulator.accept("new"), "new",
                       "a short first snapshot must survive a reset")
    }

    // MARK: - Contract held end to end

    /// The property the coordinator actually depends on: whatever comes out is non-decreasing
    /// in word count, so `ingestAccumulated`'s `words.count < emittedWordCount` guard can
    /// never fire. Driven with a stream that shrinks, diverges and recovers.
    func testOutputIsMonotonicUnderAHostileStream() {
        var accumulator = MeetingTranscriptAccumulator()
        let stream = [
            "a", "a b", "a b c", "a b",            // shrink
            "a b c d", "x y z",                     // divergence
            "a b c d e", "a b c d e", "a b c d e f",
        ]
        var forwarded: [Int] = []
        for snapshot in stream {
            if let out = accumulator.accept(snapshot) {
                forwarded.append(out.split(separator: " ").count)
            }
        }
        XCTAssertEqual(forwarded, forwarded.sorted(), "forwarded word counts must never decrease")
        XCTAssertEqual(Set(forwarded).count, forwarded.count, "no duplicate word counts forwarded")
        XCTAssertEqual(accumulator.published, "a b c d e f")
    }

    /// RTL text is split on spaces the same way; the guard must not depend on script.
    func testWorksOnHebrew() {
        var accumulator = MeetingTranscriptAccumulator()
        XCTAssertEqual(accumulator.accept("שלום"), "שלום")
        XCTAssertEqual(accumulator.accept("שלום עולם"), "שלום עולם")
        XCTAssertNil(accumulator.accept("שלום"))
        XCTAssertEqual(accumulator.published, "שלום עולם")
    }
}
