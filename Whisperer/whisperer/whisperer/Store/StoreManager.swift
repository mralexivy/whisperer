//
//  StoreManager.swift
//  Whisperer
//
//  StoreKit 2 integration for Pro Pack in-app purchase
//  Manages product loading, purchasing, and entitlement verification
//

import Foundation
import StoreKit
import Combine

enum StoreError: Error {
    case verificationFailed
    case productNotFound
    case purchaseCancelled
    case purchasePending
    case unknown

    var localizedDescription: String {
        switch self {
        case .verificationFailed:
            return "Purchase verification failed. Please contact support."
        case .productNotFound:
            return "Pro Pack product not found. Please try again later."
        case .purchaseCancelled:
            return "Purchase was cancelled."
        case .purchasePending:
            return "Purchase is pending approval."
        case .unknown:
            return "An unknown error occurred."
        }
    }
}

@MainActor
class StoreManager: ObservableObject {
    static let shared = StoreManager()

    // Published properties
    @Published var isPro: Bool = false
    @Published var products: [Product] = []
    @Published var isPurchasing: Bool = false
    @Published var errorMessage: String?

    // Pro Pack product ID
    private let productId = "com.ivy.whisperer.propack"

    // UserDefaults key for caching pro status
    private let proStatusKey = "whisperer_pro_status"

    // Transaction update listener task
    private var transactionUpdateTask: Task<Void, Never>?

    private init() {
        // Load cached pro status
        isPro = UserDefaults.standard.bool(forKey: proStatusKey)

        // Start listening for transaction updates
        transactionUpdateTask = listenForTransactions()
    }

    deinit {
        transactionUpdateTask?.cancel()
    }

    // MARK: - Public API

    /// Load available products from the App Store
    func loadProducts() async {
        do {
            let loadedProducts = try await Product.products(for: [productId])
            products = loadedProducts

            if loadedProducts.isEmpty {
                Logger.warning("No products found for ID: \(productId)", subsystem: .app)
            } else {
                Logger.info("Loaded \(loadedProducts.count) product(s)", subsystem: .app)
            }
        } catch {
            Logger.error("Failed to load products: \(error.localizedDescription)", subsystem: .app)
            errorMessage = "Failed to load Pro Pack. Please check your internet connection."
        }
    }

    /// Purchase the Pro Pack
    func purchase() async throws {
        guard let product = products.first else {
            throw StoreError.productNotFound
        }

        isPurchasing = true
        errorMessage = nil

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                // Verify the transaction
                let transaction = try checkVerified(verification)

                // Update pro status
                isPro = true
                saveProStatus(true)

                // Finish the transaction
                await transaction.finish()

                Logger.info("✅ Pro Pack purchased successfully", subsystem: .app)

            case .userCancelled:
                throw StoreError.purchaseCancelled

            case .pending:
                throw StoreError.purchasePending

            @unknown default:
                throw StoreError.unknown
            }
        } catch {
            Logger.error("Purchase failed: \(error.localizedDescription)", subsystem: .app)
            errorMessage = (error as? StoreError)?.localizedDescription ?? error.localizedDescription
            throw error
        }

        isPurchasing = false
    }

    /// Restore previous purchases
    func restorePurchases() async {
        Logger.info("Restoring purchases...", subsystem: .app)

        do {
            try await AppStore.sync()
            await checkPurchased()
        } catch {
            Logger.error("Failed to restore purchases: \(error.localizedDescription)", subsystem: .app)
            errorMessage = "Failed to restore purchases. Please try again."
        }
    }

    /// Check if user has already purchased Pro Pack
    func checkPurchased() async {
        var hasPro = false

        // Iterate through all transactions
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                if transaction.productID == productId {
                    hasPro = true
                    break
                }
            }
        }

        isPro = hasPro
        saveProStatus(hasPro)

        if hasPro {
            Logger.info("✅ Pro Pack entitlement verified", subsystem: .app)
        } else {
            Logger.info("ℹ️ No Pro Pack entitlement found", subsystem: .app)
        }
    }

    // MARK: - Private Helpers

    /// Listen for transaction updates
    private func listenForTransactions() -> Task<Void, Never> {
        let productId = self.productId
        return Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try self.checkVerified(result)

                    // Update pro status
                    await MainActor.run {
                        if transaction.productID == productId {
                            self.isPro = true
                            self.saveProStatus(true)
                            Logger.info("Transaction update: Pro Pack activated", subsystem: .app)
                        }
                    }

                    // Finish the transaction
                    await transaction.finish()
                } catch {
                    await MainActor.run {
                        Logger.error("Transaction verification failed: \(error)", subsystem: .app)
                    }
                }
            }
        }
    }

    /// Verify that a transaction result is valid
    private nonisolated func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.verificationFailed
        case .verified(let safe):
            return safe
        }
    }

    /// Save pro status to UserDefaults
    private func saveProStatus(_ status: Bool) {
        UserDefaults.standard.set(status, forKey: proStatusKey)
    }

    // MARK: - Product Information

    /// Get the Pro Pack product
    var proPackProduct: Product? {
        return products.first
    }

    /// Get localized price string
    var proPackPrice: String? {
        return proPackProduct?.displayPrice
    }
}
