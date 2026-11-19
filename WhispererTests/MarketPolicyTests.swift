//
//  MarketPolicyTests.swift
//  WhispererTests
//
//  The China market switch: every regulated feature closes under "CHN", nothing else does, and the storefront
//  code is read the way Apple documents it.
//

import XCTest
@testable import whisperer

@MainActor
final class MarketPolicyTests: XCTestCase {
    override func tearDown() async throws {
        #if DEBUG
        MarketPolicy.testOverride = nil
        #endif
    }

    func testStorefrontCodesMapToMarkets() {
        XCTAssertEqual(MarketPolicy.market(forStorefrontCountry: "CHN"), .chinaMainland)
        XCTAssertEqual(MarketPolicy.market(forStorefrontCountry: "chn"), .chinaMainland)
        XCTAssertEqual(MarketPolicy.market(forStorefrontCountry: "USA"), .other)
        XCTAssertEqual(MarketPolicy.market(forStorefrontCountry: "HKG"), .other, "Hong Kong is not mainland China")
        XCTAssertEqual(MarketPolicy.market(forStorefrontCountry: "TWN"), .other)
        XCTAssertEqual(MarketPolicy.market(forStorefrontCountry: nil), .unknown)
        XCTAssertEqual(MarketPolicy.market(forStorefrontCountry: ""), .unknown)
    }

    func testEveryRegulatedFeatureIsClosedInChinaAndOpenElsewhere() throws {
        #if DEBUG && !CHINA_EDITION
        MarketPolicy.testOverride = .chinaMainland
        for feature in ComplianceFeature.allCases {
            XCTAssertFalse(MarketPolicy.allows(feature), "\(feature) must be off in China")
            XCTAssertNotNil(MarketPolicy.unavailableReason(feature))
        }
        MarketPolicy.testOverride = .other
        for feature in ComplianceFeature.allCases {
            XCTAssertTrue(MarketPolicy.allows(feature), "\(feature) must stay on elsewhere")
            XCTAssertNil(MarketPolicy.unavailableReason(feature))
        }
        #else
        throw XCTSkip("needs a Debug build that is not the China edition")
        #endif
    }

    func testAnUnknownMarketHoldsBackOnlyWhatNeedsTheNetwork() throws {
        #if DEBUG && !CHINA_EDITION
        MarketPolicy.testOverride = .unknown
        for feature in ComplianceFeature.allCases where feature.needsNetwork {
            XCTAssertFalse(MarketPolicy.allows(feature), "\(feature) waits for the storefront")
        }
        for feature in ComplianceFeature.allCases where !feature.needsNetwork {
            XCTAssertTrue(MarketPolicy.allows(feature), "\(feature) works offline while the storefront is unknown")
        }
        #else
        throw XCTSkip("needs a Debug build that is not the China edition")
        #endif
    }

    func testWhatChinaKeepsIsExactlyWhatWasDecided() {
        // The decision (docs/exec-plans/china-compliance.md §4): these are off, everything else is not in the enum.
        XCTAssertEqual(MarketPolicy.restrictedInChina, Set(ComplianceFeature.allCases),
                       "a feature added to ComplianceFeature must be an explicit decision")
        XCTAssertEqual(Set(ComplianceFeature.allCases.map(\.rawValue)),
                       ["askAIChat", "connectedCloudAI", "cliAIProviders", "commandMode", "voiceReshaping", "cloudSync", "googleCalendar", "aiDictationModes"])
    }

    func testConnectedProvidersDisappearInChinaAndCliKindsToo() throws {
        #if DEBUG && !CHINA_EDITION
        MarketPolicy.testOverride = .chinaMainland
        // Third-party AI is off. A model built into macOS is not third-party and is left to macOS (see the provider).
        for id in AIProviderID.allCases where id.leavesTheMac { XCTAssertFalse(id.isAvailableInThisBuild, "\(id) must not be offered in China") }
        let defaults = UserDefaults(suiteName: "market-\(UUID().uuidString)")!
        let store = ConnectedAIStore(defaults: defaults, keychain: KeychainStore(service: "com.ivy.whisperer.tests.\(UUID().uuidString)"))
        XCTAssertEqual(store.availableProviders.filter(\.leavesTheMac), [])
        // The China declaration lists Qwen as the only models: the built-in macOS model is not offered either.
        XCTAssertFalse(AIProviderID.appleIntelligence.isAvailableInThisBuild)
        XCTAssertFalse(LLMModelVariant.available.contains(.appleIntelligence))
        // a provider chosen and consented before the market changed must not come back to life
        store.grantConsent(.openAIKey)
        store.selectedProvider = .openAIKey
        XCTAssertNil(store.activeProviderID)
        XCTAssertNil(store.activeProvider())
        MarketPolicy.testOverride = .other
        XCTAssertFalse(store.availableProviders.isEmpty)
        #else
        throw XCTSkip("needs a Debug build that is not the China edition")
        #endif
    }

    func testAskAIAndPolishEntryPointsAreClosedInChina() async throws {
        #if DEBUG && !CHINA_EDITION
        MarketPolicy.testOverride = .chinaMainland
        for kind in RecordingKind.allCases {
            XCTAssertFalse(RecordingSidebarPolicy.tabs(for: kind).contains(.askAI), "\(kind) must not get an Ask AI tab in China")
            XCTAssertFalse(RecordingSidebarPolicy.tabs(for: kind).isEmpty)
        }
        let answer = await MeetingAIService.shared.ask(question: "What was decided?", meetingID: UUID(), segments: [])
        XCTAssertTrue(answer.text.contains("isn't available in your region"), "the service refuses before any prompt is built")
        XCTAssertFalse(CloudFeature.isAvailable)
        XCTAssertFalse(CalendarAccountProvider.available.contains(.google))
        XCTAssertTrue(CalendarAccountProvider.available.contains(.microsoft))
        MarketPolicy.testOverride = .other
        XCTAssertTrue(RecordingSidebarPolicy.tabs(for: .meeting).contains(.askAI))
        XCTAssertTrue(CalendarAccountProvider.available.contains(.google))
        #else
        throw XCTSkip("needs a Debug build that is not the China edition")
        #endif
    }
}

/// The China edition offers one speech engine and one text model, both Qwen.
final class ChinaEditionLimitsTests: XCTestCase {
    func testChinaEditionOffersOnlyQwen() {
        #if CHINA_EDITION
        XCTAssertEqual(BackendType.selectable, [.qwen3asr])
        // One downloadable model; the model built into macOS is offered on top wherever macOS has it.
        let downloadable = LLMModelVariant.available.filter { $0 != .appleIntelligence }
        XCTAssertEqual(downloadable.count, 1)
        XCTAssertEqual(downloadable.first, LLMModelVariant.marketDefault)
        #else
        XCTAssertFalse(MarketPolicy.isChinaEdition)
        XCTAssertGreaterThan(BackendType.selectable.count, 1)
        #endif
    }
}

/// The China edition has no free-form AI rewrite modes: no sidebar page, and the model cannot be switched on.
@MainActor
final class ChinaAIModesTests: XCTestCase {
    override func tearDown() async throws {
        #if DEBUG
        MarketPolicy.testOverride = nil
        #endif
    }

    func testAIModesPageAndSwitchAreClosedInChina() throws {
        #if DEBUG
        MarketPolicy.testOverride = .chinaMainland
        XCTAssertFalse(HistorySidebarItem.visibleItems.contains(.aiModes))
        let state = AppState.shared
        let before = state.llmEnabled
        defer { state.llmEnabled = before }
        state.llmEnabled = true
        XCTAssertFalse(state.llmEnabled)

        MarketPolicy.testOverride = .other
        XCTAssertTrue(HistorySidebarItem.visibleItems.contains(.aiModes))
        #else
        throw XCTSkip("needs the Debug market override")
        #endif
    }
}
