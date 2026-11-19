//
//  InputRouteQuarantine.swift
//  Whisperer
//
//  Remembers which input devices recently delivered nothing but silence, so the *next*
//  recording starts on a working microphone instead of rediscovering the dead one.
//
//  2026-11-19: AirPods were the default input, their call-mode link never woke, and a
//  dictation was spent finding that out. The recovery moved to the built-in microphone, but
//  the following key press would have gone straight back to the AirPods and paid the same
//  price again. A device that just proved it is dead is not retried for a while; it is
//  forgiven when it disconnects (a reconnect renegotiates the link) or after `ttl`.
//
//  Thread-safe and clock-injectable so the policy is unit-testable without hardware.
//

import CoreAudio
import Foundation

nonisolated final class InputRouteQuarantine: @unchecked Sendable {
    static let shared = InputRouteQuarantine()

    /// Long enough to cover a work session of dictations, short enough that a headset that
    /// was merely asleep gets another chance.
    static let defaultTTL: TimeInterval = 10 * 60

    private let lock = NSLock()
    private var entries: [String: Date] = [:]
    private let ttl: TimeInterval
    private let now: () -> Date

    init(ttl: TimeInterval = InputRouteQuarantine.defaultTTL, now: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.now = now
    }

    func markSuspect(uid: String) {
        lock.lock(); defer { lock.unlock() }
        entries[uid] = now()
    }

    func isSuspect(uid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let since = entries[uid] else { return false }
        if now().timeIntervalSince(since) > ttl {
            entries[uid] = nil
            return false
        }
        return true
    }

    func clear(uid: String) {
        lock.lock(); defer { lock.unlock() }
        entries[uid] = nil
    }

    /// Forget every device that is no longer present: unplugging or reconnecting renegotiates
    /// the link, so the old verdict no longer applies.
    func forgetDevices(notIn presentUIDs: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { presentUIDs.contains($0.key) }
    }
}

/// Preference order for recovery candidates: the built-in microphone is always present and
/// always awake, wireless links are the likeliest thing to be asleep.
nonisolated enum InputTransportRank {
    static func rank(transport: UInt32) -> Int {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return 0
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return 2
        default:
            return 1
        }
    }

    static func isWireless(transport: UInt32) -> Bool { rank(transport: transport) == 2 }
}

extension InputRouteQuarantine {
    /// Whether `deviceID` is a Bluetooth or Continuity input.
    static func isWirelessInput(_ deviceID: AudioDeviceID) -> Bool {
        InputTransportRank.isWireless(transport: InputRoutePreflight.transportType(deviceID))
    }
}
