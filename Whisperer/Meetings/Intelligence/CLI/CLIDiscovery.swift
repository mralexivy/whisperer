//
//  CLIDiscovery.swift
//  Whisperer
//
//  Finds an AI CLI the user has installed. Never runs a shell, never trusts a relative
//  path: candidates are explicit absolute locations plus an optional user override.
//

#if !APP_STORE

import Foundation

nonisolated enum CLIDiscovery {

    /// UserDefaults key holding a user-chosen absolute path for a provider's binary.
    static func overrideKey(for provider: AIProviderID) -> String { "connectedAI.cliPath.\(provider.rawValue)" }

    static func binaryNames(for provider: AIProviderID) -> [String] {
        switch provider {
        case .claudeCode:  return ["claude"]
        case .codex:       return ["codex"]
        case .antigravity: return ["agy", "antigravity"]
        default:           return []
        }
    }

    /// Absolute paths that ship the CLI inside an app bundle rather than on PATH. The
    /// ChatGPT desktop app bundles Codex; users who only installed the app have no `codex`
    /// on PATH but are signed in all the same.
    static func bundledCandidates(for provider: AIProviderID) -> [String] {
        switch provider {
        case .codex:
            return [
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                "/Applications/Codex.app/Contents/Resources/codex",
                "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            ]
        case .antigravity:
            return ["/Applications/Antigravity.app/Contents/Resources/app/bin/agy"]
        default:
            return []
        }
    }

    static func searchDirectories(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        [
            "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.bun/bin",
            "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.antigravity/bin",
            "/opt/homebrew/bin", "/usr/local/bin",
        ]
    }

    /// Resolves the binary for `provider`, or nil if none is installed.
    static func locate(_ provider: AIProviderID,
                       defaults: UserDefaults = .standard,
                       fileManager: FileManager = .default) -> URL? {
        if let override = defaults.string(forKey: overrideKey(for: provider)),
           override.hasPrefix("/"), fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        for dir in searchDirectories() {
            for name in binaryNames(for: provider) {
                let path = "\(dir)/\(name)"
                if fileManager.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path).resolvingSymlinksInPath()
                }
            }
        }
        // nvm installs per Node version; take the newest that has the binary.
        let nvm = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node").path
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvm) {
            for version in versions.sorted(by: >) {
                for name in binaryNames(for: provider) {
                    let path = "\(nvm)/\(version)/bin/\(name)"
                    if fileManager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
                }
            }
        }
        for path in bundledCandidates(for: provider) where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Install page shown on a card whose CLI is missing.
    static func installURL(for provider: AIProviderID) -> URL? {
        switch provider {
        case .claudeCode:  return URL(string: "https://code.claude.com/docs/en/setup")
        case .codex:       return URL(string: "https://developers.openai.com/codex/cli")
        case .antigravity: return URL(string: "https://antigravity.google/docs/cli")
        default:           return nil
        }
    }

    /// The command the user runs in Terminal to sign in. Whisperer never runs it for them:
    /// the login belongs to the vendor's tool, not to us.
    static func signInCommand(for provider: AIProviderID) -> String? {
        switch provider {
        case .claudeCode:  return "claude auth login"
        case .codex:       return "codex login"
        case .antigravity: return "agy"
        default:           return nil
        }
    }
}

#endif
