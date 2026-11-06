//
//  ModelRow.swift
//  Whisperer
//
//  One row for every downloadable speech model in the Models tab.
//
//  Replaces five copies (Whisper, Parakeet, Nemotron Hebrew, Qwen3, WhisperKit) that had
//  drifted apart: some showed a percent and some only "Downloading", none said how much was
//  left, only Whisper could be cancelled — through a button nested inside the row's own button,
//  so the click could land on the row — and a failure surfaced only as a global banner. Every
//  row was also disabled while *any* model downloaded, which froze the tab for a 2.5 GB fetch.
//
//  States, in priority order: downloading → failed → loading → ready to activate → active →
//  on disk → not downloaded. The trailing control and the line under the title always say
//  which one the model is in.
//

import SwiftUI

/// What the row needs to know about its model that the download record does not.
struct ModelRowState {
    var isActive: Bool
    var isLoading: Bool
    var isOnDisk: Bool
    var isReadyToActivate: Bool = false
}

struct ModelRow<Badges: View>: View {
    let asset: ModelAsset
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let state: ModelRowState
    /// Use a model already on disk.
    let onSelect: () -> Void
    var onActivate: (() -> Void)?
    @ViewBuilder var badges: () -> Badges

    @ObservedObject private var appState = AppState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var download: ModelDownloadProgress? { appState.modelDownloads[asset] }
    private var failure: String? { appState.modelDownloadFailures[asset] }
    private var isHighlighted: Bool { state.isActive || state.isLoading || download != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // The tappable area is its own button so the trailing controls (Cancel, Retry,
                // Activate) are siblings, never buttons nested inside a button.
                Button(action: primaryAction) {
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .foregroundColor(iconColor)
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(title)
                                    .font(.system(size: 12, weight: isHighlighted ? .semibold : .regular))
                                    .foregroundColor(isHighlighted ? MBColors.textPrimary : MBColors.textSecondary)
                                    .lineLimit(1)
                                badges()
                            }
                            Text(secondaryLine)
                                .font(.caption2)
                                .foregroundColor(failure != nil ? .orange : MBColors.textTertiary)
                                .lineLimit(2)
                                .monospacedDigit()
                        }

                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerOnHover()
                // Not `.disabled`: that dims the row, and a row mid-download must read as the
                // brightest thing in the list, not the faintest.
                .allowsHitTesting(primaryEnabled)
                .accessibilityAddTraits(primaryEnabled ? [] : .isStaticText)
                .help(primaryHelp)
                .uiTestFrame("model.\(asset.testID).row")

                trailing
            }

            if let download {
                ModelDownloadBar(progress: download)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? MBColors.accent.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isHighlighted ? MBColors.accent.opacity(0.3) : Color.clear, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: download != nil)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: failure)
    }

    // MARK: - Text

    private var secondaryLine: String {
        if let download { return download.detailText(approximateTotal: asset.approximateBytes) }
        if let failure { return failure }
        if state.isLoading { return "Loading into memory…" }
        if state.isReadyToActivate { return "Downloaded — activate when you're ready" }
        return subtitle
    }

    private var primaryHelp: String {
        if download != nil { return "Downloading \(title)" }
        if state.isActive { return "\(title) is in use" }
        if state.isOnDisk { return "Use \(title)" }
        return "Download \(title) (\(asset.sizeLabel)). Dictation keeps working while it downloads."
    }

    // MARK: - Actions

    private var primaryEnabled: Bool {
        if download != nil || state.isLoading || state.isActive { return false }
        // Picking a model loads it; one load at a time. Starting a download is always allowed.
        if state.isOnDisk { return !appState.isModelBusy && appState.state == .idle }
        return true
    }

    private func primaryAction() {
        if state.isReadyToActivate, let onActivate {
            onActivate()
        } else if state.isOnDisk {
            onSelect()
        } else {
            appState.startDownload(asset)
        }
    }

    // MARK: - Trailing control

    @ViewBuilder
    private var trailing: some View {
        if let download {
            HStack(spacing: 6) {
                if download.phase == .downloading, download.fraction > 0 {
                    Text("\(Int(download.fraction * 100))%")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(MBColors.accent)
                        .monospacedDigit()
                }
                Button(action: { appState.cancelDownload(asset) }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(MBColors.textTertiary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain).pointerOnHover()
                .help("Cancel download")
                .accessibilityLabel("Cancel download of \(title)")
                .uiTestFrame("model.\(asset.testID).cancel")
            }
        } else if failure != nil {
            Button(action: { appState.startDownload(asset) }) {
                Label("Retry", systemImage: "arrow.clockwise")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange))
            }
            .buttonStyle(.plain).pointerOnHover()
            .accessibilityLabel("Retry download of \(title)")
            .uiTestFrame("model.\(asset.testID).retry")
        } else if state.isLoading {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Loading")
                    .font(.caption2)
                    .foregroundColor(MBColors.accent)
            }
        } else if state.isReadyToActivate, let onActivate {
            Button(action: onActivate) {
                Text("Activate")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(MBColors.accent))
            }
            .buttonStyle(.plain).pointerOnHover()
            .disabled(appState.state != .idle)
            .help(appState.state != .idle ? "Available when the recording ends" : "Switch to \(title)")
        } else if state.isActive {
            Text("Active")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(MBColors.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(MBColors.accent.opacity(0.15)))
        } else if state.isOnDisk {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(MBColors.accent.opacity(0.5))
                .font(.system(size: 14))
                .help("Downloaded")
                .accessibilityLabel("Downloaded")
        } else {
            Button(action: { appState.startDownload(asset) }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14))
                    Text(asset.sizeLabel)
                        .font(.caption2)
                }
                .foregroundColor(MBColors.accent)
            }
            .buttonStyle(.plain).pointerOnHover()
            .accessibilityLabel("Download \(title), \(asset.sizeLabel)")
            .uiTestFrame("model.\(asset.testID).download")
        }
    }
}

extension ModelRow where Badges == EmptyView {
    init(asset: ModelAsset, icon: String, iconColor: Color, title: String, subtitle: String,
         state: ModelRowState, onSelect: @escaping () -> Void, onActivate: (() -> Void)? = nil) {
        self.init(asset: asset, icon: icon, iconColor: iconColor, title: title, subtitle: subtitle,
                  state: state, onSelect: onSelect, onActivate: onActivate, badges: { EmptyView() })
    }
}

/// The bar under a downloading row. Drawn rather than `ProgressView`, which turns grey when its
/// window is not key — the menu bar popover often is not — and cannot show "no bytes yet".
struct ModelDownloadBar: View {
    let progress: ModelDownloadProgress
    var height: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    private var color: Color {
        switch progress.phase {
        case .waitingForNetwork, .retrying: return .orange
        default: return MBColors.accent
        }
    }

    /// Connecting, or waiting with nothing fetched yet: no honest fraction to show.
    private var isIndeterminate: Bool {
        progress.fraction <= 0 && progress.phase != .downloading
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                if isIndeterminate {
                    Capsule()
                        .fill(color.opacity(0.7))
                        .frame(width: geometry.size.width * 0.25)
                        .offset(x: sweep ? geometry.size.width * 0.75 : 0)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: sweep)
                        .onAppear { sweep = true }
                } else {
                    Capsule()
                        .fill(LinearGradient(colors: [color, color.opacity(0.75)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, geometry.size.width * progress.fraction))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: progress.fraction)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int(progress.fraction * 100)) percent")
    }
}
