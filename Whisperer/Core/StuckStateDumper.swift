//
//  StuckStateDumper.swift
//  Whisperer
//
//  DEBUG-only state dumper triggered when the audio-progress watchdog detects
//  a stuck recording. Writes a self-contained snapshot to disk so the bug can
//  be analyzed post-mortem instead of guessed at from log fragments.
//

#if DEBUG

import AppKit
import AVFoundation
import Foundation

enum StuckStateDumper {

    @MainActor
    static func dump(reason: String) {
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let timestamp = isoFormatter.string(from: now)
            .replacingOccurrences(of: ":", with: "-")

        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Whisperer/stuck-dumps")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let dumpURL = logsDir.appendingPathComponent("stuck-\(timestamp).txt")

        var output = ""
        output += renderHeader(reason: reason, now: now)
        output += renderAppState()
        output += renderAudioRecorder()
        output += renderAudioMuter()
        output += renderWindows()
        output += renderThreadSample()
        output += renderRecentLogs()

        try? output.write(to: dumpURL, atomically: true, encoding: .utf8)

        Logger.error("Stuck state dump written: \(dumpURL.path)", subsystem: .app)
    }

    // MARK: - Sections

    private static func renderHeader(reason: String, now: Date) -> String {
        let pid = ProcessInfo.processInfo.processIdentifier
        let uptime = ProcessInfo.processInfo.systemUptime
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return """
        # Whisperer Stuck-State Dump

        - **Reason:** \(reason)
        - **Timestamp (UTC):** \(now)
        - **PID:** \(pid)
        - **System uptime:** \(String(format: "%.0f", uptime))s
        - **App version:** \(version) (\(build))
        - **Build config:** DEBUG

        """
    }

    @MainActor
    private static func renderAppState() -> String {
        let s = AppState.shared
        var lines: [String] = []
        lines.append("\n## AppState\n")
        lines.append("- state: `\(s.state)`")
        lines.append("- streamingTranscriber: \(s.streamingTranscriberIsNil ? "nil" : "alive")")
        let live = s.liveTranscription
        let preview = String(live.prefix(200))
        lines.append("- liveTranscription (\(live.count) chars): `\(preview)\(live.count > 200 ? "…" : "")`")
        lines.append("- isMicMuted: \(s.isMicMuted)")
        lines.append("- isPaused: \(s.isPaused)")
        lines.append("- isOutputAudioMuted: \(s.isOutputAudioMuted)")
        lines.append("- showModelLoadingToast: \(s.showModelLoadingToast)")
        lines.append("- showClipboardToast: \(s.showClipboardToast)")
        lines.append("- errorMessage: \(s.errorMessage ?? "nil")")
        lines.append("- recordingSessionID: \(s.recordingSessionID.uuidString)")
        if let last = s.lastAmplitudeUpdateTimeForDebug {
            lines.append("- lastAmplitudeUpdateTime: \(last) (Δ \(String(format: "%.2f", Date().timeIntervalSince(last)))s ago)")
        } else {
            lines.append("- lastAmplitudeUpdateTime: nil (no audio buffer ever received)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @MainActor
    private static func renderAudioRecorder() -> String {
        guard let recorder = AppState.shared.audioRecorder else {
            return "\n## AudioRecorder\n\n_nil_\n"
        }
        var lines: [String] = ["\n## AudioRecorder\n"]
        let snap = recorder.debugSnapshot()
        for key in snap.keys.sorted() {
            lines.append("- \(key): \(snap[key] ?? "nil")")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @MainActor
    private static func renderAudioMuter() -> String {
        guard let muter = AppState.shared.audioMuter else {
            return "\n## AudioMuter\n\n_nil_\n"
        }
        var lines: [String] = ["\n## AudioMuter\n"]
        let snap = muter.debugSnapshot()
        for key in snap.keys.sorted() {
            lines.append("- \(key): \(snap[key] ?? "nil")")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @MainActor
    private static func renderWindows() -> String {
        var lines: [String] = ["\n## NSApp Windows\n"]
        for window in NSApp.windows {
            let frame = window.frame
            lines.append("- `\(window.className)` visible=\(window.isVisible) alpha=\(window.alphaValue) level=\(window.level.rawValue) frame=(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height)))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func renderThreadSample() -> String {
        let pid = ProcessInfo.processInfo.processIdentifier
        let sampleURL = URL(fileURLWithPath: "/tmp/whisperer-stuck-sample.txt")
        try? FileManager.default.removeItem(at: sampleURL)

        let task = Process()
        task.launchPath = "/usr/bin/sample"
        task.arguments = ["\(pid)", "1", "-file", sampleURL.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return "\n## Thread Sample\n\n_sample command failed: \(error.localizedDescription)_\n"
        }

        let body = (try? String(contentsOf: sampleURL, encoding: .utf8)) ?? "_no output_"
        return "\n## Thread Sample\n\n```\n\(body)\n```\n"
    }

    private static func renderRecentLogs() -> String {
        let url = Logger.logFileURL
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return "\n## Recent Logs\n\n_could not read \(url.path)_\n"
        }
        let lines = text.components(separatedBy: "\n")
        let tail = lines.suffix(200).joined(separator: "\n")
        return "\n## Recent Logs (last 200 lines from \(url.lastPathComponent))\n\n```\n\(tail)\n```\n"
    }
}

#endif
