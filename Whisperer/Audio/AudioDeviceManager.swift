//
//  AudioDeviceManager.swift
//  Whisperer
//
//  Manages audio input device enumeration, selection, and monitoring
//

import Foundation
import CoreAudio
import Combine
import AVFoundation
import AppKit

// MARK: - ResolvedInputRoute

/// Represents the resolved audio input route at recording start time.
/// Device identity is resolved fresh from CoreAudio — never cached.
enum ResolvedInputRoute: Sendable, Equatable, CustomStringConvertible {
    case systemDefault
    case explicit(uid: String, deviceID: AudioDeviceID)

    var description: String {
        switch self {
        case .systemDefault: return "systemDefault"
        case .explicit(let uid, let id): return "explicit(uid: \(uid), id: \(id))"
        }
    }
}

@MainActor
class AudioDeviceManager: ObservableObject {
    static let shared = AudioDeviceManager()

    struct AudioDevice: Identifiable, Equatable, Hashable {
        let id: AudioDeviceID
        let name: String
        let uid: String  // Persistent identifier across sessions

        static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
            return lhs.uid == rhs.uid && lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(uid)
        }
    }

    @Published var availableInputDevices: [AudioDevice] = []
    @Published var selectedDevice: AudioDevice?
    @Published var preferredDeviceUID: String? {
        didSet {
            UserDefaults.standard.set(preferredDeviceUID, forKey: "preferredMicrophoneUID")
        }
    }

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceConnectedObserver: NSObjectProtocol?
    private var deviceDisconnectedObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var isMonitoring = false
    private var cachedDeviceUIDs: Set<String> = []

    private init() {
        // Load saved preference
        preferredDeviceUID = UserDefaults.standard.string(forKey: "preferredMicrophoneUID")

        // Initial device enumeration
        refreshDevices()
    }

    // MARK: - Device Enumeration

    func refreshDevices() {
        // Dispatch CoreAudio queries off main thread to prevent deadlocks
        // during HAL topology changes (the HAL may hold internal locks when
        // calling our listener, and synchronous queries would deadlock)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let devices = AudioDeviceManager.enumerateInputDevices()
            DispatchQueue.main.async {
                guard let self else { return }
                let previousDevices = self.availableInputDevices
                self.availableInputDevices = devices

                // Diff detection for diagnostics
                let newUIDs = Set(devices.map { $0.uid })
                let added = newUIDs.subtracting(self.cachedDeviceUIDs)
                let removed = self.cachedDeviceUIDs.subtracting(newUIDs)
                self.cachedDeviceUIDs = newUIDs

                let selection = self.updateSelectedDevice(previousDevices: previousDevices)

                // An unchanged device list is not news — this runs on every launch,
                // every HAL notification and every wake, and used to cost three lines
                // each time. One record, only when the set or the selection moved.
                guard !added.isEmpty || !removed.isEmpty || selection.changed else { return }

                var fields: [String: MetadataValue] = [
                    "n": .int(devices.count),
                    "sel": .string(self.selectedDevice?.name ?? "none"),
                    "why": .string(selection.reason)
                ]
                if !added.isEmpty {
                    fields["add"] = .string(devices.filter { added.contains($0.uid) }
                        .map { $0.name }.joined(separator: ","))
                }
                if !removed.isEmpty {
                    fields["rm"] = .string(previousDevices.filter { removed.contains($0.uid) }
                        .map { $0.name }.joined(separator: ","))
                }
                if selection.preferredLost { fields["preflost"] = .bool(true) }

                // Losing the chosen mic or ending up with none is a degraded outcome;
                // gaining a device is not.
                let degraded = selection.preferredLost || self.selectedDevice == nil
                Logger.event(.devChange, .audio, fields, level: degraded ? .warning : .info)
            }
        }
    }

    // nonisolated static: pure CoreAudio C API calls, no instance state access.
    // Must be callable from background threads for deadlock-free HAL queries.
    private nonisolated static func enumerateInputDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        )

        guard status == noErr else {
            Logger.event(.devFail, .audio, ["at": .string("size"), "os": .int(Int(status))], level: .error)
            return []
        }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )

        guard status == noErr else {
            Logger.event(.devFail, .audio, ["at": .string("list"), "os": .int(Int(status))], level: .error)
            return []
        }

        // Filter to input devices only
        var inputDevices: [AudioDevice] = []

        for deviceID in deviceIDs {
            if hasInputStreams(deviceID: deviceID),
               let name = getDeviceName(deviceID: deviceID),
               let uid = getDeviceUID(deviceID: deviceID) {
                inputDevices.append(AudioDevice(id: deviceID, name: name, uid: uid))
            }
        }

        // The set itself is reported by the `dev.change` diff in refreshDevices(),
        // and only when it moves. Enumerating is not an outcome.
        Logger.step("dev.enum", .audio, ["n": .int(inputDevices.count)])
        return inputDevices
    }

    private nonisolated static func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize
        )

        return status == noErr && propertySize > 0
    }

    private nonisolated static func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString = "" as CFString
        var propertySize = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &name) { namePtr in
            AudioObjectGetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                &propertySize,
                namePtr
            )
        }

        guard status == noErr else { return nil }
        return name as String
    }

    private nonisolated static func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: CFString = "" as CFString
        var propertySize = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &uid) { uidPtr in
            AudioObjectGetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                &propertySize,
                uidPtr
            )
        }

        guard status == noErr else { return nil }
        return uid as String
    }

    // MARK: - Device Selection

    /// What the selection pass did, so the caller can fold it into the single
    /// `dev.change` record instead of each branch logging its own line.
    private struct SelectionOutcome {
        var changed = false
        var reason = "preferred"   // preferred | default | first | none
        var preferredLost = false
    }

    @discardableResult
    private func updateSelectedDevice(previousDevices: [AudioDevice]) -> SelectionOutcome {
        var outcome = SelectionOutcome()

        // If we have a preferred device UID, try to find it
        if let preferredUID = preferredDeviceUID {
            if let device = availableInputDevices.first(where: { $0.uid == preferredUID }) {
                // Preferred device is available
                if selectedDevice?.uid != device.uid {
                    selectedDevice = device
                    outcome.changed = true
                }
                return outcome
            } else {
                // Preferred device not available - check if it was just disconnected
                outcome.preferredLost = previousDevices.contains(where: { $0.uid == preferredUID })
            }
        }

        // Fall back to default device
        if let defaultDevice = getDefaultInputDevice() {
            outcome.reason = "default"
            if selectedDevice?.id != defaultDevice.id {
                selectedDevice = defaultDevice
                outcome.changed = true
            }
        } else if let first = availableInputDevices.first {
            outcome.reason = "first"
            outcome.changed = selectedDevice?.uid != first.uid
            selectedDevice = first
        } else {
            outcome.reason = "none"
            outcome.changed = selectedDevice != nil
            selectedDevice = nil
        }

        return outcome
    }

    func selectDevice(_ device: AudioDevice?) {
        if let device = device {
            preferredDeviceUID = device.uid
            selectedDevice = device
            Logger.event(.devSelect, .audio, ["sel": .string(device.name), "pinned": .bool(true)])
        } else {
            // nil means use system default
            preferredDeviceUID = nil
            if let defaultDevice = getDefaultInputDevice() {
                selectedDevice = defaultDevice
                Logger.event(.devSelect, .audio, ["sel": .string(defaultDevice.name),
                                                  "pinned": .bool(false)])
            }
        }
    }

    func getDefaultInputDevice() -> AudioDevice? {
        var deviceID = AudioDeviceID()
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr,
              let name = Self.getDeviceName(deviceID: deviceID),
              let uid = Self.getDeviceUID(deviceID: deviceID) else {
            return nil
        }

        return AudioDevice(id: deviceID, name: name, uid: uid)
    }

    // MARK: - Route Resolution for Recording

    /// Resolve the input route to use for a recording session.
    /// If the user has a preferred device, resolves its UID to a current AudioDeviceID
    /// via a fresh CoreAudio query. Returns .systemDefault if no preference or device not found.
    func resolveInputRouteForRecording() -> ResolvedInputRoute {
        guard let preferredUID = preferredDeviceUID else {
            return .systemDefault
        }
        if let deviceID = Self.resolveDeviceIDByUID(preferredUID) {
            return .explicit(uid: preferredUID, deviceID: deviceID)
        }
        Logger.event(.devFail, .audio, ["at": .string("resolve"), "uid": .string(preferredUID),
                                        "fallback": .string("default")], level: .warning)
        return .systemDefault
    }

    /// Pure HAL lookup: resolve a device UID to its current AudioDeviceID.
    /// No caching, no fallback, no mutation. Returns nil if device not found.
    nonisolated static func resolveDeviceIDByUID(_ uid: String) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        )
        guard status == noErr, propertySize > 0 else { return nil }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )
        guard status == noErr else { return nil }

        for deviceID in deviceIDs {
            if let deviceUID = getDeviceUID(deviceID: deviceID), deviceUID == uid {
                return deviceID
            }
        }
        return nil
    }

    // MARK: - Device Monitoring

    func startMonitoring() {
        guard !isMonitoring else { return }

        // Monitor device add/remove events
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        listenerBlock = { [weak self] (_, _) in
            DispatchQueue.main.async {
                self?.refreshDevices()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            listenerBlock!
        )

        if status != noErr {
            Logger.event(.devFail, .audio, ["at": .string("monitor"), "which": .string("list"),
                                            "os": .int(Int(status))], level: .error)
            return
        }

        // Monitor default input device changes
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        defaultDeviceListenerBlock = { [weak self] (_, _) in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // When default device changes, refresh devices and update selection
                // if user is following system default (preferredDeviceUID is nil)
                if self.preferredDeviceUID == nil {
                    // The refresh below reports the outcome; the trigger is only
                    // interesting when the outcome went wrong, which is what a
                    // failure block's ring-buffer dump is for.
                    Logger.step("dev.defaultchanged", .audio)
                    self.refreshDevices()
                }
            }
        }

        let defaultStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            DispatchQueue.main,
            defaultDeviceListenerBlock!
        )

        if defaultStatus != noErr {
            Logger.event(.devFail, .audio, ["at": .string("monitor"), "which": .string("default"),
                                            "os": .int(Int(defaultStatus))], level: .error)
            // Continue anyway - we have the device list monitoring
        }

        // Add AVFoundation device notifications for redundancy
        // These work alongside CoreAudio listeners for more reliable detection
        deviceConnectedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let device = notification.object as? AVCaptureDevice,
               device.hasMediaType(.audio) {
                // Redundant with the CoreAudio listener — both funnel into the same
                // refresh, and `dev.change` is the record that says what resulted.
                Logger.step("dev.avconnect", .audio, ["name": .string(device.localizedName)])
                self?.refreshDevices()
            }
        }

        deviceDisconnectedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let device = notification.object as? AVCaptureDevice,
               device.hasMediaType(.audio) {
                Logger.step("dev.avdisconnect", .audio, ["name": .string(device.localizedName)])
                self?.refreshDevices()
            }
        }

        // Monitor sleep/wake — device IDs change after wake
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Logger.step("sys.wake", .audio)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.refreshDevices()
            }
        }

        isMonitoring = true
        Logger.step("dev.monitor", .audio, ["state": .string("on")])
    }

    func stopMonitoring() {
        guard isMonitoring else { return }

        // Remove device list listener
        if let listenerBlock = listenerBlock {
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                DispatchQueue.main,
                listenerBlock
            )
            self.listenerBlock = nil
        }

        // Remove default device listener
        if let defaultDeviceListenerBlock = defaultDeviceListenerBlock {
            var defaultDeviceAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultDeviceAddress,
                DispatchQueue.main,
                defaultDeviceListenerBlock
            )
            self.defaultDeviceListenerBlock = nil
        }

        // Remove AVFoundation observers
        if let observer = deviceConnectedObserver {
            NotificationCenter.default.removeObserver(observer)
            deviceConnectedObserver = nil
        }

        if let observer = deviceDisconnectedObserver {
            NotificationCenter.default.removeObserver(observer)
            deviceDisconnectedObserver = nil
        }

        // Remove wake observer
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }

        isMonitoring = false
        Logger.step("dev.monitor", .audio, ["state": .string("off")])
    }

    // Note: deinit removed - AudioDeviceManager is a singleton that lives for app lifetime
}
