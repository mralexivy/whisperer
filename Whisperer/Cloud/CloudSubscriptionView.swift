//
//  CloudSubscriptionView.swift
//  Whisperer
//
//  The purchase surface: Apple's own `SubscriptionStoreView`, so prices, intro offers, the terms and
//  privacy links from App Store Connect and the localised legal text are Apple's, not ours. We add the
//  appAccountToken to each purchase, a Restore button, and refresh our state when a purchase completes.
//  Reached only from the Cloud row, which exists only when `CloudFeature.isAvailable`.
//

import SwiftUI
import StoreKit

struct CloudSubscriptionView: View {
    @ObservedObject var store: CloudSubscriptionStore = .shared
    /// The Cloud panel explains the offer itself, so it hides this marketing header.
    var showsHeader = true
    /// Runs after a completed purchase, so the account state machine can carry on (create the account).
    var onPurchased: (@MainActor () async -> Void)?

    var body: some View {
        SubscriptionStoreView(productIDs: CloudProduct.launchIDs) {
            if showsHeader {
                VStack(spacing: 8) {
                    Image(systemName: "icloud.and.arrow.up.fill").font(.system(size: 34)).foregroundColor(.purple)
                    Text("Whisperer Cloud").font(.system(size: 22, weight: .light))
                    Text("End-to-end encrypted history, synced across your Macs.")
                        .font(.system(size: 13)).multilineTextAlignment(.center).foregroundColor(.white.opacity(0.7))
                }
                .padding(.vertical, 12)
            }
        }
        .subscriptionStoreControlStyle(.picker)
        .subscriptionStoreButtonLabel(.multiline)
        .storeButton(.visible, for: .restorePurchases)
        .storeButton(.visible, for: .policies)
        .inAppPurchaseOptions { _ in
            guard let token = CloudAccountToken.current() else { return [] }
            return [.appAccountToken(token)]
        }
        .onInAppPurchaseCompletion { _, result in
            if case .success(.success(let verification)) = result,
               case .verified(let transaction) = verification {
                await transaction.finish()
            }
            await store.refreshStatus()
            await onPurchased?()
        }
        .task { await store.refreshStatus() }
    }
}
