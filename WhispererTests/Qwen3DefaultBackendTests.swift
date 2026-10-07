//
//  Qwen3DefaultBackendTests.swift
//  WhispererTests
//
//  Qwen3 is the default engine. These tests pin the three rules that make that safe:
//  it is only the default once its weights exist, it is visible in the picker, and an
//  explicit user choice is never overwritten.
//
//  Pure and fast — no model loads. Safe to run on every edit.
//

import XCTest
@testable import whisperer

final class Qwen3DefaultBackendTests: XCTestCase {

    // MARK: - Default resolution

    /// The whole point of `defaultBackend`: never hand a new user a backend with no weights.
    /// Qwen3 is a 2.5 GB download, so until it is cached the default must be whisper.cpp.
    func testDefaultRequiresBothAvailabilityAndCachedWeights() {
        let resolved = BackendType.defaultBackend
        if BackendType.qwen3asr.isAvailable && Qwen3ASRBridge.isModelCached() {
            XCTAssertEqual(resolved, .qwen3asr,
                           "Qwen3 is available and cached — it must be the default")
        } else {
            XCTAssertEqual(resolved, .whisperCpp,
                           "Without cached Qwen3 weights the default must fall back to whisper.cpp")
        }
    }

    /// whisper.cpp specifically, not Parakeet: it is the only backend with no Apple Silicon
    /// requirement and the widest language coverage, so it is the one fallback that always works.
    func testFallbackIsAlwaysAvailable() {
        XCTAssertTrue(BackendType.whisperCpp.isAvailable,
                      "the fallback backend must be available on every machine")
    }

    // MARK: - Picker

    /// `allCases` is the picker's source and its order. Qwen3 must lead it and must not be
    /// filtered out the way the hidden sub-backends are.
    func testQwen3LeadsThePicker() {
        XCTAssertEqual(BackendType.allCases.first, .qwen3asr)

        // The filter the Models tab applies — hidden sub-backends only.
        let visible = BackendType.allCases.filter { $0 != .nemotron && $0 != .nemotronHebrew }
        XCTAssertTrue(visible.contains(.qwen3asr), "Qwen3 must be selectable")
        XCTAssertTrue(visible.contains(.whisperCpp), "the fallback must stay selectable")
        XCTAssertTrue(visible.contains(.parakeet))
        XCTAssertTrue(visible.contains(.speechAnalyzer))
    }

    /// Nothing was deleted — the user keeps every engine they had.
    func testOtherBackendsSurvive() {
        for backend in [BackendType.whisperCpp, .parakeet, .whisperKit, .speechAnalyzer] {
            XCTAssertTrue(BackendType.allCases.contains(backend),
                          "\(backend.rawValue) must remain selectable")
        }
    }

    /// Raw values are persisted in `UserDefaults` under `selectedBackendType`. Reordering the
    /// enum must not change them, or every existing user's stored choice decodes to nil and
    /// silently resets to the default.
    func testRawValuesAreStableAcrossTheReorder() {
        XCTAssertEqual(BackendType.qwen3asr.rawValue, "Qwen3ASR")
        XCTAssertEqual(BackendType.whisperCpp.rawValue, "whisper.cpp")
        XCTAssertEqual(BackendType.parakeet.rawValue, "Parakeet")
        XCTAssertEqual(BackendType.nemotron.rawValue, "Nemotron")
        XCTAssertEqual(BackendType.nemotronHebrew.rawValue, "NemotronHebrew")
        XCTAssertEqual(BackendType.speechAnalyzer.rawValue, "Apple Speech")
        XCTAssertEqual(BackendType.whisperKit.rawValue, "WhisperKit")

        for backend in BackendType.allCases {
            XCTAssertEqual(BackendType(rawValue: backend.rawValue), backend,
                           "\(backend.rawValue) must round-trip through UserDefaults")
        }
    }

    // MARK: - Native language detection

    /// Qwen3 prints its own `language <Name>` header, so running `LanguageRouter` + `ModelPool`
    /// alongside it would load a Whisper model to answer a question already answered.
    func testQwen3DetectsLanguageNatively() {
        XCTAssertTrue(BackendType.qwen3asr.detectsLanguageNatively)
        XCTAssertTrue(BackendType.parakeet.detectsLanguageNatively)
        XCTAssertTrue(BackendType.nemotron.detectsLanguageNatively)
        XCTAssertFalse(BackendType.whisperCpp.detectsLanguageNatively,
                       "whisper.cpp is exactly the backend the routing pipeline exists for")
        XCTAssertFalse(BackendType.whisperKit.detectsLanguageNatively)
    }

    /// Every language the engine can be forced into must be one it can also name back, or the
    /// detected code and the forced code describe different sets.
    func testForcedLanguagesAndReportedLanguagesAgree() {
        let forced = Set(Qwen3ASREngine.forcedLanguageTokens.keys)
        let reported = Set(Qwen3ASREngine.languageCodes.values)
        XCTAssertEqual(forced, reported,
                       "forcedLanguageTokens and languageCodes must cover the same languages")
        XCTAssertEqual(forced.count, 31,
                       "settingsSubtitle advertises 31 languages — update both together")
    }

    // MARK: - Upgrade offer

    func testOfferOnlyWhenAvailableUncachedAndNotDismissed() {
        XCTAssertTrue(Qwen3UpgradeOffer.shouldOffer(isAvailable: true, isCached: false, isDismissed: false))
        XCTAssertFalse(Qwen3UpgradeOffer.shouldOffer(isAvailable: true, isCached: true, isDismissed: false),
                       "nothing to offer once the model is on disk")
        XCTAssertFalse(Qwen3UpgradeOffer.shouldOffer(isAvailable: true, isCached: false, isDismissed: true),
                       "an offer declined once must not come back")
        XCTAssertFalse(Qwen3UpgradeOffer.shouldOffer(isAvailable: false, isCached: false, isDismissed: false),
                       "never offer a download the machine cannot run")
    }

    func testNoOfferForLanguagesQwen3IsWeakAt() {
        XCTAssertFalse(
            Qwen3UpgradeOffer.shouldOffer(isAvailable: true, isCached: false, isDismissed: false,
                                          language: .hebrew),
            "2.5 GB that makes Hebrew transcripts worse is not an upgrade")
        XCTAssertTrue(
            Qwen3UpgradeOffer.shouldOffer(isAvailable: true, isCached: false, isDismissed: false,
                                          language: .english))
    }

    // MARK: - Measured weak languages

    /// Qwen3 wins overall and loses Hebrew. Both halves are measured
    /// (`Qwen3GateBenchmarkTests`, 2026-10-07: English 0.039 vs 0.072; Hebrew 0.341 vs 0.183).
    func testHebrewIsTheOnlyWeakLanguage() {
        XCTAssertEqual(BackendType.qwen3asr.weakLanguages, [.hebrew])
        for backend in BackendType.allCases where backend != .qwen3asr {
            XCTAssertTrue(backend.weakLanguages.isEmpty,
                          "\(backend.rawValue) has no measured weak set — do not invent one")
        }
    }

    /// A Hebrew user must not be defaulted onto the engine that garbles Hebrew, even on a
    /// machine where Qwen3 is available and cached.
    func testHebrewUsersDefaultToWhisper() {
        XCTAssertEqual(BackendType.defaultBackend(for: .hebrew), .whisperCpp)
    }

    func testNonWeakLanguagesFollowTheGlobalDefault() {
        for language in [TranscriptionLanguage.english, .auto, .russian, .german] {
            XCTAssertEqual(BackendType.defaultBackend(for: language), BackendType.defaultBackend,
                           "\(language.rawValue) must follow the global default")
        }
    }

    /// Weak is not unsupported. Qwen3 still produces Hebrew, and a user who explicitly picks it
    /// must not be blocked or warned off by the language-support check.
    func testWeakLanguagesAreStillSupported() {
        XCTAssertTrue(BackendType.qwen3asr.supportsLanguage(.hebrew),
                      "weakLanguages biases the default; it must not revoke support")
    }
}
