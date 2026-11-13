//
//  CloudConfig.swift
//  Whisperer
//
//  Which Whisperer Cloud service this build talks to. StoreKit tells us which App Store environment the app
//  is running in: App Store purchases go to the production service; TestFlight and Xcode purchases are
//  Sandbox and go to the sandbox service (separate data, smaller limits, its own notification URL), so a
//  tester can never touch a real customer's library. Service URLs are Cloud Run's stable addresses.
//

import Foundation
import StoreKit

nonisolated enum CloudEnvironment: Sendable { case production, sandbox }

nonisolated enum CloudConfig {
    static let productionURL = URL(string: "https://whisperer-api-933733507703.us-central1.run.app")!
    static let sandboxURL = URL(string: "https://whisperer-api-sandbox-933733507703.us-central1.run.app")!

    static func baseURL(for environment: CloudEnvironment) -> URL {
        environment == .production ? productionURL : sandboxURL
    }

    /// Decided from the app's own App Store transaction. If it cannot be read (offline, no receipt) a release
    /// build assumes production — the only environment real customers are in — and a debug build assumes sandbox.
    static func detectEnvironment() async -> CloudEnvironment {
        #if DEBUG
        let fallback = CloudEnvironment.sandbox
        #else
        let fallback = CloudEnvironment.production
        #endif
        guard let result = try? await AppTransaction.shared else { return fallback }
        let environment: AppStore.Environment
        switch result {
        case .verified(let transaction): environment = transaction.environment
        case .unverified(let transaction, _): environment = transaction.environment
        }
        return environment == .production ? .production : .sandbox
    }
}
