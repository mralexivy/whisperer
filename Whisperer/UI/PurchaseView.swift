//
//  PurchaseView.swift
//  Whisperer
//
//  Pro Pack purchase UI with feature comparison
//

import SwiftUI
import StoreKit

struct PurchaseView: View {
    @ObservedObject var storeManager = StoreManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if storeManager.isPro {
                // Already purchased
                proActivatedView
            } else {
                // Purchase UI
                purchaseOptionsView
            }
        }
        .task {
            // Load products when view appears
            await storeManager.loadProducts()
            await storeManager.checkPurchased()
        }
    }

    // MARK: - Pro Activated View

    private static let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969) // #5B6CF7

    private var proActivatedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 24))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisperer Pro Activated")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Thank you for your support!")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.15))
            .cornerRadius(8)

            Text("You have access to all Pro features:")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(ProPitch.rows) { row in
                    proFeatureRow(icon: row.icon, title: row.title, description: row.detail)
                }
            }
        }
    }

    // MARK: - Purchase Options View

    private var purchaseOptionsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Upgrade to Whisperer Pro")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)

                Text("Meetings, calendar, AI notes and the MCP server. One purchase, no subscription.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }

            Divider()
                .opacity(0.3)

            // Feature comparison
            VStack(alignment: .leading, spacing: 10) {
                Text("What's included:")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ProPitch.rows) { row in
                        proFeatureRow(icon: row.icon, title: row.title, description: row.detail)
                    }
                }
            }

            Divider()
                .opacity(0.3)

            // Purchase button
            if let product = storeManager.proPackProduct {
                VStack(spacing: 8) {
                    Button(action: {
                        Task {
                            do {
                                try await storeManager.purchase()
                            } catch {
                                // Error is already logged in StoreManager
                            }
                        }
                    }) {
                        HStack {
                            if storeManager.isPurchasing {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .padding(.trailing, 4)
                            }

                            Text(storeManager.isPurchasing ? "Processing..." : "Unlock Pro")
                                .font(.system(size: 13, weight: .semibold))

                            Spacer()

                            if !storeManager.isPurchasing {
                                Text(product.displayPrice)
                                    .font(.system(size: 13, weight: .bold))
                            }
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(
                                colors: [Self.blueAccent, Color(red: 0.545, green: 0.361, blue: 0.965)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain).pointerOnHover()
                    .disabled(storeManager.isPurchasing)

                    // Restore purchases button
                    Button(action: {
                        Task {
                            await storeManager.restorePurchases()
                        }
                    }) {
                        Text("Restore Purchases")
                            .font(.system(size: 11))
                            .foregroundColor(Self.blueAccent)
                    }
                    .buttonStyle(.plain).pointerOnHover()
                }
            } else {
                // Loading state
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading Pro...")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            // Error message
            if let error = storeManager.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
            }

            // One-time purchase note
            Text("One-time purchase. Includes future Pro features.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Helper Views

    private func proFeatureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(Self.blueAccent)
                .font(.system(size: 14))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)

                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
