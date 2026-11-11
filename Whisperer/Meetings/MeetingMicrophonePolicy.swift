//
//  MeetingMicrophonePolicy.swift
//  Whisperer
//
//  Which microphone a meeting records from when the user has not picked one.
//
//  Opening a Bluetooth headset's microphone switches it from its playback profile to the headset
//  (call) profile: mono, 16–24 kHz, more latency and audible hiss in the user's ears. When the call
//  app talks through the Mac's own microphone, Whisperer opening the AirPods microphone is what
//  made the call sound worse (user report, 2026-11-11: "delay and sometimes noise in the AirPods").
//  So a meeting follows the call: if the call app already has the headset microphone open, the
//  profile has switched anyway and the headset is the user's voice; otherwise the built-in
//  microphone records and the headset stays in high quality. The call's other side comes from the
//  process tap either way, not from a microphone.
//
//  Pure decision plus the HAL reads it needs.
//

import CoreAudio
import Foundation

nonisolated enum MeetingMicrophonePolicy {

    struct Device: Equatable, Sendable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transport: UInt32

        var isBluetooth: Bool {
            transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        }
    }

    enum Choice: Equatable, Sendable {
        case keep(reason: String)
        case useBuiltIn(Device, reason: String)
    }

    /// - Parameters:
    ///   - route: the route Settings resolved — an explicit choice is the user's and is kept.
    ///   - defaultInput: the system's default input.
    ///   - builtIn: the Mac's own microphone, if it has one.
    ///   - callAppInputs: the input devices other apps (the call) have open right now.
    static func choose(route: ResolvedInputRoute, defaultInput: Device?, builtIn: Device?,
                       callAppInputs: Set<AudioDeviceID>) -> Choice {
        if case .explicit = route { return .keep(reason: "microphone chosen in Settings") }
        guard let defaultInput, defaultInput.isBluetooth else { return .keep(reason: "default input is not a headset") }
        guard let builtIn, builtIn.id != defaultInput.id else { return .keep(reason: "no built-in microphone") }
        if callAppInputs.contains(defaultInput.id) {
            return .keep(reason: "the call already uses \(defaultInput.name)'s microphone")
        }
        return .useBuiltIn(builtIn, reason: "keeps \(defaultInput.name) in high-quality playback")
    }

    /// The route for a meeting starting now, with the reason logged.
    @MainActor
    static func route(for resolved: ResolvedInputRoute, processMonitor: AudioProcessMonitor) -> ResolvedInputRoute {
        let callInputs = processMonitor.inputRoutes().reduce(into: Set<AudioDeviceID>()) { $0.formUnion($1.devices) }
        let choice = choose(route: resolved, defaultInput: defaultInputDevice(), builtIn: builtInInputDevice(),
                            callAppInputs: callInputs)
        switch choice {
        case .keep(let reason):
            Logger.info("Meeting microphone: \(resolved) — \(reason)", subsystem: .audio)
            return resolved
        case .useBuiltIn(let device, let reason):
            Logger.info("Meeting microphone: \(device.name) — \(reason)", subsystem: .audio)
            return .explicit(uid: device.uid, deviceID: device.id)
        }
    }

    // MARK: - HAL

    static func defaultInputDevice() -> Device? {
        var address = SystemAudioCapture.address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return device(id)
    }

    static func builtInInputDevice() -> Device? {
        var address = SystemAudioCapture.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.lazy.compactMap(device).first { $0.transport == kAudioDeviceTransportTypeBuiltIn && hasInput($0.id) }
    }

    private static func device(_ id: AudioDeviceID) -> Device? {
        guard let uid = SystemAudioCapture.stringProperty(id, kAudioDevicePropertyDeviceUID),
              !uid.hasPrefix(SystemAudioCapture.aggregateUIDPrefix) else { return nil }
        let name = SystemAudioCapture.stringProperty(id, kAudioObjectPropertyName) ?? uid
        let transport = SystemAudioCapture.uint32Property(id, kAudioDevicePropertyTransportType) ?? 0
        return Device(id: id, uid: uid, name: name, transport: transport)
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = SystemAudioCapture.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }
}
