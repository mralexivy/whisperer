//
//  CloudAccess.swift
//  Whisperer
//
//  What the user's subscription lets them do, decided from StoreKit's renewal state. Pure, so every state
//  is tested without the App Store. The server independently decides the same thing from Apple's own
//  records (docs/exec-plans/cloud-sync-implementation.md §6.4); this is the app's local, optimistic view.
//

import Foundation
import StoreKit

nonisolated enum CloudAccess: Equatable, Sendable {
    case none          // never subscribed
    case active        // paid up (auto-renew may be off: access runs to the expiry)
    case grace         // billing problem inside Apple's grace period: still full access
    case retry         // Apple is retrying the charge: read-only
    case expired       // lapsed: read-only, then deletion (the Cloud page shows the date)
    case revoked       // refunded or revoked by Apple: read-only

    var canWrite: Bool { self == .active || self == .grace }
    var canRead: Bool { self == .active || self == .grace || self == .retry || self == .expired || self == .revoked }
    var isPaying: Bool { canWrite }

    /// Preference when a group reports several statuses (e.g. an old, expired one and a current one).
    fileprivate var rank: Int {
        switch self {
        case .active: return 5
        case .grace: return 4
        case .retry: return 3
        case .expired: return 2
        case .revoked: return 1
        case .none: return 0
        }
    }

    init(_ state: Product.SubscriptionInfo.RenewalState) {
        switch state {
        case .subscribed: self = .active
        case .inGracePeriod: self = .grace
        case .inBillingRetryPeriod: self = .retry
        case .expired: self = .expired
        case .revoked: self = .revoked
        default: self = .none
        }
    }

    /// The best of several states.
    static func strongest(_ all: [CloudAccess]) -> CloudAccess {
        all.max { $0.rank < $1.rank } ?? .none
    }
}
