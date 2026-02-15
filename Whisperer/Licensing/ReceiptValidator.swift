//
//  ReceiptValidator.swift
//  Whisperer
//
//  App Store receipt validation using StoreKit 2
//  Validates that the app was purchased through the Mac App Store
//

import Foundation
import StoreKit

enum ReceiptValidationError: Error {
    case noReceiptFound
    case invalidReceipt
    case verificationFailed
    case unknownError

    var localizedDescription: String {
        switch self {
        case .noReceiptFound:
            return "No App Store receipt found. Please ensure the app was downloaded from the Mac App Store."
        case .invalidReceipt:
            return "The App Store receipt is invalid or corrupted."
        case .verificationFailed:
            return "App Store verification failed."
        case .unknownError:
            return "An unknown error occurred during validation."
        }
    }
}

@MainActor
class ReceiptValidator {
    static let shared = ReceiptValidator()

    private var isValidated = false
    private var cachedResult: Bool?

    private init() {}

    /// Validate the App Store receipt using StoreKit 2's AppTransaction API
    /// Returns true if valid, throws error if invalid
    func validateReceipt() async throws -> Bool {
        // Return cached result if already validated
        if let cached = cachedResult {
            return cached
        }

        do {
            // Use StoreKit 2's AppTransaction to verify the app purchase
            let result = try await AppTransaction.shared

            switch result {
            case .verified(let appTransaction):
                // The app transaction is verified by Apple
                Logger.info("✅ App Store verification passed - Original purchase: \(appTransaction.originalPurchaseDate)", subsystem: .app)
                isValidated = true
                cachedResult = true
                return true

            case .unverified(_, let verificationError):
                // Verification failed
                Logger.error("App Store verification failed: \(verificationError)", subsystem: .app)
                throw ReceiptValidationError.verificationFailed
            }
        } catch let error as ReceiptValidationError {
            throw error
        } catch {
            // For development/TestFlight builds, AppTransaction may not be available
            // Log the error but don't fail the app
            Logger.warning("App Store validation skipped: \(error.localizedDescription)", subsystem: .app)

            // In development, allow the app to run
            #if DEBUG
            isValidated = true
            cachedResult = true
            return true
            #else
            // In production, if we can't verify, check for receipt file as fallback
            if hasReceiptFile() {
                Logger.info("Receipt file exists, allowing app to run", subsystem: .app)
                isValidated = true
                cachedResult = true
                return true
            }
            throw ReceiptValidationError.noReceiptFound
            #endif
        }
    }

    /// Check if a receipt file exists (fallback for edge cases)
    private func hasReceiptFile() -> Bool {
        guard let receiptURL = Bundle.main.appStoreReceiptURL else {
            return false
        }
        return FileManager.default.fileExists(atPath: receiptURL.path)
    }

    /// Check if the app has a valid purchase
    var isPurchased: Bool {
        return cachedResult ?? false
    }

    /// Reset validation state (for testing)
    func reset() {
        isValidated = false
        cachedResult = nil
    }
}
