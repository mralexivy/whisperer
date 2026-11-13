//
//  CloudFeature.swift
//  Whisperer
//
//  The single switch for Whisperer Cloud. The feature is a StoreKit subscription, so it exists only in
//  the Mac App Store build; the direct-download build has no way to sell or verify it and never shows it.
//  `isLive` stays false until the service is deployed and the products are on sale — flipping it is the
//  release step (docs/exec-plans/cloud-sync-implementation.md, stage J). Nothing else decides visibility.
//

import Foundation

nonisolated enum CloudFeature {
    /// Compiled in only for the App Store build.
    static let isStoreBuild: Bool = {
        #if APP_STORE
        return true
        #else
        return false
        #endif
    }()

    /// Flip to true when the service is deployed and the subscriptions are approved for sale.
    static let isLive = false

    /// Whether the app may show, start or sync anything Cloud. Overridable in tests.
    static var isAvailable: Bool {
        #if DEBUG
        if let forced = testOverride { return forced }
        #endif
        return isStoreBuild && isLive
    }

    #if DEBUG
    /// Lets click and render tests put the Cloud UI on screen. Compiled out of Release builds, so the
    /// shipped app cannot be switched on this way.
    nonisolated(unsafe) static var testOverride: Bool?
    #endif
}
