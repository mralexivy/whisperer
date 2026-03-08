//
//  SetupChecklistView.swift
//  Whisperer
//
//  Persistent setup checklist showing configuration status
//

import SwiftUI

struct SetupChecklistView: View {
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var permissionManager = PermissionManager.shared
    @State private var appearedSections: Set<Int> = []
    @State private var hoveredItem: Int? = nil

    private var completedCount: Int {
        checklistItems.filter { $0.isComplete }.count
    }

    private var checklistItems: [ChecklistItem] {
        [
            ChecklistItem(
                icon: "cpu",
                title: "Download Voice Model",
                description: "Download a whisper model for transcription",
                color: .orange,
                isComplete: appState.isModelLoaded,
                action: nil
            ),
            ChecklistItem(
                icon: "mic.fill",
                title: "Grant Microphone Access",
                description: "Required for voice recording",
                color: Color(hex: "22C55E"),
                isComplete: permissionManager.microphoneStatus == .granted,
                action: {
                    permissionManager.requestMicrophonePermission()
                }
            ),
            ChecklistItem(
                icon: "keyboard",
                title: "Configure Shortcut",
                description: "Set your recording trigger key",
                color: .red,
                isComplete: appState.keyListener?.shortcutConfig != nil,
                action: nil
            ),
            ChecklistItem(
                icon: "doc.on.clipboard",
                title: "Enable Auto-Paste",
                description: "Automatically insert text at cursor (optional)",
                color: .blue,
                isComplete: appState.autoPasteEnabled,
                action: {
                    appState.autoPasteEnabled = true
                }
            ),
        ]
    }

    private var allComplete: Bool {
        completedCount == checklistItems.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                setupHeader
                    .padding(.bottom, 24)
                    .sectionFadeIn(index: 0, appeared: $appearedSections)

                progressHero
                    .padding(.bottom, 20)
                    .sectionFadeIn(index: 1, appeared: $appearedSections)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(checklistItems.enumerated()), id: \.offset) { index, item in
                        checklistCard(item, index: index)
                            .sectionFadeIn(index: index + 2, appeared: $appearedSections)
                    }
                }

                privacyFooter
                    .padding(.top, 24)
                    .sectionFadeIn(index: checklistItems.count + 2, appeared: $appearedSections)

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WhispererColors.background(colorScheme))
        .onAppear {
            appearedSections = []
            for i in 0..<(checklistItems.count + 3) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 + Double(i) * 0.08) {
                    withAnimation(.easeOut(duration: 0.4)) { _ = appearedSections.insert(i) }
                }
            }
        }
    }

    // MARK: - Header

    private var setupHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [WhispererColors.accentBlue.opacity(0.18), WhispererColors.accentPurple.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                    .shadow(color: WhispererColors.accentBlue.opacity(0.08), radius: 4, y: 1)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Setup")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))

                Text("Make sure everything is configured for the best experience")
                    .font(.system(size: 13))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }

            Spacer()
        }
    }

    // MARK: - Progress Hero

    private var progressHero: some View {
        SettingsCard(colorScheme: colorScheme, borderColor: allComplete ? Color(hex: "22C55E").opacity(0.12) : nil) {
            HStack(spacing: 20) {
                // Glow ring progress indicator
                ZStack {
                    // Outer glow ring
                    Circle()
                        .fill(progressColor.opacity(0.05))
                        .frame(width: 96, height: 96)

                    Circle()
                        .stroke(progressColor.opacity(0.1), lineWidth: 1)
                        .frame(width: 96, height: 96)

                    // Middle ring
                    Circle()
                        .fill(progressColor.opacity(0.08))
                        .frame(width: 72, height: 72)

                    Circle()
                        .stroke(progressColor.opacity(0.15), lineWidth: 1.5)
                        .frame(width: 72, height: 72)

                    // Progress arc
                    Circle()
                        .trim(from: 0, to: CGFloat(completedCount) / CGFloat(checklistItems.count))
                        .stroke(
                            progressColor,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 72, height: 72)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.6), value: completedCount)

                    // Inner hero number
                    VStack(spacing: 0) {
                        Text("\(completedCount)")
                            .font(.system(size: 32, weight: .light, design: .rounded))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.4), value: completedCount)

                        Text("of \(checklistItems.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(progressColor)
                            .tracking(0.5)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(allComplete ? "All Set!" : "Getting Started")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))

                    Text(progressMessage)
                        .font(.system(size: 12))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                        .lineSpacing(3)

                    // Progress bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(WhispererColors.border(colorScheme))
                                .frame(height: 5)

                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    allComplete
                                        ? LinearGradient(colors: [Color(hex: "22C55E"), Color(hex: "22C55E")], startPoint: .leading, endPoint: .trailing)
                                        : WhispererColors.accentGradient
                                )
                                .frame(width: max(0, geometry.size.width * CGFloat(completedCount) / CGFloat(checklistItems.count)), height: 5)
                                .animation(.easeInOut(duration: 0.4), value: completedCount)
                        }
                    }
                    .frame(height: 5)
                    .padding(.top, 4)

                    HStack(spacing: 6) {
                        statusPill(
                            icon: "checkmark",
                            text: "\(completedCount) complete",
                            color: Color(hex: "22C55E")
                        )

                        if !allComplete {
                            statusPill(
                                icon: "circle.dashed",
                                text: "\(checklistItems.count - completedCount) remaining",
                                color: WhispererColors.accentBlue
                            )
                        }
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var progressColor: Color {
        allComplete ? Color(hex: "22C55E") : WhispererColors.accentBlue
    }

    private var progressMessage: String {
        if allComplete { return "Whisperer is fully configured and ready to use. Hold your shortcut key and start speaking!" }
        let remaining = checklistItems.count - completedCount
        if remaining == checklistItems.count { return "Complete the steps below to set up Whisperer for the best dictation experience." }
        return "Almost there! \(remaining) more \(remaining == 1 ? "step" : "steps") to complete your setup."
    }

    // MARK: - Checklist Card

    private func checklistCard(_ item: ChecklistItem, index: Int) -> some View {
        let isHovered = hoveredItem == index

        return SettingsCard(colorScheme: colorScheme, borderColor: item.isComplete ? Color(hex: "22C55E").opacity(0.1) : nil) {
            HStack(spacing: 14) {
                // Step number / check indicator
                ZStack {
                    if item.isComplete {
                        Circle()
                            .fill(Color(hex: "22C55E").opacity(0.12))
                            .frame(width: 40, height: 40)

                        Circle()
                            .stroke(Color(hex: "22C55E").opacity(0.2), lineWidth: 1)
                            .frame(width: 40, height: 40)

                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Color(hex: "22C55E"))
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                LinearGradient(
                                    colors: [item.color.opacity(isHovered ? 0.18 : 0.12), item.color.opacity(isHovered ? 0.12 : 0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 40, height: 40)
                            .shadow(color: item.color.opacity(0.06), radius: 3, y: 1)

                        Image(systemName: item.icon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(item.color)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("STEP \(index + 1)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(item.isComplete ? Color(hex: "22C55E").opacity(0.6) : item.color.opacity(0.6))
                            .tracking(0.8)

                        if item.isComplete {
                            Text("COMPLETE")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Color(hex: "22C55E"))
                                .tracking(0.8)
                        }
                    }

                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))

                    Text(item.description)
                        .font(.system(size: 12))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                }

                Spacer()

                if item.isComplete {
                    Text("Done")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "22C55E"))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color(hex: "22C55E").opacity(0.12))
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color(hex: "22C55E").opacity(0.15), lineWidth: 0.5)
                        )
                } else if let action = item.action {
                    Button(action: action) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Enable")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(WhispererColors.accentGradient))
                        .shadow(color: WhispererColors.accentBlue.opacity(0.25), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain).pointerOnHover()
                } else {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(item.color.opacity(0.5))
                            .frame(width: 6, height: 6)
                        Text("Pending")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(WhispererColors.pillBackground)
                    )
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredItem = hovering ? index : nil
            }
        }
    }

    // MARK: - Helpers

    private func statusPill(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
    }

    private var privacyFooter: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.6))
                Text("All processing happens locally on your Mac")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.6))
            }
            Spacer()
        }
    }
}

// MARK: - Checklist Item Model

private struct ChecklistItem {
    let icon: String
    let title: String
    let description: String
    let color: Color
    let isComplete: Bool
    let action: (() -> Void)?
}
