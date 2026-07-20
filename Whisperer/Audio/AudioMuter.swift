//
//  AudioMuter.swift
//  Whisperer
//
//  Mutes system audio output during voice capture to prevent interference
//

import CoreAudio
import AudioToolbox

class AudioMuter {
    // Saved state for restoration
    private var savedVolumes: [UInt32: Float32] = [:]  // element -> volume
    private var isMutedByUs: Bool = false
    private var mutedDeviceID: AudioDeviceID = 0

    // Serial queue serializes all CoreAudio property access; unmute dispatches async so callers don't block.
    private let operationQueue = DispatchQueue(label: "audio.muter", qos: .userInitiated)

    // MARK: - Public API

    /// Mute system audio output, saving previous state.
    /// Blocks caller until mute completes (intentional — recording must not start until muted).
    func muteSystemAudio() {
        operationQueue.sync { self._muteSystemAudio() }
    }

    /// Restore system audio to previous state.
    /// Returns immediately — restoration runs on a background queue.
    func unmuteSystemAudio() {
        operationQueue.async { self._unmuteSystemAudio() }
    }

    /// Force restore (emergency unmute). Returns immediately.
    func forceRestore() {
        Logger.warning("forceRestore() called", subsystem: .audio)
        operationQueue.async {
            self.isMutedByUs = true  // force guard to pass
            self._unmuteSystemAudio()
        }
    }

    // MARK: - Internal Implementation (must run on operationQueue)

    private func _muteSystemAudio() {
        Logger.debug("muteSystemAudio() called", subsystem: .audio)

        guard !isMutedByUs else {
            Logger.debug("Already muted by us, skipping", subsystem: .audio)
            return
        }

        guard let deviceID = getDefaultOutputDevice() else {
            Logger.error("Could not get default output device", subsystem: .audio)
            return
        }

        Logger.debug("Muting output device: \(deviceID)", subsystem: .audio)
        mutedDeviceID = deviceID

        // Save and mute only non-zero channels. Channels already at 0 are skipped —
        // they need no muting and we have no valid restore target for them.
        var newlySaved: [UInt32: Float32] = [:]
        for element: UInt32 in [0, 1, 2] {
            guard let volume = getVolume(device: deviceID, element: element), volume > 0.001 else { continue }
            newlySaved[element] = volume
            if setVolume(device: deviceID, element: element, volume: 0.0) {
                Logger.debug("Muted element \(element) from \(volume)", subsystem: .audio)
            }
        }

        savedVolumes = newlySaved

        if !savedVolumes.isEmpty {
            isMutedByUs = true
            Logger.info("System audio MUTED (\(savedVolumes.count) channels)", subsystem: .audio)
        } else {
            Logger.error("Failed to mute any channels", subsystem: .audio)
        }
    }

    private func _unmuteSystemAudio() {
        Logger.debug("unmuteSystemAudio() called (isMutedByUs: \(isMutedByUs), savedVolumes: \(savedVolumes.count) channels)", subsystem: .audio)

        guard isMutedByUs else {
            Logger.debug("Not muted by us, skipping unmute", subsystem: .audio)
            return
        }

        // Use saved device ID, or get current if different
        var deviceID = mutedDeviceID
        if deviceID == 0 {
            guard let currentDeviceID = getDefaultOutputDevice() else {
                Logger.error("Could not get default output device for unmute", subsystem: .audio)
                return
            }
            deviceID = currentDeviceID
        }

        Logger.debug("Restoring volume on device: \(deviceID)", subsystem: .audio)

        var restoredCount = 0
        for (element, volume) in savedVolumes {
            // Try up to 5 times with increasing delays to ensure it takes effect
            var success = false
            for attempt in 1...5 {
                if setVolume(device: deviceID, element: element, volume: volume) {
                    // Longer delay to let macOS process the change (especially when idle)
                    usleep(30_000)  // 30ms

                    // Verify it was actually set
                    if let actualVolume = getVolume(device: deviceID, element: element) {
                        if abs(actualVolume - volume) < 0.01 {  // Close enough
                            Logger.debug("Restored element \(element) to \(volume) (attempt \(attempt))", subsystem: .audio)
                            success = true
                            break
                        } else {
                            Logger.warning("Attempt \(attempt)/5: Set volume to \(volume) but read back \(actualVolume) for element \(element)", subsystem: .audio)
                        }
                    } else {
                        Logger.warning("Attempt \(attempt)/5: Could not read back volume for element \(element)", subsystem: .audio)
                    }
                }

                if attempt < 5 {
                    // Increasing delay between retries (100ms, 150ms, 200ms, 250ms)
                    let delayMs = 100_000 + (attempt * 50_000)
                    usleep(UInt32(delayMs))
                }
            }

            if success {
                restoredCount += 1
            } else {
                Logger.error("FAILED to restore element \(element) after 5 attempts", subsystem: .audio)
                // Last-ditch effort: try one more time with longer delay
                usleep(300_000)  // 300ms
                if setVolume(device: deviceID, element: element, volume: volume) {
                    usleep(50_000)  // 50ms
                    if let finalVolume = getVolume(device: deviceID, element: element) {
                        Logger.warning("Final attempt: volume is now \(finalVolume) (target was \(volume))", subsystem: .audio)
                        if abs(finalVolume - volume) < 0.01 {
                            restoredCount += 1
                        }
                    }
                }
            }
        }

        isMutedByUs = false
        savedVolumes = [:]
        mutedDeviceID = 0

        if restoredCount > 0 {
            Logger.info("System audio RESTORED (\(restoredCount) channels)", subsystem: .audio)
        } else {
            Logger.error("Failed to restore any channels", subsystem: .audio)
        }
    }

    // MARK: - CoreAudio Helpers

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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

        if status != noErr {
            Logger.error("Failed to get default output device, error: \(status)", subsystem: .audio)
            return nil
        }

        return deviceID
    }

    private func getVolume(device: AudioDeviceID, element: UInt32) -> Float32? {
        var volume: Float32 = 0
        var propertySize = UInt32(MemoryLayout<Float32>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )

        // Check if property exists
        guard AudioObjectHasProperty(device, &propertyAddress) else {
            return nil
        }

        let status = AudioObjectGetPropertyData(
            device,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &volume
        )

        if status != noErr {
            return nil
        }

        return volume
    }

    private func setVolume(device: AudioDeviceID, element: UInt32, volume: Float32) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )

        // Check if property exists and is settable
        guard AudioObjectHasProperty(device, &propertyAddress) else {
            return false
        }

        var isSettable: DarwinBoolean = false
        AudioObjectIsPropertySettable(device, &propertyAddress, &isSettable)

        guard isSettable.boolValue else {
            return false
        }

        var newVolume = volume
        let status = AudioObjectSetPropertyData(
            device,
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &newVolume
        )

        return status == noErr
    }
}

extension AudioMuter {
    func debugSnapshot() -> [String: String] {
        return [
            "isMutedByUs": "\(isMutedByUs)",
            "savedVolumes.count": "\(savedVolumes.count)"
        ]
    }
}
