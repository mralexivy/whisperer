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

    private init() {
        // Load saved preference
        preferredDeviceUID = UserDefaults.standard.string(forKey: "preferredMicrophoneUID")

        // Initial device enumeration
        refreshDevices()
    }

    // MARK: - Device Enumeration

    func refreshDevices() {
        let devices = enumerateInputDevices()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let previousDevices = self.availableInputDevices
            self.availableInputDevices = devices

            // Update selected device
            self.updateSelectedDevice(previousDevices: previousDevices)
        }
    }

    private func enumerateInputDevices() -> [AudioDevice] {
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
            print("Failed to get devices property size: \(status)")
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
            print("Failed to get devices: \(status)")
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

        print("Found \(inputDevices.count) input devices: \(inputDevices.map { $0.name })")
        return inputDevices
    }

    private func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
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

    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
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

    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
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
                    print("Switched to preferred device: \(device.name)")
                }
                return
            } else {
                // Preferred device not available - check if it was just disconnected
                let wasConnected = previousDevices.contains(where: { $0.uid == preferredUID })
                if wasConnected {
                    print("Preferred device disconnected, falling back to default")
                }
            }
        }

        // Fall back to default device
        if let defaultDevice = getDefaultInputDevice() {
            if selectedDevice?.id != defaultDevice.id {
                selectedDevice = defaultDevice
                print("Using default input device: \(defaultDevice.name)")
            }
        } else if let first = availableInputDevices.first {
            selectedDevice = first
            print("Using first available device: \(first.name)")
        } else {
            selectedDevice = nil
            print("No input devices available")
        }
    }

    func selectDevice(_ device: AudioDevice?) {
        if let device = device {
            preferredDeviceUID = device.uid
            selectedDevice = device
            print("Selected device: \(device.name)")
        } else {
            // nil means use system default
            preferredDeviceUID = nil
            if let defaultDevice = getDefaultInputDevice() {
                selectedDevice = defaultDevice
                print("Cleared preference, using default: \(defaultDevice.name)")
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
              let name = getDeviceName(deviceID: deviceID),
              let uid = getDeviceUID(deviceID: deviceID) else {
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
            print("Failed to start device list monitoring: \(status)")
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
                    print("Default input device changed, updating selection")
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
            print("Failed to start default device monitoring: \(defaultStatus)")
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
                print("AVFoundation: Audio device connected - \(device.localizedName)")
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
                print("AVFoundation: Audio device disconnected - \(device.localizedName)")
                self?.refreshDevices()
            }
        }

        isMonitoring = true
        print("Started monitoring audio device changes (CoreAudio + AVFoundation)")
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
        print("Stopped monitoring audio device changes")
    }

    deinit {
        stopMonitoring()
    }
}
