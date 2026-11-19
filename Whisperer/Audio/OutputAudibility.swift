//
//  OutputAudibility.swift
//  Whisperer
//
//  A meeting records the call through a process tap, which hears the call *before* the output
//  device's volume is applied. So Whisperer can be transcribing a video perfectly while the
//  user, in their AirPods, hears nothing — the output is muted or sitting at zero
//  (2026-11-19: "Whisperer hears the voices, I hear nothing until I move the volume").
//
//  This reads the default output's mute and level so the meeting can notice that mismatch,
//  and repair it, instead of the user finding the slider.
//

import CoreAudio
import Foundation

nonisolated enum OutputAudibility {

    struct Reading: Equatable {
        var volume: Float?   // highest channel, nil when the device has no volume control
        var muted: Bool?     // nil when the device has no mute control
        /// The user cannot hear this device right now.
        var isSilentToUser: Bool { muted == true || (volume.map { $0 < 0.03 } ?? false) }
    }

    /// Pure: whether `consecutiveSoundingTicks` of call audio on an inaudible output warrants repair.
    static func shouldRepair(_ reading: Reading, callSounding: Bool, consecutiveSoundingTicks: Int) -> Bool {
        callSounding && reading.isSilentToUser && consecutiveSoundingTicks >= 2
    }

    static func read(_ device: AudioDeviceID) -> Reading {
        var reading = Reading()
        var best: Float?
        for element: UInt32 in [0, 1, 2] {
            if let v = scalar(device, selector: kAudioDevicePropertyVolumeScalar, element: element) {
                best = max(best ?? 0, v)
            }
        }
        reading.volume = best
        for element: UInt32 in [0, 1, 2] {
            if let m = scalar(device, selector: kAudioDevicePropertyMute, element: element) {
                reading.muted = (reading.muted ?? false) || m != 0
            }
        }
        return reading
    }

    /// Unmutes and raises the level to `volume`. Returns true if anything was written.
    @discardableResult
    static func repair(_ device: AudioDeviceID, volume: Float) -> Bool {
        var wrote = false
        for element: UInt32 in [0, 1, 2] {
            if write(device, selector: kAudioDevicePropertyMute, element: element, value: 0) { wrote = true }
            if write(device, selector: kAudioDevicePropertyVolumeScalar, element: element, value: volume) { wrote = true }
        }
        return wrote
    }

    // MARK: HAL

    private static func address(_ selector: AudioObjectPropertySelector, _ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private static func scalar(_ device: AudioDeviceID, selector: AudioObjectPropertySelector, element: UInt32) -> Float? {
        var addr = address(selector, element)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        if selector == kAudioDevicePropertyMute {
            var v: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr ? Float(v) : nil
        }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func write(_ device: AudioDeviceID, selector: AudioObjectPropertySelector, element: UInt32, value: Float) -> Bool {
        var addr = address(selector, element)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return false }
        if selector == kAudioDevicePropertyMute {
            var v = UInt32(value)
            return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
        }
        var v = Float32(value)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }
}
