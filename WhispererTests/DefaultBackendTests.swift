//
//  DefaultBackendTests.swift
//  WhispererTests
//
//  whisper.cpp with Whisperer V3 is the default engine; Qwen3 is a choice in the picker. These
//  tests pin the rules around that: the default never depends on a download, the picker leads
//  with it and hides the engines that are not choices, and stored choices decode unchanged.
//
//  Pure and fast — no model loads. Safe to run on every edit.
//

import AppKit
import XCTest
@testable import whisperer

final class DefaultBackendTests: XCTestCase {

    // MARK: - Default resolution

    /// First launch is whisper.cpp regardless of what is on disk — not Qwen3 even when its
    /// weights are cached, and never Nemotron (live text belongs to the built-in engine).
    func testDefaultIsWhisper() {
        XCTAssertEqual(BackendType.defaultBackend, .whisperCpp)
    }

    /// whisper.cpp specifically: it is the only backend with no Apple Silicon requirement and
    /// the widest language coverage, so it is the one default that always works.
    func testDefaultIsAlwaysAvailable() {
        XCTAssertTrue(BackendType.defaultBackend.isAvailable,
                      "the default backend must be available on every machine")
    }

    /// Whisperer V3 is the model the default engine loads.
    func testDefaultWhisperModelIsWhispererV3() {
        XCTAssertEqual(WhisperModel.largeTurboQ5.displayName, "Whisperer V3")
        XCTAssertTrue(WhisperModel.largeTurboQ5.isRecommended)
        XCTAssertEqual(WhisperModel.primaryOrder.first, .largeTurboQ5)
        XCTAssertEqual(WhisperModel.displayOrder.first, .largeTurboQ5)
    }

    // MARK: - Picker

    /// `selectable` is the picker's source and its order. Whisper leads it. The built-in
    /// engine, the Hebrew sub-backend and Apple Speech never appear in any picker.
    func testWhisperLeadsThePickerAndHiddenEnginesStayHidden() {
        XCTAssertEqual(BackendType.selectable.first, .whisperCpp)
        XCTAssertFalse(BackendType.selectable.contains(.nemotron), "the built-in engine is not a choice")
        XCTAssertFalse(BackendType.selectable.contains(.nemotronHebrew))
        XCTAssertFalse(BackendType.selectable.contains(.speechAnalyzer),
                       "Apple's recognizer already runs as the live preview")
        XCTAssertTrue(BackendType.selectable.contains(.qwen3asr), "Qwen3 stays one tap away")
        XCTAssertTrue(BackendType.selectable.contains(.parakeet))
    }

    /// Every icon the picker draws must be a real SF Symbol — an unknown name renders nothing,
    /// which is how Qwen3's tab lost its icon (`waveform.badge.sparkles` does not exist).
    func testEveryEngineIconExists() {
        for backend in BackendType.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: backend.iconName, accessibilityDescription: nil),
                            "\(backend.rawValue)'s icon \(backend.iconName) is not an SF Symbol")
        }
    }

    /// Same rule for the Whisper model rows.
    func testEveryWhisperModelIconExists() {
        for model in WhisperModel.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: model.categoryIcon, accessibilityDescription: nil),
                            "\(model.displayName)'s icon \(model.categoryIcon) is not an SF Symbol")
        }
    }

    /// Nothing was deleted — the user keeps every engine they had.
    func testOtherBackendsSurvive() {
        for backend in [BackendType.whisperCpp, .qwen3asr, .parakeet, .whisperKit, .speechAnalyzer] {
            XCTAssertTrue(BackendType.allCases.contains(backend),
                          "\(backend.rawValue) must remain decodable")
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

    // MARK: - Meetings

    #if canImport(FluidAudio)
    /// A meeting transcribes with the engine the user dictates with. Qwen3 being on disk must not
    /// pull a Whisper user's meeting onto a second 2.5 GB model.
    @MainActor
    func testMeetingSpeechEngineFollowsTheUsersEngine() {
        let appState = AppState.shared
        let saved = appState.selectedBackendType
        defer { appState.selectedBackendType = saved }

        appState.selectedBackendType = .whisperCpp
        XCTAssertFalse(MeetingEngines.speechEngineIsQwen3)
        appState.selectedBackendType = .qwen3asr
        XCTAssertTrue(MeetingEngines.speechEngineIsQwen3)
    }
    #endif

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

    // MARK: - Measured weak languages

    /// Both Qwen3 and Nemotron lose Hebrew, and both halves are measured.
    /// Qwen3: `Qwen3GateBenchmarkTests`, 2026-10-07 (English 0.039 vs 0.072; Hebrew 0.341 vs 0.183).
    /// Nemotron: 100 FLEURS Hebrew clips, 2026-11-03 (WER 0.436 vs ivrit-v3-turbo's 0.148).
    func testHebrewIsTheOnlyWeakLanguage() {
        XCTAssertEqual(BackendType.qwen3asr.weakLanguages, [.hebrew])
        XCTAssertEqual(BackendType.nemotron.weakLanguages, [.hebrew])
        for backend in BackendType.allCases where backend != .qwen3asr && backend != .nemotron {
            XCTAssertTrue(backend.weakLanguages.isEmpty,
                          "\(backend.rawValue) has no measured weak set — do not invent one")
        }
    }
}
