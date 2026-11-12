//
//  FinalParagraphPassTests.swift
//  WhispererTests
//
//  The post-meeting paragraph pass: synthetic cases for the rules, then the user's real meetings.
//

import XCTest
@testable import whisperer

final class FinalParagraphPassTests: XCTestCase {

    private func sentence(_ n: Int, _ tag: String) -> String {
        (0..<n).map { _ in "word" }.joined(separator: " ") + " \(tag)."
    }

    private func segment(_ text: String, _ start: Double, _ end: Double, speaker: Int = 0,
                         rawText: String? = nil, tags: [SegmentTag] = []) -> MeetingSegment {
        MeetingSegment(timestamp: start, endTimestamp: end, text: text, speakerName: "Speaker \(speaker + 1)",
                       speakerIndex: speaker, tags: tags, rawText: rawText)
    }

    private func words(_ segments: [MeetingSegment]) -> [String] {
        segments.flatMap { $0.text.split(separator: " ").map(String.init) }
    }

    func testFragmentsWithoutAPauseAreMerged() {
        let input = [segment(sentence(9, "a"), 0, 4), segment(sentence(9, "b"), 4.2, 8), segment(sentence(9, "c"), 8.3, 12)]
        let output = FinalParagraphPass.apply(input)
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(words(output), words(input))
        XCTAssertEqual(output[0].timestamp, 0)
        XCTAssertEqual(output[0].endTimestamp, 12)
    }

    func testLongPauseKeepsTheBreak() {
        let input = [segment(sentence(30, "a"), 0, 12), segment(sentence(20, "b"), 20, 28)]
        XCTAssertEqual(FinalParagraphPass.apply(input), input)
    }

    func testWallIsSplitAtASentenceEnd() {
        let wall = (0..<10).map { sentence(12, "s\($0)") }.joined(separator: " ")   // 130 words
        let output = FinalParagraphPass.apply([segment(wall, 0, 52), segment("tail words here now.", 52.2, 56)])
        XCTAssertGreaterThan(output.count, 1)
        XCTAssertEqual(words(output), words([segment(wall, 0, 52), segment("tail words here now.", 52.2, 56)]))
        for card in output.dropLast() { XCTAssertTrue(card.text.hasSuffix("."), "cut at a sentence end") }
        for (a, b) in zip(output, output.dropFirst()) { XCTAssertLessThanOrEqual(a.endTimestamp, b.timestamp + 0.001) }
    }

    func testSpeakerChangeIsNeverMerged() {
        let input = [segment(sentence(9, "a"), 0, 4, speaker: 0), segment(sentence(9, "b"), 4.2, 8, speaker: 1),
                     segment(sentence(9, "c"), 8.3, 12, speaker: 0)]
        XCTAssertEqual(FinalParagraphPass.apply(input), input)
    }

    func testTaggedAndRewrittenCardsAreNotCut() {
        let tagged = segment(sentence(9, "a"), 0, 4, tags: [.decision])
        let next = segment(sentence(9, "b"), 4.2, 8)
        XCTAssertEqual(FinalParagraphPass.apply([tagged, next]), [tagged, next])
        let polished = segment("Polished sentence one. " + sentence(70, "z"), 0, 30, rawText: "raw")
        XCTAssertEqual(FinalParagraphPass.apply([polished, next]).first?.rawText != nil, true)
        XCTAssertFalse(FinalParagraphPass.apply([polished]).isEmpty)
    }

    func testMergedCardKeepsRawTextOfBoth() {
        let a = segment("Polished a one two three four five six seven eight.", 0, 4, rawText: "raw a")
        let b = segment("Plain b one two three four five six seven eight nine.", 4.1, 8)
        let output = FinalParagraphPass.apply([a, b])
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].rawText, "raw a Plain b one two three four five six seven eight nine.")
        XCTAssertEqual(output[0].id, a.id)
    }

    func testIdempotent() {
        let input = (0..<12).map { segment(sentence(11, "s\($0)"), Double($0) * 5, Double($0) * 5 + 4.5) }
        let once = FinalParagraphPass.apply(input)
        XCTAssertEqual(FinalParagraphPass.apply(once), once)
    }

    func testVersionNumberIsNotASentenceEnd() {
        XCTAssertEqual(FinalParagraphPass.sentenceSpans("we ship v1.2 today. then more."), ["we ship v1.2 today.", "then more."])
    }

    // MARK: - Real meetings

    /// Every saved meeting of the user's: words and speakers must survive; the report says what the
    /// pass did to the card layout. Skipped when the machine has none.
    func testRealMeetingsKeepEveryWord() throws {
        let fixtures = HistoryTestLoader.loadMeetingFixtures(maxCount: 200)
        try XCTSkipIf(fixtures.isEmpty, "no saved meetings on this machine")
        var before = Layout(), after = Layout()
        for meeting in fixtures {
            let input = meeting.segments.sorted { $0.timestamp < $1.timestamp }
            let output = FinalParagraphPass.apply(input)
            XCTAssertEqual(words(output), words(input), "words lost or reordered in \(meeting.title)")
            XCTAssertEqual(FinalParagraphPass.apply(output), output, "not idempotent on \(meeting.title)")
            for (a, b) in zip(output, output.dropFirst()) where a.speakerIndex == b.speakerIndex {
                XCTAssertLessThanOrEqual(a.endTimestamp, b.timestamp + 0.5, "cards overlap in \(meeting.title)")
            }
            before.add(input); after.add(output)
        }
        print("[Paragraphs] \(fixtures.count) meetings  before: \(before)  after: \(after)")
        XCTAssertLessThanOrEqual(after.fragments, before.fragments)
        XCTAssertLessThanOrEqual(after.walls, before.walls)
    }

    private struct Layout: CustomStringConvertible {
        var cards = 0, fragments = 0, walls = 0, turns = 0
        mutating func add(_ segments: [MeetingSegment]) {
            cards += segments.count
            for segment in segments {
                let n = FinalParagraphPass.wordCount(segment.text)
                if n < 12 { fragments += 1 }
                if n > 140 { walls += 1 }
            }
            for (a, b) in zip(segments, segments.dropFirst()) where a.speakerIndex != b.speakerIndex { turns += 1 }
            turns += segments.isEmpty ? 0 : 1
        }
        var description: String {
            String(format: "%d cards, %d turns (%.1f cards/turn), %d fragments (<12 words), %d walls (>140)",
                   cards, turns, Double(cards) / Double(max(turns, 1)), fragments, walls)
        }
    }
}
