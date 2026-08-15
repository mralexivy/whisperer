//
//  Logger.swift
//  Whisperer
//
//  Packed, agent-readable file log + os_log prose mirror.
//
//  The file records deviations and outcomes only. Narration of steps that
//  cannot fail goes to EventRingBuffer via `step()` and reaches disk only
//  when a session fails. See docs/references/log-format.md.
//

import Foundation
import os
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

    /// Single-character code used in the packed file format.
    var code: String {
        switch self {
        case .debug: return "D"
        case .info: return "I"
        case .warning: return "W"
        case .error: return "E"
        case .critical: return "C"
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

    /// Three-character code used in the packed file format.
    var code: String {
        switch self {
        case .app: return "app"
        case .audio: return "aud"
        case .transcription: return "trn"
        case .ui: return "ui"
        case .keyListener: return "key"
        case .textInjection: return "txt"
        case .permissions: return "prm"
        case .model: return "mdl"
        }
    }
}

// MARK: - Log Event

/// A stable `<area>.<verb>` event code. Stable codes are greppable, countable
/// and diffable across runs, which an English sentence is not. Declare every
/// code as a static member here so a code cannot drift between emission sites.
struct LogEvent: ExpressibleByStringLiteral, CustomStringConvertible, Hashable {
    let code: String

    init(stringLiteral value: StringLiteralType) { self.code = value }
    init(_ code: String) { self.code = code }

    var description: String { code }
}

extension LogEvent {
    // app
    static let appBoot: LogEvent            = "app.boot"
    static let appQuit: LogEvent            = "app.quit"
    static let appCrash: LogEvent           = "app.crash"
    static let appPrevCrash: LogEvent       = "app.prevcrash"
    static let appException: LogEvent       = "app.exception"

    // audio
    static let recStart: LogEvent           = "rec.start"
    static let recStop: LogEvent            = "rec.stop"
    static let recCancel: LogEvent          = "rec.cancel"
    static let recFail: LogEvent            = "rec.fail"
    static let audioFirst: LogEvent         = "audio.first"
    static let engBuild: LogEvent           = "eng.build"
    static let engTap: LogEvent             = "eng.tap"
    static let engRetry: LogEvent           = "eng.retry"
    static let engConfigChange: LogEvent    = "eng.cfgchange"
    static let devChange: LogEvent          = "dev.change"
    static let devSelect: LogEvent          = "dev.select"
    static let devFail: LogEvent            = "dev.fail"
    static let muteOn: LogEvent             = "mute.on"
    static let muteOff: LogEvent            = "mute.off"

    // transcription
    static let asrStart: LogEvent           = "asr.start"
    static let asrChunk: LogEvent           = "asr.chunk"
    static let asrPartial: LogEvent         = "asr.partial"
    static let asrDone: LogEvent            = "asr.done"
    static let asrFail: LogEvent            = "asr.fail"
    static let langDetect: LogEvent         = "lang.detect"

    // model
    static let modelLoad: LogEvent          = "model.load"
    static let modelFree: LogEvent          = "model.free"
    static let llmDone: LogEvent            = "llm.done"
    static let llmFail: LogEvent            = "llm.fail"
    static let llmDegenerate: LogEvent      = "llm.degenerate"

    // text injection
    static let injectOK: LogEvent           = "inject.ok"
    static let injectFail: LogEvent         = "inject.fail"

    // meetings
    static let meetDetect: LogEvent         = "meet.detect"
    static let meetStart: LogEvent          = "meet.start"
    static let meetStop: LogEvent           = "meet.stop"
    static let meetAbandon: LogEvent        = "meet.abandon"
    static let meetRefine: LogEvent         = "meet.refine"

    // infrastructure
    static let mcpListen: LogEvent          = "mcp.listen"
    static let mcpState: LogEvent           = "mcp.state"
    static let stall: LogEvent              = "health.stall"
    static let recovered: LogEvent          = "health.recover"
    static let mainHang: LogEvent           = "health.mainhang"
}

// MARK: - Logger

final class Logger {
    static let shared = Logger()

    /// Bumped whenever the on-disk grammar changes so a reader can tell versions apart.
    static let formatVersion = "whisperer/2"

    private let queue = DispatchQueue(label: "whisperer.logger", qos: .utility)
    private var fileHandle: FileHandle?
    private var logFileURL: URL
    private let logsDir: URL
    private let fileDateFormatter: DateFormatter
    private let anchorFormatter: DateFormatter
    private let osLog = OSLog(subsystem: "com.ivy.whisperer", category: "general")

    // Offsets in the file are relative to the most recent `#t` anchor. A new anchor
    // is written when a block opens or a minute elapses — recovering absolute time
    // at ~1 line/minute instead of 25 characters on every line.
    private var anchorInstant: ContinuousClock.Instant = .now
    private var anchorDate: Date = Date()
    private var anchorWritten = false
    private static let anchorInterval: Duration = .seconds(60)

    // Minimum log level to write
    // Default: .info in release, .debug in debug builds
    // Can be changed at runtime via Settings > Diagnostics > Verbose Logging
    var minimumLevel: LogLevel {
        didSet {
            UserDefaults.standard.set(minimumLevel.rawValue, forKey: "logMinimumLevel")
            Logger.event("log.level", .app, ["to": .string(minimumLevel.code)])
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

    // crash.log is appended to by the signal handler and is not covered by daily
    // rotation. Trimmed to this size on launch so it cannot grow without bound.
    private let maxCrashLogBytes = 1_000_000

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

        fileDateFormatter = DateFormatter()
        fileDateFormatter.dateFormat = "yyyy-MM-dd"

        anchorFormatter = DateFormatter()
        anchorFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"

        // Create log directory
        logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Whisperer")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // Use today's date in the filename
        let today = fileDateFormatter.string(from: Date())
        currentLogDate = today
        logFileURL = logsDir.appendingPathComponent("whisperer-\(today).log")

        openLogFile()
        cleanupOldLogs()
        trimCrashLog()
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

    // MARK: - Structured Events

    /// Write one packed record with a stable event code. This is the preferred form —
    /// `event()` output can be grepped, counted and diffed; prose cannot.
    static func event(
        _ event: LogEvent,
        _ subsystem: LogSubsystem = .app,
        _ metadata: [String: MetadataValue] = [:],
        level: LogLevel = .info,
        file: String = #file,
        line: Int = #line
    ) {
        shared.emit(event: event, message: nil, level: level, subsystem: subsystem,
                    metadata: metadata, file: file, line: line)
    }

    /// Record a happy-path step. Goes to `EventRingBuffer` + `os_log`, **never** to the
    /// file — it reaches disk only when a session fails and dumps its timeline.
    ///
    /// Use this for anything that reports a thing which cannot fail didn't fail.
    static func step(
        _ event: LogEvent,
        _ subsystem: LogSubsystem = .app,
        _ metadata: [String: MetadataValue] = [:],
        component: String? = nil,
        kind: EventKind = .state
    ) {
        EventRingBuffer.shared.record(
            component: component ?? subsystem.code,
            operation: event.code,
            kind: kind,
            metadata: metadata
        )
        os_log(.debug, log: shared.osLog, "%{public}@", "\(event.code) \(Logger.packMetadata(metadata))")
    }

    // MARK: - Suppression

    private struct CoalescedEntry {
        var count: Int
        var event: LogEvent
        var metadata: [String: MetadataValue]
        var subsystem: LogSubsystem
        var level: LogLevel
    }
    private struct SuppressionState {
        var lastEmit: [String: ContinuousClock.Instant] = [:]
        var suppressed: [String: Int] = [:]
        var coalesced: [String: CoalescedEntry] = [:]
    }
    private let suppression = OSAllocatedUnfairLock(initialState: SuppressionState())

    /// Emit at most one record per `interval` for `key`. The next record that does get
    /// through carries `×N` for the ones that were dropped.
    static func throttled(
        _ event: LogEvent,
        key: String,
        interval: Duration,
        _ subsystem: LogSubsystem = .app,
        _ metadata: [String: MetadataValue] = [:],
        level: LogLevel = .info,
        file: String = #file,
        line: Int = #line
    ) {
        let now = ContinuousClock.now
        let suppressedCount: Int? = shared.suppression.withLock { state in
            if let last = state.lastEmit[key], now - last < interval {
                state.suppressed[key, default: 0] += 1
                return nil
            }
            let dropped = state.suppressed.removeValue(forKey: key) ?? 0
            state.lastEmit[key] = now
            return dropped
        }
        guard let dropped = suppressedCount else { return }

        var meta = metadata
        if dropped > 0 { meta["×"] = .int(dropped) }
        shared.emit(event: event, message: nil, level: level, subsystem: subsystem,
                    metadata: meta, file: file, line: line)
    }

    /// Count silently. `flushCoalesced` writes one record carrying the total.
    /// The last call's metadata wins — coalescing is for "this happened N times",
    /// not for retaining every occurrence's fields.
    static func coalesced(
        _ event: LogEvent,
        key: String,
        _ subsystem: LogSubsystem = .app,
        _ metadata: [String: MetadataValue] = [:],
        level: LogLevel = .info
    ) {
        shared.suppression.withLock { state in
            let count = (state.coalesced[key]?.count ?? 0) + 1
            state.coalesced[key] = CoalescedEntry(
                count: count, event: event, metadata: metadata,
                subsystem: subsystem, level: level
            )
        }
    }

    /// Write the accumulated count for `key` as a single record, or nothing if it never fired.
    static func flushCoalesced(key: String, file: String = #file, line: Int = #line) {
        let entry = shared.suppression.withLock { state in
            state.coalesced.removeValue(forKey: key)
        }
        guard let entry, entry.count > 0 else { return }

        var meta = entry.metadata
        if entry.count > 1 { meta["×"] = .int(entry.count) }
        shared.emit(event: entry.event, message: nil, level: entry.level, subsystem: entry.subsystem,
                    metadata: meta, file: file, line: line)
    }

    // MARK: - Redaction

    /// User speech never reaches disk unless the user opts in. Returns a shape
    /// summary (`‹92c/16w›`) instead of the text itself.
    static func redact(_ text: String) -> String {
        if UserDefaults.standard.bool(forKey: "logShowTranscripts") {
            return text
        }
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return "‹\(text.count)c/\(words)w›"
    }

    // MARK: - Blocks

    /// Open a block. `header` is written verbatim (e.g. `>ses 7 dictation route=default`),
    /// the offset origin is reset to now, and the block tally starts from zero.
    static func beginBlock(_ header: String) {
        shared.blockState.withLock { $0 = BlockState() }
        shared.queue.async { [weak shared] in
            guard let shared else { return }
            shared.resetAnchorLocked(force: true)
            shared.writeToFile(header + "\n")
        }
    }

    /// Close a block. `footer` is written verbatim (e.g. `<ses 7 ok dur=8.9`).
    static func endBlock(_ footer: String) {
        shared.queue.async { [weak shared] in
            shared?.writeToFile(footer + "\n")
        }
    }

    struct BlockState {
        var warn = 0
        var err = 0
        /// Last event code written in this block — what a `FAIL` verdict reports as `at=`.
        var lastEvent = "-"
    }

    /// Tally of what has been written since the last `beginBlock`.
    static var blockState: BlockState {
        shared.blockState.withLock { $0 }
    }

    private let blockState = OSAllocatedUnfairLock(initialState: BlockState())

    /// Append raw pre-formatted lines (a ring-buffer timeline on a failed session).
    static func writeRaw(_ text: String) {
        guard !text.isEmpty else { return }
        shared.queue.async { [weak shared] in
            shared?.writeToFile(text.hasSuffix("\n") ? text : text + "\n")
        }
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

    // MARK: - Packing

    /// `k=v`, sorted for determinism. Values containing a space, `=` or a quote are
    /// single-quoted; embedded newlines become `\n` so a record is always one line.
    static func packMetadata(_ metadata: [String: MetadataValue]) -> String {
        guard !metadata.isEmpty else { return "" }
        return metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(packValue($0.value.description))" }
            .joined(separator: " ")
    }

    static func packValue(_ raw: String) -> String {
        if raw.isEmpty { return "''" }
        let flat = raw
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
        guard flat.contains(" ") || flat.contains("=") || flat.contains("'") else { return flat }
        return "'" + flat.replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    // MARK: - Private Methods

    private func log(_ message: String, level: LogLevel, subsystem: LogSubsystem, file: String, line: Int) {
        emit(event: nil, message: message, level: level, subsystem: subsystem, metadata: [:], file: file, line: line)
    }

    private func emit(
        event: LogEvent?,
        message: String?,
        level: LogLevel,
        subsystem: LogSubsystem,
        metadata: [String: MetadataValue],
        file: String,
        line: Int
    ) {
        guard level >= minimumLevel || (level == .debug && verboseSubsystems.contains(subsystem)) else { return }

        blockState.withLock { state in
            if level == .warning { state.warn += 1 }
            if level >= .error { state.err += 1 }
            if let event { state.lastEvent = event.code }
        }

        let now = ContinuousClock.now
        let fileName = (file as NSString).lastPathComponent

        // Body: either a stable event code with packed fields, or `~` + prose for the
        // long tail of unconverted call sites.
        var body: String
        if let event {
            body = event.code
            let packed = Logger.packMetadata(metadata)
            if !packed.isEmpty { body += " " + packed }
        } else {
            let flat = (message ?? "")
                .replacingOccurrences(of: "\r\n", with: "\\n")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\n")
            body = "~ " + flat
        }

        // file:line is navigation for a failure and dead weight on a debug line.
        if level >= .warning {
            body += " @\(fileName):\(line)"
        }

        let record = "\(level.code) \(subsystem.code) \(body)"

        queue.async { [weak self] in
            guard let self else { return }
            self.resetAnchorLocked(force: false, now: now)
            let offset = Logger.seconds(now - self.anchorInstant)
            self.writeToFile(String(format: "+%.3f ", offset) + record + "\n")
        }

        // Prose stays available to the engineer through the os_log mirror.
        let console = message ?? "\(event?.code ?? "") \(Logger.packMetadata(metadata))"
        switch level {
        case .debug:
            os_log(.debug, log: osLog, "%{public}@", console)
        case .info:
            os_log(.info, log: osLog, "%{public}@", console)
        case .warning:
            os_log(.default, log: osLog, "⚠️ %{public}@", console)
        case .error:
            os_log(.error, log: osLog, "❌ %{public}@", console)
        case .critical:
            os_log(.fault, log: osLog, "🔴 %{public}@", console)
        }

        #if DEBUG
        print("[\(fileName):\(line)] \(record)")
        #endif
    }

    /// Must be called on `queue`.
    private func resetAnchorLocked(force: Bool, now: ContinuousClock.Instant = .now) {
        guard force || !anchorWritten || (now - anchorInstant) > Logger.anchorInterval else { return }
        anchorInstant = now
        anchorDate = Date()
        anchorWritten = true
        writeToFile("#t \(anchorFormatter.string(from: anchorDate))\n")
    }

    private func openLogFile() {
        let existed = FileManager.default.fileExists(atPath: logFileURL.path)
        if !existed {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()

        // The legend is written once per FILE, not once per launch — the old 6-line
        // startup banner cost 2,191 lines a day on its own. `app.boot` marks launches.
        let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        if !existed || size == 0 {
            fileHandle?.write(Data(Logger.legend.utf8))
        }
        anchorWritten = false
    }

    /// Self-describing header so an agent reading the file cold needs no external doc.
    static let legend = """
    #fmt \(Logger.formatVersion)  <off> <lvl> <sub> <evt|~prose> k=v…
    #lvl D=debug I=info W=warn E=error C=critical
    #sub app aud=audio trn=transcription ui key=keyListener txt=textInjection prm=permissions mdl=model
    #evt <area>.<verb> stable code; `~` = unstructured prose; ×N = N suppressed repeats
    #off seconds since the preceding #t anchor; W and above carry @file:line
    #ses >ses N … opens a recording block, <ses N ok|FAIL … closes it with the verdict
    #tl  |tl lines = in-memory step timeline, emitted only before a FAIL verdict
    #val quoted with '' when containing space/=/quote; \\n = embedded newline
    #txt ‹92c/16w› = redacted user speech (chars/words); enable Diagnostics ▸ transcript text to see it

    """

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

    /// crash.log is written by the signal handler and never rotated by the daily scheme,
    /// so it grew without bound. Keep the newest ~1 MB, cut at a report boundary.
    private func trimCrashLog() {
        let url = logsDir.appendingPathComponent("crash.log")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > maxCrashLogBytes else { return }
        guard let data = try? Data(contentsOf: url) else { return }

        var tail = data.suffix(maxCrashLogBytes)
        // Start at the first full crash report so the file never opens mid-frame.
        if let marker = "============================================".data(using: .utf8),
           let range = tail.range(of: marker) {
            tail = tail[range.lowerBound...]
        }
        let header = Data("[older crash reports trimmed]\n\n".utf8)
        try? (header + tail).write(to: url, options: .atomic)
    }

    // MARK: - Helpers

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
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
