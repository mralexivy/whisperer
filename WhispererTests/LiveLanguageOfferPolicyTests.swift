//
//  LiveLanguageOfferPolicyTests.swift
//  WhispererTests
//
//  When the "Speaking Russian?" card may appear: both signals must agree, twice, for a language
//  live preview does not already stream in and the user has not silenced.
//

import XCTest
@testable import whisperer

final class LiveLanguageOfferPolicyTests: XCTestCase {

    private let russian = "Я хочу проверить как это работает сегодня"
    private let hebrew = "אני מנסה להעביר לתוצאה מאוד איכותית"
    private let english = "I want to check how this works today"

    func testDetectedLanguageAndScriptAgree() {
        XCTAssertEqual(LiveLanguageOfferPolicy.spokenLanguage(text: russian, detected: .russian), .russian)
        XCTAssertEqual(LiveLanguageOfferPolicy.spokenLanguage(text: hebrew, detected: .hebrew), .hebrew)
    }

    /// Whisper on a short window says `en` while the text came out Cyrillic: not trusted.
    func testDisagreementIsNotASighting() {
        XCTAssertNil(LiveLanguageOfferPolicy.spokenLanguage(text: russian, detected: .english))
        XCTAssertNil(LiveLanguageOfferPolicy.spokenLanguage(text: english, detected: .russian))
    }

    func testTooShortIsIgnored() {
        XCTAssertNil(LiveLanguageOfferPolicy.spokenLanguage(text: "Привет как дела", detected: .russian))
    }

    /// No engine answer (Qwen3 path): a script with one language decides, a shared one does not.
    func testScriptAloneOnlyWhenUnambiguous() {
        let latin = LiveLanguageOfferPolicy.spokenLanguage(text: english, detected: nil)
        XCTAssertNil(latin, "Latin script names dozens of languages")
        let viaCyrillic = LiveLanguageOfferPolicy.spokenLanguage(text: russian, detected: nil)
        let cyrillicLanguages = ScriptAnalyzer.languages(for: .cyrillic)
        XCTAssertEqual(viaCyrillic, cyrillicLanguages.count == 1 ? cyrillicLanguages.first : nil)
    }

    func testOfferNeedsTwoSightings() {
        var policy = LiveLanguageOfferPolicy()
        XCTAssertNil(policy.observe(text: russian, detected: .russian, configured: [.english], silenced: []))
        XCTAssertEqual(policy.observe(text: russian, detected: .russian, configured: [.english], silenced: []), .russian)
    }

    func testCountResetsAfterAnOffer() {
        var policy = LiveLanguageOfferPolicy()
        _ = policy.observe(text: russian, detected: .russian, configured: [.english], silenced: [])
        _ = policy.observe(text: russian, detected: .russian, configured: [.english], silenced: [])
        XCTAssertNil(policy.observe(text: russian, detected: .russian, configured: [.english], silenced: []),
                     "a dismissed offer must not reappear on the very next dictation")
    }

    func testConfiguredLanguageIsNeverOffered() {
        var policy = LiveLanguageOfferPolicy()
        for _ in 0..<5 {
            XCTAssertNil(policy.observe(text: russian, detected: .russian, configured: [.english, .russian], silenced: []))
        }
    }

    func testSilencedLanguageIsNeverOffered() {
        var policy = LiveLanguageOfferPolicy()
        for _ in 0..<5 {
            XCTAssertNil(policy.observe(text: hebrew, detected: .hebrew, configured: [.english], silenced: [.hebrew]))
        }
    }

    func testMisdetectionsDoNotAccumulate() {
        var policy = LiveLanguageOfferPolicy()
        XCTAssertNil(policy.observe(text: english, detected: .russian, configured: [.english], silenced: []))
        XCTAssertNil(policy.observe(text: english, detected: .russian, configured: [.english], silenced: []))
        XCTAssertNil(policy.observe(text: english, detected: .russian, configured: [.english], silenced: []))
        XCTAssertTrue(policy.sightings.isEmpty)
    }

    func testExtrasJoinTheLivePreviewList() {
        let config = LanguageRoutingConfig.default   // single language: English
        let languages = AppState.builtinLanguages(config: config, selected: .english, extras: [.russian, .english])
        XCTAssertEqual(languages, [.english, .russian], "extras append once, after the configured languages")
    }
}
