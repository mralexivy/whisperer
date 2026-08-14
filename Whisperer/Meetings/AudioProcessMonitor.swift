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
        "com.electron.wispr-flow",
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
                return bundleID
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
    static func strippingHelperSuffix(_ bundleID: String) -> String {
        guard let range = bundleID.range(of: ".helper", options: [.caseInsensitive]) else {
            return bundleID
        }
        return String(bundleID[bundleID.startIndex..<range.lowerBound])
    }
}
