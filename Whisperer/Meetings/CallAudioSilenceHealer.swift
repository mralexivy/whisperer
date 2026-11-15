//
//  CallAudioSilenceHealer.swift
//  Whisperer
//
//  Decides when a silent call-audio tap should be rebuilt, and when to say why it is silent.
//
//  The tap that records the other side of a call can deliver exact zeros while the call is perfectly audible — a
//  stale process list, an aggregate device built before the output switched profile, a helper the tap does not
//  include. On 2026-11-15 a customer's Slack Huddle on AirPods was recorded with the far end silent for the whole
//  ten minutes and nothing tried to recover: the transcript had one speaker because there was only one voice in the
//  recording. This is the policy that now keeps trying, and logs what it found.
//
//  Pure: the controller feeds it the tap's counters and whether the call is live, and does what it says.
//

import Foundation

nonisolated struct CallAudioSilenceHealer: Equatable, Sendable {

    enum Action: Equatable, Sendable {
        case none
        /// Tear the tap down and build it again on the current output device and process list.
        case rebuild(attempt: Int)
        /// Still silent: write down which processes exist and which are playing.
        case diagnose
        /// Sound arrived after silence; `afterRebuilds` says whether a rebuild is what fixed it.
        case recovered(silentFor: TimeInterval, afterRebuilds: Int)
    }

    /// How long a live call may be silent before the first rebuild, and between later ones.
    static let firstRebuildAfter: TimeInterval = 20
    static let laterRebuildEvery: TimeInterval = 40
    static let maxRebuilds = 6
    static let diagnoseAfter: TimeInterval = 30

    private var lastSoundAt: Date
    private var lastPeak: Float = 0
    private var lastActionAt: Date
    private(set) var rebuilds = 0
    private var diagnosed = false
    private var wasSilent = false

    init(startedAt: Date) {
        lastSoundAt = startedAt
        lastActionAt = startedAt
    }

    /// - Parameters:
    ///   - peak: the mixer's running peak (0 until anything but zeros has arrived).
    ///   - callIsLive: the call app is using the microphone — someone is expected to be talking to us.
    mutating func evaluate(now: Date, peak: Float, callIsLive: Bool) -> Action {
        if peak > lastPeak {
            let silentFor = now.timeIntervalSince(lastSoundAt)
            let wasHealing = wasSilent && silentFor >= Self.firstRebuildAfter
            lastPeak = peak
            lastSoundAt = now
            let rebuildsSoFar = rebuilds
            if wasHealing {
                wasSilent = false
                rebuilds = 0
                diagnosed = false
                return .recovered(silentFor: silentFor, afterRebuilds: rebuildsSoFar)
            }
            return .none
        }
        guard callIsLive else {
            // Nobody is on the call: silence is expected, and a rebuild would only add a glitch. Restart the clock
            // so the first minutes of a call are not charged for the time before it began.
            lastSoundAt = max(lastSoundAt, now)
            return .none
        }
        let silentFor = now.timeIntervalSince(lastSoundAt)
        wasSilent = silentFor >= Self.firstRebuildAfter

        let sinceAction = now.timeIntervalSince(lastActionAt)
        let due = rebuilds == 0 ? silentFor >= Self.firstRebuildAfter : sinceAction >= Self.laterRebuildEvery
        if due, rebuilds < Self.maxRebuilds, silentFor >= Self.firstRebuildAfter {
            rebuilds += 1
            lastActionAt = now
            return .rebuild(attempt: rebuilds)
        }
        if !diagnosed, silentFor >= Self.diagnoseAfter {
            diagnosed = true
            return .diagnose
        }
        return .none
    }
}
