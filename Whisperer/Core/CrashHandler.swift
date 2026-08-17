//
//  CrashHandler.swift
//  Whisperer
//
//  Captures crashes and unexpected terminations to help diagnose issues
//

import Foundation

final class CrashHandler {
    static let shared = CrashHandler()

    private let crashMarkerURL: URL

    private init() {
        // Crash marker file location
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Whisperer")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        crashMarkerURL = logsDir.appendingPathComponent(".crash_marker")
    }

    // MARK: - Installation

    func install() {
        // Check if previous session crashed
        checkForPreviousCrash()

        // Write crash marker (will be deleted on clean exit)
        writeCrashMarker()

        // Install exception handler
        installExceptionHandler()

        // Install signal handlers
        installSignalHandlers()

        // Installing handlers cannot fail — reporting that it didn't is narration,
        // not evidence. Kept in the ring buffer so a dump still shows the ordering.
        Logger.step("crash.install", .app)
    }

    func uninstall() {
        // Remove crash marker on clean exit
        removeCrashMarker()
        Logger.step("crash.clean", .app)
    }

    // MARK: - Previous Crash Detection

    private func checkForPreviousCrash() {
        guard FileManager.default.fileExists(atPath: crashMarkerURL.path) else { return }

        // The marker is written by this class in the same `k=v` grammar as the log,
        // so its fields carry straight through instead of being re-parsed from prose.
        var fields: [String: MetadataValue] = [:]
        if let data = try? Data(contentsOf: crashMarkerURL),
           let marker = String(data: data, encoding: .utf8) {
            for pair in marker.split(whereSeparator: { $0.isWhitespace }) {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { fields[String(parts[0])] = .string(String(parts[1])) }
            }
        }
        Logger.event(.appPrevCrash, .app, fields, level: .warning)

        // Remove the old marker
        try? FileManager.default.removeItem(at: crashMarkerURL)
    }

    /// Returns true if the previous app session crashed
    var didPreviousSessionCrash: Bool {
        return FileManager.default.fileExists(atPath: crashMarkerURL.path)
    }

    // MARK: - Crash Marker

    private func writeCrashMarker() {
        // Packed `k=v`, values free of whitespace, so the next launch can read the
        // fields back without a parser. See checkForPreviousCrash().
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let marker = "at=\(ISO8601DateFormatter().string(from: Date()))"
            + " pid=\(ProcessInfo.processInfo.processIdentifier)"
            + " v=\(version)/\(build)"
        try? marker.write(to: crashMarkerURL, atomically: true, encoding: .utf8)
    }

    private func removeCrashMarker() {
        try? FileManager.default.removeItem(at: crashMarkerURL)
    }

    // MARK: - Exception Handler

    private func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            CrashHandler.handleException(exception)
        }
    }

    private static func handleException(_ exception: NSException) {
        let message = """
        UNCAUGHT EXCEPTION
        Name: \(exception.name.rawValue)
        Reason: \(exception.reason ?? "unknown")
        Stack:
        \(exception.callStackSymbols.joined(separator: "\n"))
        """

        // One record in the rolling log, the whole trace in crash.log. Duplicating the
        // backtrace into both was 55% of a day's log volume — 14,044 lines — and the
        // copy carried nothing crash.log didn't already have.
        Logger.event(.appException, .app, [
            "name": .string(exception.name.rawValue),
            "reason": .string(exception.reason ?? "?"),
            "frames": .int(exception.callStackSymbols.count),
            "file": .string("crash.log")
        ], level: .critical)
        Logger.flush()

        // Also write to a separate crash file for persistence
        writeCrashLog(message)
    }

    // MARK: - Signal Handlers

    private func installSignalHandlers() {
        // Install handlers for common crash signals
        signal(SIGABRT) { sig in CrashHandler.handleSignal(sig, name: "SIGABRT - Abort") }
        signal(SIGSEGV) { sig in CrashHandler.handleSignal(sig, name: "SIGSEGV - Segmentation Fault") }
        signal(SIGBUS) { sig in CrashHandler.handleSignal(sig, name: "SIGBUS - Bus Error") }
        signal(SIGFPE) { sig in CrashHandler.handleSignal(sig, name: "SIGFPE - Floating Point Exception") }
        signal(SIGILL) { sig in CrashHandler.handleSignal(sig, name: "SIGILL - Illegal Instruction") }
        signal(SIGTRAP) { sig in CrashHandler.handleSignal(sig, name: "SIGTRAP - Trace Trap") }
    }

    private static func handleSignal(_ signal: Int32, name: String) {
        // Capture stack trace — backtrace() is async-signal-safe on macOS
        var callStack = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let frameCount = backtrace(&callStack, 128)
        let symbols = backtrace_symbols(&callStack, frameCount)

        var stackTrace = ""
        if let symbols = symbols {
            for i in 0..<Int(frameCount) {
                if let symbol = symbols[i] {
                    stackTrace += "  \(String(cString: symbol))\n"
                }
            }
            free(symbols)
        }

        let message = """
        FATAL SIGNAL RECEIVED
        Signal: \(name) (\(signal))
        Time: \(Date())

        Stack Trace (\(frameCount) frames):
        \(stackTrace)
        """

        // Try to log (may not work depending on signal). One record only — the frames
        // go to crash.log, which is where DiagnosticsView already sends the user.
        Logger.event(.appCrash, .app, [
            "sig": .string(name.split(separator: " ").first.map(String.init) ?? name),
            "num": .int(Int(signal)),
            "frames": .int(Int(frameCount)),
            "file": .string("crash.log")
        ], level: .critical)
        Logger.flush()

        // Write to crash file
        writeCrashLog(message)

        // Re-raise the signal to get default behavior (crash report)
        Darwin.signal(signal, SIG_DFL)
        Darwin.raise(signal)
    }

    // MARK: - Crash Log

    private static func writeCrashLog(_ message: String) {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Whisperer")
        let crashLogURL = logsDir.appendingPathComponent("crash.log")

        // Include task tracker info
        let stats = TaskTracker.shared.getStatistics()
        let orphans = TaskTracker.shared.getOrphanedTasks()

        var orphanInfo = ""
        if !orphans.isEmpty {
            orphanInfo = "\nOrphaned Tasks:\n"
            for orphan in orphans {
                let age = Date().timeIntervalSince(orphan.startTime)
                orphanInfo += "  - [\(orphan.id)] \(orphan.name) (age: \(String(format: "%.1f", age))s)\n"
            }
        }

        let fullMessage = """
        ============================================
        CRASH REPORT - \(Date())
        ============================================
        \(message)

        Task Statistics:
        - Total: \(stats.total)
        - Completed: \(stats.completed)
        - Failed: \(stats.failed)
        - Cancelled: \(stats.cancelled)
        - Orphaned: \(stats.orphaned)
        \(orphanInfo)
        ============================================

        """

        if let data = fullMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: crashLogURL.path) {
                // Append to existing file
                if let handle = try? FileHandle(forWritingTo: crashLogURL) {
                    try? handle.seekToEnd()
                    // `write(contentsOf:)`: `write(_:)` raises an uncatchable ObjC exception on a
                    // full volume. Crashing inside the crash reporter destroys the report.
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                // Create new file
                try? data.write(to: crashLogURL)
            }
        }
    }

    // MARK: - Public API for Diagnostics

    /// Get path to crash log
    static var crashLogURL: URL {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Whisperer")
        return logsDir.appendingPathComponent("crash.log")
    }

    /// Check if crash log exists and is recent (less than 24 hours old)
    static var hasCrashLog: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: crashLogURL.path),
              let modified = attrs[.modificationDate] as? Date else {
            return false
        }
        return Date().timeIntervalSince(modified) < 86400
    }
}

