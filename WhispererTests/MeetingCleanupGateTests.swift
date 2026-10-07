//
//  MeetingCleanupGateTests.swift
//  WhispererTests
//
//  After a Qwen3 meeting the post-recording re-decode is only an upgrade for languages with a
//  measured specialist. These tests pin both halves of that rule: it skips where Qwen3 leads,
//  and it still runs where the specialist wins — per window, not per meeting.
//
//  Pure and fast. Safe to run on every edit.
//

import XCTest
@testable import whisperer

final class MeetingCleanupGateTests: XCTestCase {

    /// Routing off, so `modelsForCurrentConfig` falls back to the full specialist table rather
    /// than a user-specific shortlist. Keeps these assertions independent of local settings.
    private var noRouting: LanguageRoutingConfig { LanguageRoutingConfig.load() }

    // MARK: - Per-language model choice

    func testQwen3NeedsNoSecondDecodeForEnglish() {
        XCTAssertNil(
            RefineModelTable.refineModel(for: .english, liveEngine: .qwen3asr, config: noRouting),
            "Qwen3 leads English — re-decoding it with a general Whisper model is a downgrade")
    }

    func testHebrewKeepsItsSpecialist() {
        XCTAssertEqual(
            RefineModelTable.refineModel(for: .hebrew, liveEngine: .qwen3asr, config: noRouting),
            .ivritLargeTurbo,
            "Hebrew is in specialistsBeatingQwen3, so it still earns a second decode")
    }

    /// Only Qwen3 suppresses the pass. The measurement that justifies skipping is specific to
    /// it, so every other engine keeps the old unconditional behaviour.
    func testOtherEnginesStillRefineEverything() {
        for engine in [BackendType.whisperCpp, .parakeet, .nemotron, .whisperKit, .speechAnalyzer] {
            XCTAssertNotNil(
                RefineModelTable.refineModel(for: .english, liveEngine: engine, config: noRouting),
                "\(engine.rawValue) must still get a cleanup pass")
        }
        XCTAssertEqual(
            RefineModelTable.refineModel(for: .english, liveEngine: .whisperCpp, config: noRouting),
            RefineModelTable.baseline)
    }

    /// Every entry in the table must name a model the app can actually resolve, and must agree
    /// with the long-standing `builtin` table where both have an opinion.
    func testSpecialistTableIsConsistentWithBuiltin() {
        for (language, model) in RefineModelTable.specialistsBeatingQwen3 {
            XCTAssertNotNil(WhisperModel(rawValue: model.rawValue))
            if let builtin = RefineModelTable.builtin[language] {
                XCTAssertEqual(builtin, model,
                               "\(language.rawValue) must not name two different specialists")
            }
        }
    }

    // MARK: - Model set

    func testQwen3ModelSetHoldsOnlySpecialists() {
        let models = RefineModelTable.modelsForCurrentConfig(liveEngine: .qwen3asr)
        for model in models {
            XCTAssertTrue(RefineModelTable.specialistsBeatingQwen3.values.contains(model)
                          || model != RefineModelTable.baseline,
                          "the 547 MB baseline must not be an unconditional Qwen3 meeting download")
        }
    }

    func testOtherEnginesStillIncludeTheBaseline() {
        XCTAssertTrue(
            RefineModelTable.modelsForCurrentConfig(liveEngine: .whisperCpp)
                .contains(RefineModelTable.baseline),
            "the non-Qwen3 path is unchanged and still needs the baseline")
    }

    // MARK: - Plan-level skipping

    /// A monolingual English meeting after Qwen3 plans zero groups, so nothing decodes and no
    /// model loads.
    func testMonolingualEnglishPlansNothingAfterQwen3() {
        let plan = MeetingRefinePlan.build(
            windows: Self.windows(count: 4),
            timeline: .empty,
            baseLanguage: .english,
            downloaded: Set(WhisperModel.allCases),
            availableGB: 16,
            liveEngine: .qwen3asr
        )
        XCTAssertTrue(plan.groups.isEmpty, "no window needs a second decode")
        XCTAssertTrue(plan.modelsToFetch.isEmpty, "and therefore nothing to download")
    }

    func testMonolingualHebrewStillPlansTheSpecialist() {
        let plan = MeetingRefinePlan.build(
            windows: Self.windows(count: 4),
            timeline: .empty,
            baseLanguage: .hebrew,
            downloaded: Set(WhisperModel.allCases),
            availableGB: 16,
            liveEngine: .qwen3asr
        )
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertEqual(plan.groups.first?.model, .ivritLargeTurbo)
        XCTAssertEqual(plan.groups.first?.windows.count, 4)
    }

    /// The same meeting after whisper.cpp still plans a full pass — the gate is Qwen3-specific.
    func testMonolingualEnglishStillPlansAfterWhisper() {
        let plan = MeetingRefinePlan.build(
            windows: Self.windows(count: 4),
            timeline: .empty,
            baseLanguage: .english,
            downloaded: Set(WhisperModel.allCases),
            availableGB: 16,
            liveEngine: .whisperCpp
        )
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertEqual(plan.groups.first?.model, RefineModelTable.baseline)
    }

    // MARK: - Helpers

    private static func windows(count: Int) -> [MeetingRefineWindow] {
        (0..<count).map { index in
            MeetingRefineWindow(
                segmentIndices: [index],
                start: Double(index) * 30,
                end: Double(index + 1) * 30
            )
        }
    }
}
