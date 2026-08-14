//
//  MeetingDetector.swift
//  Whisperer
//
//  Event-driven meeting detection. Microphone activity is the trigger; AudioProcessMonitor
//  answers *which* app is capturing, which is what separates a meeting from a background
//  agent cycling the mic. Camera is a supporting signal (when the entitlement is available),
//  and a 5-second poll catches what the hardware events miss.
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
    /// The monitor is restarted on every device change, and a machine with no camera
    /// entitlement fails identically each time — 16 copies of the same line in one session.
    private var hasLoggedUnavailable = false

    func start() {
        refreshDevices()
        if deviceIDs.isEmpty {
            if !hasLoggedUnavailable {
                hasLoggedUnavailable = true
                Logger.warning("CameraUsageMonitor: no CMIO devices found (camera entitlement may be missing) — camera signal unavailable", subsystem: .app)
            }
            return
        }
        hasLoggedUnavailable = false
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

/// Watches `kAudioDevicePropertyDeviceIsRunningSomewhere` on every input device.
///
/// ### Why the device list is itself watched
/// The list used to be captured once in `start()` and never revisited, and no listener was ever
/// removed. A session log showed what that costs: unplugging `iPhone Microphone` left the ID in
/// the cached array and every later callback polled it, producing 17 × `AudioObjectGetPropertyData:
/// no object with given ID 140` over 75 minutes and — worse — a stale `active=true` that burnt a
/// debounce cycle with nothing recording. Devices that appeared afterwards (including the
/// `CADefaultDeviceAggregate` CoreAudio builds mid-recording) never got a listener at all, so the
/// monitor grew progressively blinder the longer the app ran.
///
/// The system's `kAudioHardwarePropertyDevices` listener rebuilds the per-device set on every
/// topology change. `AudioDeviceManager` watches the same property for its own purposes; this is a
/// second, independent registration rather than a notification hop, because the two have different
/// lifetimes and CoreAudio allows any number of listener blocks on one property.
final class MicrophoneUsageMonitor {
    var onChange: ((Bool) -> Void)?
    private(set) var isActive: Bool = false
    private var inputDeviceIDs: [AudioDeviceID] = []

    /// Installed per-device listeners, keyed by device. The block is the removal token —
    /// `AudioObjectRemovePropertyListenerBlock` matches on identity, so it has to be the same
    /// object that was registered. Keying by ID also makes a re-`start()` idempotent: a device
    /// that survives a topology change keeps its one listener instead of gaining a second.
    private var deviceListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var deviceListListener: AudioObjectPropertyListenerBlock?

    /// Fresh value per use — `AudioObject*PropertyListenerBlock` takes the address `inout`, and a
    /// shared mutable static would be handed to CoreAudio from several queues at once.
    private static var deviceListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var isRunningAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    deinit {
        stop()
    }

    func start() {
        installDeviceListListener()
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

    /// Removes every listener this monitor installed. Safe to call twice.
    func stop() {
        var isRunning = Self.isRunningAddress
        for (deviceID, block) in deviceListeners {
            AudioObjectRemovePropertyListenerBlock(deviceID, &isRunning, DispatchQueue.main, block)
        }
        deviceListeners.removeAll()
        inputDeviceIDs.removeAll()

        if let block = deviceListListener {
            var deviceList = Self.deviceListAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &deviceList, DispatchQueue.main, block
            )
            deviceListListener = nil
        }
    }

    // MARK: - Topology

    private func installDeviceListListener() {
        guard deviceListListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.rebuildListeners()
        }
        var address = Self.deviceListAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        guard status == noErr else {
            Logger.error("MicrophoneUsageMonitor: device list listener failed (\(status)) — the device set will not track hot-plugs", subsystem: .app)
            return
        }
        deviceListListener = block
    }

    /// Re-enumerates, drops listeners on departed devices and installs them on arrivals.
    ///
    /// The active flag is recomputed and only published when it actually changed — a device
    /// arriving or leaving is not itself a microphone event, and republishing would spend a
    /// debounce cycle in `MeetingDetector` for nothing.
    private func rebuildListeners() {
        let previous = Set(inputDeviceIDs)
        refreshInputDevices()
        let current = Set(inputDeviceIDs)
        guard previous != current else { return }

        var isRunning = Self.isRunningAddress
        for departed in previous.subtracting(current) {
            if let block = deviceListeners.removeValue(forKey: departed) {
                AudioObjectRemovePropertyListenerBlock(departed, &isRunning, DispatchQueue.main, block)
            }
        }
        installListeners()
        Logger.debug("MicrophoneUsageMonitor: device set changed — now \(inputDeviceIDs.count) input device(s)", subsystem: .app)

        let active = anyInputRunning()
        guard active != isActive else { return }
        isActive = active
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
        var address = Self.isRunningAddress
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private func anyInputRunning() -> Bool {
        inputDeviceIDs.contains { isRunning($0) }
    }

    /// Installs a listener on every input device that does not already have one.
    private func installListeners() {
        for deviceID in inputDeviceIDs where deviceListeners[deviceID] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                let active = self.anyInputRunning()
                // CoreAudio fires this per device, so a machine with several inputs reports the
                // same aggregate answer several times per transition. Only the transitions matter.
                guard active != self.isActive else { return }
                self.isActive = active
                Logger.debug("MicrophoneUsageMonitor: any input active=\(active)", subsystem: .app)
                self.onChange?(active)
            }
            var address = Self.isRunningAddress
            let status = AudioObjectAddPropertyListenerBlock(
                deviceID, &address, DispatchQueue.main, block
            )
            if status == noErr {
                deviceListeners[deviceID] = block
            }
        }
    }
}

// MARK: - Supporting Types

private struct HardwareState: Equatable {
    var cameraActive: Bool = false
    // True when a meeting-capable app is holding an audio input — see syncMicrophoneWithCapture().
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
    /// A browser sustaining audio capture, with no window title to name the provider more precisely.
    case browserCall
}

private struct MeetingAppDefinition {
    let provider: MeetingProvider
    let bundleIDs: Set<String>
    let displayName: String
    let iconSystemName: String
    let iconColor: Color
    /// True for apps that are running all day and only mean "meeting" while they hold the mic.
    /// Slack is the case this exists for — matching it on "running" or "frontmost" would prompt
    /// constantly. Such apps are only ever matched through process-level capture attribution.
    var requiresAudioCapture: Bool = false
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
    /// This specific app was observed capturing audio input — a fact, not an inference.
    var processCaptureConfirmed: Bool = false
    /// The provider's in-call virtual audio device is running (ZoomAudioDevice, Teams Audio, …).
    var virtualMeetingDeviceActive: Bool = false

    /// Something says a call is actually *happening*, as opposed to the app being open.
    ///
    /// This is the whole gate. Every other field — running, frontmost, recently activated — is
    /// presence, and presence is what made launching Zoom raise a prompt on its sign-in screen.
    /// A meeting app is open most of the working day; it holds the microphone, or spins up its
    /// in-call audio device, or shows an in-call tab title, only while a call is on.
    var callIsLive: Bool {
        processCaptureConfirmed || virtualMeetingDeviceActive || browserMeetingWindow
    }
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
        // Slack only opens the mic during a huddle, so capture by Slack *is* the huddle signal —
        // no window title needed. It never matches on "running" (see requiresAudioCapture).
        .init(provider: .slackHuddle,
              bundleIDs: ["com.tinyspeck.slackmacgap"],
              displayName: "Slack Huddle",
              iconSystemName: "headphones",
              iconColor: Color(red: 0.44, green: 0.13, blue: 0.51),
              requiresAudioCapture: true),
    ]

    /// Browsers and web-app shells that host meetings. Used two ways: the Accessibility path reads
    /// their window titles for a precise provider name, and the capture path treats sustained mic
    /// capture by one of them as a meeting when Accessibility is unavailable.
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

    /// How long a browser must capture continuously before it counts as a meeting. A voice search
    /// or a "test your microphone" page lasts a couple of seconds; a call does not.
    private let browserSustainedCaptureSeconds: TimeInterval = 15

    private let knownNonMeetingBundleIDs: Set<String> = [
        "com.apple.PhotoBooth",
        "com.apple.iSight",
        "com.obsproject.obs-studio",
    ]

    // MARK: State

    private let cameraMonitor = CameraUsageMonitor()
    private let micMonitor = MicrophoneUsageMonitor()
    private let processMonitor = AudioProcessMonitor()
    /// Apps observed capturing audio input as of the last refresh.
    private var capturingApps: Set<String> = []
    private var hardware = HardwareState()
    private var activationHistory = AppActivationHistory()
    private var detectorState: DetectorState = .idle

    #if !APP_STORE
    /// Why the last AX window-title read failed, or nil if it succeeded. Sandboxed builds fail
    /// with `.cannotComplete` on every app, which used to be invisible in the log — the browser
    /// path simply produced nothing and no line said why.
    private var lastAXFailure: String?
    #endif

    private var axStatusDescription: String {
        #if APP_STORE
        return "n/a"
        #else
        return lastAXFailure ?? "ok"
        #endif
    }

    /// Per display-name refire guard, released when the call it belongs to ends.
    /// See `MeetingPromptLedger` for why this is not a plain 30-minute window.
    private var ledger = MeetingPromptLedger()
    /// Name of the toast currently on screen, so `onUserDismissed()` knows what was dismissed.
    private var lastFiredName: String?
    /// Throttle for the suppression log — the guard is consulted on every poll branch.
    private var lastSuppressionLog: [String: Date] = [:]

    private var pollTimer: Timer?
    /// 1 Hz capture sampler, alive only while the ledger holds an outstanding prompt guard.
    private var captureSampler: Timer?
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
        captureSampler?.invalidate()
        captureSampler = nil
        micMonitor.stop()
        processMonitor.reset()
        capturingApps = []
        if let obs = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = terminateObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = appStateObserver { NotificationCenter.default.removeObserver(obs) }
        activationObserver = nil
        terminateObserver = nil
        appStateObserver = nil
    }

    func onUserDismissed() {
        if case .debouncing(let task) = detectorState { task.cancel() }
        if let name = lastFiredName { ledger.recordDismissal(name: name) }
        detectorState = .suppressedUntilHardwareIdle
        Logger.debug("MeetingDetector: suppressed until hardware goes idle (dismissed \(lastFiredName ?? "unknown"))", subsystem: .app)
    }

    // MARK: - Hardware events

    private func cameraChanged(_ active: Bool) {
        hardware.cameraActive = active
        hardwareChanged()
    }

    private func microphoneChanged(_ deviceIsHot: Bool) {
        refreshCapturingApps()
        syncMicrophoneWithCapture()
    }

    /// Attribution decides whether the microphone counts as in use, for both the device listener
    /// and the poll. The device bit only says "some input is hot": background agents hold it for
    /// long stretches with no meeting anywhere (Cisco Proximity's room pairing cycles it all day),
    /// and Whisperer's own dictation would otherwise self-detect — both are on the ignore list, so
    /// an empty capturing set *is* an idle microphone.
    ///
    /// Stating the rule in one place is what makes hardware-idle reachable. The poll used to latch
    /// `microphoneActive = true` whenever anything was capturing and never lower it, so on the very
    /// devices the poll exists for — Bluetooth, virtual — the falling edge never arrived,
    /// `hardwareWentIdle()` never ran, and a dismissal lasted the rest of the session.
    private func syncMicrophoneWithCapture() {
        let before = hardware
        hardware.microphoneActive = !capturingApps.isEmpty
        guard hardware != before else { return }
        hardwareChanged()
    }

    /// Refreshes the set of apps currently capturing audio input.
    ///
    /// Called at every decision point rather than driven by a listener: it is a few dozen property
    /// reads, and the 5s fallback poll re-runs it anyway, which also covers the small window where
    /// the device listener fires before CoreAudio has published the process's input state.
    private func refreshCapturingApps() {
        capturingApps = processMonitor.capturingBundleIDs()
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
        case .prompted:
            #if !APP_STORE
            AppState.shared.dismissMeetingNotification()
            #endif
        case .suppressedUntilHardwareIdle, .idle:
            break
        }
        detectorState = .idle

        // Hardware idle only releases providers whose call end can't be observed — one matched by
        // a virtual audio device or by being frontmost, which never appears in the capturing set.
        // For an attributed provider this signal is too coarse to mean "the call is over": muting
        // yourself with the camera off looks identical, and releasing on it would raise a second
        // toast for the meeting already running. Those wait for `releaseEndedCalls`, which needs
        // the provider to have genuinely stayed off the microphone.
        let released = ledger.releaseUnobservableCalls { [processMonitor] bundleID in
            processMonitor.captureStatus(for: bundleID)
        }
        updateCaptureSampler()
        if !released.isEmpty {
            released.forEach { lastSuppressionLog[$0] = nil }
            Logger.debug("MeetingDetector: hardware idle — prompt guard released for \(released.joined(separator: ", "))", subsystem: .app)
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

    /// A resolve pass ended without firing. Only the debounce it belongs to may be cleared:
    /// writing `.idle` unconditionally would drop a suppression or a live prompt established while
    /// the pass was in flight — turning a dismissal into an immediate refire.
    private func returnToIdleAfterDebounce() {
        if case .debouncing = detectorState { detectorState = .idle }
    }

    private func resolveAndConfirm() {
        guard isReadyToTrigger(), hardware.isAnyActive else {
            returnToIdleAfterDebounce()
            return
        }
        refreshCapturingApps()
        guard let candidate = resolve() else {
            // Never say "score below threshold" here — resolve() usually returns nil because no
            // strategy produced a candidate to score at all, and the old wording sent three hours
            // of logs down the wrong trail. Print the evidence instead.
            let capturing = capturingApps.isEmpty ? "none" : capturingApps.sorted().joined(separator: ", ")
            Logger.debug(
                "MeetingDetector: no candidate — capturing: [\(capturing)], camera=\(hardware.cameraActive), mic=\(hardware.microphoneActive), accessibility=\(axStatusDescription)",
                subsystem: .app
            )
            returnToIdleAfterDebounce()
            return
        }

        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.isReadyToTrigger(), self.hardware.isAnyActive else {
                    self?.returnToIdleAfterDebounce()
                    return
                }
                self.fire(candidate)
            }
        }
        detectorState = .debouncing(task)
    }

    private func fire(_ candidate: MeetingCandidate) {
        ledger.recordPrompt(name: candidate.displayName, bundleID: candidate.bundleID)
        updateCaptureSampler()
        lastFiredName = candidate.displayName
        detectorState = .prompted
        #if !APP_STORE
        AppState.shared.showMeetingNotification(app: DetectedMeetingApp(
            name: candidate.displayName,
            iconSystemName: candidate.iconSystemName,
            iconColor: candidate.iconColor,
            bundleID: candidate.bundleID
        ))
        #endif
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
        guard ledger.isSuppressed(name) else { return false }

        // Suppression is the only decision on this path that produces no output of its own: it is
        // checked before any scoring, so a candidate rejected here reads in the log exactly like
        // no candidate at all. That opacity is what hid the guard staying pinned across two
        // meetings. Throttled — the poll asks every 5 seconds.
        let now = Date()
        if lastSuppressionLog[name].map({ now.timeIntervalSince($0) < 60 }) != true {
            lastSuppressionLog[name] = now
            let bundleID = ledger.bundleID(for: name) ?? "?"
            let status: String
            switch processMonitor.captureStatus(for: bundleID) {
            case .capturing(let since, let gap):
                let gapText = gap.map { String(format: "%.1fs", $0) } ?? "none"
                status = "capturing for \(String(format: "%.0fs", now.timeIntervalSince(since))), gap before run: \(gapText)"
            case .ended(let endedAt):
                status = "off mic for \(String(format: "%.0fs", now.timeIntervalSince(endedAt)))"
            case .unobserved:
                status = "never attributed — held to the refire ceiling"
            }
            Logger.debug("MeetingDetector: \(name) suppressed — already prompted for this call (\(bundleID): \(status))", subsystem: .app)
        }
        return true
    }

    /// Releases the prompt guard for every provider whose call has ended — it stopped holding the
    /// microphone and has stayed off it past the grace period. This is the fine-grained
    /// counterpart to `hardwareWentIdle()`: back-to-back meetings, or a second call while another
    /// app still has the mic open, never produce a hardware-idle transition at all.
    private func releaseEndedCalls() {
        let released = ledger.releaseEndedCalls { [processMonitor] bundleID in
            processMonitor.captureStatus(for: bundleID)
        }
        updateCaptureSampler()
        guard !released.isEmpty else { return }
        released.forEach { lastSuppressionLog[$0] = nil }
        Logger.debug("MeetingDetector: call ended — prompt guard released for \(released.joined(separator: ", "))", subsystem: .app)
    }

    /// While a prompt guard is outstanding, sample capture attribution once a second.
    ///
    /// The 5s poll quantizes *both* ends of a capture gap, so the 8s gap between two back-to-back
    /// meetings can measure anywhere from 3s to 13s — indistinguishable from a device-switch blip,
    /// whichever threshold is picked. Sampling at 1 Hz brings the error to ±1s, which separates
    /// them cleanly. It runs only while the ledger holds an entry: outside that window no gap is
    /// being waited on, so the idle cost is zero. Bookkeeping only — the poll still owns firing.
    private func updateCaptureSampler() {
        if ledger.isEmpty {
            captureSampler?.invalidate()
            captureSampler = nil
        } else if captureSampler == nil {
            captureSampler = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshCapturingApps()
                    self.releaseEndedCalls()
                }
            }
        }
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

        // Attribution is strictly better evidence than the device-level "some input is hot" bit,
        // and it covers the case where the device listener never fired (Bluetooth headsets,
        // virtual devices that don't publish IsRunningSomewhere).
        if !capturingApps.isEmpty { evidence.microphoneActive = true }

        // 1. A meeting app that is actually capturing audio — the only strategy that observes who
        //    holds the mic rather than inferring it, and so the one the others fall back from.
        for def in nativeApps {
            guard let matchedBID = def.bundleIDs.first(where: { capturingApps.contains($0) }) else { continue }
            var e = evidence
            e.provider = def.provider
            e.processCaptureConfirmed = true
            e.providerAppRunning = true
            e.providerAppFrontmost = frontmostBID.map { def.bundleIDs.contains($0) } ?? false
            e.recentlyActivatedProvider = def.bundleIDs.contains {
                activationHistory.wasRecentlyActivated($0, within: 5)
            }
            if let candidate = score(e,
                                     displayName: def.displayName,
                                     iconSystemName: def.iconSystemName,
                                     iconColor: def.iconColor,
                                     bundleID: matchedBID) {
                return candidate
            }
        }

        // 2. Virtual audio devices (Zoom, Teams, Webex) — spun up for a call, so they stand in for
        //    attribution when the native app above wasn't matched (capture routed through a helper
        //    we can't resolve, or a differently-packaged build).
        //
        //    There is deliberately no "native app merely running" strategy between these two. It
        //    scored mic(0.30) + running(0.15) + frontmost(0.15) = 0.60 and fired for any meeting
        //    app that happened to be open while *something else* held the microphone.
        if evidence.microphoneActive || evidence.cameraActive {
            if let vd = detectActiveVirtualMeetingDevice() {
                var vEvidence = evidence
                vEvidence.provider = vd.provider
                vEvidence.virtualMeetingDeviceActive = true
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

        // 3. Browser meeting, named from its window title. Accessibility only — unavailable in a
        //    sandboxed process and absent from the App Store build, which is why step 4 exists.
        #if !APP_STORE
        if let result = detectBrowserMeeting(running: running) {
            var e = evidence
            e.provider = result.provider
            e.browserMeetingWindow = true
            e.providerAppFrontmost = frontmostBID == result.bundleID
            e.recentlyActivatedProvider = activationHistory.wasRecentlyActivated(result.bundleID, within: 5)
            if let candidate = score(e,
                                     displayName: result.displayName,
                                     iconSystemName: result.iconSystemName,
                                     iconColor: result.iconColor,
                                     bundleID: result.bundleID) {
                return candidate
            }
        }
        #endif

        // 4. Browser sustaining audio capture with no title to read. Less precise than step 3 —
        //    we know a call is happening, not which service — but it is the only browser signal
        //    that survives without Accessibility.
        if let browser = sustainedCapturingBrowser(running: running) {
            var e = evidence
            e.provider = .browserCall
            e.processCaptureConfirmed = true
            e.providerAppRunning = true
            e.providerAppFrontmost = frontmostBID == browser.bundleID
            if let candidate = score(e,
                                     displayName: browser.displayName,
                                     iconSystemName: "video.fill",
                                     iconColor: .blue,
                                     bundleID: browser.bundleID) {
                return candidate
            }
        }

        return nil
    }

    private struct CapturingBrowser {
        let bundleID: String
        let displayName: String
    }

    /// A browser that has held the microphone continuously for long enough to be a call.
    private func sustainedCapturingBrowser(running: [NSRunningApplication]) -> CapturingBrowser? {
        for bundleID in browserBundleIDs where capturingApps.contains(bundleID) {
            guard let duration = processMonitor.captureDuration(for: bundleID),
                  duration >= browserSustainedCaptureSeconds else { continue }
            let appName = running.first { $0.bundleIdentifier == bundleID }?.localizedName ?? "browser"
            return CapturingBrowser(bundleID: bundleID, displayName: "Meeting in \(appName)")
        }
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

        // An open app is not a meeting. Every vendor goes through this one gate, so no provider
        // can be added later that prompts on presence alone — which is what "fallback detected
        // Zoom" was, fired at the sign-in screen with Zoom never once attributed a capture run.
        guard e.callIsLive else {
            Logger.debug("MeetingDetector: \(displayName) is open but no call is live (capture=false, virtual device=false, in-call title=false) — skipping", subsystem: .app)
            return nil
        }

        var s = 0.0

        if e.cameraActive && e.microphoneActive {
            s += 0.60  // Both — very strong signal
        } else if e.cameraActive {
            s += 0.35  // Camera only — might be Photo Booth
        } else if e.microphoneActive {
            s += 0.30  // Mic only — audio call or podcast
        }

        // This app was seen holding the mic — the strongest single piece of evidence here, and the
        // only one that is observed rather than inferred.
        if e.processCaptureConfirmed        { s += 0.35 }
        if e.virtualMeetingDeviceActive     { s += 0.35 }
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
        guard let def = nativeApps.first(where: { $0.bundleIDs.contains(bundleID) }) else { return }
        ledger.release(def.displayName)
        lastSuppressionLog[def.displayName] = nil
        updateCaptureSampler()
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
        // Bookkeeping runs before the gate, never after it. `isReadyToTrigger()` is false for the
        // whole time a toast is up, a meeting is recording, or a dismissal is in force — and while
        // the poll returned early, capture runs went stale and the end of the call was never seen.
        // That is what pinned the guard: the one event that releases it could only be observed in
        // the window where the code refused to look.
        refreshCapturingApps()
        syncMicrophoneWithCapture()
        releaseEndedCalls()

        guard isReadyToTrigger() else { return }

        let running = NSWorkspace.shared.runningApplications

        // Native app actually holding the mic. Definitive, and the only path apps flagged
        // requiresAudioCapture (Slack) can ever match on.
        for def in nativeApps {
            guard let matchedBID = def.bundleIDs.first(where: { capturingApps.contains($0) }) else { continue }
            guard !recentlyFired(def.displayName) else { continue }
            fireDirect(name: def.displayName, iconSystemName: def.iconSystemName, iconColor: def.iconColor, bundleID: matchedBID)
            return
        }

        // Deliberately no "native app is frontmost" and no "native app is running while the mic is
        // hot" branch. Both fired on presence: the first raised "Meeting detected — Zoom" the
        // moment Zoom was launched (its sign-in screen, no mic, no camera, no capture — the poll
        // calls fireDirect, so it never met the 0.45 threshold that would have rejected it), and
        // the second handed any hot microphone to whichever meeting app happened to be open, so a
        // Chrome voice search with Zoom in the dock prompted for Zoom. The branch above — this app
        // is holding the microphone — is the same "not frontmost" and "Bluetooth device" coverage
        // they were there for, but attributed to the app that is actually in the call.

        // Virtual audio device: Zoom/Teams may capture through a helper that resolves to no bundle
        // ID, but their in-call audio device running is evidence of a call in its own right.
        if hardware.microphoneActive,
           let vd = detectActiveVirtualMeetingDevice(),
           !recentlyFired(vd.displayName) {
            fireDirect(name: vd.displayName, iconSystemName: vd.iconSystemName, iconColor: vd.iconColor, bundleID: vd.bundleID)
            return
        }

        // Browser meeting check: no frontmost requirement — Google Meet etc. often run in the
        // background. `detectBrowserMeeting` requires the browser to be capturing audio, which is
        // what stands in for the hardware gate the native branches above get.
        #if !APP_STORE
        if let result = detectBrowserMeeting(running: running) {
            guard !recentlyFired(result.displayName) else { return }
            fireDirect(name: result.displayName, iconSystemName: result.iconSystemName, iconColor: result.iconColor, bundleID: result.bundleID)
            return
        }
        #endif

        // Browser holding the mic with no readable title — we know a call is happening, not which
        // service. The only browser signal that survives without Accessibility.
        if let browser = sustainedCapturingBrowser(running: running),
           !recentlyFired(browser.displayName) {
            fireDirect(name: browser.displayName, iconSystemName: "video.fill", iconColor: .blue, bundleID: browser.bundleID)
        }
    }

    private func fireDirect(name: String, iconSystemName: String, iconColor: Color, bundleID: String) {
        ledger.recordPrompt(name: name, bundleID: bundleID)
        updateCaptureSampler()
        lastFiredName = name
        detectorState = .prompted
        #if !APP_STORE
        AppState.shared.showMeetingNotification(app: DetectedMeetingApp(
            name: name,
            iconSystemName: iconSystemName,
            iconColor: iconColor,
            bundleID: bundleID
        ))
        #endif
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

    private let meetingPatterns: [(pattern: String, provider: MeetingProvider, name: String, icon: String, color: Color)] = [
        // An in-call Meet tab is titled "Meet – abc-defg-hij" (the separator has shifted between
        // hyphen, en dash and em dash across releases, so all three are here). The bare product
        // name below is the *landing* page — it was the only Meet title the table used to match,
        // which is why the prompt appeared on meet.google.com/home and never during a real call.
        ("Meet – ",             .googleMeet,     "Google Meet",     "video.fill",    .green),
        ("Meet — ",             .googleMeet,     "Google Meet",     "video.fill",    .green),
        ("Meet - ",             .googleMeet,     "Google Meet",     "video.fill",    .green),
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

    /// Window titles that are a service's own landing page rather than a call. Google Meet's home
    /// page is titled exactly "Google Meet"; a call is "Meet – abc-defg-hij". Matching the bare
    /// product name is how a tab sitting on meet.google.com/home raised a meeting prompt — the
    /// pattern matched the one title that proves a call is *not* happening.
    private let nonCallWindowTitles: Set<String> = [
        "Google Meet", "Meet", "Google Hangouts", "Hangouts",
        "Microsoft Teams", "Teams", "Zoom", "Webex", "Whereby", "Around", "Slack",
    ]

    private func detectBrowserMeeting(running: [NSRunningApplication]) -> BrowserMatch? {
        for bundleID in browserBundleIDs {
            guard let app = running.first(where: { $0.bundleIdentifier == bundleID }) else { continue }

            // A meeting tab that isn't holding the microphone is not a meeting. It is the service's
            // landing page, a calendar invite, or a tab left open from this morning's call. The
            // window title says *which* service; capture says whether a call is actually happening,
            // and only the pair is evidence. Without this gate the fallback poll fired on the title
            // alone — no mic, no camera, no capture — because it calls `fireDirect` and so never
            // reached the 0.45 threshold that rejects a title-only candidate on the scored path.
            guard capturingApps.contains(bundleID) else { continue }

            guard let titles = allWindowTitles(pid: app.processIdentifier) else { continue }
            for title in titles {
                guard !nonCallWindowTitles.contains(title.trimmingCharacters(in: .whitespaces)) else { continue }
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
        guard result == .success else {
            // Warn on EVERY failure, not just .apiDisabled/.notImplemented. A sandboxed process
            // gets .cannotComplete from every other app — the one case that used to be silent.
            let reason = Self.axErrorDescription(result)
            if lastAXFailure != reason {
                Logger.warning("MeetingDetector: window titles unavailable (\(reason)) — browser detection degraded", subsystem: .app)
            }
            lastAXFailure = reason
            return nil
        }
        lastAXFailure = nil
        guard let windows = windowsRef as? [AXUIElement], !windows.isEmpty else { return nil }
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

    private static func axErrorDescription(_ error: AXError) -> String {
        switch error {
        case .apiDisabled:      return "Accessibility not granted"
        case .notImplemented:   return "app does not implement AX"
        case .cannotComplete:   return "cannot complete — process is sandboxed or app is unresponsive"
        case .invalidUIElement: return "invalid element"
        case .attributeUnsupported: return "windows attribute unsupported"
        case .noValue:          return "no windows"
        default:                return "AXError \(error.rawValue)"
        }
    }
    #endif
}
