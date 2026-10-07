//
//  Qwen3UpgradeCard.swift
//  Whisperer
//
//  Offers the Qwen3-ASR download to users who do not have it yet.
//
//  Qwen3 is the default engine, but it is a 2.5 GB download, so `BackendType.defaultBackend`
//  resolves to whisper.cpp until the weights are on disk. This card is how the better engine
//  becomes discoverable without anyone being blocked: dictation already works, and the offer
//  sits above it until the user accepts or dismisses it.
//
//  Self-hiding, like `PolishModelCard`. It disappears for good once the model is cached or the
//  user dismisses it, so it can be mounted unconditionally.
//

import SwiftUI

struct Qwen3UpgradeCard: View {
    @ObservedObject var appState = AppState.shared

    /// Set when the user dismisses the offer. Never cleared — an offer declined once must not
    /// reappear on the next launch.
    @AppStorage(Qwen3UpgradeOffer.dismissedKey) private var dismissed = false

    /// Re-read on appear only. `isModelCached()` touches the filesystem, so it must not run on
    /// every SwiftUI body evaluation.
    @State private var isCached = true

    var body: some View {
        Group {
            if appState.isDownloadingQwen3ASR || appState.isLoadingQwen3ASR {
                progressCard
            } else if Qwen3UpgradeOffer.shouldOffer(isAvailable: Qwen3UpgradeOffer.isAvailable,
                                                    isCached: isCached,
                                                    isDismissed: dismissed,
                                                    language: appState.selectedLanguage) {
                offerCard
            }
        }
        .onAppear { isCached = appState.isQwen3ASRModelCached() }
        .onChange(of: appState.isLoadingQwen3ASR) { _ in
            isCached = appState.isQwen3ASRModelCached()
        }
    }

    // MARK: - Offer

    private var offerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MBColors.accentGradient)
                Text("A better engine is available")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(MBColors.textPrimary)
                Spacer()
                Text(Qwen3ASREngine.downloadSizeLabel)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(MBColors.textSecondary)
            }

            Text("Qwen3 ASR leads the Open ASR Leaderboard and covers 31 languages. "
                 + "One engine handles dictation and meetings, so your Mac loads fewer models.")
                .font(.system(size: 11))
                .foregroundColor(MBColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Download") { appState.downloadQwen3ASRModel() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MBColors.accentGradient)

                Button("Not now") { withAnimation { dismissed = true } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(MBColors.textSecondary)
            }
        }
        .padding(12)
        .background(MBColors.cardSurface)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(MBColors.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Progress

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MBColors.accentGradient)
                Text("Qwen3 ASR")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(MBColors.textPrimary)
                Spacer()
                Text(appState.qwen3asrDownloadStatus)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(MBColors.textSecondary)
            }

            ProgressView(value: appState.downloadProgress)
                .progressViewStyle(.linear)
                .tint(MBColors.accent)

            Text("Downloading in the background — dictation keeps working meanwhile.")
                .font(.system(size: 11))
                .foregroundColor(MBColors.textTertiary)
        }
        .padding(12)
        .background(MBColors.cardSurface)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(MBColors.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Offer policy

/// When the Qwen3 download offer may be shown. Separated from the view so the policy is
/// testable without a SwiftUI host.
enum Qwen3UpgradeOffer {
    static let dismissedKey = "qwen3UpgradeOfferDismissed"

    /// True when the machine can actually run Qwen3. Does **not** consider whether the model is
    /// cached or the offer dismissed — those are read from live state by the view, and baking a
    /// filesystem probe into a static would make the view's `onAppear` refresh pointless.
    static var isAvailable: Bool { BackendType.qwen3asr.isAvailable }

    /// Whether to offer the download, given the inputs the view holds.
    ///
    /// `language` suppresses the offer for languages Qwen3 is measured to be weak at. Asking
    /// a Hebrew user to download 2.5 GB that would make their transcripts worse is not an
    /// upgrade. See `BackendType.weakLanguages`.
    static func shouldOffer(
        isAvailable: Bool,
        isCached: Bool,
        isDismissed: Bool,
        language: TranscriptionLanguage = .auto
    ) -> Bool {
        guard isAvailable, !isCached, !isDismissed else { return false }
        return !BackendType.qwen3asr.weakLanguages.contains(language)
    }
}
