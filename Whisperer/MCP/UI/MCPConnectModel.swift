//
//  MCPConnectModel.swift
//  Whisperer
//
//  Everything the MCP "Connect" page decides without drawing anything:
//
//  • `MCPClient.configState(info:fileContents:)` — pure: does a client's config file already
//    hold a Whisperer entry, and does it still point at the current URL and token?
//  • `MCPClientDetector` — which AI apps are on this Mac (best effort, read-only, never writes),
//    and the "on this Mac first" ordering of the app picker.
//  • `MCPConnectGuide` — the numbered "what happens next" steps and button titles per client.
//  • `MCPConnectActions` — every side effect the page performs (write a config, copy, reveal
//    in Finder, test the server, switch it on), injectable so click tests never touch the
//    user's real ~/.codex, ~/.claude.json, ~/.cursor or pasteboard.
//  • `MCPConnectPageModel` — the page's state machine: selection, connect → test, detection.
//

import Combine
import Foundation
import SwiftUI

// MARK: - Config state (pure)

/// Whether a client's config file already contains Whisperer.
nonisolated enum MCPConfigState: Equatable, Sendable {
    case notConfigured
    /// A Whisperer entry exists and matches the current URL (and token, when one is required).
    case configured
    /// A Whisperer entry exists but points at another URL/port or lacks the current token.
    case outdated
}

extension MCPClient {

    /// Reads a client's config text and reports whether Whisperer is already in it. Pure and
    /// best-effort: unparseable text counts as not configured, never as an error.
    nonisolated func configState(info: MCPConnectionInfo, fileContents: String?) -> MCPConfigState {
        guard let text = fileContents, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .notConfigured
        }
        let entryText: String
        switch snippetFormat {
        case .toml:
            guard let block = Self.codexServerLines(in: text) else { return .notConfigured }
            entryText = block
        case .json:
            guard let root = jsonRootKey,
                  let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let servers = parsed[root] as? [String: Any],
                  let entry = servers[Self.serverName] else { return .notConfigured }
            guard JSONSerialization.isValidJSONObject(entry),
                  let data = try? JSONSerialization.data(withJSONObject: entry, options: [.withoutEscapingSlashes]) else {
                return .outdated
            }
            entryText = String(decoding: data, as: UTF8.self)
        case .text:
            return .notConfigured
        }
        guard entryText.contains(info.url) else { return .outdated }
        if let token = info.token, !entryText.contains(token) { return .outdated }
        return .configured
    }

    /// Convenience for callers that only need yes/no.
    nonisolated func isConfigured(info: MCPConnectionInfo, fileContents: String?) -> Bool {
        configState(info: info, fileContents: fileContents) != .notConfigured
    }

    /// The lines of a Codex config.toml that define `mcp_servers.whisperer` (its table, its
    /// subtables and dotted keys), or nil when there are none.
    nonisolated static func codexServerLines(in toml: String) -> String? {
        var current: [String] = []
        var collected: [String] = []
        var found = false
        for line in toml.components(separatedBy: "\n") {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if let header = MCPTOML.tableHeaderPath(stripped) {
                current = header
                if header.count >= 2, header[0] == "mcp_servers", header[1] == serverName {
                    found = true
                    collected.append(line)
                }
                continue
            }
            let inOurTable = current.count >= 2 && current[0] == "mcp_servers" && current[1] == serverName
            if inOurTable {
                collected.append(line)
            } else if let key = MCPTOML.keyPath(stripped) {
                let full = current + key
                if full.count >= 2, full[0] == "mcp_servers", full[1] == serverName {
                    found = true
                    collected.append(line)
                }
            }
        }
        return found ? collected.joined(separator: "\n") : nil
    }
}

// MARK: - Detection

nonisolated struct MCPClientPresence: Equatable, Sendable {
    /// The app or CLI is on this Mac.
    var installed: Bool
    /// What its config file says about Whisperer.
    var config: MCPConfigState

    static let unknown = MCPClientPresence(installed: false, config: .notConfigured)

    /// Shown in the "On this Mac" group.
    var isRelevant: Bool { installed || config != .notConfigured }
}

/// The file system as detection sees it — real in the app, faked in tests.
nonisolated struct MCPDetectionProbe: Sendable {
    var home: URL
    var fileExists: @Sendable (String) -> Bool
    /// Whether the client's CLI resolves on this Mac (CLIDiscovery in direct builds).
    var cliInstalled: @Sendable (MCPClient) -> Bool
    /// Reads a config file; nil when missing or unreadable (e.g. inside the App Sandbox).
    var readFile: @Sendable (URL) -> String?

    static var live: MCPDetectionProbe {
        MCPDetectionProbe(
            home: MCPClientDetector.realHome,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            cliInstalled: { client in
                #if !APP_STORE
                switch client {
                case .claudeCode:  return CLIDiscovery.locate(.claudeCode) != nil
                case .codex:       return CLIDiscovery.locate(.codex) != nil
                case .antigravity: return CLIDiscovery.locate(.antigravity) != nil
                default:           return false
                }
                #else
                return false
                #endif
            },
            readFile: { url in
                // ~/.claude.json can be large; anything past 16 MB is not a config we parse.
                guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
                      size.intValue < 16 * 1024 * 1024 else { return nil }
                return try? String(contentsOf: url, encoding: .utf8)
            })
    }
}

nonisolated enum MCPClientDetector {

    /// The user's real home — also inside the App Sandbox.
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// App bundles (and bundled binaries) whose presence means the client is installed.
    static func appPaths(for client: MCPClient, home: URL) -> [String] {
        let names: [String]
        switch client {
        case .claudeCode:    names = []
        case .claudeDesktop: names = ["Claude.app"]
        case .codex:         names = ["Codex.app", "ChatGPT.app/Contents/Resources/codex-cli/bin/codex"]
        case .cursor:        names = ["Cursor.app"]
        case .vscode:        names = ["Visual Studio Code.app", "Visual Studio Code - Insiders.app"]
        case .windsurf:      names = ["Windsurf.app"]
        case .antigravity:   names = ["Antigravity.app"]
        case .chatgpt:       names = ["ChatGPT.app"]
        case .other:         names = []
        }
        let roots = ["/Applications", home.appendingPathComponent("Applications").path]
        return roots.flatMap { root in names.map { "\(root)/\($0)" } }
    }

    /// Well-known CLI locations, used where CLIDiscovery is unavailable (App Store build).
    static func cliPaths(for client: MCPClient, home: URL) -> [String] {
        let names: [String]
        switch client {
        case .claudeCode:  names = ["claude"]
        case .codex:       names = ["codex"]
        case .antigravity: names = ["agy", "antigravity"]
        default:           names = []
        }
        let dirs = ["\(home.path)/.local/bin", "\(home.path)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.flatMap { dir in names.map { "\(dir)/\($0)" } }
    }

    static func isInstalled(_ client: MCPClient, probe: MCPDetectionProbe) -> Bool {
        if client == .other { return false }
        if probe.cliInstalled(client) { return true }
        let paths = appPaths(for: client, home: probe.home) + cliPaths(for: client, home: probe.home)
        return paths.contains(where: probe.fileExists)
    }

    /// Presence of every client. Reads config files, never writes them.
    static func presence(of clients: [MCPClient] = MCPClient.allCases,
                         info: MCPConnectionInfo,
                         probe: MCPDetectionProbe) -> [MCPClient: MCPClientPresence] {
        var out: [MCPClient: MCPClientPresence] = [:]
        for client in clients {
            let contents = client.configPath(home: probe.home).flatMap(probe.readFile)
            out[client] = MCPClientPresence(installed: isInstalled(client, probe: probe),
                                            config: client.configState(info: info, fileContents: contents))
        }
        return out
    }

    /// Splits the catalog for the picker: apps on this Mac (or already connected) first —
    /// connected ones leading — then everything else, with "Other client" always last.
    static func arrange(_ clients: [MCPClient] = MCPClient.allCases,
                        presence: [MCPClient: MCPClientPresence]) -> (onThisMac: [MCPClient], more: [MCPClient]) {
        func rank(_ c: MCPClient) -> Int {
            switch presence[c]?.config ?? .notConfigured {
            case .configured: return 0
            case .outdated:   return 1
            case .notConfigured: return 2
            }
        }
        let relevant = clients.filter { $0 != .other && (presence[$0]?.isRelevant ?? false) }
        let onThisMac = relevant.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
        var more = clients.filter { !onThisMac.contains($0) && $0 != .other }
        if clients.contains(.other) { more.append(.other) }
        return (onThisMac, more)
    }
}

// MARK: - Guide copy (pure)

nonisolated struct MCPConnectStep: Equatable, Hashable, Sendable {
    let title: String
    let detail: String
    /// Whisperer does this step itself when the user presses the primary button.
    var automatic: Bool = false
}

nonisolated enum MCPConnectGuide {

    static let samplePrompt = "“What did we decide in my last meeting?”"

    /// The 1-2-3 shown in the panel. `autoInstall` = this build writes the config itself;
    /// `serverOn` false adds "Whisperer turns on" as the first step.
    static func steps(for client: MCPClient, autoInstall: Bool, serverOn: Bool) -> [MCPConnectStep] {
        var steps: [MCPConnectStep] = []
        if !serverOn {
            steps.append(.init(title: "Whisperer turns on",
                               detail: "Starts a small read-only server only this Mac can reach.",
                               automatic: true))
        }
        let ask = MCPConnectStep(title: "Ask \(client == .other ? "your app" : client.displayName)",
                                 detail: samplePrompt)
        switch client {
        case .chatgpt:
            steps += [
                .init(title: "Add a public URL",
                      detail: "ChatGPT connects from the cloud — paste a tunnel URL in Advanced."),
                .init(title: "Create a connector",
                      detail: "ChatGPT → Settings → Apps & Connectors → Developer mode → Create."),
                ask,
            ]
        case .other:
            steps += [
                .init(title: "Copy the connection details",
                      detail: "Streamable HTTP URL, SSE fallback and token if one is needed."),
                .init(title: "Add a server in your app",
                      detail: "Use Streamable HTTP when offered; SSE for older clients."),
                ask,
            ]
        default:
            if autoInstall, let path = client.configPathDisplay {
                steps.append(.init(title: "Whisperer adds itself",
                                   detail: "Into \(path). Other servers stay untouched; a backup is kept.",
                                   automatic: true))
            } else if let path = client.configPathDisplay {
                steps.append(.init(title: "Paste the setup",
                                   detail: "It's copied for you, and \(path) opens in Finder."))
            } else {
                steps.append(.init(title: "Paste the setup", detail: client.instructions))
            }
            steps.append(restartStep(for: client))
            steps.append(ask)
        }
        return steps
    }

    static func restartStep(for client: MCPClient) -> MCPConnectStep {
        switch client {
        case .claudeCode:    return .init(title: "Start a new session", detail: "Run /mcp in Claude Code to see Whisperer listed.")
        case .claudeDesktop: return .init(title: "Reopen Claude Desktop", detail: "Quit and relaunch it. The bridge needs Node.js.")
        case .codex:         return .init(title: "Restart Codex", detail: "The CLI, IDE extension and ChatGPT app share this config.")
        case .cursor:        return .init(title: "Reload Cursor", detail: "Settings → MCP shows Whisperer with a green dot.")
        case .vscode:        return .init(title: "Reload VS Code", detail: "Then use Copilot Chat in Agent mode.")
        case .windsurf:      return .init(title: "Refresh Cascade", detail: "Cascade → MCP servers → Refresh.")
        case .antigravity:   return .init(title: "Save the raw config", detail: "Agent panel → MCP Servers → Manage → View raw config.")
        case .chatgpt, .other: return .init(title: "Reload your app", detail: "So it picks up the new server.")
        }
    }

    /// Title of the one primary button.
    static func primaryTitle(for client: MCPClient, autoInstall: Bool, serverOn: Bool,
                             config: MCPConfigState) -> String {
        guard autoInstall else {
            switch client {
            case .chatgpt: return serverOn ? "Copy connector URL" : "Turn on & copy URL"
            case .other:   return serverOn ? "Copy connection details" : "Turn on & copy details"
            default:       return serverOn ? "Copy setup" : "Turn on & copy setup"
            }
        }
        let verb: String
        switch config {
        case .configured:    verb = "Reconnect"
        case .outdated:      verb = "Update"
        case .notConfigured: verb = "Connect to"
        }
        return serverOn ? "\(verb) \(client.displayName)" : "Turn on & \(verb.lowercased()) \(client.displayName)"
    }

    /// One-line fix for a failed connection test, or nil when there is nothing to suggest.
    static func fix(for result: MCPConnectionTestResult, port: Int) -> String? {
        guard !result.success else { return nil }
        let m = result.message.lowercased()
        if m.contains("unauthorized") {
            return "The app has an old token. Connect it again so it gets the current one."
        }
        if m.contains("not reachable") || m.contains("health") {
            return "Make sure Whisperer is on, and that no other app uses port \(port) (Advanced → Port)."
        }
        if m.contains("not valid") {
            return "Check the public URL in Advanced, or clear it to use this Mac's address."
        }
        return "Turn Whisperer off and on again, then retry."
    }

    /// One-line fix for a failed install.
    static func installFix(for client: MCPClient) -> String {
        if let path = client.configPathDisplay {
            return "Check that \(path) is writable, or open Show config and paste it yourself."
        }
        return "Open Show config and paste it yourself."
    }
}

// MARK: - Side effects (injectable)

struct MCPConnectActions {
    var install: @MainActor (MCPClient, MCPConnectionInfo) -> MCPInstallResult
    var canAutoInstall: @MainActor (MCPClient) -> Bool
    var copy: @MainActor (String) -> Void
    var reveal: @MainActor (MCPClient) -> Void
    var test: @MainActor (MCPConnectionInfo) async -> MCPConnectionTestResult
    /// Runs off the main thread.
    var detect: @Sendable (MCPConnectionInfo) -> [MCPClient: MCPClientPresence]
    var isServerEnabled: @MainActor () -> Bool
    var setServerEnabled: @MainActor (Bool) -> Void
    var isServerRunning: @MainActor () -> Bool

    static var live: MCPConnectActions {
        MCPConnectActions(
            install: { MCPClientInstaller.install($0, info: $1) },
            canAutoInstall: { MCPClientInstaller.canAutoInstall($0) },
            copy: { MCPClientInstaller.copy($0) },
            reveal: { MCPClientInstaller.reveal($0) },
            test: { await MCPConnectionTester.run(info: $0) },
            detect: { info in MCPClientDetector.presence(info: info, probe: .live) },
            isServerEnabled: { AppState.shared.mcpEnabled },
            setServerEnabled: { AppState.shared.mcpEnabled = $0 },
            isServerRunning: { AppState.shared.mcpServerRunning })
    }
}

// MARK: - Page state

enum MCPConnectOutcome: Equatable {
    case installed(path: String)
    case copied(hint: String)
    case revealed(path: String)

    init?(_ result: MCPInstallResult) {
        switch result {
        case .installed(let p): self = .installed(path: p)
        case .copied(let h):    self = .copied(hint: h)
        case .revealed(let p):  self = .revealed(path: p)
        case .failed:           return nil
        }
    }
}

enum MCPConnectPhase: Equatable {
    case idle
    case working
    case succeeded(MCPConnectOutcome)
    case failed(String)
}

enum MCPTestPhase: Equatable {
    case idle
    case waitingForServer
    case testing
    case finished(MCPConnectionTestResult)

    var isBusy: Bool { self == .waitingForServer || self == .testing }
}

@MainActor
final class MCPConnectPageModel: ObservableObject {
    let actions: MCPConnectActions

    @Published var selected: MCPClient?
    @Published private(set) var phases: [MCPClient: MCPConnectPhase] = [:]
    /// The connection test that follows a connect, for the selected client.
    @Published private(set) var connectTest: MCPTestPhase = .idle
    /// The manual "Test connection" in Advanced.
    @Published private(set) var advancedTest: MCPTestPhase = .idle
    @Published private(set) var presence: [MCPClient: MCPClientPresence] = [:]
    @Published private(set) var detectionFinished = false
    @Published var showMoreApps = false
    @Published var advancedExpanded = false

    private var detectionGeneration = 0

    init(actions: MCPConnectActions) {
        self.actions = actions
    }

    func phase(for client: MCPClient) -> MCPConnectPhase { phases[client] ?? .idle }
    func presence(for client: MCPClient) -> MCPClientPresence { presence[client] ?? .unknown }

    var arrangement: (onThisMac: [MCPClient], more: [MCPClient]) {
        MCPClientDetector.arrange(presence: presence)
    }

    var connectedCount: Int { presence.values.filter { $0.config == .configured }.count }

    func toggleSelection(_ client: MCPClient) {
        if selected == client {
            selected = nil
        } else {
            selected = client
            connectTest = .idle
            if phase(for: client) != .working { phases[client] = .idle }
        }
    }

    // MARK: Detection

    func refreshDetection(info: MCPConnectionInfo) {
        detectionGeneration += 1
        let generation = detectionGeneration
        let detect = actions.detect
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { detect(info) }.value
            guard let self, generation == self.detectionGeneration else { return }
            self.presence = result
            self.detectionFinished = true
        }
    }

    // MARK: Connect

    func connect(_ client: MCPClient, info: MCPConnectionInfo, port: Int) {
        phases[client] = .working
        connectTest = .idle
        if !actions.isServerEnabled() { actions.setServerEnabled(true) }
        let result = actions.install(client, info)
        guard let outcome = MCPConnectOutcome(result) else {
            if case .failed(let message) = result { phases[client] = .failed(message) }
            return
        }
        phases[client] = .succeeded(outcome)
        refreshDetection(info: info)
        Task { [weak self] in await self?.runTest(info: info, port: port, forConnect: true) }
    }

    func testFromAdvanced(info: MCPConnectionInfo, port: Int) {
        Task { [weak self] in await self?.runTest(info: info, port: port, forConnect: false) }
    }

    private func setTest(_ phase: MCPTestPhase, forConnect: Bool) {
        if forConnect { connectTest = phase } else { advancedTest = phase }
    }

    private func runTest(info: MCPConnectionInfo, port: Int, forConnect: Bool) async {
        if !actions.isServerRunning() {
            setTest(.waitingForServer, forConnect: forConnect)
            let deadline = Date().addingTimeInterval(6)
            while !actions.isServerRunning(), Date() < deadline {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard actions.isServerRunning() else {
                setTest(.finished(MCPConnectionTestResult(
                    success: false, steps: [],
                    message: "Whisperer's server is not reachable on port \(port)")), forConnect: forConnect)
                return
            }
        }
        setTest(.testing, forConnect: forConnect)
        let result = await actions.test(info)
        setTest(.finished(result), forConnect: forConnect)
    }

    /// Clears results that no longer describe the server (token or URL changed).
    func connectionInfoChanged(_ info: MCPConnectionInfo) {
        advancedTest = .idle
        connectTest = .idle
        refreshDetection(info: info)
    }
}
