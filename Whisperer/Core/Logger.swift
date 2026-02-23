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

enum LogSubsystem: String {
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
    private let logFileURL: URL
    private let dateFormatter: DateFormatter
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

    // Maximum log file size before rotation (10 MB)
    private let maxFileSize: UInt64 = 10 * 1024 * 1024

    // Number of rotated logs to keep
    private let maxRotatedFiles = 7

    private init() {
        // Load persisted log level, default to .info for release, .debug for debug builds
        #if DEBUG
        let defaultLevel = LogLevel.debug.rawValue
        #else
        let defaultLevel = LogLevel.info.rawValue
        #endif
        let savedLevel = UserDefaults.standard.object(forKey: "logMinimumLevel") as? Int ?? defaultLevel
        minimumLevel = LogLevel(rawValue: savedLevel) ?? .info

        // Setup date formatter
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        // Create log directory
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Whisperer")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        logFileURL = logsDir.appendingPathComponent("whisperer.log")

        // Open log file
        openLogFile()

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
        return shared.logFileURL.deletingLastPathComponent()
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
        guard level >= minimumLevel else { return }

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

        // Check if rotation is needed
        rotateIfNeeded()

        // Open for appending
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
    }

    private func writeToFile(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        fileHandle?.write(data)

        // Periodically check file size
        if let size = try? FileManager.default.attributesOfItem(atPath: logFileURL.path)[.size] as? UInt64,
           size > maxFileSize {
            rotateLogFiles()
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? UInt64,
              size > maxFileSize else { return }
        rotateLogFiles()
    }

    private func rotateLogFiles() {
        fileHandle?.closeFile()
        fileHandle = nil

        let logsDir = logFileURL.deletingLastPathComponent()

        // Rotate existing files
        for i in (1..<maxRotatedFiles).reversed() {
            let oldPath = logsDir.appendingPathComponent("whisperer.\(i).log")
            let newPath = logsDir.appendingPathComponent("whisperer.\(i + 1).log")
            try? FileManager.default.moveItem(at: oldPath, to: newPath)
        }

        // Rename current log to .1.log
        let rotatedPath = logsDir.appendingPathComponent("whisperer.1.log")
        try? FileManager.default.moveItem(at: logFileURL, to: rotatedPath)

        // Delete oldest file if over limit
        let oldestPath = logsDir.appendingPathComponent("whisperer.\(maxRotatedFiles).log")
        try? FileManager.default.removeItem(at: oldestPath)

        // Create new log file
        FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
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
