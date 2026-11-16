//
//  FileTranscriptParagraphsTests.swift
//  WhispererTests
//
//  The paragraph cut of a finished file transcription must work in any script and never lose a word.
//

import XCTest
@testable import whisperer

final class FileTranscriptParagraphsTests: XCTestCase {

    private func sentences(_ sentence: String, count: Int) -> String {
        Array(repeating: sentence, count: count).joined(separator: " ")
    }

    private func squashed(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    private func assertLossless(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let paragraphs = FileTranscriptParagraphs.split(text)
        XCTAssertEqual(squashed(paragraphs.map(\.text).joined()), squashed(text), file: file, line: line)
    }

    func testEnglishBreaksIntoReadableParagraphs() {
        let text = sentences("We are going to dive into how this product works for teams today.", count: 40)
        let paragraphs = FileTranscriptParagraphs.split(text)
        XCTAssertGreaterThan(paragraphs.count, 5)
        XCTAssertTrue(paragraphs.allSatisfy { $0.words <= FileTranscriptParagraphs.maxWords })
        assertLossless(text)
    }

    func testHebrewRussianChineseAndJapaneseAllSplit() {
        let samples = [
            sentences("אנחנו הולכים לדבר היום על איך המוצר הזה עובד בצוותים גדולים וקטנים.", count: 30),
            sentences("Сегодня мы расскажем о том, как этот продукт помогает командам работать вместе.", count: 30),
            sentences("今天我们将介绍这个产品如何帮助团队更好地协同工作，并分享一些真实的使用案例。", count: 40),
            sentences("今日はこの製品がチームの共同作業をどのように助けるかについてお話しします。", count: 40),
        ]
        for text in samples {
            let paragraphs = FileTranscriptParagraphs.split(text)
            XCTAssertGreaterThan(paragraphs.count, 1, String(text.prefix(20)))
            assertLossless(text)
        }
    }

    func testShortTextIsOneParagraph() {
        XCTAssertEqual(FileTranscriptParagraphs.split("Hello there. How are you?").count, 1)
        XCTAssertTrue(FileTranscriptParagraphs.split("").isEmpty)
    }

    func testTrailingFragmentFoldsIntoThePreviousParagraph() {
        let text = sentences("This sentence has exactly eight words in it.", count: 8) + " The end."
        let paragraphs = FileTranscriptParagraphs.split(text)
        XCTAssertGreaterThanOrEqual(paragraphs.last?.words ?? 0, FileTranscriptParagraphs.minimumTrailingWords)
    }

    func testTimestampsFollowAnchorsAndNeverGoBackwards() {
        let text = sentences("One two three four five six seven eight nine ten.", count: 60)
        let total = FileTranscriptParagraphs.wordCount(text)
        let anchors = [
            FileTranscriptAnchor(word: 0, seconds: 0),
            FileTranscriptAnchor(word: total / 2, seconds: 30),
            FileTranscriptAnchor(word: total, seconds: 60),
        ]
        let paragraphs = FileTranscriptParagraphs.split(text, anchors: anchors)
        XCTAssertEqual(paragraphs.first?.start ?? -1, 0, accuracy: 0.01)
        let starts = paragraphs.compactMap(\.start)
        XCTAssertEqual(starts.count, paragraphs.count)
        XCTAssertEqual(starts, starts.sorted())
        XCTAssertLessThan(starts.last ?? 99, 60)
        // the paragraph that begins halfway through the words begins about halfway through the audio
        let middle = paragraphs.min { abs(($0.start ?? 0) - 30) < abs(($1.start ?? 0) - 30) }
        XCTAssertEqual(middle?.start ?? 0, 30, accuracy: 6)
    }

    func testNoAnchorsMeansNoTimes() {
        let paragraphs = FileTranscriptParagraphs.split(sentences("A short sentence goes here.", count: 30))
        XCTAssertTrue(paragraphs.allSatisfy { $0.start == nil })
    }

    func testClockFormat() {
        XCTAssertEqual(FileTranscriptClock.format(75), "1:15")
        XCTAssertEqual(FileTranscriptClock.format(3725), "1:02:05")
    }
}
