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
    private var mutedDeviceUID: String?

    /// The mute survives a crash or a lost restore as a note on disk: "this device was muted by
    /// us, here is what it was". Without it a failed restore left the volume at 0 until the user
    /// noticed and dragged the slider (2026-11-19, AirPods).
    private static let pendingKey = "audioMuter.pendingRestore"

    init() {
        operationQueue.async { self.restorePendingIfStillMuted() }
    }

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

        // Muting exists so speaker sound does not leak into the microphone. Headphones have no
        // such path, and a Bluetooth headset is the one output whose volume is rewritten by
        // macOS when its profile flips to call mode and back — where a mute-and-restore cycle
        // went wrong and left AirPods silent until the slider was touched. Leave them alone.
        if Self.isHeadphoneOutput(deviceID) {
            Logger.info("Output is headphones — not muting", subsystem: .audio)
            return
        }

        Logger.debug("Muting output device: \(deviceID)", subsystem: .audio)
        mutedDeviceID = deviceID
        mutedDeviceUID = AudioDeviceManager.getDeviceUID(deviceID: deviceID)

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
            savePending()
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

        // Resolve by UID: a Bluetooth device can come back under a new ID after a profile flip.
        var deviceID = mutedDeviceUID.flatMap { AudioDeviceManager.resolveDeviceIDByUID($0) } ?? mutedDeviceID
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

        let restoredVolumes = savedVolumes
        let restoredUID = mutedDeviceUID
        isMutedByUs = false
        savedVolumes = [:]
        mutedDeviceID = 0
        mutedDeviceUID = nil

        if restoredCount == restoredVolumes.count {
            Logger.info("System audio RESTORED (\(restoredCount) channels)", subsystem: .audio)
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        } else {
            // Keep the on-disk note: the verify passes below and the next launch finish the job.
            Logger.error("Restored \(restoredCount)/\(restoredVolumes.count) channels — will keep retrying", subsystem: .audio)
        }
        verifyRestore(uid: restoredUID, volumes: restoredVolumes, remainingPasses: 6)
    }

    /// Re-checks the restore after the device has settled. A Bluetooth headset reports success
    /// for a write and then has the value replaced when it finishes switching profile, so a
    /// single verified write is not the end of the job. Only touches a channel that is still
    /// at zero — a volume the user has since set is theirs.
    private func verifyRestore(uid: String?, volumes: [UInt32: Float32], remainingPasses: Int) {
        guard remainingPasses > 0, !volumes.isEmpty else { return }
        operationQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.isMutedByUs else { return }
            // The device it was muted on, and whatever is the default now (profile flip).
            var targets: [AudioDeviceID] = []
            if let uid, let id = AudioDeviceManager.resolveDeviceIDByUID(uid) { targets.append(id) }
            if let current = self.getDefaultOutputDevice(), !targets.contains(current) { targets.append(current) }
            var stillMuted = false
            for device in targets {
                for (element, volume) in volumes {
                    guard let actual = self.getVolume(device: device, element: element), actual < 0.001 else { continue }
                    stillMuted = true
                    if self.setVolume(device: device, element: element, volume: volume) {
                        Logger.warning("Output still muted after restore — restored element \(element) to \(volume)", subsystem: .audio)
                    }
                }
            }
            if stillMuted {
                self.verifyRestore(uid: uid, volumes: volumes, remainingPasses: remainingPasses - 1)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.pendingKey)
            }
        }
    }

    private func savePending() {
        var note: [String: Any] = ["volumes": savedVolumes.reduce(into: [String: Double]()) { $0[String($1.key)] = Double($1.value) }]
        if let uid = mutedDeviceUID { note["uid"] = uid }
        UserDefaults.standard.set(note, forKey: Self.pendingKey)
    }

    /// At launch: if a previous run muted the output and never restored it, and it is still at
    /// zero, put it back.
    private func restorePendingIfStillMuted() {
        guard let note = UserDefaults.standard.dictionary(forKey: Self.pendingKey),
              let raw = note["volumes"] as? [String: Double] else { return }
        let volumes = raw.reduce(into: [UInt32: Float32]()) { if let e = UInt32($1.key) { $0[e] = Float32($1.value) } }
        Logger.warning("Found an unrestored output mute from a previous run — restoring", subsystem: .audio)
        verifyRestore(uid: note["uid"] as? String, volumes: volumes, remainingPasses: 3)
    }

    /// Bluetooth, or the headphone jack: no acoustic path from output to microphone.
    private static func isHeadphoneOutput(_ deviceID: AudioDeviceID) -> Bool {
        let transport = InputRoutePreflight.transportType(deviceID)
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return true }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var source: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &source) == noErr else { return false }
        return source == 0x6864706E  // 'hdpn'
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
