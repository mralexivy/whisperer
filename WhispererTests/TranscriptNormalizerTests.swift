//
//  TranscriptNormalizerTests.swift
//  WhispererTests
//

import XCTest
@testable import whisperer

final class TranscriptNormalizerTests: XCTestCase {

    private func normalized(_ text: String) -> String {
        var graph = TokenGraph.from(text: text)
        TranscriptNormalizer.apply(to: &graph)
        return graph.render()
    }

    // MARK: - Fillers

    func testEnglishFillersAreRemoved() {
        XCTAssertEqual(normalized("um so I think uh we should ship"),
                       "so I think we should ship")
        XCTAssertEqual(normalized("uh uh uh hello"), "hello")
    }

    /// The gap: today's filler list is Latin-only, so a Hebrew transcript gets no disfluency
    /// removal at all.
    func testHebrewFillersAreRemoved() {
        XCTAssertEqual(normalized("אז כאילו צריך להריץ את זה"), "אז צריך להריץ את זה")
        XCTAssertEqual(normalized("אמ אני חושב שכן"), "אני חושב שכן")
    }

    func testRussianFillersAreRemoved() {
        XCTAssertEqual(normalized("ну типа надо запустить"), "ну надо запустить")
        XCTAssertEqual(normalized("это самое надо проверить"), "надо проверить")
        XCTAssertEqual(normalized("как бы всё готово"), "всё готово")
    }

    /// `like` stays. It is a content word far too often for any threshold to clear the
    /// 0.99-precision bar, and deleting it from `I like it` is the catastrophic direction.
    func testAmbiguousEnglishMarkerIsKept() {
        XCTAssertEqual(normalized("I like it like that"), "I like it like that")
    }

    // MARK: - Adjacent duplicates

    func testStutterIsCollapsed() {
        XCTAssertEqual(normalized("the the deployment failed"), "the deployment failed")
        XCTAssertEqual(normalized("я я не знаю"), "я не знаю")
    }

    func testIntentionalRepetitionIsKept() {
        XCTAssertEqual(normalized("it was very very fast"), "it was very very fast")
        XCTAssertEqual(normalized("he had had enough"), "he had had enough")
    }

    func testRepetitionAcrossPunctuationIsKept() {
        // `the cat, the cat` repeats a phrase; deleting one word breaks it.
        XCTAssertEqual(normalized("run it, it works"), "run it, it works")
    }

    // MARK: - Punctuation and whitespace

    func testDuplicatePunctuationCollapses() {
        XCTAssertEqual(normalized("really.... yes!!"), "really. yes!")
        // Distinct marks are deliberate.
        XCTAssertEqual(normalized("really?!"), "really?!")
    }

    func testPunctuationAcrossWordsIsNotCollapsed() {
        XCTAssertEqual(normalized("one. two. three."), "one. two. three.")
    }

    func testWhitespaceIsNormalized() {
        XCTAssertEqual(normalized("  too   many    spaces  "), "too many spaces")
        // Paragraph structure is content, not noise.
        XCTAssertEqual(normalized("first line\n\nsecond line"), "first line\nsecond line")
    }

    // MARK: - Protection and lifecycle

    func testProtectedAndCommittedTokensAreUntouched() {
        var graph = TokenGraph.from(text: "um the the code")
        graph.protect(graph.tokens.filter { $0.rawText == "um" }.map(\.id), as: .hard)
        TranscriptNormalizer.apply(to: &graph)
        XCTAssertTrue(graph.render().contains("um"))

        var committed = TokenGraph.from(text: "um hello")
        committed.promote(committed.tokens.map(\.id), to: .userFinal)
        TranscriptNormalizer.apply(to: &committed)
        XCTAssertEqual(committed.render(), "um hello")
    }

    // MARK: - Engine independence

    func testIdenticalOnBothBuilders() {
        let words = [
            WhisperStreamWord(text: "um", tokens: [1], start: 0, end: 0.2, probability: 0.3),
            WhisperStreamWord(text: " the", tokens: [2], start: 0.2, end: 0.4, probability: 0.9),
            WhisperStreamWord(text: " the", tokens: [3], start: 0.4, end: 0.6, probability: 0.9),
            WhisperStreamWord(text: " code", tokens: [4], start: 0.6, end: 0.9, probability: 0.9),
        ]
        var fromWords = TokenGraph.from(words: words)
        var fromText = TokenGraph.from(text: "um the the code")
        TranscriptNormalizer.apply(to: &fromWords)
        TranscriptNormalizer.apply(to: &fromText)
        XCTAssertEqual(fromWords.render(), fromText.render())
        XCTAssertEqual(fromText.render(), "the code")
    }

    // MARK: - The worked example, deterministic half

    /// Everything M2 owns in the plan's worked example: fillers gone in all three scripts,
    /// aliases canonicalized, and — the rule the example's own prose violates — `сегодня` left
    /// in Russian rather than translated.
    func testWorkedExampleThroughDeterministicPasses() {
        let input = "okay um first send the deployment to chat gpt second update postgress "
                  + "and then כאילו restart the service сегодня"

        var graph = TokenGraph.from(text: input)
        ProtectionDetector.annotate(&graph)
        AliasEngine().apply(to: &graph)
        TranscriptNormalizer.apply(to: &graph)
        let output = graph.render()

        XCTAssertEqual(output, "okay first send the deployment to ChatGPT second update "
                             + "PostgreSQL and then restart the service сегодня")
        XCTAssertFalse(output.contains("כאילו"), "Hebrew filler survived")
        XCTAssertTrue(output.contains("сегодня"), "Russian word was translated or dropped")
        XCTAssertFalse(output.contains("היום"), "translation happened — a flat disqualifier")
    }

    // MARK: - Corpus safety

    func testNormalizationRateOnRealCorpus() throws {
        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 400)
        try XCTSkipIf(fixtures.isEmpty, "No transcriptions in the local history database")

        var words = 0, deletedWords = 0, changedFixtures = 0
        for fixture in fixtures {
            var graph = TokenGraph.from(text: fixture.transcript)
            let before = graph.tokens.filter(\.isWord).count
            words += before
            TranscriptNormalizer.apply(to: &graph)
            let removed = before - graph.tokens.filter(\.isWord).count
            deletedWords += removed
            if removed > 0 { changedFixtures += 1 }
        }
        print(String(format: "Normalizer removed %d of %d words (%.2f%%) across %d/%d fixtures",
                     deletedWords, words, Double(deletedWords) / Double(words) * 100,
                     changedFixtures, fixtures.count))
        XCTAssertLessThan(Double(deletedWords) / Double(words), 0.05,
                          "normalizer is eating real speech")
    }
}
