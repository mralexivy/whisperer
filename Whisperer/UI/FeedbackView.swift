//
//  FeedbackView.swift
//  Whisperer
//
//  In-app feedback form using system email composer
//

import SwiftUI

struct FeedbackView: View {
    @Environment(\.colorScheme) var colorScheme
    enum FeedbackCategory: String, CaseIterable {
        case bug = "Bug Report"
        case feature = "Feature Request"
        case general = "General Feedback"

        var icon: String {
            switch self {
            case .bug: return "ladybug.fill"
            case .feature: return "lightbulb.fill"
            case .general: return "hand.thumbsup.fill"
            }
        }

        var color: Color {
            switch self {
            case .bug: return Color(hex: "EF4444")
            case .feature: return Color(hex: "EAB308")
            case .general: return Color(hex: "22C55E")
            }
        }
    }

    @State private var feedbackText: String = ""
    @State private var emailAddress: String = ""
    @State private var selectedCategory: FeedbackCategory = .general
    @State private var attachLogs: Bool = true
    @State private var showSentConfirmation: Bool = false
    @State private var appearedSections: Set<Int> = []
    @State private var hoveredSystemRow: Int? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                feedbackHeader
                    .padding(.bottom, 24)
                    .sectionFadeIn(index: 0, appeared: $appearedSections)

                VStack(alignment: .leading, spacing: 16) {
                    descriptionCard
                        .sectionFadeIn(index: 1, appeared: $appearedSections)

                    HStack(alignment: .top, spacing: 12) {
                        contactCard
                        systemInfoCard
                    }
                    .sectionFadeIn(index: 2, appeared: $appearedSections)

                    sendButton
                        .sectionFadeIn(index: 3, appeared: $appearedSections)

                    privacyFooter
                        .sectionFadeIn(index: 4, appeared: $appearedSections)
                }

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
            for i in 0..<5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 + Double(i) * 0.08) {
                    withAnimation(.easeOut(duration: 0.4)) { _ = appearedSections.insert(i) }
                }
            }
        }
    }

    // MARK: - Header

    private var feedbackHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "22C55E").opacity(0.18), Color(hex: "22C55E").opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                    .shadow(color: Color(hex: "22C55E").opacity(0.08), radius: 4, y: 1)

                Image(systemName: "envelope.fill")
                    .font(.system(size: 22))
                    .foregroundColor(Color(hex: "22C55E"))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Feedback")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))

                Text("Help us improve Whisperer with your feedback")
                    .font(.system(size: 13))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }

            Spacer()
        }
    }

    // MARK: - Description Card

    private var descriptionCard: some View {
        SettingsCard(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSectionHeader(
                    icon: "text.alignleft",
                    title: "Description",
                    colorScheme: colorScheme,
                    color: Color(hex: "22C55E")
                )

                Text("tell us what's on your mind")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .padding(.leading, 38)

                TextEditor(text: $feedbackText)
                    .font(.system(size: 13))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120, maxHeight: 200)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.4))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                    )

                HStack(spacing: 6) {
                    ForEach(FeedbackCategory.allCases, id: \.self) { category in
                        categoryPill(category)
                    }
                }
            }
        }
    }

    // MARK: - Contact Card

    private var contactCard: some View {
        SettingsCard(colorScheme: colorScheme, fillHeight: true) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSectionHeader(
                    icon: "at",
                    title: "Contact",
                    colorScheme: colorScheme,
                    color: .blue
                )

                Text("so we can follow up")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .padding(.leading, 38)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Email (optional)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))

                    TextField("your@email.com", text: $emailAddress)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.4))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                        )
                }

                // Gradient divider
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [WhispererColors.accentBlue.opacity(0.3), WhispererColors.accentPurple.opacity(0.3), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 0.5)

                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                LinearGradient(
                                    colors: [Color.cyan.opacity(0.18), Color.cyan.opacity(0.10)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 36, height: 36)

                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.cyan)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Attach Diagnostic Logs")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                        Text("Include app logs to help diagnose issues")
                            .font(.system(size: 11))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    }

                    Spacer()

                    Toggle("", isOn: $attachLogs)
                        .toggleStyle(.switch)
                        .tint(WhispererColors.accent)
                        .labelsHidden()
                }
            }
        }
    }

    // MARK: - System Info Card

    private var systemInfoCard: some View {
        SettingsCard(colorScheme: colorScheme, fillHeight: true) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSectionHeader(
                    icon: "info.circle.fill",
                    title: "System Info",
                    colorScheme: colorScheme,
                    color: .orange
                )

                Text("included with your feedback")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .padding(.leading, 38)

                VStack(spacing: 6) {
                    systemInfoRow(0, icon: "app.badge.fill", label: "App Version", value: appVersion, color: WhispererColors.accentBlue)
                    systemInfoRow(1, icon: "desktopcomputer", label: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString, color: Color(hex: "22C55E"))
                    systemInfoRow(2, icon: "cpu", label: "Model", value: AppState.shared.selectedModel.displayName, color: .orange)
                    systemInfoRow(3, icon: "server.rack", label: "Backend", value: AppState.shared.selectedBackendType.rawValue, color: Color(hex: "A855F7"))
                }
            }
        }
    }

    // MARK: - Send Button

    private var sendButton: some View {
        HStack {
            Spacer()

            Button(action: sendFeedback) {
                HStack(spacing: 8) {
                    Image(systemName: showSentConfirmation ? "checkmark.circle.fill" : "paperplane.fill")
                        .font(.system(size: 13, weight: .medium))
                    Text(showSentConfirmation ? "Email Drafted!" : "Send Feedback")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(showSentConfirmation
                              ? AnyShapeStyle(Color(hex: "22C55E"))
                              : AnyShapeStyle(WhispererColors.accentGradient))
                )
                .shadow(color: (showSentConfirmation ? Color(hex: "22C55E") : WhispererColors.accentBlue).opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(.plain).pointerOnHover()
            .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)

            Spacer()
        }
    }

    // MARK: - Footer

    private var privacyFooter: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.6))
                Text("Feedback is sent via your default email client")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.6))
            }
            Spacer()
        }
    }

    // MARK: - Helpers

    private func systemInfoRow(_ index: Int, icon: String, label: String, value: String, color: Color) -> some View {
        let isHovered = hoveredSystemRow == index

        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.opacity(isHovered ? 0.18 : 0.12))
                    .frame(width: 24, height: 24)

                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(color)
            }

            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))

            Spacer()

            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(WhispererColors.primaryText(colorScheme))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(WhispererColors.elevatedBackground(colorScheme).opacity(isHovered ? 0.6 : 0.4))
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredSystemRow = hovering ? index : nil
            }
        }
    }

    private func categoryPill(_ category: FeedbackCategory) -> some View {
        let isSelected = selectedCategory == category
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) { selectedCategory = category }
        }) {
            HStack(spacing: 4) {
                Image(systemName: category.icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isSelected ? .white : category.color)
                Text(category.rawValue)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .white : category.color)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isSelected ? category.color : category.color.opacity(0.12))
            )
            .shadow(color: isSelected ? category.color.opacity(0.25) : .clear, radius: 4, y: 1)
        }
        .buttonStyle(.plain).pointerOnHover()
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func sendFeedback() {
        let subject = "[\(selectedCategory.rawValue)] Whisperer Feedback — v\(appVersion)"
        var body = "Category: \(selectedCategory.rawValue)\n\n\(feedbackText)"

        body += "\n\n--- System Info ---"
        body += "\nApp Version: \(appVersion)"
        body += "\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)"
        body += "\nModel: \(AppState.shared.selectedModel.displayName)"
        body += "\nBackend: \(AppState.shared.selectedBackendType.rawValue)"

        if !emailAddress.isEmpty {
            body += "\nContact: \(emailAddress)"
        }

        let service = NSSharingService(named: .composeEmail)
        service?.recipients = ["feedback@whispererapp.com"]
        service?.subject = subject

        if attachLogs {
            let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Logs/Whisperer")
            var attachments: [URL] = []
            if let logsDir = logsDir,
               let files = try? FileManager.default.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) {
                attachments = Array(files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).prefix(3))
            }
            if service?.canPerform(withItems: [body as NSString] + attachments.map { $0 as NSURL }) == true {
                service?.perform(withItems: [body as NSString] + attachments.map { $0 as NSURL })
            } else {
                service?.perform(withItems: [body as NSString])
            }
        } else {
            service?.perform(withItems: [body as NSString])
        }

        withAnimation(.easeInOut(duration: 0.2)) { showSentConfirmation = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation(.easeInOut(duration: 0.2)) { showSentConfirmation = false }
        }
    }
}
