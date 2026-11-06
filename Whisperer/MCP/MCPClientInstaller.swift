//
//  MCPClientInstaller.swift
//  Whisperer
//
//  Writes (or copies) the per-client MCP config entry for Whisperer. The entry shapes
//  and merge logic live in MCPClientConfig.swift (pure, unit-tested); this file only
//  does the file system and pasteboard side effects.
//
//  In non-sandboxed builds the entry is merged directly into the client's config
//  file.  In the sandboxed AppStore build the entry is copied to the clipboard
//  and the config file is revealed in Finder — we cannot write to files outside
//  the container.
//
//  Merge semantics: read existing config, replace only the "whisperer" entry,
//  write back atomically after backing the old file up to `<file>.whisperer.bak`.
//  Pre-existing servers are untouched.  If the file is missing it is created.  If it
//  is malformed the operation falls back to copy + reveal (never overwrites it).
//

import AppKit
import Foundation

// MARK: - Result

enum MCPInstallResult {
    case installed(path: String)       // file written successfully
    case copied(hint: String)          // clipboard set; hint for user
    case revealed(path: String)        // file revealed in Finder (AppStore / malformed file)
    case failed(String)                // unrecoverable error
}

// MARK: - Installer

enum MCPClientInstaller {

    /// The user's real home directory — also inside the App Sandbox, where
    /// `homeDirectoryForCurrentUser` points into the container.
    static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func configURL(for client: MCPClient) -> URL? {
        client.configPath(home: realHomeDirectory)
    }

    /// Whether this build can write the client's config itself.
    static func canAutoInstall(_ client: MCPClient) -> Bool {
#if APP_STORE
        return false
#else
        return client.canAutoInstall
#endif
    }

    /// Install or copy the Whisperer MCP entry for the given client.
    static func install(_ client: MCPClient, info: MCPConnectionInfo) -> MCPInstallResult {
        let snippet = client.snippet(for: info)

        guard let configURL = configURL(for: client) else {
            copy(snippet)
            return .copied(hint: client.instructions)
        }

#if APP_STORE
        return copyAndReveal(snippet: snippet, path: configURL, client: client)
#else
        switch client.snippetFormat {
        case .toml:
            return installCodex(info: info, configURL: configURL, snippet: snippet)
        case .json:
            return installJSON(client: client, info: info, configURL: configURL, snippet: snippet)
        case .text:
            copy(snippet)
            return .copied(hint: client.instructions)
        }
#endif
    }

    /// Copies text to the general pasteboard.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Reveals the client's config file (or its folder when the file does not exist yet).
    static func reveal(_ client: MCPClient) {
        guard let url = configURL(for: client) else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if fm.fileExists(atPath: url.deletingLastPathComponent().path) {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

#if !APP_STORE
    // MARK: - JSON configs

    private static func installJSON(client: MCPClient,
                                    info: MCPConnectionInfo,
                                    configURL: URL,
                                    snippet: String) -> MCPInstallResult {
        guard let rootKey = client.jsonRootKey, let entry = client.jsonEntry(for: info) else {
            return .failed("No config format for \(client.displayName)")
        }
        let fm = FileManager.default
        let existing = fm.fileExists(atPath: configURL.path) ? (try? Data(contentsOf: configURL)) : nil
        if fm.fileExists(atPath: configURL.path) && existing == nil {
            return copyAndReveal(snippet: snippet, path: configURL, client: client)
        }

        let merged: Data
        do {
            merged = try MCPConfigMerge.mergeJSON(existing: existing, rootKey: rootKey, entry: entry)
        } catch {
            Logger.warning("MCPClientInstaller: \(configURL.lastPathComponent) is malformed — falling back to copy", subsystem: .app)
            return copyAndReveal(snippet: snippet, path: configURL, client: client)
        }
        return write(merged, to: configURL)
    }

    // MARK: - Codex TOML

    private static func installCodex(info: MCPConnectionInfo,
                                     configURL: URL,
                                     snippet: String) -> MCPInstallResult {
        let fm = FileManager.default
        var existing = ""
        if fm.fileExists(atPath: configURL.path) {
            guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
                return copyAndReveal(snippet: snippet, path: configURL, client: .codex)
            }
            existing = text
        }
        let merged = MCPConfigMerge.mergeCodexTOML(existing: existing,
                                                   block: MCPClient.codexTOMLBlock(for: info))
        return write(Data(merged.utf8), to: configURL)
    }

    // MARK: - Writing

    /// Backs up the current file, then writes atomically.
    private static func write(_ data: Data, to configURL: URL) -> MCPInstallResult {
        let fm = FileManager.default
        let dir = configURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .failed("Could not create \(dir.path): \(error.localizedDescription)")
        }

        if fm.fileExists(atPath: configURL.path) {
            let backupURL = configURL.appendingPathExtension("whisperer.bak")
            try? fm.removeItem(at: backupURL)
            do {
                try fm.copyItem(at: configURL, to: backupURL)
            } catch {
                Logger.warning("MCPClientInstaller: could not back up \(configURL.lastPathComponent): \(error.localizedDescription)", subsystem: .app)
            }
        }

        do {
            try data.write(to: configURL, options: .atomic)
            Logger.info("MCPClientInstaller: wrote \(configURL.lastPathComponent)", subsystem: .app)
            return .installed(path: configURL.path)
        } catch {
            return .failed("Could not write \(configURL.lastPathComponent): \(error.localizedDescription)")
        }
    }
#endif

    // MARK: - Copy + reveal fallback

    private static func copyAndReveal(snippet: String, path: URL, client: MCPClient) -> MCPInstallResult {
        copy(snippet)
        if FileManager.default.fileExists(atPath: path.path) {
            NSWorkspace.shared.activateFileViewerSelecting([path])
            return .revealed(path: path.path)
        }
        return .copied(hint: "Copied. Paste it into \(client.configPathDisplay ?? path.lastPathComponent).")
    }
}
