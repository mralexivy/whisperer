//
//  MCPClientInstaller.swift
//  Whisperer
//
//  Writes (or copies) the per-client MCP config entry for Whisperer.
//
//  In non-sandboxed builds the entry is merged directly into the client's config
//  file.  In the sandboxed AppStore build the entry is copied to the clipboard
//  and the config file is revealed in Finder — we cannot write to files outside
//  the container.
//
//  Merge semantics: read existing config, replace only the "whisperer" key,
//  write back atomically.  Pre-existing servers are untouched.  If the file is
//  missing it is created.  If it is malformed the operation falls back to
//  copy + reveal (never overwrites a malformed file).
//

import AppKit
import Foundation

// MARK: - Result

enum MCPInstallResult {
    case installed(path: String)       // file written successfully
    case copied(hint: String)          // clipboard set; hint for user
    case revealed(path: String)        // file revealed in Finder (AppStore)
    case failed(String)                // unrecoverable error
}

// MARK: - Client definitions

enum MCPClient: CaseIterable {
    case claudeCode
    case claudeDesktop
    case codex
    case chatgpt

    var displayName: String {
        switch self {
        case .claudeCode:    return "Claude Code"
        case .claudeDesktop: return "Claude Desktop"
        case .codex:         return "Codex"
        case .chatgpt:       return "ChatGPT"
        }
    }

    var description: String {
        switch self {
        case .claudeCode:    return "Add to Claude Code (CLI + IDE extensions)"
        case .claudeDesktop: return "Add to Claude Desktop"
        case .codex:         return "Add to Codex (OpenAI agent)"
        case .chatgpt:       return "Copy connection URL"
        }
    }

    var iconName: String {
        switch self {
        case .claudeCode:    return "terminal.fill"
        case .claudeDesktop: return "desktopcomputer"
        case .codex:         return "cpu"
        case .chatgpt:       return "bubble.left.and.bubble.right.fill"
        }
    }

    /// Absolute path to the config file, nil for clients with no file (ChatGPT).
    func configPath() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claudeCode:
            return home.appendingPathComponent(".claude.json")
        case .claudeDesktop:
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("Claude/claude_desktop_config.json")
        case .codex:
            return home.appendingPathComponent(".codex/config.toml")
        case .chatgpt:
            return nil
        }
    }
}

// MARK: - Installer

enum MCPClientInstaller {

    /// Install or copy the Whisperer MCP entry for the given client.
    /// `url` is the full MCP endpoint URL (e.g. "http://localhost:8080/mcp").
    static func install(_ client: MCPClient, url: String) -> MCPInstallResult {
        switch client {
        case .chatgpt:
            return installChatGPT(url: url)
        case .claudeCode:
            return installJSON(client: client, url: url)
        case .claudeDesktop:
            return installJSON(client: client, url: url)
        case .codex:
            return installTOML(url: url)
        }
    }

    // MARK: - ChatGPT (URL copy only — requires a public https URL for remote connectors)

    private static func installChatGPT(url: String) -> MCPInstallResult {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        return .copied(hint: "Paste this URL in ChatGPT → Settings → Connectors → Add custom connector. ChatGPT requires a public https URL; enable LAN access or use a tunnel for remote connectivity.")
    }

    // MARK: - JSON-based configs (Claude Code, Claude Desktop)

    private static func installJSON(client: MCPClient, url: String) -> MCPInstallResult {
        guard let configURL = client.configPath() else {
            return .failed("No config path for \(client.displayName)")
        }

        let entry = jsonEntry(for: client, url: url)
        let snippet = snippetForCopy(client: client, entry: entry)

#if APP_STORE
        return copyAndReveal(snippet: snippet, path: configURL)
#else
        return mergeJSON(configURL: configURL, serverName: "whisperer", entry: entry, snippet: snippet)
#endif
    }

    /// Returns the JSON object to place under `mcpServers.whisperer`.
    private static func jsonEntry(for client: MCPClient, url: String) -> [String: Any] {
        switch client {
        case .claudeCode:
            // Claude Code supports streamable-http natively.
            return ["type": "streamable-http", "url": url]
        case .claudeDesktop:
            // Claude Desktop routes http MCP via mcp-remote (stdio bridge).
            return [
                "command": "npx",
                "args": ["-y", "mcp-remote@latest", url],
                "env": [String: String](),
            ]
        default:
            return [:]
        }
    }

    private static func snippetForCopy(client: MCPClient, entry: [String: Any]) -> String {
        let wrapper = ["mcpServers": ["whisperer": entry]]
        if let data = try? JSONSerialization.data(withJSONObject: wrapper, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    private static func mergeJSON(configURL: URL,
                                  serverName: String,
                                  entry: [String: Any],
                                  snippet: String) -> MCPInstallResult {
        let fm = FileManager.default

        // Ensure parent directory exists.
        let dir = configURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                return .failed("Could not create directory \(dir.path): \(error.localizedDescription)")
            }
        }

        // Read existing config or start fresh.
        var root: [String: Any]
        if fm.fileExists(atPath: configURL.path) {
            guard let data = try? Data(contentsOf: configURL),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Malformed — fall back to copy + reveal rather than clobbering.
                Logger.warning("MCPClientInstaller: \(configURL.lastPathComponent) is malformed — falling back to copy", subsystem: .app)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(snippet, forType: .string)
                NSWorkspace.shared.activateFileViewerSelecting([configURL])
                return .revealed(path: configURL.path)
            }
            root = parsed
        } else {
            root = [:]
        }

        // Merge mcpServers.whisperer.
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = entry
        root["mcpServers"] = servers

        // Write atomically with a backup.
        do {
            let newData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])

            // Backup existing file alongside as .bak.
            let backupURL = configURL.appendingPathExtension("whisperer.bak")
            if fm.fileExists(atPath: configURL.path) {
                _ = try? fm.replaceItemAt(backupURL, withItemAt: configURL)
            }

            let tmpURL = configURL.appendingPathExtension("tmp")
            try newData.write(to: tmpURL, options: .atomic)
            _ = try fm.replaceItemAt(configURL, withItemAt: tmpURL)

            Logger.info("MCPClientInstaller: wrote \(configURL.lastPathComponent)", subsystem: .app)
            return .installed(path: configURL.path)
        } catch {
            return .failed("Could not write \(configURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - TOML config (Codex)

    private static func installTOML(url: String) -> MCPInstallResult {
        guard let configURL = MCPClient.codex.configPath() else {
            return .failed("No config path for Codex")
        }

        let block = """

[mcp_servers.whisperer]
url = "\(url)"

"""

#if APP_STORE
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(block.trimmingCharacters(in: .newlines), forType: .string)
        if FileManager.default.fileExists(atPath: configURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([configURL])
            return .revealed(path: configURL.path)
        }
        return .copied(hint: "Paste this block into ~/.codex/config.toml")
#else
        return mergeTOML(configURL: configURL, block: block)
#endif
    }

    private static func mergeTOML(configURL: URL, block: String) -> MCPInstallResult {
        let fm = FileManager.default

        let dir = configURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { return .failed("Could not create \(dir.path): \(error.localizedDescription)") }
        }

        var existing = ""
        if fm.fileExists(atPath: configURL.path) {
            existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        }

        // Remove any existing [mcp_servers.whisperer] block.
        let cleaned = removeTOMLSection(existing, header: "[mcp_servers.whisperer]")
        let merged = cleaned + block

        do {
            let backupURL = configURL.appendingPathExtension("whisperer.bak")
            if fm.fileExists(atPath: configURL.path) {
                try? fm.copyItem(at: configURL, to: backupURL)
            }
            try merged.write(to: configURL, atomically: true, encoding: .utf8)
            Logger.info("MCPClientInstaller: wrote \(configURL.lastPathComponent)", subsystem: .app)
            return .installed(path: configURL.path)
        } catch {
            return .failed("Could not write \(configURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Removes a TOML section (from its header line to the next section header or EOF).
    private static func removeTOMLSection(_ toml: String, header: String) -> String {
        var lines = toml.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
            return toml  // section not present
        }
        // Find the next section header (line starting with "[" but not after the match).
        let rest = lines.indices.dropFirst(start + 1)
        let end = rest.first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("[") }) ?? lines.endIndex
        lines.removeSubrange(start..<end)
        return lines.joined(separator: "\n")
    }

    // MARK: - AppStore fallback: copy + reveal

    private static func copyAndReveal(snippet: String, path: URL) -> MCPInstallResult {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        if FileManager.default.fileExists(atPath: path.path) {
            NSWorkspace.shared.activateFileViewerSelecting([path])
            return .revealed(path: path.path)
        }
        return .copied(hint: "Paste this into \(path.lastPathComponent)")
    }
}
