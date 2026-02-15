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

    // MARK: - Public API

    /// Mute system audio output, saving previous state
    func muteSystemAudio() {
        print("🔇 AudioMuter.muteSystemAudio() called")

        guard !isMutedByUs else {
            print("🔇 Already muted by us, skipping")
            return
        }

        guard let deviceID = getDefaultOutputDevice() else {
            print("❌ AudioMuter: Could not get default output device")
            return
        }

        print("🔇 Got device ID: \(deviceID)")
        mutedDeviceID = deviceID

        // Save current volumes for all channels and set to 0
        // Don't clear savedVolumes - keep previous values if current is 0
        var newlySaved: [UInt32: Float32] = [:]

        // Try channels 0, 1, 2 (master, left, right)
        for element: UInt32 in [0, 1, 2] {
            if let volume = getVolume(device: deviceID, element: element) {
                // Only save non-zero volumes to avoid saving our own muted state
                if volume > 0.001 {  // Use small threshold to avoid floating point issues
                    newlySaved[element] = volume
                    print("💾 Saved volume for element \(element): \(volume)")
                } else if let previousVolume = savedVolumes[element] {
                    // Volume is 0, but we have a previous value - keep it
                    newlySaved[element] = previousVolume
                    print("💾 Keeping previous volume for element \(element): \(previousVolume) (current is 0)")
                } else {
                    // Volume is 0 and we have no previous value - try master volume
                    if let masterVolume = getMasterVolume(device: deviceID), masterVolume > 0.001 {
                        newlySaved[element] = masterVolume
                        print("💾 Using master volume for element \(element): \(masterVolume) (current is 0)")
                    } else {
                        // Last resort: use 100% so user doesn't lose their audio
                        newlySaved[element] = 1.0
                        print("💾 Using 100% default for element \(element) (current is 0, no master found)")
                    }
                }

                if setVolume(device: deviceID, element: element, volume: 0.0) {
                    print("🔇 Set element \(element) volume to 0")
                }
            }
        }

        savedVolumes = newlySaved

        if !savedVolumes.isEmpty {
            isMutedByUs = true
            print("✅ AudioMuter: System audio MUTED (\(savedVolumes.count) channels)")
        } else {
            print("❌ AudioMuter: Failed to mute any channels")
        }
    }

    /// Restore system audio to previous state
    func unmuteSystemAudio() {
        print("🔊 AudioMuter.unmuteSystemAudio() called")
        print("🔊 isMutedByUs: \(isMutedByUs), savedVolumes: \(savedVolumes)")

        guard isMutedByUs else {
            print("⚠️ Not muted by us, skipping unmute")
            return
        }

        // Use saved device ID, or get current if different
        var deviceID = mutedDeviceID
        if deviceID == 0 {
            guard let currentDeviceID = getDefaultOutputDevice() else {
                print("❌ AudioMuter: Could not get default output device")
                return
            }
            deviceID = currentDeviceID
        }

        print("🔊 Restoring device ID: \(deviceID)")

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
                            print("🔊 Restored element \(element) to volume: \(volume) (verified on attempt \(attempt))")
                            success = true
                            break
                        } else {
                            print("⚠️ Attempt \(attempt)/5: Set volume to \(volume) but read back \(actualVolume)")
                        }
                    } else {
                        print("⚠️ Attempt \(attempt)/5: Could not read back volume for element \(element)")
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
                print("❌ FAILED to restore element \(element) after 5 attempts - volume may be stuck at 0!")
                // Last-ditch effort: try one more time with longer delay
                usleep(300_000)  // 300ms
                if setVolume(device: deviceID, element: element, volume: volume) {
                    usleep(50_000)  // 50ms
                    if let finalVolume = getVolume(device: deviceID, element: element) {
                        print("🚨 Final attempt: volume is now \(finalVolume) (target was \(volume))")
                        if abs(finalVolume - volume) < 0.01 {
                            restoredCount += 1
                        }
                    }
                }
            }
        }

        // Clear mute flag but KEEP savedVolumes for next cycle
        isMutedByUs = false
        // Don't clear savedVolumes - we need them for the next mute
        // savedVolumes.removeAll()
        mutedDeviceID = 0

        if restoredCount > 0 {
            print("✅ AudioMuter: System audio RESTORED (\(restoredCount) channels, keeping volumes for next cycle)")
        } else {
            print("❌ AudioMuter: Failed to restore any channels")
        }
    }

    /// Force restore (emergency unmute)
    func forceRestore() {
        print("🚨 AudioMuter.forceRestore() called")
        isMutedByUs = true  // Force the guard to pass
        unmuteSystemAudio()
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
            print("❌ Failed to get default output device, error: \(status)")
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

    /// Try to get the master/main volume as a fallback when element volume is 0
    private func getMasterVolume(device: AudioDeviceID) -> Float32? {
        // Try master element (0) specifically
        return getVolume(device: device, element: kAudioObjectPropertyElementMain)
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
