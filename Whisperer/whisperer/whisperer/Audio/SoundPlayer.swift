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

    /// Play start sound immediately (non-blocking for instant response)
    func playStartSound() {
        print("🔔 Playing start sound (ID: \(startSoundID))")

        if startSoundID != 0 {
            AudioServicesPlaySystemSound(startSoundID)
        } else {
            AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert)
        }
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
