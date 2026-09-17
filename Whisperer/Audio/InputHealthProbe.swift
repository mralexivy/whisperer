//
//  InputHealthProbe.swift
//  Whisperer
//
//  Answers the one question the capture path could never answer: when every sample is
//  zero, *why*?
//
//  On 2026-09-14 a 58-minute meeting recorded 8 seconds of -91 dB silence. The engine was
//  healthy the whole time — device bound, 48 kHz mono negotiated, tap installed, 4096-frame
//  buffers arriving at ~12 Hz, every one of them zero-filled. The recorder measured RMS and
//  nothing else, so all it could say was `eng.retry reason=silence_1.5s`, and all it could do
//  was rebuild the same engine on the same device four times and give up.
//
//  A muted input, an input gain dragged to zero, a revoked TCC grant and a genuinely wedged
//  HAL all produce that identical signature. Three of those four cannot be fixed by rebuilding
//  an AVAudioEngine, and all four can be told apart by asking CoreAudio directly. This type
//  asks.
//
//  Pure C API reads and one AVFoundation authorization check — `nonisolated`, safe from any
//  thread, and deliberately free of app state so `verdict(for:)` is unit-testable without a
//  microphone.
//

import AVFoundation
import CoreAudio
import Foundation

// MARK: - Facts

/// Raw readings taken from the HAL for one input device. Separated from the verdict so the
/// decision logic can be tested without hardware.
struct InputHealthFacts: Equatable {
    var authorization: AVAuthorizationStatus = .authorized
    var deviceExists = true
    var isAlive = true
    var hasInputStreams = true
    /// `nil` when the device exposes no mute control (most aggregates and virtual devices).
    var isMuted: Bool?
    /// Highest per-channel input gain in 0…1, or `nil` when the device exposes no volume control.
    var inputVolume: Float?
    /// Some other process holds the device hot. Informational only — it does not by itself
    /// explain silence, since CoreAudio happily shares an input.
    var isRunningSomewhere = false
}

// MARK: - Verdict

/// Why the input is producing silence, ordered from most to least actionable.
enum InputHealthVerdict: Equatable {
    /// Nothing wrong with the device — the room really is quiet, or the HAL is wedged in a way
    /// no property exposes. The only case where rebuilding the engine is the right response.
    case healthy
    case permissionDenied
    case permissionNotDetermined
    case deviceGone
    case noInputStreams
    case muted
    case gainZero

    /// Stable code for the structured log. Matches the `reason=` vocabulary already used by
    /// `RecordingFailureReason`.
    var logCode: String {
        switch self {
        case .healthy:                 return "device_ok_but_silent"
        case .permissionDenied:        return "mic_permission_denied"
        case .permissionNotDetermined: return "mic_permission_not_determined"
        case .deviceGone:              return "input_device_gone"
        case .noInputStreams:          return "input_device_has_no_streams"
        case .muted:                   return "input_muted"
        case .gainZero:                return "input_gain_zero"
        }
    }

    /// Shown to the user verbatim. Each one names the thing they can actually go and change —
    /// the old copy ("Microphone stopped responding") named nothing.
    var userMessage: String {
        switch self {
        case .healthy:
            return "No sound is reaching Whisperer. Trying to restart the microphone…"
        case .permissionDenied:
            return "Whisperer no longer has microphone access. Open System Settings ▸ Privacy & Security ▸ Microphone and enable Whisperer."
        case .permissionNotDetermined:
            return "Whisperer hasn't been granted microphone access yet."
        case .deviceGone:
            return "The microphone was disconnected."
        case .noInputStreams:
            return "The selected audio device has no microphone input."
        case .muted:
            return "Your microphone is muted. Unmute it in Control Center or System Settings ▸ Sound ▸ Input."
        case .gainZero:
            return "Your microphone input level is set to zero. Raise it in System Settings ▸ Sound ▸ Input."
        }
    }

    /// Whether tearing down and rebuilding the audio engine could plausibly help.
    ///
    /// Rebuilding a graph cannot un-mute a device, restore a gain slider or grant a TCC
    /// permission — the pre-fix code did it anyway, four times, burning the entire retry budget
    /// on an action that was guaranteed not to work.
    var rebuildCanHelp: Bool {
        switch self {
        case .healthy, .deviceGone:
            return true
        case .permissionDenied, .permissionNotDetermined, .noInputStreams, .muted, .gainZero:
            return false
        }
    }

    /// Whether switching to a different input device could plausibly help.
    var otherDeviceCanHelp: Bool {
        switch self {
        case .deviceGone, .noInputStreams, .muted, .gainZero, .healthy:
            return true
        case .permissionDenied, .permissionNotDetermined:
            return false
        }
    }

    /// Whether Whisperer can repair this itself without the user leaving the app.
    var isSelfRepairable: Bool {
        self == .gainZero || self == .muted
    }
}

// MARK: - Probe

enum InputHealthProbe {

    /// Below this the device is delivering, at best, sub-LSB signal. Not `== 0`: macOS stores
    /// the slider as a float and a nudged-then-returned-to-zero control can read 1e-7.
    static let zeroGainThreshold: Float = 0.001

    // MARK: Decision (pure — unit-testable without hardware)

    static func verdict(for facts: InputHealthFacts) -> InputHealthVerdict {
        // Permission first: a denied grant makes every other reading meaningless, because the
        // HAL still reports a perfectly healthy device and simply feeds the process zeros.
        switch facts.authorization {
        case .denied, .restricted: return .permissionDenied
        case .notDetermined:       return .permissionNotDetermined
        default:                   break
        }

        guard facts.deviceExists, facts.isAlive else { return .deviceGone }
        guard facts.hasInputStreams else { return .noInputStreams }

        if facts.isMuted == true { return .muted }
        if let volume = facts.inputVolume, volume < zeroGainThreshold { return .gainZero }

        return .healthy
    }

    // MARK: Readings

    /// Probes `deviceID` and returns both the raw facts and the verdict derived from them.
    /// Safe to call from any thread; performs only synchronous HAL property reads.
    static func probe(deviceID: AudioDeviceID?) -> (facts: InputHealthFacts, verdict: InputHealthVerdict) {
        var facts = InputHealthFacts()
        facts.authorization = AVCaptureDevice.authorizationStatus(for: .audio)

        guard let deviceID, deviceID != kAudioObjectUnknown else {
            facts.deviceExists = false
            return (facts, verdict(for: facts))
        }

        facts.isAlive = isAlive(deviceID)
        facts.hasInputStreams = hasInputStreams(deviceID)
        facts.isMuted = isMuted(deviceID)
        facts.inputVolume = inputVolume(deviceID)
        facts.isRunningSomewhere = isRunningSomewhere(deviceID)

        return (facts, verdict(for: facts))
    }

    /// Structured log fields for the probe result — attached to the `eng.retry` / `rec.fail`
    /// line so a future dump says *why* instead of just "silence".
    static func logFields(_ facts: InputHealthFacts, _ verdict: InputHealthVerdict) -> [String: MetadataValue] {
        var fields: [String: MetadataValue] = [
            "verdict": .string(verdict.logCode),
            "alive": .bool(facts.isAlive),
            "streams": .bool(facts.hasInputStreams),
            "hot": .bool(facts.isRunningSomewhere)
        ]
        if let muted = facts.isMuted { fields["muted"] = .bool(muted) }
        if let volume = facts.inputVolume { fields["gain"] = .string(String(format: "%.3f", volume)) }
        return fields
    }

    // MARK: - Self-repair

    /// Raises a zeroed input gain back to a usable level, mirroring what
    /// `AudioMuter.unmuteSystemAudio()` already does for the *output* device.
    /// Returns true if at least one channel was written.
    @discardableResult
    static func restoreInputLevel(deviceID: AudioDeviceID, to level: Float = 0.75) -> Bool {
        var wroteAny = false

        // Try the master element first; many devices only accept per-channel writes.
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            var value = level
            let status = AudioObjectSetPropertyData(
                deviceID, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value
            )
            if status == noErr { wroteAny = true }
        }

        if wroteAny {
            Logger.event(.devSelect, .audio, [
                "id": .int(Int(deviceID)),
                "action": .string("input_gain_restored"),
                "to": .string(String(format: "%.2f", level))
            ])
        }
        return wroteAny
    }

    /// Clears `kAudioDevicePropertyMute` on the input scope. Returns true if the write landed.
    @discardableResult
    static func unmuteInput(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
              settable.boolValue else { return false }

        var value: UInt32 = 0
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        )
        if status == noErr {
            Logger.event(.devSelect, .audio, [
                "id": .int(Int(deviceID)), "action": .string("input_unmuted")
            ])
        }
        return status == noErr
    }

    // MARK: - Individual HAL reads

    private static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        // A device that refuses the read is gone, not alive.
        return status == noErr && value != 0
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
    }

    /// `nil` when the device has no input mute control at all.
    private static func isMuted(_ deviceID: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    /// Highest gain across the master element and the first two channels.
    ///
    /// Taking the maximum, not the master alone: on several built-in and USB inputs the master
    /// element is absent or stuck at 0 while the per-channel controls carry the real value, and
    /// reporting that stale 0 would misdiagnose a working mic as `gainZero`.
    private static func inputVolume(_ deviceID: AudioDeviceID) -> Float? {
        var best: Float?
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { continue }
            best = max(best ?? 0, value)
        }
        return best
    }

    private static func isRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }
}
