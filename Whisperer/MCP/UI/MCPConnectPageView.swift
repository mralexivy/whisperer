//
//  MCPConnectPageView.swift
//  Whisperer
//
//  The "MCP" workspace page — connect your AI apps to Whisperer.
//
//  Structure (progressive disclosure, one primary action at a time):
//   1. Hero — what this does in one sentence, a single on/off switch with a live status.
//      Off: explains what turning on does, with one "Turn on" button.
//   2. Connect an app — the main act. Apps found on this Mac (and already-connected ones)
//      come first and are badged; the rest sit under "More apps". Picking a tile opens an
//      inline panel: 1-2-3 of what happens, ONE primary button, then a drawn-in check and an
//      automatic connection test. "Show config" holds the raw snippet for manual setup.
//      Connecting while off turns Whisperer on as its first step.
//   3. Advanced (collapsed) — endpoints + test, port, access token, LAN, public URL.
//
//  Every side effect goes through `MCPConnectActions` so click tests can inject them.
//

import SwiftUI

struct MCPConnectPageView: View {
    let colorScheme: ColorScheme
    let testScope: String

    @ObservedObject private var appState = AppState.shared
    @StateObject private var model: MCPConnectPageModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace

    @State private var customURLDraft = ""
    @State private var portDraft = ""
    /// Whether AI apps may add notes to meetings (MCPNoteWrites).
    @AppStorage(MCPNoteWrites.key) private var allowNoteWrites = true
    @State private var tokenRevealed = false
    @State private var confirmRegenerate = false
    @State private var appeared = false

    init(colorScheme: ColorScheme, actions: MCPConnectActions = .live, testScope: String = "") {
        self.colorScheme = colorScheme
        self.testScope = testScope
        _model = StateObject(wrappedValue: MCPConnectPageModel(actions: actions))
    }

    private var info: MCPConnectionInfo { appState.mcpConnectionInfo }
    private var serverOn: Bool { appState.mcpEnabled }
    private var running: Bool { appState.mcpServerRunning }

    private var spring: Animation? {
        reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.84)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    hero
                    appsSection(proxy: proxy)
                    advancedSection
                        .id("mcp.advanced.anchor")
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
                .frame(maxWidth: 1080, alignment: .leading)
                .frame(maxWidth: .infinity)
                .opacity(appeared || reduceMotion ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WhispererColors.background(colorScheme))
        .environment(\.uiTestScope, testScope)
        .onAppear {
            customURLDraft = appState.mcpCustomURL
            portDraft = String(appState.mcpPort)
            model.refreshDetection(info: info)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) { appeared = true }
        }
        .onChange(of: info) { _, newInfo in model.connectionInfoChanged(newInfo) }
        .onChange(of: appState.mcpPort) { _, port in
            if Int(portDraft) != port { portDraft = String(port) }
        }
        .alert("Regenerate access token?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { appState.regenerateMCPToken() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apps set up with the current token stop connecting until you connect them again.")
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                heroIcon
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect your AI apps")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Let your AI apps read your meetings and transcriptions — locally. Nothing leaves your Mac.")
                        .font(.system(size: 13.5))
                        .foregroundColor(Color.white.opacity(0.55))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                powerControl
            }

            Rectangle()
                .fill(LinearGradient(colors: [WhispererColors.accentBlue.opacity(serverOn ? 0.35 : 0.12),
                                              WhispererColors.accentPurple.opacity(serverOn ? 0.25 : 0.08),
                                              .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)

            Group {
                if serverOn { heroOnStrip } else { heroOffStrip }
            }
            .transition(.opacity)
        }
        .padding(24)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(WhispererColors.cardBackground(colorScheme))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(RadialGradient(colors: [WhispererColors.accentBlue.opacity(serverOn ? 0.2 : 0.06), .clear],
                                         center: .topLeading, startRadius: 0, endRadius: 520))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(RadialGradient(colors: [WhispererColors.accentPurple.opacity(serverOn ? 0.14 : 0.03), .clear],
                                         center: .topTrailing, startRadius: 0, endRadius: 420))
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Color.white.opacity(serverOn ? 0.09 : 0.06), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.14), radius: 16, y: 6)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: serverOn)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: running)
    }

    private var heroIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(serverOn ? AnyShapeStyle(LinearGradient(colors: [WhispererColors.accentBlue, WhispererColors.accentPurple],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                               : AnyShapeStyle(Color.white.opacity(0.06)))
                .frame(width: 52, height: 52)
                .shadow(color: WhispererColors.accentBlue.opacity(serverOn ? 0.45 : 0), radius: 14, y: 3)
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(serverOn ? .white : Color.white.opacity(0.45))
        }
    }

    private var statusColor: Color {
        running ? MCPPalette.success : (serverOn ? MCPPalette.warning : Color.white.opacity(0.3))
    }

    private var statusText: String {
        running ? "Running" : (serverOn ? "Starting…" : "Off")
    }

    private var powerControl: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                MCPPulsingDot(color: statusColor, active: running, size: 7)
                Text(statusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(running ? MCPPalette.success : Color.white.opacity(0.55))
                    .contentTransition(.opacity)
            }
            .padding(.leading, 4).padding(.trailing, 12)
            .frame(height: 30)
            .background(Capsule().fill(statusColor.opacity(running ? 0.12 : 0.06)))

            Toggle("", isOn: Binding(get: { appState.mcpEnabled },
                                     set: { model.actions.setServerEnabled($0) }))
                .toggleStyle(.switch)
                .tint(WhispererColors.accent)
                .labelsHidden()
                .controlSize(.large)
                .help(serverOn ? "Turn off — connected apps lose access" : "Turn on")
                .uiTestFrame("mcp.power")
        }
    }

    private var heroOnStrip: some View {
        HStack(spacing: 8) {
            MCPChip(icon: appState.mcpLANEnabled ? "wifi" : "lock.laptopcomputer",
                    text: appState.mcpLANEnabled ? "This Mac + your network" : "Only this Mac",
                    color: appState.mcpLANEnabled ? MCPPalette.warning : WhispererColors.accentBlue)
            MCPChip(icon: allowNoteWrites ? "note.text.badge.plus" : "eye",
                    text: allowNoteWrites ? "Reads + adds notes" : "Read-only",
                    color: WhispererColors.accentPurple)
            MCPChip(icon: appState.mcpTokenRequired ? "key.fill" : "key",
                    text: appState.mcpTokenRequired ? "Token required" : "No token",
                    color: Color(hex: "FBBF24"))
            if model.connectedCount > 0 {
                MCPChip(icon: "link", text: "\(model.connectedCount) app\(model.connectedCount == 1 ? "" : "s") connected",
                        color: MCPPalette.success)
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Text(info.url)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                MCPCopyButton(text: info.url, copy: model.actions.copy, testID: "mcp.copy.heroURL")
            }
        }
    }

    private var heroOffStrip: some View {
        HStack(spacing: 14) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(WhispererColors.accentBlue)
            Text("Turning on starts a small read-only server that only apps on this Mac can reach. They can look up your notes — never change them.")
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.6))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                model.actions.setServerEnabled(true)
            } label: {
                Label("Turn on", systemImage: "power")
            }
            .buttonStyle(MCPPrimaryButtonStyle(large: true))
            .uiTestFrame("mcp.turnOn")
        }
    }

    // MARK: - Apps

    private func appsSection(proxy: ScrollViewProxy) -> some View {
        let arrangement = model.arrangement
        let showSplit = model.detectionFinished && !arrangement.onThisMac.isEmpty
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                MCPIconTile(icon: "square.grid.2x2.fill", color: WhispererColors.accentPurple, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect an app")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(serverOn
                         ? "Pick the app you use — Whisperer sets it up for you."
                         : "Pick the app you use — Whisperer turns on and sets it up for you.")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.5))
                }
                Spacer()
                Button {
                    model.refreshDetection(info: info)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(MCPSecondaryButtonStyle())
                .help("Look for apps again")
                .uiTestFrame("mcp.rescan")
            }

            if showSplit {
                MCPSectionLabel(text: "On this Mac")
                    .padding(.top, 2)
                grid(arrangement.onThisMac, proxy: proxy)

                moreAppsToggle(count: arrangement.more.count)
                if model.showMoreApps {
                    grid(arrangement.more, proxy: proxy)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            } else if model.detectionFinished {
                grid(MCPClient.allCases, proxy: proxy)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 14, height: 14)
                    Text("Looking for AI apps on this Mac…")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
                .transition(.opacity)
            }
        }
    }

    private func moreAppsToggle(count: Int) -> some View {
        Button {
            withAnimation(spring) { model.showMoreApps.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(model.showMoreApps ? 90 : 0))
                Text("More apps")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .foregroundColor(Color.white.opacity(0.6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerOnHover()
        .uiTestFrame("mcp.moreApps")
    }

    private func grid(_ clients: [MCPClient], proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(clients) { client in
                    MCPClientTile(client: client,
                                  presence: model.presence(for: client),
                                  selected: model.selected == client,
                                  namespace: selectionNamespace) {
                        withAnimation(spring) { model.toggleSelection(client) }
                    }
                }
            }
            if let selected = model.selected, clients.contains(selected) {
                MCPClientConnectPanel(
                    client: selected,
                    info: info,
                    port: appState.mcpPort,
                    serverOn: serverOn,
                    needsPublicURL: selected == .chatgpt && !hasPublicHTTPS,
                    model: model,
                    onOpenAdvanced: {
                        withAnimation(spring) { model.advancedExpanded = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            withAnimation(spring) { proxy.scrollTo("mcp.advanced.anchor", anchor: .top) }
                        }
                    },
                    onClose: { withAnimation(spring) { model.selected = nil } })
                .id(selected)
                .transition(reduceMotion ? .opacity
                            : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                                                        .combined(with: .offset(y: -8)),
                                          removal: .opacity))
            }
        }
    }

    private var hasPublicHTTPS: Bool {
        appState.mcpCustomURLIsValid
            && appState.mcpCustomURL.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("https://")
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(spring) { model.advancedExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    MCPIconTile(icon: "slider.horizontal.3", color: Color(hex: "94A3B8"), size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Advanced")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text("Endpoints, port, access token and network access")
                            .font(.system(size: 11.5))
                            .foregroundColor(Color.white.opacity(0.45))
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.45))
                        .rotationEffect(.degrees(model.advancedExpanded ? 180 : 0))
                }
                .padding(14)
                .contentShape(Rectangle())
                .background(MCPHoverBackground(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .uiTestFrame("mcp.advanced")

            if model.advancedExpanded {
                advancedContent
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var advancedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            advancedGroup("Endpoints") {
                endpointRow(icon: "bolt.horizontal.fill", color: WhispererColors.accentBlue,
                            title: "Streamable HTTP", badge: "Recommended",
                            helper: "What current MCP clients use.",
                            url: info.url, testID: "mcp.copy.streamable")
                rowDivider
                endpointRow(icon: "dot.radiowaves.left.and.right", color: .orange,
                            title: "Legacy SSE", badge: "Older clients",
                            helper: "For clients that only speak the 2024 SSE transport.",
                            url: info.sseURL, testID: "mcp.copy.sse")
                rowDivider
                testRow
            }

            advancedGroup("Access") {
                settingRow(icon: "key.fill", color: Color(hex: "FBBF24"),
                           title: "Require access token",
                           helper: appState.mcpLANEnabled
                           ? "Always on while network access is allowed — other devices must prove they're yours."
                           : "Optional on this Mac: the server only listens locally and blocks web pages. Turn on to make every app authenticate.") {
                    Toggle("", isOn: Binding(get: { appState.mcpTokenRequired },
                                             set: { appState.mcpRequireToken = $0 }))
                        .toggleStyle(.switch)
                        .tint(WhispererColors.accent)
                        .labelsHidden()
                        .disabled(appState.mcpLANEnabled)
                        .uiTestFrame("mcp.requireToken")
                }
                if appState.mcpTokenRequired {
                    rowDivider
                    tokenRow
                        .transition(.opacity)
                }
            }

            advancedGroup("Notes") {
                settingRow(icon: "note.text.badge.plus", color: Color(hex: "06B6D4"),
                           title: "Let AI apps add notes",
                           helper: "Claude, Codex and others can save their thoughts to a meeting. They show up labelled with the app's name, Ask AI uses them, and apps can only change notes they added — never yours.") {
                    Toggle("", isOn: $allowNoteWrites)
                        .toggleStyle(.switch)
                        .tint(WhispererColors.accent)
                        .labelsHidden()
                        .uiTestFrame("mcp.allowNotes")
                }
            }

            advancedGroup("Network") {
                settingRow(icon: "number", color: Color(hex: "22D3EE"),
                           title: "Port",
                           helper: "Change it only if another app already uses \(appState.mcpPort). Reconnect your apps afterwards.") {
                    TextField("8080", text: $portDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .foregroundColor(.white)
                        .frame(width: 64)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(fieldBackground)
                        .onSubmit(commitPort)
                        .onChange(of: portDraft) { _, _ in commitPort() }
                        .uiTestFrame("mcp.port")
                }
                rowDivider
                settingRow(icon: "network.badge.shield.half.filled", color: .orange,
                           title: "Allow devices on your network",
                           helper: appState.mcpLANEnabled
                           ? "On — devices on your Wi-Fi that have the token can read your meeting notes and transcriptions."
                           : "Off — only apps on this Mac can connect.",
                           helperColor: appState.mcpLANEnabled ? .orange : nil) {
                    Toggle("", isOn: $appState.mcpLANEnabled)
                        .toggleStyle(.switch)
                        .tint(WhispererColors.accent)
                        .labelsHidden()
                        .uiTestFrame("mcp.lan")
                }
                rowDivider
                publicURLRow
            }
        }
    }

    private func advancedGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MCPSectionLabel(text: title).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 16).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(WhispererColors.cardBackground(colorScheme)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.08), radius: 6, y: 2)
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1).padding(.leading, 44)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.6))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func settingRow<Trailing: View>(icon: String, color: Color, title: String, helper: String,
                                            helperColor: Color? = nil,
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 14) {
            MCPIconTile(icon: icon, color: color, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Text(helper)
                    .font(.system(size: 11.5))
                    .foregroundColor(helperColor ?? Color.white.opacity(0.5))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 12)
    }

    private func endpointRow(icon: String, color: Color, title: String, badge: String,
                             helper: String, url: String, testID: String) -> some View {
        HStack(spacing: 14) {
            MCPIconTile(icon: icon, color: color, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                    Text(badge)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(color)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(color.opacity(0.12)))
                    Text(helper)
                        .font(.system(size: 11.5))
                        .foregroundColor(Color.white.opacity(0.4))
                        .lineLimit(1)
                }
                Text(url)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            MCPCopyButton(text: url, copy: model.actions.copy, testID: testID)
        }
        .padding(.vertical, 12)
    }

    private var testRow: some View {
        HStack(alignment: .center, spacing: 14) {
            MCPIconTile(icon: "stethoscope", color: MCPPalette.success, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("Test connection")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                testStatus
            }
            Spacer(minLength: 12)
            Button {
                model.testFromAdvanced(info: info, port: appState.mcpPort)
            } label: {
                HStack(spacing: 6) {
                    if model.advancedTest.isBusy {
                        ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    }
                    Text(model.advancedTest.isBusy ? "Testing…" : "Run test")
                }
            }
            .buttonStyle(MCPSecondaryButtonStyle())
            .disabled(model.advancedTest.isBusy || !running)
            .uiTestFrame("mcp.test")
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder private var testStatus: some View {
        switch model.advancedTest {
        case .finished(let r):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: r.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.system(size: 11))
                    Text(r.message)
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(r.success ? MCPPalette.success : MCPPalette.danger)
                if let fix = MCPConnectGuide.fix(for: r, port: appState.mcpPort) {
                    Text(fix)
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.5))
                } else if !r.steps.isEmpty {
                    Text(r.steps.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.4))
                }
            }
            .transition(.opacity)
        default:
            Text(running ? "Talks to Whisperer exactly like an app would: health, initialize, list tools."
                         : "Turn Whisperer on to test it.")
                .font(.system(size: 11.5))
                .foregroundColor(Color.white.opacity(0.5))
        }
    }

    private var tokenRow: some View {
        HStack(spacing: 10) {
            Text(tokenRevealed ? appState.mcpBearerToken : maskedToken)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fieldBackground)
            Button {
                tokenRevealed.toggle()
            } label: {
                Image(systemName: tokenRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 14)
            }
            .buttonStyle(MCPSecondaryButtonStyle())
            .help(tokenRevealed ? "Hide token" : "Show token")
            .uiTestFrame("mcp.token.reveal")
            MCPCopyButton(text: appState.mcpBearerToken, copy: model.actions.copy, testID: "mcp.token.copy")
            Button("Regenerate") { confirmRegenerate = true }
                .buttonStyle(MCPSecondaryButtonStyle())
                .uiTestFrame("mcp.token.regenerate")
        }
        .padding(.leading, 44)
        .padding(.vertical, 12)
    }

    private var maskedToken: String {
        String(repeating: "•", count: 16) + appState.mcpBearerToken.suffix(4)
    }

    private var publicURLRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingRow(icon: "globe", color: .purple,
                       title: "Public URL",
                       helper: "Only for reaching Whisperer from elsewhere — e.g. ChatGPT. Paste a tunnel URL (Cloudflare Tunnel, Tailscale Funnel, ngrok).") {
                EmptyView()
            }
            .padding(.bottom, -10)
            HStack(spacing: 8) {
                TextField("", text: $customURLDraft,
                          prompt: Text(verbatim: "https://your-tunnel.trycloudflare.com/mcp")
                            .foregroundColor(Color.white.opacity(0.3)))
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .onChange(of: customURLDraft) { _, value in appState.mcpCustomURL = value }
                    .uiTestFrame("mcp.publicURL")
                if !customURLDraft.isEmpty {
                    Image(systemName: appState.mcpCustomURLIsValid ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(appState.mcpCustomURLIsValid ? MCPPalette.success : .orange)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(fieldBackground)
            .padding(.leading, 44)
            if !customURLDraft.isEmpty && !appState.mcpCustomURLIsValid {
                Text("Enter a valid http or https URL")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .padding(.leading, 44)
            }
        }
        .padding(.bottom, 12)
    }

    private func commitPort() {
        if let v = Int(portDraft.trimmingCharacters(in: .whitespaces)), v > 1024, v < 65535, v != appState.mcpPort {
            appState.mcpPort = v
        }
    }
}

// MARK: - Hover background

/// Card surface that lifts slightly on hover.
struct MCPHoverBackground: View {
    var cornerRadius: CGFloat = 14
    @State private var hovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(hovered ? WhispererColors.elevatedBackground(.dark).opacity(0.7)
                          : WhispererColors.cardBackground(.dark))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(hovered ? 0.1 : 0.06), lineWidth: 1))
            .shadow(color: Color.black.opacity(hovered ? 0.12 : 0.06), radius: hovered ? 8 : 4, y: hovered ? 3 : 1)
            .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { hovered = h } }
    }
}

// MARK: - App tile

private struct MCPClientTile: View {
    let client: MCPClient
    let presence: MCPClientPresence
    let selected: Bool
    let namespace: Namespace.ID
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                MCPClientIcon(client: client, size: 38, glowing: selected || hovered)
                VStack(alignment: .leading, spacing: 3) {
                    Text(client.displayName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    statusLine
                }
                Spacer(minLength: 4)
                trailingMark
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .offset(y: hovered && !selected && !reduceMotion ? -2 : 0)
        }
        .buttonStyle(.plain)
        .pointerOnHover()
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { hovered = h } }
        .accessibilityLabel("\(client.displayName)\(statusAccessibility)")
        .uiTestFrame("mcp.tile.\(client.rawValue)")
    }

    private var statusAccessibility: String {
        switch presence.config {
        case .configured: return ", connected"
        case .outdated: return ", needs update"
        case .notConfigured: return presence.installed ? ", on this Mac" : ""
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch presence.config {
        case .configured:
            label("Connected", icon: "checkmark.circle.fill", color: MCPPalette.success)
        case .outdated:
            label("Needs update", icon: "arrow.triangle.2.circlepath", color: MCPPalette.warning)
        case .notConfigured:
            if presence.installed {
                label("Installed", icon: "checkmark.seal.fill", color: WhispererColors.accentBlue)
            } else {
                Text(client.tileSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
    }

    private func label(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
            Text(text).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundColor(color)
    }

    private var trailingMark: some View {
        Image(systemName: selected ? "chevron.up" : "chevron.down")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(selected ? WhispererColors.accent : Color.white.opacity(hovered ? 0.55 : 0.25))
            .frame(width: 20, height: 20)
            .background(Circle().fill(selected ? WhispererColors.accent.opacity(0.15) : .clear))
    }

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hovered || selected ? WhispererColors.elevatedBackground(.dark).opacity(0.75)
                                          : WhispererColors.cardBackground(.dark))
            if selected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(WhispererColors.accent.opacity(0.85), lineWidth: 1.5)
                    .shadow(color: WhispererColors.accent.opacity(0.45), radius: 8)
                    .matchedGeometryEffect(id: "mcp.selection", in: namespace)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(hovered ? client.tint.opacity(0.35) : Color.white.opacity(0.06), lineWidth: 1)
            }
        }
        .shadow(color: Color.black.opacity(hovered ? 0.14 : 0.07), radius: hovered ? 10 : 4, y: hovered ? 4 : 1)
    }
}
