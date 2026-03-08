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

@MainActor
class AudioDeviceManager: ObservableObject {
    static let shared = AudioDeviceManager()

    struct AudioDevice: Identifiable, Equatable, Hashable {
        let id: AudioDeviceID
        let name: String
        let uid: String  // Persistent identifier across sessions

        static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
            return lhs.uid == rhs.uid
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
                if !added.isEmpty {
                    let names = devices.filter { added.contains($0.uid) }.map { $0.name }
                    Logger.info("Audio devices added: \(names)", subsystem: .audio)
                }
                if !removed.isEmpty {
                    let names = previousDevices.filter { removed.contains($0.uid) }.map { $0.name }
                    Logger.warning("Audio devices removed: \(names)", subsystem: .audio)
                }
                self.cachedDeviceUIDs = newUIDs

                self.updateSelectedDevice(previousDevices: previousDevices)
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
            Logger.error("Failed to get devices property size: \(status)", subsystem: .audio)
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
            Logger.error("Failed to get devices: \(status)", subsystem: .audio)
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

        Logger.info("Found \(inputDevices.count) input devices: \(inputDevices.map { $0.name })", subsystem: .audio)
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

    private func updateSelectedDevice(previousDevices: [AudioDevice]) {
        // If we have a preferred device UID, try to find it
        if let preferredUID = preferredDeviceUID {
            if let device = availableInputDevices.first(where: { $0.uid == preferredUID }) {
                // Preferred device is available
                if selectedDevice?.uid != device.uid {
                    selectedDevice = device
                    Logger.info("Switched to preferred device: \(device.name)", subsystem: .audio)
                }
                return
            } else {
                // Preferred device not available - check if it was just disconnected
                let wasConnected = previousDevices.contains(where: { $0.uid == preferredUID })
                if wasConnected {
                    Logger.warning("Preferred device disconnected, falling back to default", subsystem: .audio)
                }
            }
        }

        // Fall back to default device
        if let defaultDevice = getDefaultInputDevice() {
            if selectedDevice?.id != defaultDevice.id {
                selectedDevice = defaultDevice
                Logger.info("Using default input device: \(defaultDevice.name)", subsystem: .audio)
            }
        } else if let first = availableInputDevices.first {
            selectedDevice = first
            Logger.info("Using first available device: \(first.name)", subsystem: .audio)
        } else {
            selectedDevice = nil
            Logger.warning("No input devices available", subsystem: .audio)
        }
    }

    func selectDevice(_ device: AudioDevice?) {
        if let device = device {
            preferredDeviceUID = device.uid
            selectedDevice = device
            Logger.info("Selected device: \(device.name)", subsystem: .audio)
        } else {
            // nil means use system default
            preferredDeviceUID = nil
            if let defaultDevice = getDefaultInputDevice() {
                selectedDevice = defaultDevice
                Logger.info("Cleared preference, using default: \(defaultDevice.name)", subsystem: .audio)
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
            Logger.error("Failed to start device list monitoring: \(status)", subsystem: .audio)
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
                    Logger.info("Default input device changed, updating selection", subsystem: .audio)
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
            Logger.error("Failed to start default device monitoring: \(defaultStatus)", subsystem: .audio)
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
                Logger.info("AVFoundation: Audio device connected - \(device.localizedName)", subsystem: .audio)
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
                Logger.warning("AVFoundation: Audio device disconnected - \(device.localizedName)", subsystem: .audio)
                self?.refreshDevices()
            }
        }

        isMonitoring = true
        Logger.info("Started monitoring audio device changes (CoreAudio + AVFoundation)", subsystem: .audio)
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

        isMonitoring = false
        Logger.info("Stopped monitoring audio device changes", subsystem: .audio)
    }

    // Note: deinit removed - AudioDeviceManager is a singleton that lives for app lifetime
}
