//
//  LLMPageView.swift
//  Whisperer
//
//  Workspace → LLM: every language-model choice in one place.
//
//   1. Meeting notes & Ask AI — ONE list of choices. "On this Mac" first, then the AI
//      subscriptions the user already has (signed-in ones float to the top), then API keys.
//      Clicking a row either uses it at once, or opens the one thing it still needs right
//      there in the row: a consent panel, a sign-in step, or a key field. No sheets for the
//      main flow, no jargon, nothing to configure that the user didn't ask for.
//   2. Dictation polish — the on-device model that cleans up dictation (always local).
//   3. Privacy — one switch and three plain facts.
//
//  Behavior lives in `ConnectedAIPageController`, so clicks are unit- and click-tested.
//

import AppKit
import SwiftUI

struct LLMPageView: View {
    let colorScheme: ColorScheme
    @StateObject private var controller: ConnectedAIPageController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace

    private var store: ConnectedAIStore { controller.store }

    init(colorScheme: ColorScheme, store: ConnectedAIStore? = nil) {
        self.colorScheme = colorScheme
        _controller = StateObject(wrappedValue: ConnectedAIPageController(store: store))
    }

    /// Click-test scope: one per store, so each test's page has its own frame keys.
    static func testScope(for store: ConnectedAIStore) -> String {
        String(UInt(bitPattern: ObjectIdentifier(store).hashValue))
    }

    private var spring: Animation? {
        reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let notice = store.lastNotice { noticeBanner(notice) }
                meetingSection
                #if !APP_STORE
                DictationPolishCard(colorScheme: colorScheme)
                #endif
                privacyCard
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(WhispererColors.background(colorScheme))
        .animation(spring, value: controller.expanded)
        .animation(spring, value: store.activeProviderID)
        .animation(spring, value: store.keepLocalOnly)
        .accessibilityIdentifier("llm.page")
        .environment(\.uiTestScope, Self.testScope(for: store))
        .task { await store.refreshAll() }
        .sheet(item: $controller.keyEditorFor) { id in
            APIKeyEditorSheet(provider: id, colorScheme: colorScheme, store: store) { controller.keyEditorFor = nil }
                .environment(\.uiTestScope, Self.testScope(for: store))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(WhispererColors.accentGradient)
                    .frame(width: 52, height: 52)
                    .shadow(color: WhispererColors.accentPurple.opacity(0.35), radius: 12, y: 4)
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .pulseIfAvailable(isActive: store.activeProviderID != nil && !reduceMotion)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("LLM")
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))
                Text("The AI that writes your meeting notes, answers your questions and polishes dictation.")
                    .font(.system(size: 13))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Meeting notes & Ask AI

    private var meetingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("MEETING NOTES & ASK AI",
                         detail: "Choose who writes the title, summary and action items when a meeting ends, and who answers in Ask AI.")

            CurrentChoiceBanner(colorScheme: colorScheme,
                                provider: store.activeProviderID,
                                keepLocal: store.keepLocalOnly)

            VStack(spacing: 8) {
                localRow
                groupLabel("YOUR AI SUBSCRIPTIONS", hint: subscriptionHint)
                ForEach(orderedSubscriptions) { id in providerRow(id) }
                groupLabel("API KEYS", hint: "Billed to your own key. Stored in the Keychain on this Mac.")
                ForEach(controller.apiKeyProviders) { id in providerRow(id) }
            }
        }
    }

    private var subscriptionHint: String {
        #if APP_STORE
        return "Sign in with an account you already pay for. Usage counts against your plan."
        #else
        return "Uses the AI apps you're already signed in to. Usage counts against your plan — no extra bill."
        #endif
    }

    /// Ready (installed and signed in) subscriptions first, then the rest in catalog order.
    private var orderedSubscriptions: [AIProviderID] {
        let all = controller.subscriptionProviders
        return all.filter { store.readiness[$0]?.isReady == true } + all.filter { store.readiness[$0]?.isReady != true }
    }

    // MARK: Rows

    private var localRow: some View {
        ChoiceRow(
            colorScheme: colorScheme,
            icon: "desktopcomputer", tint: Color(hex: "06B6D4"),
            title: "On this Mac", subtitle: "Private and offline. Uses the built-in model.",
            status: LocalMeetingModelStatus.current(),
            isSelected: store.activeProviderID == nil,
            namespace: selectionNamespace,
            badge: nil,
            hasPanel: false,
            action: { controller.localTapped() }
        ) { EmptyView() }
        .uiTestFrame("llm.row.local")
    }

    private func providerRow(_ id: AIProviderID) -> some View {
        let model = controller.cardModel(id)
        let panel = controller.panel(for: id)
        return ChoiceRow(
            colorScheme: colorScheme,
            icon: id.badgeGlyph, tint: providerColor(id),
            title: id.displayName, subtitle: id.vendorLine,
            status: RowStatus(text: model.statusText, tone: model.tone, isWorking: store.checking.contains(id)),
            isSelected: store.activeProviderID == id,
            namespace: selectionNamespace,
            badge: model.badge,
            hasPanel: panel != .none,
            mark: id,
            action: { controller.rowTapped(id) }
        ) {
            switch panel {
            case .consent: consentPanel(id)
            case .setup:   setupPanel(id, model: model)
            case .manage:  managePanel(id)
            case .none:    EmptyView()
            }
        }
        .uiTestFrame("llm.row.\(id.rawValue)")
    }

    // MARK: Inline panels

    private func consentPanel(_ id: AIProviderID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before \(id.displayName) writes your meeting notes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(WhispererColors.primaryText(colorScheme))
            VStack(alignment: .leading, spacing: 7) {
                fact("arrow.up.doc.fill", Color(hex: "8B5CF6"),
                     "The meeting's transcript text and your questions go to \(id.recipient), under your account.")
                fact("waveform.slash", Color(hex: "10B981"), "Audio and dictation never leave this Mac.")
                fact(id.kind == .apiKey ? "creditcard.fill" : "gauge.with.dots.needle.50percent", Color(hex: "F59E0B"),
                     id.kind == .apiKey ? "Requests are billed to your API key." : "Requests count against your plan's limits.")
                fact("arrow.uturn.backward", Color(hex: "06B6D4"), "If it's ever unavailable, this Mac takes over.")
            }
            HStack(spacing: 10) {
                PrimaryButton(title: "Allow and use \(id.displayName)", colorScheme: colorScheme) {
                    controller.allowConsent(id)
                }
                .uiTestFrame("llm.consent.allow")
                SecondaryButton(title: "Not now", colorScheme: colorScheme) { controller.cancelConsent() }
                    .uiTestFrame("llm.consent.cancel")
                Spacer()
                if let url = id.privacyPolicyURL {
                    Link("Privacy policy", destination: url)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(WhispererColors.accentBlue)
                }
            }
        }
    }

    /// For the row in use: prove it works, change its key or model, or take it back.
    private func managePanel(_ id: AIProviderID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(id.displayName) writes your meeting notes and answers Ask AI.")
                .font(.system(size: 12))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))
            HStack(spacing: 10) {
                SecondaryButton(title: store.checking.contains(id) ? "Testing…" : "Send a test request", colorScheme: colorScheme) {
                    controller.perform(.test, id: id)
                }
                .uiTestFrame("llm.manage.test.\(id.rawValue)")
                if id.kind == .apiKey {
                    SecondaryButton(title: "Change key or model", colorScheme: colorScheme) {
                        controller.perform(.enterKey, id: id)
                    }
                    .uiTestFrame("llm.manage.key.\(id.rawValue)")
                }
                if id.kind == .oauth {
                    SecondaryButton(title: "Sign out of ChatGPT", colorScheme: colorScheme) {
                        controller.perform(.disconnectChatGPT, id: id)
                    }
                    .uiTestFrame("llm.manage.signout.\(id.rawValue)")
                }
                SecondaryButton(title: "Stop sending meetings here", colorScheme: colorScheme) {
                    controller.perform(.revokePermission, id: id)
                }
                .uiTestFrame("llm.manage.revoke.\(id.rawValue)")
            }
            if let message = controller.testMessages[id] {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
            }
        }
    }

    @ViewBuilder
    private func setupPanel(_ id: AIProviderID, model: ProviderCardModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if id.kind == .apiKey {
                keyEntry(id)
            } else if id.kind == .oauth {
                step(1, "Sign in with the ChatGPT account you already pay for.")
                step(2, "Approve using your ChatGPT plan when the browser asks.")
                PrimaryButton(title: controller.signingIn ? "Waiting for the browser…" : "Continue with ChatGPT",
                              colorScheme: colorScheme) {
                    controller.perform(.connectChatGPT, id: id)
                }
                .disabled(controller.signingIn)
                .uiTestFrame("llm.setup.chatgpt")
            } else if case .install(let url)? = model.primary {
                step(1, "Install \(id.displayName) on this Mac.")
                step(2, "Sign in once in Terminal, then come back.")
                HStack(spacing: 10) {
                    PrimaryButton(title: "Get \(id.displayName)", colorScheme: colorScheme) {
                        controller.perform(.install(url), id: id)
                    }
                    .uiTestFrame("llm.setup.install.\(id.rawValue)")
                    checkAgainButton(id)
                }
            } else if case .copySignInCommand(let command)? = model.primary {
                step(1, "Open Terminal and sign in to \(id.displayName):")
                CommandPill(command: command, colorScheme: colorScheme, copied: controller.copiedCommand == id) {
                    controller.perform(.copySignInCommand(command), id: id)
                }
                .uiTestFrame("llm.setup.copy.\(id.rawValue)")
                step(2, "Come back and check again.")
                checkAgainButton(id)
            } else {
                Text(store.readiness[id]?.statusText ?? "Checking whether \(id.displayName) is set up…")
                    .font(.system(size: 12))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
                checkAgainButton(id)
            }
            if let message = controller.testMessages[id] {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func keyEntry(_ id: AIProviderID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            step(1, "Paste your \(id.displayName) key. It stays in this Mac's Keychain.")
            HStack(spacing: 10) {
                SecureField("Paste key", text: Binding(
                    get: { controller.keyDrafts[id] ?? "" },
                    set: { controller.keyDrafts[id] = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(WhispererColors.elevatedBackground(colorScheme)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(WhispererColors.border(colorScheme), lineWidth: 1))
                    .uiTestFrame("llm.key.field.\(id.rawValue)")
                PrimaryButton(title: "Save key", colorScheme: colorScheme) { controller.saveKey(id) }
                    .disabled((controller.keyDrafts[id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                    .uiTestFrame("llm.key.save.\(id.rawValue)")
            }
            Button("Choose model…") { controller.perform(.enterKey, id: id) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(WhispererColors.accentBlue)
                .uiTestFrame("llm.key.model.\(id.rawValue)")
        }
    }

    private func checkAgainButton(_ id: AIProviderID) -> some View {
        SecondaryButton(title: store.checking.contains(id) ? "Checking…" : "Check again", colorScheme: colorScheme) {
            controller.checkAgain(id)
        }
        .uiTestFrame("llm.setup.check.\(id.rawValue)")
    }

    // MARK: - Privacy

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("PRIVACY", detail: nil)
            HStack(alignment: .top, spacing: 12) {
                privacyFact("waveform", "Audio stays on this Mac", Color(hex: "10B981"))
                privacyFact("keyboard", "Dictation stays on this Mac", Color(hex: "06B6D4"))
                privacyFact("hand.raised.fill", "You allow each AI once", Color(hex: "8B5CF6"))
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep all meeting AI on this Mac")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))
                    Text("Nothing is sent to any AI service, whatever is chosen above.")
                        .font(.system(size: 11))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                }
                Spacer()
                Toggle("", isOn: Binding(get: { store.keepLocalOnly }, set: { store.keepLocalOnly = $0 }))
                    .toggleStyle(.switch)
                    .tint(WhispererColors.accent)
                    .labelsHidden()
                    .accessibilityIdentifier("llm.keepLocal")
                    .uiTestFrame("llm.keepLocal")
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(WhispererColors.cardBackground(colorScheme)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(WhispererColors.border(colorScheme), lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
        }
    }

    private func privacyFact(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.15)).frame(width: 26, height: 26)
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundColor(color)
            }
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Notice

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "F59E0B"))
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(WhispererColors.primaryText(colorScheme).opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { store.lastNotice = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "F59E0B").opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "F59E0B").opacity(0.2), lineWidth: 1))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Small pieces

    private func sectionTitle(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(WhispererColors.tertiaryText(colorScheme))
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func groupLabel(_ title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.0)
                .foregroundColor(WhispererColors.tertiaryText(colorScheme))
            Text(hint)
                .font(.system(size: 11))
                .foregroundColor(WhispererColors.tertiaryText(colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .padding(.leading, 4)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(WhispererColors.accent))
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(WhispererColors.primaryText(colorScheme).opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fact(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func providerColor(_ id: AIProviderID) -> Color { id.brandColor }
}

// MARK: - Row status

struct RowStatus: Equatable {
    var text: String
    var tone: ProviderCardModel.Tone
    var isWorking: Bool = false
    var progress: Double? = nil
}

/// Readiness of the on-device meeting model, for the "On this Mac" row.
enum LocalMeetingModelStatus {
    @MainActor
    static func current() -> RowStatus {
        #if canImport(FluidAudio)
        switch MeetingEngines.shared.readiness[.intelligence] {
        case .ready?:                    return RowStatus(text: "Ready", tone: .ready)
        case .downloading(let p)?:       return RowStatus(text: "Downloading \(Int(p * 100))%", tone: .attention,
                                                          isWorking: true, progress: p)
        case .preparing?, .needsWarmup?: return RowStatus(text: "Preparing…", tone: .attention, isWorking: true)
        case .needsDownload?:            return RowStatus(text: "Downloads on first use", tone: .neutral)
        case .unavailable(let why)?:     return RowStatus(text: why.isEmpty ? "Unavailable" : why, tone: .error)
        case nil:                        return RowStatus(text: "Built in", tone: .ready)
        }
        #else
        return RowStatus(text: "Built in", tone: .ready)
        #endif
    }
}

// MARK: - Current choice banner

/// "Your meeting → <AI> → Notes" with a dot travelling along the line, so the current
/// choice is the first thing the eye lands on.
private struct CurrentChoiceBanner: View {
    let colorScheme: ColorScheme
    let provider: AIProviderID?
    let keepLocal: Bool
    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            node(icon: "person.2.wave.2.fill", label: "Your meeting", color: Color(hex: "06B6D4"))
            flowLine
            providerNode
                .id(provider?.rawValue ?? "local")
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            flowLine
            node(icon: "doc.text.fill", label: "Notes & answers", color: Color(hex: "10B981"))
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(headline)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))
                    .contentTransition(.opacity)
                Text(provider == nil || keepLocal ? "Nothing leaves your Mac" : "If it's unavailable, this Mac takes over")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [WhispererColors.accentBlue.opacity(0.16), WhispererColors.accentPurple.opacity(0.08)],
                                     startPoint: .leading, endPoint: .trailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(WhispererColors.accent.opacity(0.25), lineWidth: 1))
        .shadow(color: WhispererColors.accent.opacity(0.12), radius: 10, y: 3)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }

    private var headline: String {
        if keepLocal { return "Kept on this Mac" }
        return provider?.badgeName ?? "This Mac"
    }

    /// The chosen AI, with its real icon.
    private var providerNode: some View {
        VStack(spacing: 5) {
            ProviderMark(provider: provider, size: 34)
            Text(provider?.badgeName ?? "This Mac")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                .lineLimit(1)
                .fixedSize()
        }
        .frame(minWidth: 70)
    }

    private func node(icon: String, label: String, color: Color) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 34, height: 34)
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundColor(color)
            }
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                .lineLimit(1)
                .fixedSize()
        }
        .frame(minWidth: 70)
    }

    /// A dot travelling left to right — the transcript moving through the chosen AI.
    private var flowLine: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(WhispererColors.accent.opacity(0.2)).frame(width: 34, height: 2)
            Circle()
                .fill(WhispererColors.accent)
                .frame(width: 5, height: 5)
                .shadow(color: WhispererColors.accent, radius: 3)
                .offset(x: 29 * phase)
                .opacity(reduceMotion ? 0 : 1)
        }
        .frame(width: 34, height: 34)
        .offset(y: -8)
    }
}

// MARK: - Choice row

/// One selectable option. The selection ring slides between rows (matched geometry), and
/// the inline panel unfolds under the row.
private struct ChoiceRow<Panel: View>: View {
    let colorScheme: ColorScheme
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let status: RowStatus
    let isSelected: Bool
    let namespace: Namespace.ID
    let badge: String?
    let hasPanel: Bool
    /// When set, the row shows this AI's real icon instead of the glyph tile.
    var mark: AIProviderID? = nil
    let action: () -> Void
    @ViewBuilder let panel: () -> Panel

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                HStack(spacing: 14) {
                    if let mark {
                        ProviderMark(provider: mark, size: 36)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.15)).frame(width: 36, height: 36)
                            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundColor(tint)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(WhispererColors.primaryText(colorScheme))
                            if let badge {
                                Text(badge.uppercased())
                                    .font(.system(size: 9, weight: .bold))
                                    .tracking(0.6)
                                    .foregroundColor(Color(hex: "F59E0B"))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color(hex: "F59E0B").opacity(0.15)))
                            }
                        }
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    StatusPill(status: status, colorScheme: colorScheme)
                    radio
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hasPanel {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(WhispererColors.border(colorScheme)).frame(height: 1)
                    panel()
                        .padding(.vertical, 14)
                        .padding(.leading, 64)
                        .padding(.trailing, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
        }
        // Border and selection ring live in the background layer: an overlay would sit on top
        // of the row's button and swallow its clicks.
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(hovering || hasPanel ? WhispererColors.elevatedBackground(colorScheme).opacity(0.55)
                                               : WhispererColors.cardBackground(colorScheme))
                if isSelected {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(WhispererColors.accent, lineWidth: 1.5)
                        .shadow(color: WhispererColors.accent.opacity(0.45), radius: 6)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(hasPanel ? WhispererColors.accent.opacity(0.35) : WhispererColors.border(colorScheme),
                                      lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 8 : 4, y: hovering ? 3 : 1)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    private var radio: some View {
        ZStack {
            Circle()
                .stroke(isSelected ? WhispererColors.accent : WhispererColors.tertiaryText(colorScheme), lineWidth: 1.5)
                .frame(width: 18, height: 18)
            if isSelected {
                Circle().fill(WhispererColors.accent).frame(width: 18, height: 18)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundColor(.white)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }
}

private struct StatusPill: View {
    let status: RowStatus
    let colorScheme: ColorScheme
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if status.isWorking {
                    Circle().fill(color.opacity(0.35)).frame(width: 12, height: 12)
                        .scaleEffect(pulse ? 1.5 : 0.8).opacity(pulse ? 0 : 1)
                        .onAppear { withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true } }
                }
                Circle().fill(color).frame(width: 7, height: 7)
            }
            .frame(width: 12, height: 12)
            Text(status.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                .lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.1)))
        .overlay(alignment: .bottom) {
            if let p = status.progress {
                GeometryReader { geo in
                    Capsule().fill(color).frame(width: geo.size.width * p, height: 2)
                }
                .frame(height: 2)
            }
        }
    }

    private var color: Color {
        switch status.tone {
        case .ready:     return Color(hex: "10B981")
        case .attention: return Color(hex: "F59E0B")
        case .neutral:   return Color.white.opacity(0.4)
        case .error:     return Color(hex: "EF4444")
        }
    }
}

// MARK: - Buttons

struct PrimaryButton: View {
    let title: String
    let colorScheme: ColorScheme
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(WhispererColors.accentGradient))
                .shadow(color: WhispererColors.accentPurple.opacity(hovering ? 0.45 : 0.2), radius: hovering ? 8 : 4, y: 2)
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(hovering && isEnabled ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

struct SecondaryButton: View {
    let title: String
    let colorScheme: ColorScheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(WhispererColors.primaryText(colorScheme))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(WhispererColors.elevatedBackground(colorScheme).opacity(hovering ? 1 : 0.7)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(WhispererColors.border(colorScheme), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

/// A terminal command with a copy control that turns into "Copied".
private struct CommandPill: View {
    let command: String
    let colorScheme: ColorScheme
    let copied: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("$")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                Text(command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))
                Spacer(minLength: 12)
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(copied ? Color(hex: "10B981") : WhispererColors.accentBlue)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(WhispererColors.border(colorScheme), lineWidth: 1))
            .animation(.easeOut(duration: 0.2), value: copied)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 420)
    }
}

private extension View {
    /// A gentle pulse on the header sparkle while a connected AI is in use (macOS 14+).
    @ViewBuilder
    func pulseIfAvailable(isActive: Bool) -> some View {
        if #available(macOS 14.0, *) {
            self.symbolEffect(.pulse, options: .repeating, isActive: isActive)
        } else {
            self
        }
    }
}

// MARK: - Dictation polish (local LLM)

#if !APP_STORE
/// The on-device model that cleans up dictation. Shown here as well as in the menu bar's
/// "AI Post-Processing" card, so every LLM choice lives on one page.
struct DictationPolishCard: View {
    let colorScheme: ColorScheme
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var modes = AIModeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DICTATION POLISH")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                Text("Fixes grammar and punctuation in what you dictate. Always runs on this Mac.")
                    .font(.system(size: 13))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9).fill(Color(hex: "8B5CF6").opacity(0.15)).frame(width: 36, height: 36)
                        Image(systemName: "wand.and.stars").font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(hex: "8B5CF6"))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Polish dictation with AI")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))
                        HStack(spacing: 4) {
                            Text("Mode: \(modes.activeMode.name)")
                            Text("·")
                            Button("Edit modes") { NotificationCenter.default.post(name: .switchToAIModesTab, object: nil) }
                                .buttonStyle(.plain)
                                .foregroundColor(WhispererColors.accentBlue)
                        }
                        .font(.system(size: 12))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    }
                    Spacer()
                    Toggle("", isOn: $appState.llmEnabled)
                        .toggleStyle(.switch)
                        .tint(WhispererColors.accent)
                        .labelsHidden()
                        .disabled(appState.llmPostProcessor?.isLoading == true)
                        .uiTestFrame("llm.dictation.toggle")
                }
                .padding(14)

                if appState.llmEnabled {
                    Rectangle().fill(WhispererColors.border(colorScheme)).frame(height: 1)
                    VStack(spacing: 4) {
                        ForEach(LLMModelVariant.allCases) { variant in modelRow(variant) }
                    }
                    .padding(10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(WhispererColors.cardBackground(colorScheme)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(WhispererColors.border(colorScheme), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: appState.llmEnabled)
        }
    }

    private func modelRow(_ variant: LLMModelVariant) -> some View {
        let selected = appState.selectedLLMModel == variant
        return Button { appState.selectedLLMModel = variant } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(selected ? WhispererColors.accent : WhispererColors.tertiaryText(colorScheme), lineWidth: 1.5)
                        .frame(width: 15, height: 15)
                    if selected { Circle().fill(WhispererColors.accent).frame(width: 8, height: 8) }
                }
                Text(variant.displayName)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))
                if variant.isRecommended {
                    Text("RECOMMENDED")
                        .font(.system(size: 9, weight: .bold)).tracking(0.6)
                        .foregroundColor(WhispererColors.accentBlue)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(WhispererColors.accent.opacity(0.14)))
                }
                Spacer()
                if selected, let processor = appState.llmPostProcessor {
                    LocalModelPhase(processor: processor, colorScheme: colorScheme)
                } else {
                    Text("\(variant.sizeDescription) · \(variant.speedDescription)")
                        .font(.system(size: 11))
                        .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? WhispererColors.accent.opacity(0.1) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(appState.llmPostProcessor?.isLoading == true)
    }
}

private struct LocalModelPhase: View {
    @ObservedObject var processor: LLMPostProcessor
    let colorScheme: ColorScheme

    var body: some View {
        switch processor.loadPhase {
        case .idle:
            Text("Not loaded").font(.system(size: 11)).foregroundColor(WhispererColors.tertiaryText(colorScheme))
        case .downloading(let p):
            HStack(spacing: 6) {
                ProgressView(value: max(p, 0.01)).tint(WhispererColors.accent).frame(width: 80)
                Text("\(Int(p * 100))%").font(.system(size: 11, weight: .medium))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading…").font(.system(size: 11)).foregroundColor(WhispererColors.secondaryText(colorScheme))
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(hex: "10B981"))
        case .error(let message):
            HStack(spacing: 6) {
                Text(message).font(.system(size: 11)).foregroundColor(Color(hex: "EF4444")).lineLimit(1)
                Button("Retry") { AppState.shared.preloadLLM() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                    .foregroundColor(WhispererColors.accentBlue)
            }
        }
    }
}
#endif

// MARK: - Flow layout for chips

/// Wraps chips onto as many lines as they need.
struct FlowChips: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(width, maxX), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - API key / model sheet

struct APIKeyEditorSheet: View {
    let provider: AIProviderID
    let colorScheme: ColorScheme
    @ObservedObject var store: ConnectedAIStore
    let onDone: () -> Void

    @State private var key = ""
    @State private var model = ""
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var message: String?

    init(provider: AIProviderID, colorScheme: ColorScheme, store: ConnectedAIStore? = nil,
         onDone: @escaping () -> Void) {
        self.provider = provider
        self.colorScheme = colorScheme
        self.store = store ?? .shared
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(provider.displayName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(WhispererColors.primaryText(colorScheme))
            Text("Your key is stored in this Mac's Keychain and sent only to \(provider.recipient).")
                .font(.system(size: 12))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))

            VStack(alignment: .leading, spacing: 6) {
                Text("API KEY")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                SecureField(store.apiKey(for: provider) == nil ? "Paste your key" : "•••••••• (saved — paste to replace)",
                            text: $key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("MODEL")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                HStack {
                    TextField("Model id", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Menu {
                        if models.isEmpty { Text(loadingModels ? "Loading…" : "Load models with the key first") }
                        ForEach(models, id: \.self) { m in Button(m) { model = m } }
                    } label: { Text("Choose").font(.system(size: 11, weight: .medium)) }
                    .fixedSize()
                    Button(loadingModels ? "Loading…" : "Load models") { loadModels() }
                        .disabled(loadingModels)
                }
            }

            if let message {
                Text(message).font(.system(size: 11)).foregroundColor(WhispererColors.secondaryText(colorScheme))
            }

            HStack {
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Save") {
                    if !key.isEmpty { store.setAPIKey(key, for: provider) }
                    if !model.isEmpty { store.setModel(model, for: provider) }
                    Task { await store.refreshReadiness(provider) }
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .tint(WhispererColors.accent)
                .buttonStyle(.borderedProminent)
                .uiTestFrame("llm.keysheet.save")
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(WhispererColors.background(colorScheme))
        .onAppear { model = store.model(for: provider) }
    }

    private func loadModels() {
        let candidate = key.isEmpty ? (store.apiKey(for: provider) ?? "") : key
        guard !candidate.isEmpty else { message = "Paste a key first."; return }
        loadingModels = true
        message = nil
        let provider = self.provider
        Task {
            do {
                let list: [String]
                switch provider {
                case .openAIKey:    list = try await OpenAIResponsesProvider.listModels(token: candidate)
                case .anthropicKey: list = try await AnthropicAPIProvider.listModels(apiKey: candidate)
                case .geminiKey:    list = try await GeminiAPIProvider.listModels(apiKey: candidate)
                default:            list = []
                }
                models = list
                message = list.isEmpty ? "The key works, but no models were listed." : "\(list.count) models available."
            } catch {
                message = (error as? MeetingAIProviderError)?.localizedDescription ?? error.localizedDescription
            }
            loadingModels = false
        }
    }
}

// MARK: - Settings summary row

/// One row in Settings showing who writes meeting notes, linking to the LLM page.
struct LLMSettingsSummary: View {
    let colorScheme: ColorScheme
    @ObservedObject private var store = ConnectedAIStore.shared

    var body: some View {
        SettingsRow(colorScheme: colorScheme) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Meeting notes and Ask AI")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))
                    Text(store.activeProviderID.map { "\($0.badgeName) — \($0.vendorLine.lowercased())" }
                         ?? "Written on this Mac. You can use your Claude, ChatGPT or Codex plan instead.")
                        .font(.system(size: 11))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                PrimaryButton(title: "Open LLM", colorScheme: colorScheme) {
                    NotificationCenter.default.post(name: .switchToLLMTab, object: nil)
                }
            }
        }
    }
}
