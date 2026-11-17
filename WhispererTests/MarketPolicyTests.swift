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
                       ["askAIChat", "connectedCloudAI", "cliAIProviders", "commandMode", "voiceReshaping", "cloudSync", "googleCalendar"])
    }

    func testConnectedProvidersDisappearInChinaAndCliKindsToo() throws {
        #if DEBUG && !CHINA_EDITION
        MarketPolicy.testOverride = .chinaMainland
        for id in AIProviderID.allCases { XCTAssertFalse(id.isAvailableInThisBuild, "\(id) must not be offered in China") }
        let defaults = UserDefaults(suiteName: "market-\(UUID().uuidString)")!
        let store = ConnectedAIStore(defaults: defaults, keychain: KeychainStore(service: "com.ivy.whisperer.tests.\(UUID().uuidString)"))
        XCTAssertTrue(store.availableProviders.isEmpty)
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
        XCTAssertEqual(LLMModelVariant.available.count, 1)
        XCTAssertEqual(LLMModelVariant.available.first, LLMModelVariant.marketDefault)
        #else
        XCTAssertFalse(MarketPolicy.isChinaEdition)
        XCTAssertGreaterThan(BackendType.selectable.count, 1)
        #endif
    }
}
