//
//  ListFormatterMultilingualTests.swift
//  WhispererTests
//
//  `ListFormatter` already ran before the LLM; its marker tables were English-only, so a Hebrew
//  or Russian enumeration stayed a paragraph. These cover the table additions — and, more
//  importantly, the cases that must keep being left alone, since the false-positive guards
//  (`falsePositivePrecedingWords`) are an English word list that cannot catch a Hebrew or
//  Russian misfire.
//

import XCTest
@testable import whisperer

final class ListFormatterMultilingualTests: XCTestCase {

    private func lines(_ text: String) -> [String] {
        ListFormatter.format(text).components(separatedBy: "\n")
    }

    // MARK: - English must not move

    func testEnglishOrdinalListStillFormats() {
        let out = lines("here is the plan. first update the database. "
                      + "second restart the service. third check the logs")
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out[0], "here is the plan:")
        XCTAssertTrue(out[1].hasPrefix("1. "), out[1])
        XCTAssertTrue(out[2].hasPrefix("2. "), out[2])
        XCTAssertTrue(out[3].hasPrefix("3. "), out[3])
    }

    func testEnglishNumberPhraseStillFormats() {
        let out = lines("number one update the database. number two restart the service")
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], "1. Update the database")
        XCTAssertEqual(out[1], "2. Restart the service")
    }

    func testEnglishNonListIsUntouched() {
        let input = "I bought two apples and three oranges at the store"
        XCTAssertEqual(ListFormatter.format(input), input)
    }

    // MARK: - Russian

    func testRussianDiscourseOrdinalsFormat() {
        let out = lines("нужно сделать три вещи. во-первых, обновить базу. "
                      + "во-вторых, перезапустить сервис. в-третьих, проверить логи")
        XCTAssertEqual(out.count, 4, ListFormatter.format("…"))
        XCTAssertEqual(out[0], "нужно сделать три вещи:")
        XCTAssertEqual(out[1], "1. Обновить базу")
        XCTAssertEqual(out[2], "2. Перезапустить сервис")
        XCTAssertEqual(out[3], "3. Проверить логи")
    }

    func testRussianNumberPhraseFormats() {
        let out = lines("номер один обновить базу. номер два перезапустить сервис")
        XCTAssertEqual(out, ["1. Обновить базу", "2. Перезапустить сервис"])
    }

    func testRussianContinuationExtendsAList() {
        let out = lines("во-первых, обновить базу. затем перезапустить сервис")
        XCTAssertEqual(out, ["1. Обновить базу", "2. Перезапустить сервис"])
    }

    /// `второй` is an everyday adjective, not a list marker. Matching it would shred ordinary
    /// speech — which is why the adjectival ordinals are deliberately absent from the table.
    func testRussianAdjectivalOrdinalsAreNotMarkers() {
        let input = "это уже второй раз когда сервис падает и третий за неделю"
        XCTAssertEqual(ListFormatter.format(input), input)
    }

    func testRussianBareCardinalsAreNotMarkers() {
        let input = "я купил два яблока и три апельсина"
        XCTAssertEqual(ListFormatter.format(input), input)
    }

    // MARK: - Hebrew

    func testHebrewDiscourseOrdinalsFormat() {
        let out = lines("צריך לעשות שלושה דברים. ראשית, לעדכן את הבסיס. "
                      + "שנית, להפעיל מחדש. שלישית, לבדוק לוגים")
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out[0], "צריך לעשות שלושה דברים:")
        XCTAssertEqual(out[1], "1. לעדכן את הבסיס")
        XCTAssertEqual(out[2], "2. להפעיל מחדש")
        XCTAssertEqual(out[3], "3. לבדוק לוגים")
    }

    func testHebrewNumberPhraseFormats() {
        let out = lines("מספר אחת לעדכן את הבסיס. מספר שתיים לבדוק לוגים")
        XCTAssertEqual(out, ["1. לעדכן את הבסיס", "2. לבדוק לוגים"])
    }

    /// `ראשון` and `שני` are Sunday and Monday. This is the single most likely false positive in
    /// Hebrew, and the reason only the adverbial forms (`ראשית`, `שנית`) are in the table.
    func testHebrewWeekdaysAreNotMarkers() {
        let input = "נפגשים ביום ראשון בבוקר ואז ביום שני בערב"
        XCTAssertEqual(ListFormatter.format(input), input)
    }

    /// A prefixed word is not a marker: `בראשית` is not `ראשית`.
    func testHebrewPrefixedFormIsNotAMarker() {
        let input = "בראשית ברא אלוהים את השמים ואת הארץ"
        XCTAssertEqual(ListFormatter.format(input), input)
    }

    // MARK: - Corpus safety

    /// The tables grew; the share of real transcripts that get reformatted must not.
    func testFormattingRateOnRealCorpus() throws {
        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 400)
        try XCTSkipIf(fixtures.isEmpty, "No transcriptions in the local history database")

        var changed = 0
        for fixture in fixtures where ListFormatter.format(fixture.transcript) != fixture.transcript {
            changed += 1
        }
        print("ListFormatter reformatted \(changed)/\(fixtures.count) fixtures")
        XCTAssertLessThan(Double(changed) / Double(fixtures.count), 0.15,
                          "list detection is firing on ordinary speech")
    }
}
