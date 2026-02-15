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
        Logger.debug("Installing crash handlers...", subsystem: .app)

        // Check if previous session crashed
        checkForPreviousCrash()

        // Write crash marker (will be deleted on clean exit)
        writeCrashMarker()

        // Install exception handler
        installExceptionHandler()

        // Install signal handlers
        installSignalHandlers()

        Logger.debug("Crash handlers installed", subsystem: .app)
    }

    func uninstall() {
        // Remove crash marker on clean exit
        removeCrashMarker()
        Logger.debug("Crash marker removed - clean exit", subsystem: .app)
    }

    // MARK: - Previous Crash Detection

    private func checkForPreviousCrash() {
        if FileManager.default.fileExists(atPath: crashMarkerURL.path) {
            // Previous session crashed!
            if let data = try? Data(contentsOf: crashMarkerURL),
               let crashInfo = String(data: data, encoding: .utf8) {
                Logger.warning("Previous session crashed! Info: \(crashInfo)", subsystem: .app)
            } else {
                Logger.warning("Previous session crashed! (no additional info)", subsystem: .app)
            }

            // Remove the old marker
            try? FileManager.default.removeItem(at: crashMarkerURL)
        }
    }

    /// Returns true if the previous app session crashed
    var didPreviousSessionCrash: Bool {
        return FileManager.default.fileExists(atPath: crashMarkerURL.path)
    }

    // MARK: - Crash Marker

    private func writeCrashMarker() {
        let info = """
        Session started: \(Date())
        PID: \(ProcessInfo.processInfo.processIdentifier)
        Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")
        """
        try? info.write(to: crashMarkerURL, atomically: true, encoding: .utf8)
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

        Logger.critical(message, subsystem: .app)
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
        let message = """
        FATAL SIGNAL RECEIVED
        Signal: \(name) (\(signal))
        Time: \(Date())
        """

        // Try to log (may not work depending on signal)
        Logger.critical(message, subsystem: .app)
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
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
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

    /// Check if crash log exists
    static var hasCrashLog: Bool {
        return FileManager.default.fileExists(atPath: crashLogURL.path)
    }
}

