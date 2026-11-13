//
//  CloudPlan.swift
//  Whisperer
//
//  The Whisperer Cloud catalogue as the app knows it: four tiers in one subscription group, each monthly
//  or yearly. Product ids and limits mirror server/internal/quota (the server is the authority; these
//  numbers only label the UI and order the choices).
//

import Foundation

nonisolated enum CloudTier: String, CaseIterable, Comparable, Sendable {
    case starter, standard, large, max

    var title: String {
        switch self {
        case .starter: return "Starter"
        case .standard: return "Standard"
        case .large: return "Large"
        case .max: return "Max"
        }
    }

    var storageGB: Int {
        switch self {
        case .starter: return 5
        case .standard: return 25
        case .large: return 100
        case .max: return 500
        }
    }

    /// How many Macs may be signed in at once.
    var deviceLimit: Int {
        switch self {
        case .starter: return 2
        case .standard: return 4
        case .large, .max: return 8
        }
    }

    static func < (a: CloudTier, b: CloudTier) -> Bool { a.storageGB < b.storageGB }
}

nonisolated enum CloudPeriod: String, Sendable {
    case monthly, yearly
}

/// One sellable product: `com.ivy.whisperer.cloud.<tier>.<monthly|yearly>`.
nonisolated struct CloudProduct: Equatable, Hashable, Sendable {
    static let prefix = "com.ivy.whisperer.cloud."

    let tier: CloudTier
    let period: CloudPeriod

    var id: String { "\(Self.prefix)\(tier.rawValue).\(period.rawValue)" }

    init(tier: CloudTier, period: CloudPeriod) { self.tier = tier; self.period = period }

    /// Nil for any id that is not a Whisperer Cloud product (a Pro Pack id, a typo, another app's).
    init?(id: String) {
        guard id.hasPrefix(Self.prefix) else { return nil }
        let parts = id.dropFirst(Self.prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let tier = CloudTier(rawValue: String(parts[0])),
              let period = CloudPeriod(rawValue: String(parts[1])) else { return nil }
        self.init(tier: tier, period: period)
    }

    /// What goes on sale at launch. Max is defined in the server so it can be added without an update, but is
    /// not offered yet.
    static let launchTiers: [CloudTier] = [.starter, .standard, .large]

    /// Product ids in display order: by size, monthly before yearly.
    static let launchIDs: [String] = launchTiers.flatMap { tier in
        [CloudPeriod.monthly, .yearly].map { CloudProduct(tier: tier, period: $0).id }
    }

    /// Sorts product ids the way the store shows them; unknown ids go last.
    static func displayOrder(_ a: String, _ b: String) -> Bool {
        guard let x = CloudProduct(id: a) else { return false }
        guard let y = CloudProduct(id: b) else { return true }
        return x.tier != y.tier ? x.tier < y.tier : (x.period == .monthly && y.period == .yearly)
    }
}
