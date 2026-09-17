//
//  SoundPlayer.swift
//  Whisperer
//
//  Plays friendly audio feedback sounds for recording start/stop
//

import AppKit
import AudioToolbox

enum SoundOption: String, CaseIterable {
    case defaultSounds = "default"
    case subtle = "subtle"
    case silent = "silent"

    var displayName: String {
        switch self {
        case .defaultSounds: return "Default"
        case .subtle: return "Subtle"
        case .silent: return "Silent"
        }
    }

    static func load() -> SoundOption {
        let raw = UserDefaults.standard.string(forKey: "soundOption") ?? "default"
        return SoundOption(rawValue: raw) ?? .defaultSounds
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: "soundOption")
    }
}

class SoundPlayer {
    // System sound IDs for reliable playback
    private var startSoundID: SystemSoundID = 0
    private var stopSoundID: SystemSoundID = 0
    private var subtleStartSoundID: SystemSoundID = 0
    private var subtleStopSoundID: SystemSoundID = 0
    private var errorSoundID: SystemSoundID = 0

    var soundOption: SoundOption = .load()

    init() {
        // Default sounds: Tink (start) and Pop (stop)
        if let startURL = URL(string: "file:///System/Library/Sounds/Tink.aiff") {
            AudioServicesCreateSystemSoundID(startURL as CFURL, &startSoundID)
        }

        if let stopURL = URL(string: "file:///System/Library/Sounds/Pop.aiff") {
            AudioServicesCreateSystemSoundID(stopURL as CFURL, &stopSoundID)
        }

        // Subtle sounds: Morse (start) and Purr (stop) — quieter system sounds
        if let subtleStartURL = URL(string: "file:///System/Library/Sounds/Morse.aiff") {
            AudioServicesCreateSystemSoundID(subtleStartURL as CFURL, &subtleStartSoundID)
        }

        if let subtleStopURL = URL(string: "file:///System/Library/Sounds/Purr.aiff") {
            AudioServicesCreateSystemSoundID(subtleStopURL as CFURL, &subtleStopSoundID)
        }

        // Failure alert: Basso, the system's conventional "something went wrong" sound, and
        // distinct from every chime above so it is not mistaken for a normal stop.
        if let errorURL = URL(string: "file:///System/Library/Sounds/Basso.aiff") {
            AudioServicesCreateSystemSoundID(errorURL as CFURL, &errorSoundID)
        }

        Logger.info("SoundPlayer initialized", subsystem: .audio)
    }

    deinit {
        if startSoundID != 0 { AudioServicesDisposeSystemSoundID(startSoundID) }
        if stopSoundID != 0 { AudioServicesDisposeSystemSoundID(stopSoundID) }
        if subtleStartSoundID != 0 { AudioServicesDisposeSystemSoundID(subtleStartSoundID) }
        if subtleStopSoundID != 0 { AudioServicesDisposeSystemSoundID(subtleStopSoundID) }
        if errorSoundID != 0 { AudioServicesDisposeSystemSoundID(errorSoundID) }
    }

    // MARK: - Public API

    /// Play start sound immediately (non-blocking for instant response)
    func playStartSound() {
        switch soundOption {
        case .defaultSounds:
            if startSoundID != 0 {
                AudioServicesPlaySystemSound(startSoundID)
            } else {
                AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert)
            }
        case .subtle:
            if subtleStartSoundID != 0 {
                AudioServicesPlaySystemSound(subtleStartSoundID)
            }
        case .silent:
            break
        }
    }

    /// Play an alert indicating capture has failed.
    ///
    /// Deliberately ignores `soundOption`, including `.silent`. The start/stop chimes are
    /// feedback for an action the user just took and are reasonably suppressed — meetings
    /// suppress them on purpose. This is not feedback; it is the only audible signal that the
    /// recording they walked away from is capturing nothing. A user who silenced the chimes has
    /// not asked to be kept in the dark about a failure.
    func playErrorSound() {
        if errorSoundID != 0 {
            AudioServicesPlaySystemSound(errorSoundID)
        } else {
            AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert)
        }
    }

    /// Play a gentle sound indicating recording has stopped
    func playStopSound() {
        switch soundOption {
        case .defaultSounds:
            if stopSoundID != 0 {
                AudioServicesPlaySystemSound(stopSoundID)
            } else {
                AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert)
            }
        case .subtle:
            if subtleStopSoundID != 0 {
                AudioServicesPlaySystemSound(subtleStopSoundID)
            }
        case .silent:
            break
        }
    }
}
