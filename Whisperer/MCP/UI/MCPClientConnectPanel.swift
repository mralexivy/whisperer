//
//  MCPClientConnectPanel.swift
//  Whisperer
//
//  The inline panel that opens under a picked app: what will happen (1-2-3), one primary
//  button, then the result — a drawn-in check, followed by a live connection test — or an
//  error with a fix. "Show config" reveals the exact snippet, CLI command and file path for
//  people who prefer to paste it themselves.
//

import SwiftUI

struct MCPClientConnectPanel: View {
    let client: MCPClient
    let info: MCPConnectionInfo
    let port: Int
    let serverOn: Bool
    /// ChatGPT only: no public https URL is set yet.
    let needsPublicURL: Bool
    @ObservedObject var model: MCPConnectPageModel
    let onOpenAdvanced: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showConfig = false

    private var actions: MCPConnectActions { model.actions }
    private var autoInstall: Bool { actions.canAutoInstall(client) }
    private var phase: MCPConnectPhase { model.phase(for: client) }
    private var presence: MCPClientPresence { model.presence(for: client) }
    private var id: String { client.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if needsPublicURL { publicURLCallout }
            stepsRow
            actionRow
            resultArea
            if showConfig {
                configDisclosure
                    .transition(reduceMotion ? .opacity
                                : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(WhispererColors.cardBackground(.dark))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(RadialGradient(colors: [client.tint.opacity(0.14), .clear],
                                         center: .topLeading, startRadius: 0, endRadius: 420))
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(LinearGradient(colors: [client.tint.opacity(0.35), Color.white.opacity(0.05)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.14), radius: 14, y: 6)
        .uiTestFrame("mcp.panel.\(id)")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            MCPClientIcon(client: client, size: 44, glowing: true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(client == .other ? "Connect any MCP client" : "Connect \(client.displayName)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    statusBadge
                }
                Text(client.description)
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.5))
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.6))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.06)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerOnHover()
            .help("Close")
            .uiTestFrame("mcp.close.\(id)")
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch presence.config {
        case .configured:
            MCPChip(icon: "checkmark.circle.fill", text: "Connected", color: MCPPalette.success)
        case .outdated:
            MCPChip(icon: "arrow.triangle.2.circlepath", text: "Needs update", color: MCPPalette.warning)
        case .notConfigured:
            if presence.installed {
                MCPChip(icon: "checkmark.seal.fill", text: "On this Mac", color: WhispererColors.accentBlue)
            }
        }
    }

    // MARK: ChatGPT callout

    private var publicURLCallout: some View {
        HStack(spacing: 12) {
            MCPIconTile(icon: "globe", color: MCPPalette.warning, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("ChatGPT needs a public URL")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white)
                Text("It connects from the cloud, so it can't reach localhost. Add a tunnel URL first.")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color.white.opacity(0.55))
            }
            Spacer()
            Button("Set public URL", action: onOpenAdvanced)
                .buttonStyle(MCPSecondaryButtonStyle())
                .uiTestFrame("mcp.setPublicURL")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(MCPPalette.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(MCPPalette.warning.opacity(0.2), lineWidth: 1))
    }

    // MARK: Steps

    private var stepsRow: some View {
        let steps = MCPConnectGuide.steps(for: client, autoInstall: autoInstall, serverOn: serverOn)
        return HStack(alignment: .top, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                stepCard(index: index, step: step, done: stepDone(step))
            }
        }
    }

    /// After a successful connect, the steps Whisperer did itself show as done.
    private func stepDone(_ step: MCPConnectStep) -> Bool {
        guard step.automatic, case .succeeded(let outcome) = phase else { return false }
        if case .installed = outcome { return true }
        return step.title == "Whisperer turns on"
    }

    private func stepCard(index: Int, step: MCPConnectStep, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(done ? AnyShapeStyle(MCPPalette.success.opacity(0.18))
                               : AnyShapeStyle(WhispererColors.accentBlue.opacity(0.16)))
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(MCPPalette.success)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(WhispererColors.accentBlue)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white)
                Text(step.detail)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color.white.opacity(0.5))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.05), lineWidth: 1))
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) {
                    model.connect(client, info: info, port: port)
                }
            } label: {
                HStack(spacing: 7) {
                    if phase == .working {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: autoInstall ? "bolt.fill" : "doc.on.clipboard.fill")
                            .font(.system(size: 11, weight: .bold))
                    }
                    Text(MCPConnectGuide.primaryTitle(for: client, autoInstall: autoInstall,
                                                      serverOn: serverOn, config: presence.config))
                }
            }
            .buttonStyle(MCPPrimaryButtonStyle(large: true))
            .disabled(phase == .working)
            .uiTestFrame("mcp.primary.\(id)")

            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
                    showConfig.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showConfig ? 90 : 0))
                    Text(showConfig ? "Hide config" : "Show config")
                }
            }
            .buttonStyle(MCPSecondaryButtonStyle())
            .uiTestFrame("mcp.showConfig.\(id)")

            Spacer()
        }
    }

    // MARK: Result

    @ViewBuilder private var resultArea: some View {
        switch phase {
        case .idle, .working:
            EmptyView()
        case .succeeded(let outcome):
            successView(outcome)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
        case .failed(let message):
            messageRow(icon: "exclamationmark.triangle.fill", color: MCPPalette.danger,
                       title: message, detail: MCPConnectGuide.installFix(for: client))
                .uiTestFrame("mcp.error.\(id)")
                .transition(.opacity)
        }
    }

    private func successView(_ outcome: MCPConnectOutcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                MCPSuccessCheck(size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(successTitle(outcome))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text(successDetail(outcome))
                        .font(.system(size: 11.5))
                        .foregroundColor(Color.white.opacity(0.55))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            testLine
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(MCPPalette.success.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(MCPPalette.success.opacity(0.18), lineWidth: 1))
        .uiTestFrame("mcp.success.\(id)")
    }

    private func successTitle(_ outcome: MCPConnectOutcome) -> String {
        switch outcome {
        case .installed:
            return "\(client.displayName) is set up"
        case .copied, .revealed:
            return client == .chatgpt ? "Connector URL copied" : "Setup copied to your clipboard"
        }
    }

    private func successDetail(_ outcome: MCPConnectOutcome) -> String {
        switch outcome {
        case .installed(let path):
            let display = path.replacingOccurrences(of: MCPClientDetector.realHome.path, with: "~")
            return "Added to \(display). \(MCPConnectGuide.restartStep(for: client).title) to start using it."
        case .revealed:
            return "The config file couldn't be updated safely, so it's open in Finder — paste the setup into it."
        case .copied(let hint):
            return hint
        }
    }

    @ViewBuilder private var testLine: some View {
        switch model.connectTest {
        case .idle:
            EmptyView()
        case .waitingForServer:
            progressLine("Starting Whisperer's server…")
        case .testing:
            progressLine("Checking that apps can reach Whisperer…")
        case .finished(let r):
            if r.success {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(MCPPalette.success)
                    Text("Whisperer is reachable — \(r.message.replacingOccurrences(of: "Connected — ", with: ""))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(MCPPalette.success)
                }
                .uiTestFrame("mcp.testOK.\(id)")
                .transition(.opacity)
            } else {
                messageRow(icon: "exclamationmark.triangle.fill", color: MCPPalette.danger,
                           title: r.message, detail: MCPConnectGuide.fix(for: r, port: port))
                    .uiTestFrame("mcp.testFailed.\(id)")
            }
        }
    }

    private func progressLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 14, height: 14)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.6))
        }
    }

    private func messageRow(icon: String, color: Color, title: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(color)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundColor(Color.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.08)))
    }

    // MARK: Show config

    private var configDisclosure: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(client.instructions)
                .font(.system(size: 11.5))
                .foregroundColor(Color.white.opacity(0.55))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if let cli = client.cliCommand(for: info) {
                MCPCodeBlock(title: "Terminal", code: cli, copy: actions.copy,
                             copyTestID: "mcp.copy.cli.\(id)")
            }
            MCPCodeBlock(title: snippetTitle, code: client.snippet(for: info), copy: actions.copy,
                         copyTestID: "mcp.copy.snippet.\(id)",
                         textTestID: "mcp.snippetText.\(id)")

            if let path = client.configPathDisplay {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(WhispererColors.accentPurple)
                    Text(path)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        actions.reveal(client)
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .buttonStyle(MCPSecondaryButtonStyle())
                    .uiTestFrame("mcp.reveal.\(id)")
                }
            }
        }
    }

    private var snippetTitle: String {
        switch client.snippetFormat {
        case .json: return "JSON config"
        case .toml: return "TOML config"
        case .text: return client == .chatgpt ? "Connector URL" : "Connection details"
        }
    }
}
