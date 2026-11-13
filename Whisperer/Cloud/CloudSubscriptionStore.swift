//
//  CloudSubscriptionStore.swift
//  Whisperer
//
//  StoreKit 2 for Whisperer Cloud, the way Apple prescribes it: one object owns every purchase path;
//  `Transaction.updates` is listened to from launch (renewals, refunds, Ask-to-Buy approvals and purchases
//  made on another Mac arrive there, not from `purchase()`); every transaction is verified before it
//  counts and finished after; subscription state comes from `Product.SubscriptionInfo.status`; Restore is
//  `AppStore.sync()`. The `appAccountToken` rides on every purchase so the server can tie the subscription
//  to the library without Apple ID data.
//
//  StoreKit proves the *device* holds an entitlement. The server re-verifies the signed transaction
//  (`jwsRepresentation`) against Apple's root before it believes anything.
//

import Foundation
import StoreKit
import Combine

enum CloudPurchaseOutcome: Equatable {
    case purchased
    case pending      // Ask to Buy / SCA: completes later through Transaction.updates
    case cancelled
}

@MainActor
final class CloudSubscriptionStore: ObservableObject {
    static let shared = CloudSubscriptionStore()

    @Published private(set) var products: [Product] = []
    @Published private(set) var access: CloudAccess = .none
    /// The plan the user holds (or last held).
    @Published private(set) var currentPlan: CloudProduct?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var autoRenews: Bool?
    @Published private(set) var isWorking = false
    @Published private(set) var isPendingApproval = false
    @Published var errorMessage: String?

    private var updatesTask: Task<Void, Never>?
    private var started = false

    init() {}

    deinit { updatesTask?.cancel() }

    /// Call once at launch, only when `CloudFeature.isAvailable`. Apple requires the updates listener to be
    /// running from launch or transactions that complete while the app is closed are missed.
    func start() {
        guard !started else { return }
        started = true
        updatesTask = Task.detached(priority: .utility) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.handle(update: result)
            }
        }
        Task { [weak self] in
            await self?.loadProducts()
            await self?.refreshStatus()
        }
    }

    // MARK: Products

    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: CloudProduct.launchIDs)
            products = loaded.sorted { CloudProduct.displayOrder($0.id, $1.id) }
            let missing = Set(CloudProduct.launchIDs).subtracting(loaded.map(\.id))
            if !missing.isEmpty {
                Logger.warning("Cloud: \(missing.count) product(s) not returned by the App Store: \(missing.sorted())", subsystem: .app)
            }
        } catch {
            Logger.error("Cloud: loading products failed: \(error.localizedDescription)", subsystem: .app)
            errorMessage = "Plans could not be loaded. Check your connection and try again."
        }
    }

    // MARK: Purchase

    @discardableResult
    func purchase(_ product: Product) async -> CloudPurchaseOutcome? {
        guard !isWorking else { return nil }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        var options: Set<Product.PurchaseOption> = []
        if let token = CloudAccountToken.current() { options.insert(.appAccountToken(token)) }
        do {
            switch try await product.purchase(options: options) {
            case .success(let verification):
                let transaction = try Self.verified(verification)
                await transaction.finish()
                isPendingApproval = false
                await refreshStatus()
                Logger.info("Cloud: purchased \(transaction.productID)", subsystem: .app)
                return .purchased
            case .pending:
                isPendingApproval = true
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return nil
            }
        } catch {
            Logger.error("Cloud: purchase failed: \(error.localizedDescription)", subsystem: .app)
            errorMessage = "The purchase could not be completed. You have not been charged."
            return nil
        }
    }

    /// Restore Purchases (App Review requires it): ask the App Store to resync, then re-read entitlements.
    func restore() async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await AppStore.sync()
            await refreshStatus()
        } catch {
            Logger.error("Cloud: restore failed: \(error.localizedDescription)", subsystem: .app)
            errorMessage = "Purchases could not be restored. Try again in a moment."
        }
    }

    // MARK: State

    /// Recomputes `access` from the App Store's subscription status for the group.
    func refreshStatus() async {
        if products.isEmpty { await loadProducts() }
        guard let anyProduct = products.first,
              let statuses = try? await anyProduct.subscription?.status else {
            return
        }
        var states: [CloudAccess] = []
        var best: (access: CloudAccess, status: Product.SubscriptionInfo.Status)?
        for status in statuses {
            guard case .verified(let transaction) = status.transaction,
                  CloudProduct(id: transaction.productID) != nil else { continue }
            let access = CloudAccess(status.state)
            states.append(access)
            if best == nil || CloudAccess.strongest([best!.access, access]) == access && access != best!.access {
                best = (access, status)
            }
        }
        access = CloudAccess.strongest(states)
        if access == .active || access == .grace { isPendingApproval = false }
        guard let best, case .verified(let transaction) = best.status.transaction else {
            currentPlan = nil; expiresAt = nil; autoRenews = nil
            return
        }
        currentPlan = CloudProduct(id: transaction.productID)
        expiresAt = transaction.expirationDate
        if case .verified(let renewal) = best.status.renewalInfo { autoRenews = renewal.willAutoRenew } else { autoRenews = nil }
    }

    /// The signed transaction the server verifies against Apple's root: the live entitlement with the
    /// latest expiry. Nil when there is none.
    func currentTransactionJWS() async -> String? {
        var newest: (date: Date, jws: String)?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, CloudProduct(id: transaction.productID) != nil else { continue }
            let date = transaction.expirationDate ?? .distantPast
            if newest == nil || date > newest!.date { newest = (date, result.jwsRepresentation) }
        }
        return newest?.jws
    }

    // MARK: Updates

    private func handle(update result: VerificationResult<Transaction>) async {
        do {
            let transaction = try Self.verified(result)
            guard CloudProduct(id: transaction.productID) != nil else { return } // Pro Pack etc. have their own store
            await transaction.finish()
            await refreshStatus()
            Logger.info("Cloud: transaction update for \(transaction.productID)", subsystem: .app)
        } catch {
            Logger.error("Cloud: ignoring a transaction that failed verification", subsystem: .app)
        }
    }

    nonisolated static func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified: throw StoreError.verificationFailed
        }
    }
}
