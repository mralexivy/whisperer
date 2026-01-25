//
//  SoundPlayer.swift
//  Whisperer
//
//  Plays friendly audio feedback sounds for recording start/stop
//

import AppKit
import AudioToolbox

class SoundPlayer {
    // System sound IDs for reliable playback
    private var startSoundID: SystemSoundID = 0
    private var stopSoundID: SystemSoundID = 0

    init() {
        // Load system sounds from /System/Library/Sounds/
        if let startURL = URL(string: "file:///System/Library/Sounds/Tink.aiff") {
            AudioServicesCreateSystemSoundID(startURL as CFURL, &startSoundID)
            print("🔔 Loaded start sound (ID: \(startSoundID))")
        }

        if let stopURL = URL(string: "file:///System/Library/Sounds/Pop.aiff") {
            AudioServicesCreateSystemSoundID(stopURL as CFURL, &stopSoundID)
            print("🔔 Loaded stop sound (ID: \(stopSoundID))")
        }

        print("🔔 SoundPlayer initialized")
    }

    deinit {
        if startSoundID != 0 {
            AudioServicesDisposeSystemSoundID(startSoundID)
        }
        if stopSoundID != 0 {
            AudioServicesDisposeSystemSoundID(stopSoundID)
        }
    }

    // MARK: - Public API

    /// Play start sound and wait for it to complete (async so muting waits)
    func playStartSoundAndWait() async {
        print("🔔 Playing start sound (ID: \(startSoundID))...")

        if startSoundID != 0 {
            AudioServicesPlaySystemSound(startSoundID)
        } else {
            // Fallback to system alert
            AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert)
        }

        // Wait for sound to complete (Tink is ~0.1 seconds, add buffer)
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        print("🔔 Start sound finished")
    }

    /// Play a gentle sound indicating recording has stopped
    func playStopSound() {
        print("🔔 Playing stop sound (ID: \(stopSoundID))")

        if stopSoundID != 0 {
            AudioServicesPlaySystemSound(stopSoundID)
        } else {
            // Fallback to system alert
            AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert)
        }
    }
}
