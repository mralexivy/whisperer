//
//  Logger.swift
//  Whisperer
//
//  Centralized logging system with file output for debugging
//

import Foundation
import os.log
import AppKit

// MARK: - Log Level

enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case critical = 4

    var prefix: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .critical: return "CRITICAL"
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Log Subsystem

enum LogSubsystem: String, CaseIterable {
    case app = "App"
    case audio = "Audio"
    case transcription = "Transcription"
    case ui = "UI"
    case keyListener = "KeyListener"
    case textInjection = "TextInjection"
    case permissions = "Permissions"
    case model = "Model"
}

// MARK: - Logger

final class Logger {
    static let shared = Logger()

    private let queue = DispatchQueue(label: "whisperer.logger", qos: .utility)
    private var fileHandle: FileHandle?
    private var logFileURL: URL
    private let logsDir: URL
    private let dateFormatter: DateFormatter
    private let fileDateFormatter: DateFormatter
    private let osLog = OSLog(subsystem: "com.ivy.whisperer", category: "general")

    // Minimum log level to write
    // Default: .info in release, .debug in debug builds
    // Can be changed at runtime via Settings > Diagnostics > Verbose Logging
    var minimumLevel: LogLevel {
        didSet {
            UserDefaults.standard.set(minimumLevel.rawValue, forKey: "logMinimumLevel")
            let timestamp = dateFormatter.string(from: Date())
            let msg = "[\(timestamp)] [INFO] [App] [Logger.swift:0] Log level changed to \(minimumLevel.prefix)\n"
            queue.async { [weak self] in
                self?.writeToFile(msg)
            }
        }
    }

    /// Whether verbose (debug) logging is enabled
    static var isVerbose: Bool {
        get { shared.minimumLevel == .debug }
        set { shared.minimumLevel = newValue ? .debug : .info }
    }

    /// Per-subsystem verbose overrides.
    /// When a subsystem is set to verbose, its debug messages are logged
    /// even when the global minimum level is .info.
    private var verboseSubsystems: Set<LogSubsystem> = []

    /// Check if a specific subsystem has verbose logging enabled
    static func isSubsystemVerbose(_ subsystem: LogSubsystem) -> Bool {
        shared.verboseSubsystems.contains(subsystem)
    }

    /// Enable or disable verbose logging for a specific subsystem
    static func setSubsystemVerbose(_ verbose: Bool, for subsystem: LogSubsystem) {
        if verbose {
            shared.verboseSubsystems.insert(subsystem)
        } else {
            shared.verboseSubsystems.remove(subsystem)
        }
        UserDefaults.standard.set(verbose, forKey: "logVerbose_\(subsystem.rawValue)")
    }

    // Track the current log date to detect day changes
    private var currentLogDate: String

    // Number of daily log files to keep
    private let maxDaysToKeep = 7

    private init() {
        // Load persisted log level, default to .info for release, .debug for debug builds
        #if DEBUG
        let defaultLevel = LogLevel.debug.rawValue
        #else
        let defaultLevel = LogLevel.info.rawValue
        #endif
        let savedLevel = UserDefaults.standard.object(forKey: "logMinimumLevel") as? Int ?? defaultLevel
        minimumLevel = LogLevel(rawValue: savedLevel) ?? .info

        // Load per-subsystem verbose flags
        for subsystem in LogSubsystem.allCases {
            if UserDefaults.standard.bool(forKey: "logVerbose_\(subsystem.rawValue)") {
                verboseSubsystems.insert(subsystem)
            }
        }

        // Setup date formatters
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        fileDateFormatter = DateFormatter()
        fileDateFormatter.dateFormat = "yyyy-MM-dd"

        // Create log directory
        logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Whisperer")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // Use today's date in the filename
        let today = fileDateFormatter.string(from: Date())
        currentLogDate = today
        logFileURL = logsDir.appendingPathComponent("whisperer-\(today).log")

        // Open log file and clean up old logs
        openLogFile()
        cleanupOldLogs()

        // Write startup marker
        let startupMessage = "\n" + String(repeating: "=", count: 60) + "\n"
            + "Whisperer Started - \(dateFormatter.string(from: Date()))\n"
            + "Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")\n"
            + "Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")\n"
            + String(repeating: "=", count: 60) + "\n"
        writeToFile(startupMessage)
    }

    deinit {
        queue.sync {
            fileHandle?.synchronizeFile()
            fileHandle?.closeFile()
        }
    }

    // MARK: - Public Logging Methods

    static func debug(_ message: String, subsystem: LogSubsystem = .app, file: String = #file, line: Int = #line) {
        shared.log(message, level: .debug, subsystem: subsystem, file: file, line: line)
    }

    static func info(_ message: String, subsystem: LogSubsystem = .app, file: String = #file, line: Int = #line) {
        shared.log(message, level: .info, subsystem: subsystem, file: file, line: line)
    }

    static func warning(_ message: String, subsystem: LogSubsystem = .app, file: String = #file, line: Int = #line) {
        shared.log(message, level: .warning, subsystem: subsystem, file: file, line: line)
    }

    static func error(_ message: String, subsystem: LogSubsystem = .app, file: String = #file, line: Int = #line) {
        shared.log(message, level: .error, subsystem: subsystem, file: file, line: line)
    }

    static func critical(_ message: String, subsystem: LogSubsystem = .app, file: String = #file, line: Int = #line) {
        shared.log(message, level: .critical, subsystem: subsystem, file: file, line: line)
    }

    // MARK: - Log File Access

    static var logFileURL: URL {
        return shared.logFileURL
    }

    static var logsDirectoryURL: URL {
        return shared.logsDir
    }

    static func openLogInFinder() {
        // Open the logs folder so users can see all logs including crash.log
        NSWorkspace.shared.open(logsDirectoryURL)
    }

    static func openLogInConsole() {
        NSWorkspace.shared.open(shared.logFileURL)
    }

    // MARK: - Private Methods

    private func log(_ message: String, level: LogLevel, subsystem: LogSubsystem, file: String, line: Int) {
        guard level >= minimumLevel || (level == .debug && verboseSubsystems.contains(subsystem)) else { return }

        let fileName = (file as NSString).lastPathComponent
        let timestamp = dateFormatter.string(from: Date())
        let formattedMessage = "[\(timestamp)] [\(level.prefix)] [\(subsystem.rawValue)] [\(fileName):\(line)] \(message)"

        // Write to file asynchronously
        queue.async { [weak self] in
            self?.writeToFile(formattedMessage + "\n")
        }

        // Also log to system console
        switch level {
        case .debug:
            os_log(.debug, log: osLog, "%{public}@", message)
        case .info:
            os_log(.info, log: osLog, "%{public}@", message)
        case .warning:
            os_log(.default, log: osLog, "⚠️ %{public}@", message)
        case .error:
            os_log(.error, log: osLog, "❌ %{public}@", message)
        case .critical:
            os_log(.fault, log: osLog, "🔴 %{public}@", message)
        }

        // Also print to console in debug builds
        #if DEBUG
        print(formattedMessage)
        #endif
    }

    private func openLogFile() {
        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        // Open for appending
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
    }

    private func writeToFile(_ text: String) {
        // Check if the day has changed — rotate to a new file if so
        let today = fileDateFormatter.string(from: Date())
        if today != currentLogDate {
            rotateToDailyFile(date: today)
        }

        guard let data = text.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }

    /// Switch to a new daily log file
    private func rotateToDailyFile(date: String) {
        fileHandle?.synchronizeFile()
        fileHandle?.closeFile()
        fileHandle = nil

        currentLogDate = date
        logFileURL = logsDir.appendingPathComponent("whisperer-\(date).log")

        openLogFile()
        cleanupOldLogs()
    }

    /// Delete log files older than maxDaysToKeep days
    private func cleanupOldLogs() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: logsDir.path) else { return }

        let logFiles = files.filter { $0.hasPrefix("whisperer-") && $0.hasSuffix(".log") }

        // Also clean up legacy numbered logs from the old rotation scheme
        let legacyFiles = files.filter {
            $0 == "whisperer.log" ||
            ($0.hasPrefix("whisperer.") && $0.hasSuffix(".log") && $0 != "whisperer.log")
        }
        for legacy in legacyFiles {
            try? FileManager.default.removeItem(at: logsDir.appendingPathComponent(legacy))
        }

        // Keep only the most recent maxDaysToKeep daily log files
        guard logFiles.count > maxDaysToKeep else { return }

        // Date-named files sort lexicographically (yyyy-MM-dd)
        let sorted = logFiles.sorted()
        let toDelete = sorted.dropLast(maxDaysToKeep)
        for file in toDelete {
            try? FileManager.default.removeItem(at: logsDir.appendingPathComponent(file))
        }
    }

    // MARK: - Flush (for crash handling)

    func flush() {
        queue.sync {
            fileHandle?.synchronizeFile()
        }
    }

    static func flush() {
        shared.flush()
    }
}
