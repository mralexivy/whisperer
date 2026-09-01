//
//  CorrectionPopoverTests.swift
//  WhispererTests
//
//  The correction card's pure core: what the user can click, and what the learner is told when
//  they click it.
//

import XCTest
@testable import whisperer

final class CorrectionPromptTokenizerTests: XCTestCase {
    func testKeepsEveryCharacterAndMarksOnlyWordsClickable() {
        let tokens = CorrectionPromptTokenizer.tokenize("we can glyn a lot, right?")
        XCTAssertEqual(CorrectionPromptTokenizer.text(of: tokens), "we can glyn a lot, right?")
        XCTAssertEqual(
            tokens.filter(\.isWord).map(\.text),
            ["we", "can", "glyn", "a", "lot", "right"]
        )
    }

    func testTrimsFromTheFrontAtAWordBoundary() {
        let tokens = CorrectionPromptTokenizer.tokenize("one two three four five", keepingLastWords: 2)
        XCTAssertEqual(CorrectionPromptTokenizer.text(of: tokens), "four five")
        XCTAssertTrue(CorrectionPromptTokenizer.isTruncated("one two three four five", keepingLastWords: 2))
        XCTAssertFalse(CorrectionPromptTokenizer.isTruncated("one two", keepingLastWords: 2))
    }

    func testEmptyForTextWithNoWords() {
        XCTAssertTrue(CorrectionPromptTokenizer.tokenize("").isEmpty)
        XCTAssertTrue(CorrectionPromptTokenizer.tokenize("...  ").isEmpty)
    }

    /// The defect this guards: replacing by string would rewrite both occurrences and hand the
    /// miner a two-substitution diff, which it discards — the user's correction would vanish.
    func testReplacesOnlyTheClickedOccurrenceOfARepeatedWord() throws {
        let text = "the report says the report is late"
        let tokens = CorrectionPromptTokenizer.tokenize(text)
        let secondThe = try XCTUnwrap(tokens.filter { $0.isWord && $0.text == "the" }.last)

        let edited = try XCTUnwrap(CorrectionPromptTokenizer.replacing(
            tokenAt: secondThe.index, with: "our", in: tokens))
        XCTAssertEqual(edited, "the report says our report is late")

        XCTAssertEqual(
            CorrectionLearningCandidateExtractor.extract(from: text, edited: edited),
            [.init(observed: "the", corrected: "our")],
            "one clicked word must mine exactly one candidate"
        )
    }

    func testRejectsReplacementsThatWouldNotMineAsAOneToOneSubstitution() {
        let tokens = CorrectionPromptTokenizer.tokenize("we can glyn a lot")
        let glyn = tokens.first { $0.text == "glyn" }!.index
        let space = tokens.first { !$0.isWord }!.index

        XCTAssertNil(CorrectionPromptTokenizer.replacing(tokenAt: glyn, with: "   ", in: tokens))
        XCTAssertNil(CorrectionPromptTokenizer.replacing(tokenAt: glyn, with: "glyn", in: tokens))
        XCTAssertNil(CorrectionPromptTokenizer.replacing(tokenAt: glyn, with: "the Glean", in: tokens),
                     "a multi-word replacement is a phrase rewrite, not a learnable pair")
        XCTAssertNil(CorrectionPromptTokenizer.replacing(tokenAt: space, with: "Glean", in: tokens))
        XCTAssertNil(CorrectionPromptTokenizer.replacing(tokenAt: 999, with: "Glean", in: tokens))
    }

    func testTrimsSurroundingWhitespaceFromTheReplacement() {
        let tokens = CorrectionPromptTokenizer.tokenize("open glyn now")
        let glyn = tokens.first { $0.text == "glyn" }!.index
        XCTAssertEqual(
            CorrectionPromptTokenizer.replacing(tokenAt: glyn, with: "  Glean ", in: tokens),
            "open Glean now"
        )
    }
}

/// What the card hands the learner, end to end: click a chip, type a word, and follow the result
/// through the same extractor and the same gates the other two sources use.
///
/// Deliberately stops at `CorrectionPromotion.evaluate` rather than calling
/// `CorrectionLearningService.observe`: the funnel behind it writes to the real dictionary store,
/// and a test suite must never touch the user's data. The funnel itself is covered by
/// `CorrectionPromotionTests` and `CorrectionLearnerReplayTests`.
final class CorrectionPopoverCommitPathTests: XCTestCase {
    private func tier(_ transcript: String, fix word: String, to replacement: String,
                      tombstones: Set<String> = []) throws -> CorrectionPromotionTier {
        let tokens = CorrectionPromptTokenizer.tokenize(transcript)
        let index = try XCTUnwrap(tokens.first { $0.isWord && $0.text == word }?.index)
        let edited = try XCTUnwrap(CorrectionPromptTokenizer.replacing(
            tokenAt: index, with: replacement, in: tokens))
        let candidates = CorrectionLearningCandidateExtractor.extract(
            from: CorrectionPromptTokenizer.text(of: tokens), edited: edited)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidate.observed, word)
        XCTAssertEqual(candidate.corrected, replacement)
        return CorrectionPromotion.evaluate(
            observed: candidate.observed, corrected: candidate.corrected, tombstones: tombstones)
    }

    func testAGenuineMishearingIsLearnedOutright() throws {
        XCTAssertEqual(try tier("we can glyn a lot from these numbers", fix: "glyn", to: "Glean"),
                       .automatic)
    }

    /// The card must not launder a thought-rewrite past the gates just because it was explicit.
    /// It becomes the one-click "Always fix" offer instead, which enters as a hand-authored entry.
    func testRewritingAValidEnglishWordIsOnlyEverOffered() throws {
        XCTAssertEqual(try tier("the report says the numbers are late", fix: "report", to: "readout"),
                       .suggestion)
    }

    func testATombstonedWordIsNeitherLearnedNorOffered() throws {
        let tier = try tier("we can glyn a lot", fix: "glyn", to: "Glean", tombstones: ["glyn"])
        guard case .rejected = tier else {
            return XCTFail("a word the user already rejected must not come back, got \(tier)")
        }
    }
}

final class CorrectionPromptGatingTests: XCTestCase {
    private let text = "we can glyn a lot"

    func testNoCardWhenLearningIsOffOrTheHUDBelongsToSomethingElse() {
        XCTAssertNil(CorrectionPrompt.make(for: text, learningEnabled: false, isMeeting: false, isInApp: false))
        XCTAssertNil(CorrectionPrompt.make(for: text, learningEnabled: true, isMeeting: true, isInApp: false))
        XCTAssertNil(CorrectionPrompt.make(for: text, learningEnabled: true, isMeeting: false, isInApp: true))
        XCTAssertNil(CorrectionPrompt.make(for: "…", learningEnabled: true, isMeeting: false, isInApp: false))
    }

    func testCardShowsTheTailOfALongDictation() throws {
        let long = (1...(CorrectionPrompt.maximumWords + 10)).map { "word\($0)" }.joined(separator: " ")
        let prompt = try XCTUnwrap(CorrectionPrompt.make(
            for: long, learningEnabled: true, isMeeting: false, isInApp: false))
        XCTAssertTrue(prompt.isTruncated)
        XCTAssertEqual(prompt.tokens.filter(\.isWord).count, CorrectionPrompt.maximumWords)
        XCTAssertEqual(prompt.tokens.last(where: \.isWord)?.text, "word\(CorrectionPrompt.maximumWords + 10)")
    }
}

final class CorrectionPopoverSuggestionRemovalTests: XCTestCase {
    /// The card learns a pair through `CorrectionLearningService` and never sees a suggestion id,
    /// so it clears the pending suggestion by pair.
    func testRemovesAPendingSuggestionByItsPair() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("suggestions.json")
        let store = CorrectionSuggestionStore(fileURL: url)

        await store.record("the", "our")
        await store.record("sink", "cost")

        await store.remove(observed: "The", corrected: "OUR")
        let remaining = await store.all()
        XCTAssertEqual(remaining.map(\.observed), ["sink"])

        await store.remove(observed: "absent", corrected: "pair")
        let unchanged = await store.all()
        XCTAssertEqual(unchanged.count, 1)

        await store.deleteAll()
    }
}
