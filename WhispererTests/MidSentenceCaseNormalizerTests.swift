//
//  MidSentenceCaseNormalizerTests.swift
//  WhispererTests
//
//  Regression coverage for random capitals in live ASR hypotheses.
//

import XCTest
@testable import whisperer

final class MidSentenceCaseNormalizerTests: XCTestCase {

    func testLowersOrdinaryInteriorWordsFromReportedPreview() {
        let input = "And they Are not switching because they think That they will Get better."
        XCTAssertEqual(
            MidSentenceCaseNormalizer.normalize(text: input),
            "And they are not switching because they think that they will get better.")
    }

    func testPreservesSentenceStartsAcronymsIdentifiersAndDictionaryProducts() {
        let input = "We asked Roy to use Python with the MCP API. Then call loadModel with Claude Opus."
        let terms: Set<String> = ["Python", "Claude Opus"]
        XCTAssertEqual(MidSentenceCaseNormalizer.normalize(text: input,
                                                            dictionaryTerms: terms), input)
    }

    func testPreservesAnIsolatedUnknownTitleCaseWord() {
        // An unknown title-cased token may be a person or a niche product. Without the stronger
        // burst signal, missing one cosmetic cleanup is safer than lowercasing a proper noun.
        let input = "we should discuss Zorblax with the team"
        XCTAssertEqual(MidSentenceCaseNormalizer.normalize(text: input), input)
    }

    func testBurstSignalCleansCyrillicWithoutAnEnglishDictionary() {
        let input = "Это очень Странно потому Что многие Слова написаны Так"
        XCTAssertEqual(
            MidSentenceCaseNormalizer.normalize(text: input),
            "Это очень странно потому что многие слова написаны так")
    }

    func testRussianSingleInteriorCapitalUsesRussianLexicalEvidence() {
        XCTAssertEqual(
            MidSentenceCaseNormalizer.normalize(text: "Мы сегодня Думаем о выпуске"),
            "Мы сегодня думаем о выпуске")
    }

    func testRussianProperNounsCanBeProtectedLikeLatinTerms() {
        let text = "Мы говорили с Александром в Москве"
        XCTAssertEqual(
            MidSentenceCaseNormalizer.normalize(
                text: text,
                dictionaryTerms: ["Александром", "Москве"]),
            text)
    }

    func testEuropeanLanguagesDoNotDependOnEnglishTags() {
        XCTAssertEqual(
            MidSentenceCaseNormalizer.normalize(text: "Nous Avons terminé le travail"),
            "Nous avons terminé le travail")
        XCTAssertEqual(
            MidSentenceCaseNormalizer.normalize(text: "Wir Haben die Änderung geprüft"),
            "Wir haben die Änderung geprüft")
    }

    func testHebrewIsByteIdenticalAndMixedTechnicalTermsStayCased() {
        let hebrew = "אנחנו חושבים שזה חשוב ונבדוק את זה מחר"
        XCTAssertEqual(MidSentenceCaseNormalizer.normalize(text: hebrew), hebrew)

        let mixed = "אנחנו משתמשים ב Python וב API במערכת"
        XCTAssertEqual(
            MidSentenceCaseNormalizer.normalize(text: mixed,
                                                dictionaryTerms: ["Python", "API"]),
            mixed)
    }

    func testDeterministicPolisherUsesTheSameRule() {
        let editor = DeterministicPolisher(formatsLists: false,
                                           terminatesUtteranceEnd: false,
                                           splitsParagraphs: false)
        XCTAssertEqual(editor.polish(text: "We Need to agree how We measure It").text,
                       "We need to agree how we measure it")
    }
}
