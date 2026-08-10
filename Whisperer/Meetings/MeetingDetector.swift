//
//  MeetingDetector.swift
//  Whisperer
//
//  Event-driven meeting detection using microphone activity as the primary trigger,
//  with camera as a supporting signal (when camera entitlement is available).
//  Browser meetings (Google Meet, Teams web) are caught by a 5-second fallback poll
//  since browser-based mic usage often routes through virtual audio devices.
//

import AppKit
import CoreAudio
import CoreMediaIO
import SwiftUI
#if !APP_STORE
import ApplicationServices
#endif

// MARK: - Camera Monitor (best-effort — requires camera entitlement)

final class CameraUsageMonitor {
    var onChange: ((Bool) -> Void)?
    private(set) var isActive: Bool = false
    private var deviceIDs: [CMIODeviceID] = []
    private(set) var isAvailable: Bool = false

    func start() {
        refreshDevices()
        if deviceIDs.isEmpty {
            Logger.warning("CameraUsageMonitor: no CMIO devices found (camera entitlement may be missing) — camera signal unavailable", subsystem: .app)
            return
        }
        isAvailable = true
        installListeners()
        let active = anyRunning()
        isActive = active
        Logger.debug("CameraUsageMonitor: started, \(deviceIDs.count) device(s), initial active=\(active)", subsystem: .app)
        onChange?(active)
    }

    private func refreshDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, UInt32(0), nil, &dataSize
        ) == noErr, dataSize > 0 else { return }

        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var ids = [CMIODeviceID](repeating: CMIODeviceID(), count: count)
        var actualSize = dataSize
        let status = ids.withUnsafeMutableBytes { ptr in
            CMIOObjectGetPropertyData(
                CMIOObjectID(kCMIOObjectSystemObject), &address,
                UInt32(0), nil,
                dataSize, &actualSize,
                ptr.baseAddress
            )
        }
        if status == noErr { deviceIDs = ids }
    }

    private func isRunning(_ device: CMIODeviceID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = 0
        let inSize = UInt32(MemoryLayout<UInt32>.size)
        var outSize = inSize
        let status = CMIOObjectGetPropertyData(device, &address, UInt32(0), nil, inSize, &outSize, &value)
        return status == noErr && value != 0
    }

    private func anyRunning() -> Bool {
        deviceIDs.contains { isRunning($0) }
    }

    private func installListeners() {
        for device in deviceIDs {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            CMIOObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main) { [weak self] _, _ in
                guard let self else { return }
                let active = self.anyRunning()
                self.isActive = active
                Logger.debug("CameraUsageMonitor: camera active=\(active)", subsystem: .app)
                self.onChange?(active)
            }
        }
    }
}

// MARK: - Microphone Monitor (monitors all input devices)

final class MicrophoneUsageMonitor {
    var onChange: ((Bool) -> Void)?
    private(set) var isActive: Bool = false
    private var inputDeviceIDs: [AudioDeviceID] = []

    func start() {
        refreshInputDevices()
        if inputDeviceIDs.isEmpty {
            Logger.warning("MicrophoneUsageMonitor: no input devices found", subsystem: .app)
            return
        }
        installListeners()
        let active = anyInputRunning()
        isActive = active
        Logger.debug("MicrophoneUsageMonitor: started, \(inputDeviceIDs.count) device(s), initial active=\(active)", subsystem: .app)
        onChange?(active)
    }

    private func refreshInputDevices() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var allIDs = [AudioDeviceID](repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &allIDs
        ) == noErr else { return }

        // Keep only input (capture) devices.
        inputDeviceIDs = allIDs.filter { hasInputChannels($0) }
    }

    private func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }
        let bufferListSize = Int(dataSize)
        return bufferListSize >= MemoryLayout<AudioBufferList>.size
    }

    private func isRunning(_ deviceID: AudioDeviceID) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private func anyInputRunning() -> Bool {
        inputDeviceIDs.contains { isRunning($0) }
    }

    private func installListeners() {
        for deviceID in inputDeviceIDs {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main) { [weak self] _, _ in
                guard let self else { return }
                let active = self.anyInputRunning()
                self.isActive = active
                Logger.debug("MicrophoneUsageMonitor: any input active=\(active)", subsystem: .app)
                self.onChange?(active)
            }
        }
    }
}

// MARK: - Supporting Types

private struct HardwareState {
    var cameraActive: Bool = false
    // True when any audio input device is active AND Whisperer is not recording.
    var microphoneActive: Bool = false

    var isAnyActive: Bool { cameraActive || microphoneActive }
    var isBothActive: Bool { cameraActive && microphoneActive }
}

private struct AppActivation {
    let bundleID: String
    let timestamp: Date
}

private struct AppActivationHistory {
    private var events: [AppActivation] = []
    private let windowSeconds: TimeInterval = 10

    mutating func record(bundleID: String) {
        let now = Date()
        events.append(AppActivation(bundleID: bundleID, timestamp: now))
        events.removeAll { now.timeIntervalSince($0.timestamp) > windowSeconds }
    }

    func wasRecentlyActivated(_ bundleID: String, within seconds: TimeInterval) -> Bool {
        let cutoff = Date().addingTimeInterval(-seconds)
        return events.contains { $0.bundleID == bundleID && $0.timestamp >= cutoff }
    }
}

private enum MeetingProvider {
    case zoom, microsoftTeams, webex, facetime
    case googleMeet, googleHangouts, slackHuddle, whereby, around
}

private struct MeetingAppDefinition {
    let provider: MeetingProvider
    let bundleIDs: Set<String>
    let displayName: String
    let iconSystemName: String
    let iconColor: Color
}

private struct MeetingEvidence {
    var cameraActive: Bool = false
    var microphoneActive: Bool = false
    var provider: MeetingProvider? = nil
    var providerAppRunning: Bool = false
    var providerAppFrontmost: Bool = false
    var recentlyActivatedProvider: Bool = false
    var browserMeetingWindow: Bool = false
    var isKnownNonMeetingApp: Bool = false
}

private struct MeetingCandidate {
    let provider: MeetingProvider
    let displayName: String
    let iconSystemName: String
    let iconColor: Color
    let bundleID: String
    let confidence: Double
}

private enum DetectorState {
    case idle
    case debouncing(Task<Void, Never>)
    case prompted
    case suppressedUntilHardwareIdle
}

// MARK: - MeetingDetector

@MainActor
final class MeetingDetector {
    static let shared = MeetingDetector()

    struct DetectedMeetingApp {
        let name: String
        let iconSystemName: String
        let iconColor: Color
        let bundleID: String
    }

    // MARK: Provider registry

    private let nativeApps: [MeetingAppDefinition] = [
        .init(provider: .zoom,
              bundleIDs: ["us.zoom.xos", "zoom.us"],
              displayName: "Zoom",
              iconSystemName: "video.fill",
              iconColor: .blue),
        .init(provider: .microsoftTeams,
              bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
              displayName: "Microsoft Teams",
              iconSystemName: "person.3.fill",
              iconColor: Color(red: 0.36, green: 0.33, blue: 0.73)),
        .init(provider: .webex,
              bundleIDs: ["com.cisco.webexmeetings", "Cisco-Systems.Spark"],
              displayName: "Webex",
              iconSystemName: "video.fill",
              iconColor: .green),
        .init(provider: .facetime,
              bundleIDs: ["com.apple.facetime"],
              displayName: "FaceTime",
              iconSystemName: "video.fill",
              iconColor: .green),
    ]

    private let knownNonMeetingBundleIDs: Set<String> = [
        "com.apple.PhotoBooth",
        "com.apple.iSight",
        "com.obsproject.obs-studio",
    ]

    // MARK: State

    private let cameraMonitor = CameraUsageMonitor()
    private let micMonitor = MicrophoneUsageMonitor()
    private var hardware = HardwareState()
    private var activationHistory = AppActivationHistory()
    private var detectorState: DetectorState = .idle

    // Per display-name refire guard (30 min window).
    private var lastFiredDate: [String: Date] = [:]
    private let refireInterval: TimeInterval = 30 * 60

    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var appStateObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        cameraMonitor.onChange = { [weak self] active in
            Task { @MainActor [weak self] in self?.cameraChanged(active) }
        }
        micMonitor.onChange = { [weak self] active in
            Task { @MainActor [weak self] in self?.microphoneChanged(active) }
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier else { return }
            Task { @MainActor [weak self] in self?.activationHistory.record(bundleID: bid) }
        }

        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier else { return }
            Task { @MainActor [weak self] in self?.handleTermination(bundleID: bid) }
        }

        // Sync state when AppState auto-dismisses the 30s toast.
        appStateObserver = NotificationCenter.default.addObserver(
            forName: .init("AppStateChanged"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncWithAppState() }
        }

        cameraMonitor.start()
        micMonitor.start()
        startFallbackPoll()

        Logger.info("MeetingDetector started (event-driven, camera=\(cameraMonitor.isAvailable))", subsystem: .app)
    }

    func stop() {
        if case .debouncing(let task) = detectorState { task.cancel() }
        detectorState = .idle
        pollTimer?.invalidate()
        pollTimer = nil
        if let obs = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = terminateObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = appStateObserver { NotificationCenter.default.removeObserver(obs) }
        activationObserver = nil
        terminateObserver = nil
        appStateObserver = nil
    }

    func onUserDismissed() {
        if case .debouncing(let task) = detectorState { task.cancel() }
        detectorState = .suppressedUntilHardwareIdle
        Logger.debug("MeetingDetector: suppressed until hardware goes idle", subsystem: .app)
    }

    // MARK: - Hardware events

    private func cameraChanged(_ active: Bool) {
        hardware.cameraActive = active
        hardwareChanged()
    }

    private func microphoneChanged(_ active: Bool) {
        // Suppress mic signal while Whisperer itself is recording — don't self-detect.
        guard case .idle = AppState.shared.state else {
            hardware.microphoneActive = false
            return
        }
        hardware.microphoneActive = active
        hardwareChanged()
    }

    private func hardwareChanged() {
        if hardware.isAnyActive {
            triggerDebounce()
        } else {
            hardwareWentIdle()
        }
    }

    private func hardwareWentIdle() {
        switch detectorState {
        case .debouncing(let task):
            task.cancel()
            detectorState = .idle
        case .prompted:
            AppState.shared.dismissMeetingNotification()
            detectorState = .idle
        case .suppressedUntilHardwareIdle:
            detectorState = .idle
            lastFiredDate.removeAll()
            Logger.debug("MeetingDetector: hardware idle — suppression cleared", subsystem: .app)
        case .idle:
            break
        }
    }

    // MARK: - Debounce + confirm

    private func triggerDebounce() {
        guard isReadyToTrigger() else { return }
        if case .debouncing(let existing) = detectorState { existing.cancel() }

        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in self?.resolveAndConfirm() }
        }
        detectorState = .debouncing(task)
        Logger.debug("MeetingDetector: debouncing (camera=\(hardware.cameraActive) mic=\(hardware.microphoneActive))", subsystem: .app)
    }

    private func resolveAndConfirm() {
        guard isReadyToTrigger(), hardware.isAnyActive else {
            detectorState = .idle
            return
        }
        guard let candidate = resolve() else {
            Logger.debug("MeetingDetector: resolve returned nil (score below threshold)", subsystem: .app)
            detectorState = .idle
            return
        }

        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.isReadyToTrigger(), self.hardware.isAnyActive else {
                    self?.detectorState = .idle
                    return
                }
                self.fire(candidate)
            }
        }
        detectorState = .debouncing(task)
    }

    private func fire(_ candidate: MeetingCandidate) {
        lastFiredDate[candidate.displayName] = Date()
        detectorState = .prompted
        AppState.shared.showMeetingNotification(app: DetectedMeetingApp(
            name: candidate.displayName,
            iconSystemName: candidate.iconSystemName,
            iconColor: candidate.iconColor,
            bundleID: candidate.bundleID
        ))
        Logger.info("MeetingDetector: \(candidate.displayName) (confidence \(String(format: "%.2f", candidate.confidence)))", subsystem: .app)
    }

    // MARK: - Gate

    private func isReadyToTrigger() -> Bool {
        guard detectionIsEnabled() else { return false }
        guard case .idle = AppState.shared.state else { return false }
        guard !AppState.shared.isMeetingMode else { return false }
        guard !AppState.shared.showMeetingDetectedToast else { return false }
        switch detectorState {
        case .idle, .debouncing: return true
        case .prompted, .suppressedUntilHardwareIdle: return false
        }
    }

    private func detectionIsEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: "meetingDetectionEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "meetingDetectionEnabled")
    }

    private func recentlyFired(_ name: String) -> Bool {
        guard let last = lastFiredDate[name] else { return false }
        return Date().timeIntervalSince(last) < refireInterval
    }

    private func syncWithAppState() {
        // Reset if AppState auto-dismissed the toast (e.g. 30s timeout).
        guard case .prompted = detectorState else { return }
        if !AppState.shared.showMeetingDetectedToast {
            detectorState = .idle
        }
    }

    // MARK: - Virtual meeting audio device detection

    // Virtual audio devices created by meeting apps — active when a call is in progress.
    private struct VirtualMeetingDevice {
        let nameContains: String
        let provider: MeetingProvider
        let displayName: String
        let iconSystemName: String
        let iconColor: Color
        let bundleID: String
    }

    private let virtualMeetingDevices: [VirtualMeetingDevice] = [
        .init(nameContains: "ZoomAudioDevice",      provider: .zoom,           displayName: "Zoom",             iconSystemName: "video.fill",    iconColor: .blue,                                                  bundleID: "us.zoom.xos"),
        .init(nameContains: "Microsoft Teams Audio", provider: .microsoftTeams, displayName: "Microsoft Teams",  iconSystemName: "person.3.fill", iconColor: Color(red: 0.36, green: 0.33, blue: 0.73),               bundleID: "com.microsoft.teams2"),
        .init(nameContains: "WebexAudio",            provider: .webex,          displayName: "Webex",            iconSystemName: "video.fill",    iconColor: .green,                                                 bundleID: "com.cisco.webexmeetings"),
    ]

    private func inputDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        return status == noErr ? (name as String) : nil
    }

    private func detectActiveVirtualMeetingDevice() -> VirtualMeetingDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var allIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &allIDs) == noErr else { return nil }

        var isRunningAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for deviceID in allIDs {
            var running: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(deviceID, &isRunningAddr, 0, nil, &runSize, &running) == noErr, running != 0 else { continue }
            guard let name = inputDeviceName(deviceID) else { continue }
            if let match = virtualMeetingDevices.first(where: { name.contains($0.nameContains) }) {
                return match
            }
        }
        return nil
    }

    // MARK: - Context resolver (hardware-triggered path)

    private func resolve() -> MeetingCandidate? {
        var evidence = MeetingEvidence()
        evidence.cameraActive = hardware.cameraActive
        evidence.microphoneActive = hardware.microphoneActive

        let running = NSWorkspace.shared.runningApplications
        let frontmostBID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        if let fid = frontmostBID, knownNonMeetingBundleIDs.contains(fid) {
            evidence.isKnownNonMeetingApp = true
        }

        // Native apps first.
        for def in nativeApps {
            guard let match = running.first(where: { app in
                guard let bid = app.bundleIdentifier else { return false }
                return def.bundleIDs.contains(bid)
            }) else { continue }

            let matchedBID = match.bundleIdentifier ?? ""
            evidence.provider = def.provider
            evidence.providerAppRunning = true
            evidence.providerAppFrontmost = frontmostBID.map { def.bundleIDs.contains($0) } ?? false
            evidence.recentlyActivatedProvider = def.bundleIDs.contains {
                activationHistory.wasRecentlyActivated($0, within: 5)
            }

            if let candidate = score(evidence,
                                     displayName: def.displayName,
                                     iconSystemName: def.iconSystemName,
                                     iconColor: def.iconColor,
                                     bundleID: matchedBID) {
                return candidate
            }
        }

        // Virtual audio devices (Zoom, Teams, etc.) — active when a call is in progress even if
        // the native app wasn't matched above (e.g. running under a different bundle ID path).
        if evidence.microphoneActive || evidence.cameraActive {
            if let vd = detectActiveVirtualMeetingDevice() {
                var vEvidence = evidence
                vEvidence.provider = vd.provider
                vEvidence.providerAppRunning = true  // virtual device active = app is in a call
                if let candidate = score(vEvidence,
                                         displayName: vd.displayName,
                                         iconSystemName: vd.iconSystemName,
                                         iconColor: vd.iconColor,
                                         bundleID: vd.bundleID) {
                    return candidate
                }
            }
        }

        // Browser / AX detection (non-App Store only).
        #if !APP_STORE
        if let result = detectBrowserMeeting(running: running) {
            evidence.provider = result.provider
            evidence.browserMeetingWindow = true
            evidence.providerAppFrontmost = frontmostBID == result.bundleID
            evidence.recentlyActivatedProvider = activationHistory.wasRecentlyActivated(result.bundleID, within: 5)
            if let candidate = score(evidence,
                                     displayName: result.displayName,
                                     iconSystemName: result.iconSystemName,
                                     iconColor: result.iconColor,
                                     bundleID: result.bundleID) {
                return candidate
            }
        }
        #endif

        return nil
    }

    // MARK: - Confidence scorer

    private func score(
        _ e: MeetingEvidence,
        displayName: String,
        iconSystemName: String,
        iconColor: Color,
        bundleID: String
    ) -> MeetingCandidate? {
        guard let provider = e.provider else { return nil }
        guard !recentlyFired(displayName) else { return nil }

        var s = 0.0

        if e.cameraActive && e.microphoneActive {
            s += 0.60  // Both — very strong signal
        } else if e.cameraActive {
            s += 0.35  // Camera only — might be Photo Booth
        } else if e.microphoneActive {
            s += 0.30  // Mic only — audio call or podcast
        }

        if e.providerAppRunning         { s += 0.15 }
        if e.providerAppFrontmost       { s += 0.15 }
        if e.recentlyActivatedProvider  { s += 0.10 }
        if e.browserMeetingWindow       { s += 0.30 }
        if e.isKnownNonMeetingApp       { s -= 0.60 }

        s = min(s, 1.0)

        // Threshold: mic+running (0.45) is sufficient — camera-off meetings in background must fire.
        guard s >= 0.45 else {
            Logger.debug("MeetingDetector: \(displayName) score \(String(format: "%.2f", s)) < 0.45, skipping", subsystem: .app)
            return nil
        }

        return MeetingCandidate(
            provider: provider,
            displayName: displayName,
            iconSystemName: iconSystemName,
            iconColor: iconColor,
            bundleID: bundleID,
            confidence: s
        )
    }

    // MARK: - Termination handler

    private func handleTermination(bundleID: String) {
        guard nativeApps.contains(where: { $0.bundleIDs.contains(bundleID) }) else { return }
        if let def = nativeApps.first(where: { $0.bundleIDs.contains(bundleID) }) {
            lastFiredDate[def.displayName] = nil
        }
        if case .suppressedUntilHardwareIdle = detectorState {
            detectorState = .idle
            Logger.debug("MeetingDetector: provider quit — suppression cleared", subsystem: .app)
        }
    }

    // MARK: - Fallback poll (5s)
    //
    // Handles two cases the hardware-triggered path misses:
    // (1) Browser meetings (Google Meet, Teams web) where mic may route through
    //     a virtual audio device not caught by the hardware monitor.
    // (2) Native apps where the mic/camera signal didn't arrive (e.g. camera entitlement missing).

    private func startFallbackPoll() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fallbackPoll() }
        }
    }

    private func fallbackPoll() {
        guard isReadyToTrigger() else { return }

        let running = NSWorkspace.shared.runningApplications
        let frontmostBID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Native app check: must be frontmost (avoids prompting for background Zoom).
        for def in nativeApps {
            guard let fid = frontmostBID, def.bundleIDs.contains(fid) else { continue }
            guard running.contains(where: { $0.bundleIdentifier.map { def.bundleIDs.contains($0) } ?? false }) else { continue }
            guard !recentlyFired(def.displayName) else { continue }
            fireDirect(name: def.displayName, iconSystemName: def.iconSystemName, iconColor: def.iconColor, bundleID: fid)
            return
        }

        // Native app + mic active: fires even when not frontmost. Covers BT headset devices
        // where kAudioDevicePropertyDeviceIsRunningSomewhere is unreliable, and the common
        // case of joining a call then switching to another window.
        if hardware.microphoneActive {
            for def in nativeApps {
                guard let match = running.first(where: { app in
                    guard let bid = app.bundleIdentifier else { return false }
                    return def.bundleIDs.contains(bid)
                }) else { continue }
                let matchedBID = match.bundleIdentifier ?? ""
                guard !recentlyFired(def.displayName) else { continue }
                fireDirect(name: def.displayName, iconSystemName: def.iconSystemName, iconColor: def.iconColor, bundleID: matchedBID)
                return
            }

            // Virtual audio device fallback: Zoom/Teams may not match by bundle ID but their
            // virtual audio device being active is definitive evidence of an active call.
            if let vd = detectActiveVirtualMeetingDevice(), !recentlyFired(vd.displayName) {
                fireDirect(name: vd.displayName, iconSystemName: vd.iconSystemName, iconColor: vd.iconColor, bundleID: vd.bundleID)
                return
            }
        }

        // Browser meeting check: no frontmost requirement — Google Meet etc. often run in background.
        #if !APP_STORE
        if let result = detectBrowserMeeting(running: running) {
            guard !recentlyFired(result.displayName) else { return }
            fireDirect(name: result.displayName, iconSystemName: result.iconSystemName, iconColor: result.iconColor, bundleID: result.bundleID)
        }
        #endif
    }

    private func fireDirect(name: String, iconSystemName: String, iconColor: Color, bundleID: String) {
        lastFiredDate[name] = Date()
        detectorState = .prompted
        AppState.shared.showMeetingNotification(app: DetectedMeetingApp(
            name: name,
            iconSystemName: iconSystemName,
            iconColor: iconColor,
            bundleID: bundleID
        ))
        Logger.info("MeetingDetector: fallback detected \(name)", subsystem: .app)
    }

    // MARK: - Browser / Accessibility detection (non-App Store only)

    #if !APP_STORE
    private struct BrowserMatch {
        let provider: MeetingProvider
        let displayName: String
        let iconSystemName: String
        let iconColor: Color
        let bundleID: String
    }

    private let browserBundleIDs = [
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",    // Arc
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.tinyspeck.slackmacgap",     // Slack Huddle (web)
    ]

    private let meetingPatterns: [(pattern: String, provider: MeetingProvider, name: String, icon: String, color: Color)] = [
        ("meet.google.com",     .googleMeet,     "Google Meet",     "video.fill",    .green),
        ("Google Meet",         .googleMeet,     "Google Meet",     "video.fill",    .green),
        ("hangouts.google.com", .googleHangouts, "Google Hangouts", "video.fill",    .green),
        ("Google Hangouts",     .googleHangouts, "Google Hangouts", "video.fill",    .green),
        ("teams.microsoft.com", .microsoftTeams, "Microsoft Teams", "person.3.fill", Color(red: 0.36, green: 0.33, blue: 0.73)),
        ("Microsoft Teams",     .microsoftTeams, "Microsoft Teams", "person.3.fill", Color(red: 0.36, green: 0.33, blue: 0.73)),
        ("zoom.us/j/",          .zoom,           "Zoom",            "video.fill",    .blue),
        ("webex.com",           .webex,          "Webex",           "video.fill",    .green),
        ("whereby.com",         .whereby,        "Whereby",         "video.fill",    .purple),
        ("around.co",           .around,         "Around",          "video.fill",    .blue),
        ("Huddle",              .slackHuddle,    "Slack Huddle",    "headphones",    Color(red: 0.44, green: 0.13, blue: 0.51)),
    ]

    private func detectBrowserMeeting(running: [NSRunningApplication]) -> BrowserMatch? {
        for bundleID in browserBundleIDs {
            guard let app = running.first(where: { $0.bundleIdentifier == bundleID }) else { continue }
            guard let titles = allWindowTitles(pid: app.processIdentifier) else { continue }
            for title in titles {
                for match in meetingPatterns {
                    guard title.contains(match.pattern) else { continue }
                    return BrowserMatch(
                        provider: match.provider,
                        displayName: match.name,
                        iconSystemName: match.icon,
                        iconColor: match.color,
                        bundleID: bundleID
                    )
                }
            }
        }
        return nil
    }

    private func allWindowTitles(pid: pid_t) -> [String]? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            if result == .apiDisabled || result == .notImplemented {
                Logger.warning("MeetingDetector: Accessibility not granted — browser detection unavailable", subsystem: .app)
            }
            return nil
        }
        var titles: [String] = []
        for window in windows {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String, !title.isEmpty {
                titles.append(title)
            }
        }
        return titles.isEmpty ? nil : titles
    }
    #endif
}
