//
//  AudioProcessMonitor.swift
//  Whisperer
//
//  Per-process microphone attribution via the CoreAudio process-object API.
//  Answers "which app is capturing right now", which the device-level
//  kAudioDevicePropertyDeviceIsRunningSomewhere bit cannot.
//

import AppKit
import CoreAudio
import Darwin

/// Resolves which applications are currently capturing audio input.
///
/// `MicrophoneUsageMonitor` only reports the aggregate "some input device is hot" bit, which is
/// why `MeetingDetector` used to guess the provider from running/frontmost apps — and why a
/// background agent holding the mic (Cisco Proximity does this on a cycle all day) was
/// indistinguishable from a real meeting. The process-object API answers the question directly.
///
/// Read-only and sandbox-safe, unlike process taps, which need a TCC grant.
@MainActor
final class AudioProcessMonitor {

    /// Background agents that hold the input open without a meeting in progress. Whisperer itself
    /// is here too — dictation must never look like a meeting.
    static let ignoredBundleIDs: Set<String> = [
        "com.ivy.whisperer",
        "com.cisco.Proximity",       // Webex room pairing — opens the mic on a timer, all day
        "com.electron.dictation-app",
        "com.apple.controlcenter",
        "com.apple.Siri",
        "com.apple.assistantd",
        "com.apple.VoiceMemos",
    ]

    /// Bundle ID → when we first saw it capturing in the current continuous run.
    /// Cleared per bundle ID as soon as it stops, so `captureDuration` measures one unbroken run.
    private var captureStartedAt: [String: Date] = [:]

    /// Bundle ID → when its last capture run ended. Cleared when it starts capturing again, so
    /// this is "how long has this app been off the microphone" — the observable end of a call.
    private var captureEndedAt: [String: Date] = [:]

    /// Bundle ID → how long it was off the microphone immediately before the run it is in now.
    /// Survives the restart that clears `captureEndedAt`: the gap between two calls closes in
    /// seconds, so by the time anyone asks, the only trace of it left is this number.
    private var runPrecededByGap: [String: TimeInterval] = [:]

    /// Bundle IDs of every app currently capturing audio input, with helper processes attributed
    /// to their owning app (Chrome's audio helper reports as `com.google.Chrome`) and the
    /// ignore list applied.
    ///
    /// Cheap enough to call on demand — a few dozen process objects and two property reads each.
    @discardableResult
    func capturingBundleIDs() -> Set<String> {
        var result: Set<String> = []
        for processObject in processObjectIDs() where isRunningInput(processObject) {
            guard let owner = owningBundleID(of: processObject) else { continue }
            guard !Self.ignoredBundleIDs.contains(owner) else { continue }
            result.insert(owner)
        }
        updateCaptureRuns(current: result)
        return result
    }

    struct InputRoute: Equatable {
        let bundleID: String
        let devices: Set<AudioDeviceID>
    }

    /// Attribute active input devices to their owning app, including browser helpers.
    /// Unknown/empty routes must never count as verified routing.
    func inputRoutes() -> [InputRoute] {
        processObjectIDs().compactMap { object in
            guard isRunningInput(object), let owner = owningBundleID(of: object),
                  owner != "com.ivy.whisperer" else { return nil }
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else {
                return InputRoute(bundleID: owner, devices: [])
            }
            var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
            guard size > 0, AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else {
                return InputRoute(bundleID: owner, devices: [])
            }
            return InputRoute(bundleID: owner, devices: Set(ids))
        }
    }

    /// How long `bundleID` has been capturing without interruption, or nil if it is not capturing.
    /// Used to hold off on browser meetings until the capture is sustained — a two-second voice
    /// search must not raise a meeting prompt.
    func captureDuration(for bundleID: String) -> TimeInterval? {
        guard let start = captureStartedAt[bundleID] else { return nil }
        return Date().timeIntervalSince(start)
    }

    /// Whether `bundleID` is capturing, and if not, when it stopped — the signal `MeetingDetector`
    /// uses to decide that a call has ended. `.unobserved` means this app has never been attributed
    /// a capture run at all, so nothing can be concluded from its absence.
    func captureStatus(for bundleID: String) -> MeetingCaptureStatus {
        if let started = captureStartedAt[bundleID] {
            return .capturing(since: started, precededByGap: runPrecededByGap[bundleID])
        }
        if let ended = captureEndedAt[bundleID] { return .ended(ended) }
        return .unobserved
    }

    func reset() {
        captureStartedAt.removeAll()
        captureEndedAt.removeAll()
        runPrecededByGap.removeAll()
    }

    // MARK: - Process objects for a call-audio tap

    /// Every CoreAudio process object owned by `bundleID`, helpers included — Chrome, Slack and
    /// Teams play a call through helper processes, so tapping only the app's own pid would hear
    /// nothing. Input-only processes are kept too: Zoom and Chrome's audio service do both.
    func processObjects(ownedBy bundleID: String) -> [AudioObjectID] {
        let appPaths = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).compactMap { $0.bundleURL?.path }
        return processObjectIDs().filter { object in
            Self.belongs(rawBundleID: rawBundleID(of: object), owner: owningBundleID(of: object), to: bundleID)
                || Self.belongs(executablePath: pid(of: object).flatMap(Self.executablePath(ofPID:)), insideAppAt: appPaths)
        }
    }

    /// A helper's executable lives inside the call app's bundle (`/Applications/Slack.app/Contents/Frameworks/Slack
    /// Helper.app/…`). That holds whatever the helper's bundle ID is and whoever its parent became, so it is the
    /// attribution that cannot miss the process that actually plays the call.
    nonisolated static func belongs(executablePath: String?, insideAppAt appPaths: [String]) -> Bool {
        guard let executablePath else { return false }
        return appPaths.contains { !$0.isEmpty && executablePath.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    nonisolated static func executablePath(ofPID pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// Whether a process object is part of the call app. The process-tree walk is the primary answer; the helper's
    /// own bundle ID is the backstop, so a helper whose parent chain does not resolve (an XPC service, a re-parented
    /// audio process) still counts — the call's audio is played by exactly those helpers, and a tap that misses
    /// the one that plays hears nothing at all.
    nonisolated static func belongs(rawBundleID: String?, owner: String?, to bundleID: String) -> Bool {
        if owner == bundleID { return true }
        guard let raw = rawBundleID else { return false }
        return raw == bundleID || strippingHelperSuffix(raw) == bundleID
    }

    // MARK: - Snapshots (diagnostics)

    /// What one process object is doing right now — for the log when a call's audio goes missing, so the next report
    /// says which process was playing and whether the tap was listening to it.
    struct ProcessSnapshot: Equatable {
        let objectID: AudioObjectID
        let pid: pid_t?
        let rawBundleID: String?
        let owner: String?
        let runningInput: Bool
        let runningOutput: Bool

        var summary: String {
            "pid=\(pid.map(String.init) ?? "?") \(rawBundleID ?? "-")→\(owner ?? "-") in=\(runningInput ? 1 : 0) out=\(runningOutput ? 1 : 0)"
        }
    }

    func snapshots(of ids: [AudioObjectID]) -> [ProcessSnapshot] {
        ids.map { object in
            ProcessSnapshot(objectID: object, pid: pid(of: object), rawBundleID: rawBundleID(of: object),
                            owner: owningBundleID(of: object), runningInput: isRunningInput(object),
                            runningOutput: isRunningOutput(object))
        }
    }

    /// Every process object that is playing or recording right now (idle ones are noise).
    func activeProcessSnapshots() -> [ProcessSnapshot] {
        snapshots(of: processObjectIDs()).filter { $0.runningInput || $0.runningOutput }
    }

    /// Whether any of `ids` is playing audio right now.
    func isAnyRunningOutput(_ ids: [AudioObjectID]) -> Bool { ids.contains { isRunningOutput($0) } }

    /// Whisperer's own process object(s), excluded from a system-wide tap so the meeting never
    /// records Whisperer's own sounds.
    func ownProcessObjects() -> [AudioObjectID] {
        let me = getpid()
        return processObjectIDs().filter { pid(of: $0) == me }
    }

    // MARK: - Capture run tracking

    private func updateCaptureRuns(current: Set<String>) {
        let now = Date()
        for bundleID in current where captureStartedAt[bundleID] == nil {
            captureStartedAt[bundleID] = now
            if let ended = captureEndedAt[bundleID] {
                runPrecededByGap[bundleID] = now.timeIntervalSince(ended)
            } else {
                runPrecededByGap[bundleID] = nil
            }
            captureEndedAt[bundleID] = nil
        }
        // Snapshot the keys: the loop body mutates the dictionary.
        for bundleID in Array(captureStartedAt.keys) where !current.contains(bundleID) {
            captureStartedAt[bundleID] = nil
            captureEndedAt[bundleID] = now
        }
    }

    // MARK: - CoreAudio process objects

    private func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }
        return ids
    }

    private func isRunningInput(_ processObject: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private func isRunningOutput(_ processObject: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private func pid(of processObject: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &value) == noErr,
              value > 0 else { return nil }
        return value
    }

    private func rawBundleID(of processObject: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = value else { return nil }
        let string = cf as String
        return string.isEmpty ? nil : string
    }

    // MARK: - Helper → owning app

    /// Chrome captures through `com.google.Chrome.helper`, Slack and Teams through Electron
    /// helpers. The owning app is what the detector's provider registry is keyed on, so resolve
    /// through the process tree: the first ancestor that `NSRunningApplication` knows about wins.
    private func owningBundleID(of processObject: AudioObjectID) -> String? {
        if let pid = pid(of: processObject), let owner = owningBundleID(ofPID: pid) {
            return owner
        }
        // No pid (or nothing in the process tree is a real app) — fall back to trimming the
        // helper suffix off whatever bundle ID CoreAudio reported.
        guard let raw = rawBundleID(of: processObject) else { return nil }
        return Self.strippingHelperSuffix(raw)
    }

    private func owningBundleID(ofPID pid: pid_t) -> String? {
        var current = pid
        for _ in 0..<5 {
            if let app = NSRunningApplication(processIdentifier: current),
               let bundleID = app.bundleIdentifier,
               !bundleID.isEmpty {
                // macOS knows some helpers as apps of their own (observed on 2026-11-15: a Chrome audio helper
                // resolved to `com.google.Chrome.helper`, not Chrome). Left like that, the helper that plays the
                // call is attributed to nobody, falls out of the call app's tap, and the far end records as silence.
                return Self.strippingHelperSuffix(bundleID)
            }
            guard let parent = parentPID(of: current), parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    private func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let status = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard status == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    /// `com.google.Chrome.helper.Renderer` → `com.google.Chrome`
    nonisolated static func strippingHelperSuffix(_ bundleID: String) -> String {
        guard let range = bundleID.range(of: ".helper", options: [.caseInsensitive]) else {
            return bundleID
        }
        return String(bundleID[bundleID.startIndex..<range.lowerBound])
    }
}
