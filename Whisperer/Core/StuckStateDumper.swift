//
//  StuckStateDumper.swift
//  Whisperer
//
//  Progress-based stall dumper — runs in Release and Debug builds.
//  Triggered by HealthManager when a component exceeds its critical threshold.
//  Writes stall-latest.dump (always overwritten) and history/stall-<ts>.dump
//  (capped at 10 files).
//

import AppKit
import AVFoundation
import CoreAudio
import Foundation
import MachO

enum StuckStateDumper {

    @MainActor
    static func dump(reason: String) {
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let timestamp = isoFormatter.string(from: now)
            .replacingOccurrences(of: ":", with: "-")

        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Whisperer")
        let historyDir = logsDir.appendingPathComponent("history")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)

        var output = ""
        output += renderHeader(reason: reason, now: now, timestamp: timestamp)
        output += renderSystemSnapshot()
        output += renderComponentHealth()
        output += renderHealthTimeline()
        output += renderRingBuffer()
        output += renderAppState()
        output += renderAudioRecorder()
        output += renderAudioDevices()
        output += renderMemoryUsage()
        output += renderAudioMuter()
        output += renderWindows()
        output += renderThreadSample()
        output += renderRecentLogs()

        // Always overwrite stall-latest.dump
        let latestURL = logsDir.appendingPathComponent("stall-latest.dump")
        try? output.write(to: latestURL, atomically: true, encoding: .utf8)

        // Also write to history/ and cap at 10 files
        let historyURL = historyDir.appendingPathComponent("stall-\(timestamp).dump")
        try? output.write(to: historyURL, atomically: true, encoding: .utf8)
        pruneHistory(historyDir: historyDir, maxFiles: 10)

        Logger.error("Stall dump written: \(latestURL.path)", subsystem: .app)
    }

    // MARK: - History pruning

    private static func pruneHistory(historyDir: URL, maxFiles: Int) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: historyDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let dumps = contents.filter { $0.pathExtension == "dump" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }  // lexicographic = chronological

        if dumps.count > maxFiles {
            for url in dumps.prefix(dumps.count - maxFiles) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Sections

    private static func renderHeader(reason: String, now: Date, timestamp: String) -> String {
        let pid = ProcessInfo.processInfo.processIdentifier
        let uptime = ProcessInfo.processInfo.systemUptime
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #if DEBUG
        let buildConfig = "Debug"
        #elseif APP_STORE
        let buildConfig = "AppStore"
        #else
        let buildConfig = "Release"
        #endif
        return """
        ## Whisperer Health Dump
        Format:       v2
        HealthManager: 1.0
        App:          \(version) (build \(build))
        macOS:        \(osVersion)
        Build:        \(buildConfig)
        PID:          \(pid)
        Uptime:       \(String(format: "%.0f", uptime))s
        Timestamp:    \(timestamp)
        Reason:       \(reason)

        """
    }

    @MainActor
    private static func renderSystemSnapshot() -> String {
        let s = AppState.shared
        var lines: [String] = ["\n## System Snapshot\n"]

        // CPU (app process) — via host_processor_info for user+sys ticks
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            lines.append("Memory:          \(formatBytes(info.phys_footprint)) physFootprint")
        }

        // Focused app
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            lines.append("Focused app:     \(frontApp.bundleIdentifier ?? "unknown") (\(frontApp.localizedName ?? "?"))")
        }

        #if !APP_STORE
        // AX permission
        let axGranted = AXIsProcessTrusted()
        lines.append("AX permission:   \(axGranted ? "granted" : "denied")")
        #endif

        // Recording duration
        if case .recording(let start) = s.state {
            lines.append("Recording:       \(String(format: "%.1f", Date().timeIntervalSince(start)))s elapsed")
        } else {
            lines.append("Recording:       not active (state=\(s.state))")
        }

        // Audio device
        if let recorder = s.audioRecorder {
            let snap = recorder.debugSnapshot()
            let deviceName = snap["selectedDevice"] ?? "unknown"
            lines.append("Audio device:    \(deviceName)")
        }

        // Model
        if let loadedModel = s.loadedModelForDebug {
            let modelDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Whisperer") ?? URL(fileURLWithPath: "/tmp")
            let coreMLDir = modelDir.appendingPathComponent(loadedModel.coreMLEncoderDirectoryName ?? "")
            let hasCoreML = FileManager.default.fileExists(atPath: coreMLDir.path)
            lines.append("Model:           \(loadedModel.rawValue) + CoreML encoder (\(hasCoreML ? "present" : "absent"))")
        } else {
            lines.append("Model:           not loaded")
        }

        // Tiny bridge
        lines.append("Tiny bridge:     \(s.modelPoolForDebug?.previewBridge != nil ? "loaded (CPU-only)" : "nil")")
        lines.append("VAD:             \(s.sileroVADIsNilForDebug ? "nil" : "loaded")")
        lines.append("LLM:             \(s.llmEnabledForDebug ? "enabled" : "disabled")")

        return lines.joined(separator: "\n") + "\n"
    }

    private static func renderComponentHealth() -> String {
        let snap = HealthManager.shared.snapshot()
        return "\n## Component Health\n\n\(snap)\n"
    }

    private static func renderHealthTimeline() -> String {
        let timeline = HealthManager.shared.formattedTimeline()
        return "\n## Health Timeline (status transitions)\n\n\(timeline)\n"
    }

    private static func renderRingBuffer() -> String {
        let events = EventRingBuffer.shared.formattedSnapshot(last: 200)
        return "\n## Ring Buffer Events (last 200)\n\n\(events)\n"
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
        if let lastNonSilent = s.lastNonSilentAmplitudeTimeForDebug {
            lines.append("- lastNonSilentAmplitudeTime: \(lastNonSilent) (Δ \(String(format: "%.2f", Date().timeIntervalSince(lastNonSilent)))s ago)")
        } else {
            lines.append("- lastNonSilentAmplitudeTime: nil (never received non-silent audio — zero-filled buffers)")
        }
        lines.append("- hasTriggeredSilentAudioDump: \(s.hasTriggeredSilentAudioDumpForDebug)")
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

    private static func renderAudioDevices() -> String {
        var lines: [String] = ["\n## Audio Devices\n"]

        var defaultID: AudioDeviceID = 0
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil, &defaultSize, &defaultID
        )
        if defaultStatus == noErr {
            lines.append("- systemDefaultInputDevice: id=\(defaultID) name=\(audioDeviceName(defaultID) ?? "unknown") uid=\(audioDeviceUID(defaultID) ?? "unknown")")
        } else {
            lines.append("- systemDefaultInputDevice: error \(defaultStatus)")
        }

        var allSize: UInt32 = 0
        var allAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &allAddr, 0, nil, &allSize)
        let deviceCount = Int(allSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &allAddr, 0, nil, &allSize, &deviceIDs)

        lines.append("- allDevices (\(deviceCount) total):")
        for deviceID in deviceIDs {
            var streamsSize: UInt32 = 0
            var streamsAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            let hasInput = AudioObjectGetPropertyDataSize(deviceID, &streamsAddr, 0, nil, &streamsSize) == noErr && streamsSize > 0

            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyData(deviceID, &transportAddr, 0, nil, &transportSize, &transport)
            let transportStr: String
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn:     transportStr = "Built-in"
            case kAudioDeviceTransportTypeUSB:         transportStr = "USB"
            case kAudioDeviceTransportTypeBluetooth:   transportStr = "Bluetooth"
            case kAudioDeviceTransportTypeBluetoothLE: transportStr = "BLE"
            case kAudioDeviceTransportTypeHDMI:        transportStr = "HDMI"
            case kAudioDeviceTransportTypeDisplayPort: transportStr = "DisplayPort"
            case kAudioDeviceTransportTypeAVB:         transportStr = "AVB"
            case kAudioDeviceTransportTypeThunderbolt: transportStr = "Thunderbolt"
            case kAudioDeviceTransportTypeVirtual:     transportStr = "Virtual"
            case kAudioDeviceTransportTypeAggregate:   transportStr = "Aggregate"
            default:                                   transportStr = "0x\(String(transport, radix: 16))"
            }

            var isAlive: UInt32 = 0
            var aliveSize = UInt32(MemoryLayout<UInt32>.size)
            var aliveAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyData(deviceID, &aliveAddr, 0, nil, &aliveSize, &isAlive)

            let name = audioDeviceName(deviceID) ?? "unknown"
            let uid = audioDeviceUID(deviceID) ?? "unknown"
            let inputTag = hasInput ? " [INPUT]" : ""
            let defaultTag = deviceID == defaultID ? " ← default" : ""
            lines.append("  - id=\(deviceID) \(name)\(inputTag) transport=\(transportStr) alive=\(isAlive != 0) uid=\(uid)\(defaultTag)")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func audioDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var nameRef: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &nameRef) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        return status == noErr ? (nameRef as String) : nil
    }

    private static func audioDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var uidRef: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &uidRef) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        return status == noErr ? (uidRef as String) : nil
    }

    @MainActor
    private static func renderMemoryUsage() -> String {
        var lines: [String] = ["\n## Memory Usage\n"]

        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let rssBytes = info.phys_footprint
            lines.append("- process.physFootprint: \(formatBytes(rssBytes))")
            let rssFull = info.resident_size
            lines.append("- process.residentSize: \(formatBytes(rssFull))")
        } else {
            lines.append("- process.rss: error \(kr)")
        }

        let s = AppState.shared
        let modelDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Whisperer") ?? URL(fileURLWithPath: "/tmp")

        if let loadedModel = s.loadedModelForDebug {
            let modelURL = modelDir.appendingPathComponent(loadedModel.rawValue)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? Int64) ?? -1
            let coreMLDir = modelDir.appendingPathComponent(loadedModel.coreMLEncoderDirectoryName ?? "")
            let hasCoreML = FileManager.default.fileExists(atPath: coreMLDir.path)
            lines.append("- whisper.mainModel: \(loadedModel.rawValue) fileSize=\(formatBytes(UInt64(max(0, fileSize)))) coreMLEncoder=\(hasCoreML ? "present" : "absent")")
        } else {
            lines.append("- whisper.mainModel: not loaded")
        }

        let tinyURL = modelDir.appendingPathComponent(WhisperModel.tiny.rawValue)
        let tinyExists = FileManager.default.fileExists(atPath: tinyURL.path)
        if tinyExists {
            let tinySize = (try? FileManager.default.attributesOfItem(atPath: tinyURL.path)[.size] as? Int64) ?? -1
            let tinyCoreMLDir = modelDir.appendingPathComponent(WhisperModel.tiny.coreMLEncoderDirectoryName ?? "")
            let tinyHasCoreML = FileManager.default.fileExists(atPath: tinyCoreMLDir.path)
            lines.append("- whisper.tinyBridge: \(WhisperModel.tiny.rawValue) fileSize=\(formatBytes(UInt64(max(0, tinySize)))) coreMLEncoder=\(tinyHasCoreML ? "present" : "absent") loaded=\(s.modelPoolForDebug?.previewBridge != nil)")
        } else {
            lines.append("- whisper.tinyBridge: not downloaded")
        }

        if let pool = s.modelPoolForDebug {
            lines.append("- modelPool.previewBridge: \(pool.previewBridge != nil ? "alive" : "nil")")
            lines.append("- modelPool.fallbackProfile: \(pool.fallbackProfile.map { $0.model.rawValue } ?? "nil")")
        } else {
            lines.append("- modelPool: nil")
        }

        lines.append("- sileroVAD: \(s.sileroVADIsNilForDebug ? "nil" : "loaded")")
        lines.append("- llmEnabled: \(s.llmEnabledForDebug)")
        if s.llmEnabledForDebug {
            let llmVariant = s.selectedLLMModelForDebug
            if let llmProc = s.llmPostProcessorForDebug {
                lines.append("- llm.model: \(llmVariant.displayName) loaded=\(llmProc.isModelLoaded) loading=\(llmProc.isLoading)")
                let hfCacheBase = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".cache/huggingface/hub")
                let modelDirName = "models--" + llmVariant.huggingFaceId.replacingOccurrences(of: "/", with: "--")
                let llmDir = hfCacheBase.appendingPathComponent(modelDirName)
                if let dirSize = directorySize(llmDir) {
                    lines.append("- llm.diskSize: \(formatBytes(dirSize)) (\(llmDir.path))")
                } else {
                    lines.append("- llm.diskSize: not found at \(llmDir.path)")
                }
            } else {
                lines.append("- llm.model: \(llmVariant.displayName) processor=nil")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else {
            return "\(bytes) B"
        }
    }

    private static func directorySize(_ url: URL) -> UInt64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += UInt64(size)
        }
        return total
    }

    private static func renderThreadSample() -> String {
        #if DEBUG
        let pid = ProcessInfo.processInfo.processIdentifier
        let sampleURL = URL(fileURLWithPath: "/tmp/whisperer-stall-sample.txt")
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
        #else
        return "\n## Thread Sample\n\n_not available in Release/AppStore builds_\n"
        #endif
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
