//
//  MeetingTranscriptTextTests.swift
//  WhispererTests
//
//  Unit tests for MeetingTranscriptText — the plain-prose and labelled
//  renderings of a meeting transcript.
//

import XCTest
@testable import whisperer

final class MeetingTranscriptTextTests: XCTestCase {

    // MARK: - Helpers

    private func seg(_ text: String,
                     _ start: Double,
                     _ end: Double,
                     speaker: Int = 0,
                     name: String? = nil,
                     raw: String? = nil) -> MeetingSegment {
        MeetingSegment(timestamp: start,
                       endTimestamp: end,
                       text: text,
                       speakerName: name ?? "Speaker \(speaker + 1)",
                       speakerIndex: speaker,
                       rawText: raw)
    }

    // MARK: - Plain prose

    func testEmptySegmentsProduceEmptyString() {
        XCTAssertEqual(MeetingTranscriptText.plainProse(from: []), "")
    }

    func testSingleSegmentIsJustItsText() {
        let out = MeetingTranscriptText.plainProse(from: [seg("Hello there.", 0, 2)])
        XCTAssertEqual(out, "Hello there.")
    }

    func testSameSpeakerContinuousSpeechJoinsWithSpace() {
        let out = MeetingTranscriptText.plainProse(from: [
            seg("We start with the schema.", 0, 4),
            seg("Then the migration lands.", 4.2, 8)
        ])
        XCTAssertEqual(out, "We start with the schema. Then the migration lands.")
    }

    func testSpeakerChangeStartsNewParagraph() {
        let out = MeetingTranscriptText.plainProse(from: [
            seg("We start with the schema.", 0, 4, speaker: 0),
            seg("How long is that?", 4.1, 6, speaker: 1)
        ])
        XCTAssertEqual(out, "We start with the schema.\n\nHow long is that?")
    }

    func testLongPauseStartsNewParagraphForSameSpeaker() {
        let out = MeetingTranscriptText.plainProse(from: [
            seg("We start with the schema.", 0, 4),
            seg("Anyway, different subject.", 12, 15)
        ])
        XCTAssertEqual(out, "We start with the schema.\n\nAnyway, different subject.")
    }

    func testShortPauseDoesNotBreakParagraph() {
        // Just under the 2.5s threshold — normal breathing, not a topic change.
        let out = MeetingTranscriptText.plainProse(from: [
            seg("We start with the schema.", 0, 4),
            seg("Then the migration.", 6.4, 8)
        ])
        XCTAssertEqual(out, "We start with the schema. Then the migration.")
    }

    func testNoSpeakerLabelsOrTimestampsAppearAnywhere() {
        let out = MeetingTranscriptText.plainProse(from: [
            seg("First line.", 0, 4, speaker: 0, name: "Alex"),
            seg("Second line.", 30, 34, speaker: 1, name: "Jordan")
        ])
        XCTAssertFalse(out.contains("Alex"))
        XCTAssertFalse(out.contains("Jordan"))
        XCTAssertFalse(out.contains("["))
        XCTAssertFalse(out.contains("0:30"))
    }

    func testBlankAndWhitespaceOnlySegmentsAreDropped() {
        let out = MeetingTranscriptText.plainProse(from: [
            seg("Real text.", 0, 4),
            seg("   ", 4.1, 5),
            seg("", 5.1, 6),
            seg("More text.", 6.1, 8)
        ])
        XCTAssertEqual(out, "Real text. More text.")
    }

    func testSegmentTextIsTrimmed() {
        let out = MeetingTranscriptText.plainProse(from: [
            seg("  Leading and trailing.  ", 0, 4)
        ])
        XCTAssertEqual(out, "Leading and trailing.")
    }

    /// A dropped blank segment must not swallow the paragraph break its neighbours imply.
    func testBreakSurvivesADroppedBlankSegment() {
        let out = MeetingTranscriptText.plainProse(from: [
            seg("First speaker.", 0, 4, speaker: 0),
            seg("   ", 4.1, 4.5, speaker: 0),
            seg("Second speaker.", 4.6, 8, speaker: 1)
        ])
        XCTAssertEqual(out, "First speaker.\n\nSecond speaker.")
    }

    /// Out-of-order or overlapping spans must not be read as a long pause.
    func testNegativeGapDoesNotBreakParagraph() {
        let out = MeetingTranscriptText.plainProse(from: [
            seg("Overlapping one.", 0, 10),
            seg("Overlapping two.", 4, 12)
        ])
        XCTAssertEqual(out, "Overlapping one. Overlapping two.")
    }

    /// The caller applies the Polished/Original toggle before we see the segments, so prose
    /// renders `text` verbatim and never reaches for `rawText` itself.
    func testProseUsesTextFieldNotRawText() {
        let out = MeetingTranscriptText.plainProse(from: [
            seg("Polished sentence.", 0, 4, raw: "polished sentance")
        ])
        XCTAssertEqual(out, "Polished sentence.")
    }

    // MARK: - Labelled transcript

    func testLabelledIncludesTimestampAndSpeaker() {
        let out = MeetingTranscriptText.labelled(from: [
            seg("Hello.", 0, 2, speaker: 0, name: "Alex"),
            seg("Hi.", 75, 78, speaker: 1, name: "Jordan")
        ])
        XCTAssertEqual(out, "[0:00] Alex: Hello.\n[1:15] Jordan: Hi.")
    }

    func testLabelledDropsBlankSegments() {
        let out = MeetingTranscriptText.labelled(from: [
            seg("Hello.", 0, 2, name: "Alex"),
            seg("  ", 3, 4, name: "Alex")
        ])
        XCTAssertEqual(out, "[0:00] Alex: Hello.")
    }

    func testLabelledEmptyIsEmpty() {
        XCTAssertEqual(MeetingTranscriptText.labelled(from: []), "")
    }
}
