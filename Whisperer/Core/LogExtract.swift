//
//  LogExtract.swift
//  Whisperer
//
//  Extracts recent >ses/<ses session blocks from a Whisperer log file.
//

import Foundation

/// Lightweight log reader that surfaces recent recording session blocks.
///
/// The file log is packed `k=v` with `>ses`/`<ses` boundaries; this type extracts
/// those blocks without importing the full Logger infrastructure. FAIL blocks are
/// returned before ok blocks so the most diagnostic content appears first.
enum LogExtract {

    // MARK: - Public API

    /// Parse raw log text and return the legend lines plus up to `count` session blocks.
    ///
    /// FAIL blocks are placed before ok blocks so the most diagnostic content comes
    /// first. Within each group, chronological order is preserved.
    static func recentSessions(_ raw: String, count: Int = 5) -> String {
        let lines = raw.components(separatedBy: "\n")

        // Legend lines (# prefix) that appear before any block
        var legendLines: [String] = []
        // All completed blocks: (isFail, rawLines)
        var blocks: [(isFail: Bool, lines: [String])] = []

        var currentBlock: [String] = []
        var inBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#") && !inBlock {
                legendLines.append(line)
                continue
            }

            if trimmed.hasPrefix(">ses") {
                inBlock = true
                currentBlock = [line]
                continue
            }

            if inBlock {
                currentBlock.append(line)
                if trimmed.hasPrefix("<ses") {
                    // A block is FAIL when its closing line contains "FAIL"
                    let isFail = trimmed.contains("FAIL")
                    blocks.append((isFail: isFail, lines: currentBlock))
                    currentBlock = []
                    inBlock = false
                }
            }
        }

        // Separate and take the most recent blocks, FAIL first
        let failBlocks = blocks.filter { $0.isFail }
        let okBlocks   = blocks.filter { !$0.isFail }

        let failPart = Array(failBlocks.suffix(count))
        let okPart   = Array(okBlocks.suffix(max(0, count - failPart.count)))
        let ordered  = failPart + okPart

        var parts: [String] = []
        if !legendLines.isEmpty {
            parts.append(legendLines.joined(separator: "\n"))
        }
        parts += ordered.map { $0.lines.joined(separator: "\n") }
        return parts.joined(separator: "\n\n")
    }

    /// Read today's dated log from the Logger logs directory and return
    /// the legend lines plus up to `count` recent session blocks.
    static func fromCurrentLog(count: Int = 5) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        let url = Logger.logsDirectoryURL
            .appendingPathComponent("whisperer-\(today).log")

        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return recentSessions(raw, count: count)
    }
}
