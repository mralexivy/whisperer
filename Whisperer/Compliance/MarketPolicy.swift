//
//  MarketPolicy.swift
//  Whisperer
//
//  Which market the app is running in, and which features that market allows. The single place that knows
//  about China mainland compliance (docs/exec-plans/china-compliance.md).
//
//  How the market is decided
//  - The China edition (`CHINA_EDITION`, the `AppStoreChina` build configuration, a separate App Store app)
//    is always `.chinaMainland`. Nothing at runtime can change that.
//  - Any other App Store build asks StoreKit for the storefront: `Storefront.countryCode` is ISO 3166-1
//    alpha-3, so mainland China is "CHN". The value is cached for offline launches and re-read when the
//    storefront changes.
//  - The direct-download build has no storefront; it uses the system region (CN) as a conservative rule.
//
//  `allows(_:)` is nonisolated and lock-protected, because services call it from actors and background tasks.
//

import Combine
import Foundation
import os
import StoreKit

nonisolated enum Market: String, Sendable {
    case chinaMainland
    case other
    /// The storefront has not been read yet (first launch, offline). Treated as restricted for anything that
    /// needs a network — those features need a connection anyway, so it costs other users nothing.
    case unknown
}

/// Everything a market can switch off. Each case is something Apple's China declaration or the rules behind it
/// can reach; speech-to-text, Fast Polish, local summaries, MCP and the rest are deliberately not here.
nonisolated enum ComplianceFeature: String, CaseIterable, Sendable {
    /// Free-form chat with an AI about a recording ("Ask AI") — an AI chatbot in Apple's wording.
    case askAIChat
    /// ChatGPT sign-in and OpenAI / Anthropic / Gemini API keys: third-party AI, text leaves the Mac.
    case connectedCloudAI
    /// Claude Code / Codex / Antigravity used as AI providers (they send meeting text to a foreign cloud).
    case cliAIProviders
    /// The terminal agent.
    case commandMode
    /// Voice reshaping / transcription jammer (voice alteration).
    case voiceReshaping
    /// Whisperer Cloud: encrypted sync on servers outside China.
    case cloudSync
    /// Google calendar sign-in (Google services are unreachable in mainland China).
    case googleCalendar

    /// Whether the feature needs the network, so "market unknown" can safely hold it back.
    var needsNetwork: Bool {
        switch self {
        case .connectedCloudAI, .cliAIProviders, .cloudSync, .googleCalendar: return true
        case .askAIChat, .commandMode, .voiceReshaping: return false
        }
    }
}

nonisolated enum MarketPolicy {
    #if CHINA_EDITION
    /// A string only the China edition contains, so the submission checklist can prove which binary it holds.
    static let editionMarker = "whisperer-edition=china-mainland"
    #endif
    private static let state = OSAllocatedUnfairLock<Market?>(initialState: nil)

    /// The market right now.
    static var current: Market {
        #if CHINA_EDITION
        return .chinaMainland
        #else
        #if DEBUG
        if let forced = forcedMarket { return forced }
        #endif
        if let known = state.withLock({ $0 }) { return known }
        return fallback
        #endif
    }

    /// What to assume before StoreKit has answered: the cached storefront, else the system region.
    static var fallback: Market {
        if let cached = UserDefaults.standard.string(forKey: cacheKey).flatMap(Market.init(rawValue:)) { return cached }
        #if APP_STORE
        return .unknown
        #else
        return Locale.current.region?.identifier == "CN" ? .chinaMainland : .other
        #endif
    }

    static func allows(_ feature: ComplianceFeature) -> Bool {
        switch current {
        case .other: return true
        case .chinaMainland: return !restrictedInChina.contains(feature)
        case .unknown: return !feature.needsNetwork || !restrictedInChina.contains(feature)
        }
    }

    /// Why a feature is unavailable, for the line the UI shows in its place; nil when it is allowed.
    static func unavailableReason(_ feature: ComplianceFeature) -> String? {
        guard !allows(feature) else { return nil }
        return current == .unknown
            ? "Checking your App Store region…"
            : "This feature isn't available in your region."
    }

    /// What mainland China switches off. Changing this list is the whole compliance decision.
    static let restrictedInChina: Set<ComplianceFeature> = [
        .askAIChat, .connectedCloudAI, .cliAIProviders, .commandMode, .voiceReshaping, .cloudSync, .googleCalendar,
    ]

    // MARK: Storefront

    static let cacheKey = "compliance.market"

    static func market(forStorefrontCountry code: String?) -> Market {
        guard let code, !code.isEmpty else { return .unknown }
        return code.uppercased() == "CHN" ? .chinaMainland : .other
    }

    static func set(_ market: Market) {
        state.withLock { $0 = market }
        UserDefaults.standard.set(market.rawValue, forKey: cacheKey)
    }

    #if DEBUG
    /// Tests and `WHISPERER_FORCE_MARKET=china|other` (Debug builds only) put the app in a market.
    nonisolated(unsafe) static var testOverride: Market?
    private static var forcedMarket: Market? {
        if let testOverride { return testOverride }
        switch ProcessInfo.processInfo.environment["WHISPERER_FORCE_MARKET"]?.lowercased() {
        case "china", "chn": return .chinaMainland
        case "other": return .other
        default: return nil
        }
    }
    #endif
}

/// Reads the App Store storefront and keeps `MarketPolicy` and the UI current.
@MainActor
final class MarketMonitor: ObservableObject {
    static let shared = MarketMonitor()

    @Published private(set) var market: Market = MarketPolicy.current
    private var task: Task<Void, Never>?

    private init() {}

    /// Launch hook. Safe to call more than once. The China edition needs no storefront.
    func start() {
        #if CHINA_EDITION
        market = .chinaMainland
        Logger.info("Market: China mainland (\(MarketPolicy.editionMarker))", subsystem: .app)
        #else
        guard task == nil else { return }
        #if APP_STORE
        task = Task { [weak self] in
            if let storefront = await Storefront.current { self?.apply(storefront.countryCode) }
            for await storefront in Storefront.updates { self?.apply(storefront.countryCode) }
        }
        #else
        market = MarketPolicy.fallback
        MarketPolicy.set(market)
        Logger.info("Market: \(market.rawValue) (system region)", subsystem: .app)
        #endif
        #endif
    }

    private func apply(_ countryCode: String?) {
        let resolved = MarketPolicy.market(forStorefrontCountry: countryCode)
        MarketPolicy.set(resolved)
        if market != resolved { Logger.info("Market: \(resolved.rawValue) (storefront \(countryCode ?? "?"))", subsystem: .app) }
        market = resolved
    }
}
