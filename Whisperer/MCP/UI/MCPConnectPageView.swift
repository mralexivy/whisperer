//
//  MCPConnectPageView.swift
//  Whisperer
//
//  The "MCP" workspace page — Wispr-style layout for connecting AI tools.
//
//  Layout:
//   • Header: title, subtitle, status badge, port field.
//   • Featured client cards: Claude Code, Claude Desktop, Codex, ChatGPT.
//   • "All other apps" section: URL row + numbered steps.
//   • Settings: LAN toggle (with honest copy), optional custom URL.
//

import SwiftUI

struct MCPConnectPageView: View {
    let colorScheme: ColorScheme
    @ObservedObject private var appState = AppState.shared

    @State private var urlCopied = false
    @State private var pulse = false
    @State private var installResults: [MCPClient: MCPInstallResult] = [:]
    @State private var showLANWarning = false
    @State private var customURLDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                headerSection
                clientCardsSection
                allOtherAppsSection
                settingsSection
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WhispererColors.background(colorScheme))
        .onAppear { customURLDraft = appState.mcpCustomURL }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MCP")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(WhispererColors.primaryText(colorScheme))

            Text("Connect your AI tools to access meeting notes and transcriptions.")
                .font(.system(size: 13))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))

            Spacer().frame(height: 4)

            HStack(spacing: 10) {
                // Status badge
                HStack(spacing: 6) {
                    ZStack {
                        if appState.mcpServerRunning {
                            Circle()
                                .fill(Color.green.opacity(0.25))
                                .frame(width: 16, height: 16)
                                .scaleEffect(pulse ? 1.5 : 1.0)
                                .opacity(pulse ? 0 : 1)
                                .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
                                .onAppear { pulse = true }
                                .onDisappear { pulse = false }
                        }
                        Circle()
                            .fill(appState.mcpServerRunning ? Color.green : Color.gray.opacity(0.4))
                            .frame(width: 8, height: 8)
                    }
                    Text(appState.mcpServerRunning ? "Active" : "Stopped")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(appState.mcpServerRunning ? .green : WhispererColors.tertiaryText(colorScheme))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(appState.mcpServerRunning
                    ? Color.green.opacity(0.1)
                    : Color.white.opacity(0.05)))

                Spacer()

                // Port field
                HStack(spacing: 6) {
                    Text("Port")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    TextField("8080", text: Binding(
                        get: { String(appState.mcpPort) },
                        set: { if let v = Int($0), v > 1024, v < 65535 { appState.mcpPort = v } }
                    ))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 50)
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(WhispererColors.primaryText(colorScheme))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(WhispererColors.border(colorScheme), lineWidth: 1)))
            }
        }
    }

    // MARK: - Client cards

    private var clientCardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MCPClient.allCases, id: \.self) { client in
                clientCard(client)
            }
        }
    }

    private func clientCard(_ client: MCPClient) -> some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(clientIconBackground(client))
                    .frame(width: 36, height: 36)
                Image(systemName: client.iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(clientIconForeground(client))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(client.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))
                Text(client.description)
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }

            Spacer()

            installButton(client)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.5))
        )
    }

    @ViewBuilder
    private func installButton(_ client: MCPClient) -> some View {
        let result = installResults[client]

        Button {
            let r = MCPClientInstaller.install(client, url: appState.mcpServerURL)
            withAnimation(.easeInOut(duration: 0.15)) {
                installResults[client] = r
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { installResults[client] = nil }
            }
        } label: {
            HStack(spacing: 5) {
                if case .installed = result {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                    Text("Added")
                        .font(.system(size: 12, weight: .semibold))
                } else if case .copied = result {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                    Text("Copied")
                        .font(.system(size: 12, weight: .semibold))
                } else if case .revealed = result {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .medium))
                    Text("Revealed")
                        .font(.system(size: 12, weight: .semibold))
                } else if case .failed(let msg) = result {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                    Text("Error")
                        .font(.system(size: 12, weight: .semibold))
                        .help(msg)
                } else {
                    Text(client == .chatgpt ? "Copy URL" : "Add to \(client.displayName)")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundColor(result.isSuccess ? .green : (result?.isError == true ? .red : .white))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(result.isSuccess
                        ? Color.green.opacity(0.15)
                        : (result?.isError == true
                            ? Color.red.opacity(0.15)
                            : Color.black))
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: result?.isSuccess)
    }

    // MARK: - All other apps

    private var allOtherAppsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ALL OTHER APPS")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                .tracking(0.8)

            VStack(alignment: .leading, spacing: 14) {
                // Step 1: copy URL
                HStack(alignment: .top, spacing: 12) {
                    stepNumber(1)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Copy your connection URL")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                        // URL pill
                        HStack(spacing: 8) {
                            Image(systemName: "link")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(WhispererColors.accentBlue)
                            Text(appState.mcpServerURL)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(appState.mcpServerURL, forType: .string)
                                withAnimation { urlCopied = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    withAnimation { urlCopied = false }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: urlCopied ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 11, weight: .medium))
                                    if urlCopied {
                                        Text("Copied!")
                                            .font(.system(size: 11, weight: .medium))
                                            .transition(.opacity)
                                    }
                                }
                                .foregroundColor(urlCopied ? .green : WhispererColors.accentBlue)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(
                                    urlCopied
                                        ? Color.green.opacity(0.1)
                                        : WhispererColors.accentBlue.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                            .animation(.easeInOut(duration: 0.15), value: urlCopied)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(WhispererColors.accentBlue.opacity(0.06))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(WhispererColors.accentBlue.opacity(0.2), lineWidth: 1))
                        )
                    }
                }

                Divider().opacity(0.3)

                HStack(alignment: .top, spacing: 12) {
                    stepNumber(2)
                    Text("Add it to your AI tool as a custom MCP server or connector")
                        .font(.system(size: 13))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                }

                Divider().opacity(0.3)

                HStack(alignment: .top, spacing: 12) {
                    stepNumber(3)
                    Text("Start asking your AI about your meeting notes and transcriptions")
                        .font(.system(size: 13))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.5))
            )
        }
    }

    private func stepNumber(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(WhispererColors.accentBlue)
            .frame(width: 20, height: 20)
            .background(Circle().fill(WhispererColors.accentBlue.opacity(0.12)))
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SETTINGS")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                .tracking(0.8)

            // LAN toggle
            SettingsRow(colorScheme: colorScheme) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(
                                colors: [Color.orange.opacity(0.18), Color.orange.opacity(0.08)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 36, height: 36)
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.orange)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Allow LAN access")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))
                        Text(appState.mcpLANEnabled
                            ? "On — any device on your Wi-Fi can access your meeting notes and transcriptions"
                            : "Off — only apps on this Mac can connect")
                            .font(.system(size: 11))
                            .foregroundColor(appState.mcpLANEnabled ? .orange : WhispererColors.secondaryText(colorScheme))
                    }

                    Spacer()

                    Toggle("", isOn: $appState.mcpLANEnabled)
                        .toggleStyle(.switch)
                        .tint(WhispererColors.accent)
                        .labelsHidden()
                }
            }

            // Custom URL
            SettingsRow(colorScheme: colorScheme) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(LinearGradient(
                                    colors: [Color.purple.opacity(0.18), Color.purple.opacity(0.08)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 36, height: 36)
                            Image(systemName: "globe")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.purple)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Public URL override")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(WhispererColors.primaryText(colorScheme))
                            Text("Paste a tunnel URL (Cloudflare Tunnel, Tailscale Funnel, ngrok) to reach Whisperer from other devices")
                                .font(.system(size: 11))
                                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("https://your-tunnel.trycloudflare.com/mcp", text: $customURLDraft)
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.plain)
                            .foregroundColor(WhispererColors.primaryText(colorScheme))
                            .onChange(of: customURLDraft) { val in
                                appState.mcpCustomURL = val
                            }

                        if !customURLDraft.isEmpty {
                            Image(systemName: appState.mcpCustomURLIsValid ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(appState.mcpCustomURLIsValid ? .green : .orange)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(WhispererColors.border(colorScheme), lineWidth: 1))
                    )

                    if !customURLDraft.isEmpty && !appState.mcpCustomURLIsValid {
                        Text("Enter a valid http or https URL")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                }
            }
        }
    }

    // MARK: - Icon helpers

    private func clientIconBackground(_ client: MCPClient) -> LinearGradient {
        switch client {
        case .claudeCode:
            return LinearGradient(colors: [Color(hex: "DA7756").opacity(0.22), Color(hex: "D97B68").opacity(0.12)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .claudeDesktop:
            return LinearGradient(colors: [Color(hex: "DA7756").opacity(0.22), Color(hex: "D97B68").opacity(0.12)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .codex:
            return LinearGradient(colors: [Color.mint.opacity(0.22), Color.teal.opacity(0.12)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .chatgpt:
            return LinearGradient(colors: [Color.green.opacity(0.18), Color.teal.opacity(0.1)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func clientIconForeground(_ client: MCPClient) -> Color {
        switch client {
        case .claudeCode, .claudeDesktop: return Color(hex: "DA7756")
        case .codex: return .mint
        case .chatgpt: return .green
        }
    }
}

// MARK: - MCPInstallResult helpers

private extension MCPInstallResult {
    var isSuccess: Bool {
        switch self {
        case .installed, .copied, .revealed: return true
        case .failed: return false
        }
    }
    var isError: Bool {
        if case .failed = self { return true }
        return false
    }
}

private extension Optional where Wrapped == MCPInstallResult {
    var isSuccess: Bool { self?.isSuccess == true }
    var isError: Bool { self?.isError == true }
}
