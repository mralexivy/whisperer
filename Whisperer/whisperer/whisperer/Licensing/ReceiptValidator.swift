//
//  ReceiptValidator.swift
//  Whisperer
//
//  App Store receipt validation for anti-piracy
//  Validates that the app was purchased through the Mac App Store
//

import Foundation
import Security

enum ReceiptValidationError: Error {
    case noReceiptFound
    case invalidReceipt
    case bundleIdMismatch
    case versionMismatch
    case signatureInvalid
    case receiptExpired

    var localizedDescription: String {
        switch self {
        case .noReceiptFound:
            return "No App Store receipt found. Please ensure the app was downloaded from the Mac App Store."
        case .invalidReceipt:
            return "The App Store receipt is invalid or corrupted."
        case .bundleIdMismatch:
            return "Receipt bundle identifier does not match this app."
        case .versionMismatch:
            return "Receipt version does not match this app version."
        case .signatureInvalid:
            return "Receipt signature verification failed."
        case .receiptExpired:
            return "Receipt has expired."
        }
    }
}

class ReceiptValidator {
    static let shared = ReceiptValidator()

    private var isValidated = false
    private var cachedResult: Bool?

    private init() {}

    /// Validate the App Store receipt
    /// Returns true if valid, throws error if invalid
    /// In production, this should call exit(173) on validation failure to trigger receipt refresh
    func validateReceipt() throws -> Bool {
        // Return cached result if already validated
        if let cached = cachedResult {
            return cached
        }

        // 1. Check if receipt exists
        guard let receiptURL = Bundle.main.appStoreReceiptURL else {
            throw ReceiptValidationError.noReceiptFound
        }

        guard FileManager.default.fileExists(atPath: receiptURL.path) else {
            throw ReceiptValidationError.noReceiptFound
        }

        // 2. Load receipt data
        guard let receiptData = try? Data(contentsOf: receiptURL) else {
            throw ReceiptValidationError.invalidReceipt
        }

        // 3. Basic validation - ensure receipt is not empty
        guard receiptData.count > 0 else {
            throw ReceiptValidationError.invalidReceipt
        }

        // 4. Validate receipt structure (basic PKCS#7 check)
        // The receipt is a PKCS#7 container - check for basic structure
        guard isValidPKCS7Container(receiptData) else {
            throw ReceiptValidationError.invalidReceipt
        }

        // 5. For Mac App Store, we can do additional validation
        // In a production app, you would:
        // - Parse the PKCS#7 container using Security framework
        // - Verify Apple's signature chain
        // - Extract ASN.1 payload and verify:
        //   * Bundle ID matches Bundle.main.bundleIdentifier
        //   * App version matches Bundle.main.infoDictionary?["CFBundleShortVersionString"]
        //   * Receipt is not expired

        // For now, we implement basic validation
        // A full implementation would use OpenSSL or Security framework to parse the receipt

        Logger.info("✅ Receipt validation passed (basic check)", subsystem: .app)

        isValidated = true
        cachedResult = true
        return true
    }

    /// Check if data looks like a PKCS#7 container
    /// PKCS#7 containers start with the ASN.1 SEQUENCE tag (0x30)
    private func isValidPKCS7Container(_ data: Data) -> Bool {
        guard data.count > 20 else { return false }

        // PKCS#7 starts with 0x30 (SEQUENCE)
        // This is a very basic check - a full implementation would properly parse ASN.1
        let bytes = [UInt8](data.prefix(4))
        return bytes[0] == 0x30
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

// MARK: - Advanced Receipt Parsing (Optional Enhancement)

extension ReceiptValidator {
    /// Parse receipt and extract bundle ID (advanced)
    /// This is a placeholder for full receipt parsing using ASN.1
    /// In production, you would use a library like TPInAppReceipt or implement full ASN.1 parsing
    private func parseReceipt(_ data: Data) throws -> ReceiptInfo {
        // TODO: Implement full receipt parsing
        // This would involve:
        // 1. Extracting PKCS#7 payload
        // 2. Verifying Apple's signature
        // 3. Parsing ASN.1 structure to extract fields
        // 4. Validating bundle ID, version, purchase date, etc.

        // For now, return placeholder
        return ReceiptInfo(
            bundleId: Bundle.main.bundleIdentifier ?? "",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            originalPurchaseDate: Date()
        )
    }
}

// MARK: - Receipt Info Model

struct ReceiptInfo {
    let bundleId: String
    let appVersion: String
    let originalPurchaseDate: Date

    var isValid: Bool {
        // Validate bundle ID matches
        guard bundleId == Bundle.main.bundleIdentifier else {
            return false
        }

        // Additional validation logic can be added here
        return true
    }
}
