//
//  MCPClientConfig.swift
//  Whisperer
//
//  Pure catalog of MCP clients Whisperer can connect to: what each one's config entry
//  looks like, where it lives, and how to merge it into an existing file. No file I/O,
//  no AppKit — MCPClientInstaller does the side effects, tests exercise this directly.
//
//  Verified config shapes (2026-11):
//  - Claude Code   ~/.claude.json            mcpServers.whisperer { type: "http", url, headers? }
//                  CLI: claude mcp add --transport http --scope user whisperer <url> [--header …]
//  - Claude Desktop claude_desktop_config.json — stdio only, so bridge with `npx mcp-remote`.
//  - Codex         ~/.codex/config.toml      [mcp_servers.whisperer] url, http_headers?
//                  `headers =` (what we used to write) is not a Codex key: codex 0.166 drops
//                  it silently, so Codex connected without the token and got 401.
//                  default_tools_approval_mode = "approve" — the tools are read-only, and
//                  without it `codex exec` refuses every call (approval policy "never").
//  - Cursor        ~/.cursor/mcp.json        mcpServers.whisperer { url, headers? }
//  - VS Code       …/Code/User/mcp.json      servers.whisperer { type: "http", url, headers? }
//  - Windsurf      ~/.codeium/windsurf/mcp_config.json  mcpServers.whisperer { serverUrl, headers? }
//  - Antigravity   mcp_config.json (path unconfirmed) — snippet only, `serverUrl`.
//  - ChatGPT       custom connector, needs a public https URL — copy only.
//

import Foundation

// MARK: - Connection info

nonisolated struct MCPConnectionInfo: Equatable, Sendable {
    /// Streamable HTTP endpoint, e.g. "http://localhost:8080/mcp".
    let url: String
    /// The access token when the server requires one, nil otherwise.
    let token: String?

    init(url: String, token: String?) {
        self.url = url
        let t = token?.trimmingCharacters(in: .whitespaces) ?? ""
        self.token = t.isEmpty ? nil : t
    }

    /// The URL with its `/mcp` suffix (if any) removed and no trailing slash.
    var baseURL: String {
        var u = url
        while u.hasSuffix("/") { u.removeLast() }
        if u.lowercased().hasSuffix("/mcp") { u.removeLast(4) }
        return u
    }

    var sseURL: String { baseURL + "/sse" }
    var healthURL: String { baseURL + "/health" }

    var authorizationHeader: String? { token.map { "Bearer \($0)" } }

    /// The streamable URL with the token as a query parameter, for clients that cannot set headers.
    var urlWithTokenQuery: String? {
        guard let token,
              let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let sep = url.contains("?") ? "&" : "?"
        return "\(url)\(sep)\(MCPAuthPolicy.tokenQueryParameter)=\(encoded)"
    }

    var isLoopback: Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

// MARK: - Ordered JSON value (keeps snippet key order stable and readable)

nonisolated enum MCPJSONValue: Equatable {
    case string(String)
    case bool(Bool)
    case array([MCPJSONValue])
    case object([(String, MCPJSONValue)])

    static func == (a: MCPJSONValue, b: MCPJSONValue) -> Bool {
        switch (a, b) {
        case (.string(let x), .string(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.object(let x), .object(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    /// Foundation representation for JSONSerialization.
    var foundationValue: Any {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b
        case .array(let a): return a.map(\.foundationValue)
        case .object(let o):
            var d: [String: Any] = [:]
            for (k, v) in o { d[k] = v.foundationValue }
            return d
        }
    }

    /// Two-space indented JSON with keys in declaration order.
    func pretty(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .string(let s): return Self.quote(s)
        case .bool(let b): return b ? "true" : "false"
        case .array(let a):
            if a.isEmpty { return "[]" }
            return "[\n" + a.map { inner + $0.pretty(indent: indent + 1) }.joined(separator: ",\n") + "\n\(pad)]"
        case .object(let o):
            if o.isEmpty { return "{}" }
            return "{\n" + o.map { inner + Self.quote($0.0) + ": " + $0.1.pretty(indent: indent + 1) }
                .joined(separator: ",\n") + "\n\(pad)}"
        }
    }

    /// Single-line JSON with keys in declaration order.
    func compact() -> String {
        switch self {
        case .string(let s): return Self.quote(s)
        case .bool(let b): return b ? "true" : "false"
        case .array(let a): return "[" + a.map { $0.compact() }.joined(separator: ",") + "]"
        case .object(let o): return "{" + o.map { Self.quote($0.0) + ":" + $0.1.compact() }.joined(separator: ",") + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) }
                else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }
}

// MARK: - Client catalog

nonisolated enum MCPSnippetFormat: Equatable {
    case json, toml, text
}

nonisolated enum MCPClient: String, CaseIterable, Identifiable {
    case claudeCode
    case claudeDesktop
    case codex
    case cursor
    case vscode
    case windsurf
    case antigravity
    case chatgpt
    case other

    static let serverName = "whisperer"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode:    return "Claude Code"
        case .claudeDesktop: return "Claude Desktop"
        case .codex:         return "Codex"
        case .cursor:        return "Cursor"
        case .vscode:        return "VS Code"
        case .windsurf:      return "Windsurf"
        case .antigravity:   return "Antigravity"
        case .chatgpt:       return "ChatGPT"
        case .other:         return "Other client"
        }
    }

    var description: String {
        switch self {
        case .claudeCode:    return "CLI and IDE extensions · Streamable HTTP"
        case .claudeDesktop: return "Via the mcp-remote bridge (needs Node.js)"
        case .codex:         return "CLI, IDE extension and app · Streamable HTTP"
        case .cursor:        return "Global MCP config · Streamable HTTP"
        case .vscode:        return "Copilot agent mode · Streamable HTTP"
        case .windsurf:      return "Cascade MCP config · Streamable HTTP"
        case .antigravity:   return "Paste into Manage MCP servers → raw config"
        case .chatgpt:       return "Custom connector — needs a public https URL"
        case .other:         return "Any MCP client: Streamable HTTP, SSE or plain HTTP"
        }
    }

    var iconName: String {
        switch self {
        case .claudeCode:    return "terminal.fill"
        case .claudeDesktop: return "desktopcomputer"
        case .codex:         return "chevron.left.forwardslash.chevron.right"
        case .cursor:        return "cursorarrow.rays"
        case .vscode:        return "curlybraces.square.fill"
        case .windsurf:      return "wind"
        case .antigravity:   return "arrow.up.circle.fill"
        case .chatgpt:       return "bubble.left.and.bubble.right.fill"
        case .other:         return "puzzlepiece.extension.fill"
        }
    }

    var snippetFormat: MCPSnippetFormat {
        switch self {
        case .codex: return .toml
        case .chatgpt, .other: return .text
        default: return .json
        }
    }

    /// Top-level key that holds the server map in this client's JSON config.
    var jsonRootKey: String? {
        switch self {
        case .claudeCode, .claudeDesktop, .cursor, .windsurf, .antigravity: return "mcpServers"
        case .vscode: return "servers"
        case .codex, .chatgpt, .other: return nil
        }
    }

    /// Config file location relative to the user's real home directory, nil when the client
    /// has no file we can write (or its location is not confirmed).
    func configPath(home: URL) -> URL? {
        switch self {
        case .claudeCode:    return home.appendingPathComponent(".claude.json")
        case .claudeDesktop: return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .codex:         return home.appendingPathComponent(".codex/config.toml")
        case .cursor:        return home.appendingPathComponent(".cursor/mcp.json")
        case .vscode:        return home.appendingPathComponent("Library/Application Support/Code/User/mcp.json")
        case .windsurf:      return home.appendingPathComponent(".codeium/windsurf/mcp_config.json")
        case .antigravity, .chatgpt, .other: return nil
        }
    }

    /// `~/…` form of the config path for display.
    var configPathDisplay: String? {
        guard let p = configPath(home: URL(fileURLWithPath: "/HOME")) else { return nil }
        return p.path.replacingOccurrences(of: "/HOME", with: "~")
    }

    /// Whether Whisperer can merge its entry into the client's config file itself.
    var canAutoInstall: Bool { configPath(home: URL(fileURLWithPath: "/")) != nil }

    /// Where to paste the snippet, shown under it.
    var instructions: String {
        switch self {
        case .claudeCode:    return "Run the command in Terminal, or merge the JSON into ~/.claude.json. Restart Claude Code, then check /mcp."
        case .claudeDesktop: return "Merge into claude_desktop_config.json (Settings → Developer → Edit Config), then restart Claude Desktop."
        case .codex:         return "Append to ~/.codex/config.toml — the CLI, IDE extension and ChatGPT app share it. Restart Codex."
        case .cursor:        return "Merge into ~/.cursor/mcp.json (Settings → MCP → Add new global MCP server)."
        case .vscode:        return "Run the command, or merge into your user mcp.json (Command Palette → MCP: Open User Configuration)."
        case .windsurf:      return "Merge into ~/.codeium/windsurf/mcp_config.json (Cascade → MCP servers → View raw config)."
        case .antigravity:   return "In Antigravity open the agent panel menu → MCP Servers → Manage MCP Servers → View raw config, and merge this in."
        case .chatgpt:       return "ChatGPT → Settings → Apps & Connectors → Advanced → Developer mode → Create. ChatGPT connects from the cloud, so it needs a public https URL (set a tunnel URL below)."
        case .other:         return "Use the Streamable HTTP URL when your client supports it; fall back to the SSE URL for older clients."
        }
    }

    // MARK: Entries

    /// The value stored under `<root>.whisperer` in a JSON config.
    func jsonEntry(for info: MCPConnectionInfo) -> MCPJSONValue? {
        let headers: [(String, MCPJSONValue)] = info.authorizationHeader.map { [("Authorization", .string($0))] } ?? []
        func withHeaders(_ fields: [(String, MCPJSONValue)]) -> MCPJSONValue {
            .object(headers.isEmpty ? fields : fields + [("headers", .object(headers))])
        }
        switch self {
        case .claudeCode, .vscode:
            return withHeaders([("type", .string("http")), ("url", .string(info.url))])
        case .cursor:
            return withHeaders([("url", .string(info.url))])
        case .windsurf, .antigravity:
            return withHeaders([("serverUrl", .string(info.url))])
        case .claudeDesktop:
            var args: [MCPJSONValue] = [.string("-y"), .string("mcp-remote@latest"), .string(info.url)]
            if info.url.lowercased().hasPrefix("http://") && !info.isLoopback {
                args.append(.string("--allow-http"))
            }
            if let auth = info.authorizationHeader {
                args += [.string("--header"), .string("Authorization: \(auth)")]
            }
            return .object([("command", .string("npx")), ("args", .array(args))])
        case .codex, .chatgpt, .other:
            return nil
        }
    }

    /// The `[mcp_servers.whisperer]` table for Codex.
    static func codexTOMLBlock(for info: MCPConnectionInfo) -> String {
        var lines = ["[mcp_servers.\(serverName)]", "url = \(MCPTOML.quote(info.url))"]
        if let auth = info.authorizationHeader {
            lines.append("http_headers = { Authorization = \(MCPTOML.quote(auth)) }")
        }
        // Every Whisperer tool is read-only. Without this, Codex asks before each call, and in
        // `codex exec` (approval policy "never") the call is refused outright — verified live.
        lines.append("default_tools_approval_mode = \"approve\"")
        return lines.joined(separator: "\n")
    }

    /// Exactly what the user pastes.
    func snippet(for info: MCPConnectionInfo) -> String {
        switch self {
        case .codex:
            return Self.codexTOMLBlock(for: info)
        case .chatgpt:
            return info.url
        case .other:
            return Self.genericSnippet(for: info)
        default:
            guard let root = jsonRootKey, let entry = jsonEntry(for: info) else { return info.url }
            return MCPJSONValue.object([(root, .object([(Self.serverName, entry)]))]).pretty()
        }
    }

    /// A one-line terminal command that adds the server, when the client has one.
    func cliCommand(for info: MCPConnectionInfo) -> String? {
        switch self {
        case .claudeCode:
            var cmd = "claude mcp add --transport http --scope user \(Self.serverName) \(MCPShell.quote(info.url))"
            if let auth = info.authorizationHeader {
                cmd += " --header \(MCPShell.quote("Authorization: \(auth)"))"
            }
            return cmd
        case .codex:
            // No command: `codex mcp add` can set neither a static token (env var only) nor
            // `default_tools_approval_mode`, and without the latter `codex exec` refuses every
            // Whisperer tool call. The TOML snippet carries both.
            return nil
        case .vscode:
            guard let entry = jsonEntry(for: info), case .object(let fields) = entry else { return nil }
            let json = MCPJSONValue.object([("name", .string(Self.serverName))] + fields)
            return "code --add-mcp \(MCPShell.quote(json.compact()))"
        default:
            return nil
        }
    }

    static func genericSnippet(for info: MCPConnectionInfo) -> String {
        var lines = [
            "Streamable HTTP (recommended):  \(info.url)",
            "Legacy SSE (older clients):     \(info.sseURL)",
        ]
        if let auth = info.authorizationHeader {
            lines.append("Header:                         Authorization: \(auth)")
            if let q = info.urlWithTokenQuery {
                lines.append("No header support? Use:         \(q)")
            }
        } else {
            lines.append("Authentication:                 none (local only)")
        }
        lines.append("")
        lines.append("Test with curl:")
        var curl = ["curl -s \(MCPShell.quote(info.url))",
                    "  -H 'Content-Type: application/json'"]
        if let auth = info.authorizationHeader {
            curl.append("  -H \(MCPShell.quote("Authorization: \(auth)"))")
        }
        curl.append("  -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}'")
        lines.append(curl.joined(separator: " \\\n"))
        return lines.joined(separator: "\n")
    }
}

// MARK: - Merging

nonisolated enum MCPConfigError: Error, Equatable, LocalizedError {
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let why): return "Config file is not valid JSON: \(why)"
        }
    }
}

nonisolated enum MCPConfigMerge {

    /// Sets `<rootKey>.<name> = entry` in a JSON config, preserving everything else.
    /// `existing` nil or blank means a new file. Throws `.malformed` rather than guess.
    static func mergeJSON(existing: Data?,
                          rootKey: String,
                          name: String = MCPClient.serverName,
                          entry: MCPJSONValue) throws -> Data {
        var root: [String: Any] = [:]
        if let existing,
           !String(decoding: existing, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed: Any
            do { parsed = try JSONSerialization.jsonObject(with: existing) }
            catch { throw MCPConfigError.malformed(error.localizedDescription) }
            guard let dict = parsed as? [String: Any] else {
                throw MCPConfigError.malformed("top level is not an object")
            }
            root = dict
        }
        var servers: [String: Any] = [:]
        if let current = root[rootKey] {
            guard let dict = current as? [String: Any] else {
                throw MCPConfigError.malformed("\"\(rootKey)\" is not an object")
            }
            servers = dict
        }
        servers[name] = entry.foundationValue
        root[rootKey] = servers
        var data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(contentsOf: Array("\n".utf8))
        return data
    }

    /// Replaces any Whisperer server definition in a Codex config.toml with `block`,
    /// leaving every other table — including other servers' subtables — untouched.
    /// Idempotent: merging the same block twice gives the same text.
    static func mergeCodexTOML(existing: String, block: String) -> String {
        let cleaned = removeCodexServer(existing, name: MCPClient.serverName)
        var trimmed = cleaned
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        let body = block.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? body + "\n" : trimmed + "\n\n" + body + "\n"
    }

    /// Removes `[mcp_servers.<name>]`, every `[mcp_servers.<name>.*]` subtable (all
    /// occurrences), and dotted/inline definitions of the same server.
    static func removeCodexServer(_ toml: String, name: String) -> String {
        let lines = toml.components(separatedBy: "\n")
        var out: [String] = []
        var currentTable: [String] = []      // key path of the table we are in
        var dropping = false

        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if let header = MCPTOML.tableHeaderPath(stripped) {
                currentTable = header
                dropping = header.count >= 2 && header[0] == "mcp_servers" && header[1] == name
                if dropping { continue }
                out.append(line)
                continue
            }
            if dropping { continue }

            // Inline / dotted definitions outside our table.
            if let keyPath = MCPTOML.keyPath(stripped) {
                let full = currentTable + keyPath
                if full.count >= 2 && full[0] == "mcp_servers" && full[1] == name { continue }
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - TOML / shell helpers

nonisolated enum MCPTOML {

    /// Basic-string quoting per TOML 1.0.
    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 || ch.value == 0x7F { out += String(format: "\\u%04X", ch.value) }
                else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }

    /// For a `[a.b]` or `[[a.b]]` header line returns ["a", "b"]; nil for anything else
    /// (including array values that happen to start with `[`).
    static func tableHeaderPath(_ line: String) -> [String]? {
        var s = Substring(line)
        // Strip a trailing comment outside quotes (good enough for headers).
        if let hash = commentStart(in: s) { s = s[..<hash] }
        s = Substring(s.trimmingCharacters(in: .whitespaces))
        guard s.hasPrefix("["), s.hasSuffix("]") else { return nil }
        var inner = s.dropFirst().dropLast()
        if inner.hasPrefix("[") && inner.hasSuffix("]") { inner = inner.dropFirst().dropLast() }
        let path = splitDotted(String(inner))
        guard let path, !path.isEmpty else { return nil }
        return path
    }

    /// For a `key.path = value` line returns the key path; nil for comments/blank/other.
    static func keyPath(_ line: String) -> [String]? {
        guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("[") else { return nil }
        guard let eq = equalsOutsideQuotes(in: line) else { return nil }
        return splitDotted(String(line[..<eq]))
    }

    /// Splits `a."b.c".d` into ["a", "b.c", "d"]. Returns nil unless every segment is a bare
    /// key (`A-Za-z0-9_-`) or a quoted key, separated by dots.
    static func splitDotted(_ s: String) -> [String]? {
        let chars = Array(s)
        var i = 0
        var parts: [String] = []
        func skipSpace() { while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 } }
        func isBare(_ c: Character) -> Bool {
            c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-")
        }
        while true {
            skipSpace()
            guard i < chars.count else { return nil }
            if chars[i] == "\"" || chars[i] == "'" {
                let q = chars[i]; i += 1
                var seg = ""
                while i < chars.count, chars[i] != q { seg.append(chars[i]); i += 1 }
                guard i < chars.count else { return nil }
                i += 1
                parts.append(seg)
            } else {
                var seg = ""
                while i < chars.count, isBare(chars[i]) { seg.append(chars[i]); i += 1 }
                guard !seg.isEmpty else { return nil }
                parts.append(seg)
            }
            skipSpace()
            if i == chars.count { return parts }
            guard chars[i] == "." else { return nil }
            i += 1
        }
    }

    private static func equalsOutsideQuotes(in s: String) -> String.Index? {
        var quote: Character?
        for i in s.indices {
            let ch = s[i]
            if let q = quote { if ch == q { quote = nil }; continue }
            if ch == "\"" || ch == "'" { quote = ch; continue }
            if ch == "=" { return i }
        }
        return nil
    }

    private static func commentStart(in s: Substring) -> Substring.Index? {
        var quote: Character?
        for i in s.indices {
            let ch = s[i]
            if let q = quote { if ch == q { quote = nil }; continue }
            if ch == "\"" || ch == "'" { quote = ch; continue }
            if ch == "#" { return i }
        }
        return nil
    }
}

nonisolated enum MCPShell {
    /// Single-quotes a shell argument when it contains anything but safe characters.
    static func quote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:@%+=,")
        if !s.isEmpty && s.rangeOfCharacter(from: safe.inverted) == nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
