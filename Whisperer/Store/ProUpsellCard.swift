//
//  ProUpsellCard.swift
//  Whisperer
//
//  The one place the app asks for the $14.99 Pro purchase. It appears at the top of the pages Pro unlocks
//  (Calendar, LLM, MCP) when the Mac App Store build has no Pro purchase, says exactly what Pro adds,
//  and has one primary action. It disappears the moment Pro is bought or restored.
//

import SwiftUI

/// What Pro adds, in the words used on whispererapp.com/pricing, for this build.
enum ProPitch {
    struct Row: Identifiable {
        let id: String
        let icon: String
        let color: Color
        let title: String
        let detail: String
    }

    static let rows: [Row] = [
        Row(id: "meetings", icon: "person.2.wave.2.fill", color: .cyan, title: "Meetings",
            detail: "Record calls with named speakers and automatic detection."),
        Row(id: "calendar", icon: "calendar", color: .pink, title: "Calendar sync",
            detail: "Join and record from Google or Outlook events in one click."),
        Row(id: "notes", icon: "sparkles", color: .purple, title: "AI notes and Ask AI",
            detail: "Overview, decisions and action items, written on your Mac."),
        Row(id: "ownAI", icon: "key.fill", color: .orange, title: "Your own AI",
            detail: "Use your ChatGPT plan or an OpenAI, Anthropic or Gemini key."),
        Row(id: "mcp", icon: "point.3.connected.trianglepath.dotted", color: .teal, title: "MCP server",
            detail: "Let AI apps search your meetings, locally."),
    ]
}

struct ProUpsellCard: View {
    /// What the user was after, so the title can say it ("Meetings are part of Pro").
    var feature: ProFeature?
    @ObservedObject private var store = StoreManager.shared

    var body: some View {
        // Reading the store's published flag re-evaluates this when a purchase completes.
        if ProAccess.sellsPro, !store.isPro {
            card
        }
    }

    private var priceText: String { store.proPackPrice ?? "$14.99" }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(WhispererColors.accent.opacity(0.15))
                    Image(systemName: "sparkles").font(.system(size: 17, weight: .semibold)).foregroundColor(WhispererColors.accent)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.map { "\($0.title) \($0 == .meetings || $0 == .ai ? "are" : "is") part of Whisperer Pro" } ?? "Unlock Whisperer Pro")
                        .font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                    Text("One purchase, no subscription. Dictation, files, history and the dictionary stay in the base app.")
                        .font(.system(size: 12.5)).foregroundColor(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(ProPitch.rows) { row in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: row.icon).font(.system(size: 14, weight: .medium)).foregroundColor(row.color)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).font(.system(size: 13.5, weight: .semibold)).foregroundColor(.white)
                            Text(row.detail).font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    Task { try? await store.purchase() }
                } label: {
                    HStack(spacing: 8) {
                        if store.isPurchasing { ProgressView().scaleEffect(0.6).frame(width: 14, height: 14) }
                        Text(store.isPurchasing ? "Processing…" : "Unlock Pro")
                            .font(.system(size: 13.5, weight: .semibold))
                        if !store.isPurchasing { Text(priceText).font(.system(size: 13.5, weight: .bold)) }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(WhispererColors.accentGradient))
                }
                .buttonStyle(.plain)
                .disabled(store.isPurchasing)
                .uiTestFrame("pro.unlock")

                Button {
                    Task { await store.restorePurchases() }
                } label: {
                    Text("Restore Purchases").font(.system(size: 12.5)).foregroundColor(WhispererColors.accent)
                }
                .buttonStyle(.plain)
                .uiTestFrame("pro.restore")
                Spacer(minLength: 0)
            }

            if let error = store.errorMessage {
                Text(error).font(.system(size: 11.5)).foregroundColor(.orange)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(WhispererColors.cardBackground(.dark))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(WhispererColors.accent.opacity(0.35), lineWidth: 1))
                .allowsHitTesting(false)
        )
        .shadow(color: WhispererColors.accent.opacity(0.18), radius: 14, y: 6)
        .task {
            if store.products.isEmpty { await store.loadProducts() }
        }
    }
}
