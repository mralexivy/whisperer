//
//  IslandLevelBridge.swift
//  Whisperer
//
//  Adapter between IslandCoordinator's lifecycle calls and the HUD's WaveformState.
//
//  Performance tiers:
//   - .peek     → no 60 Hz waveform timer; only peekLevel (≤12 Hz) drives the nub glow.
//   - .compact / .expanded → full 60 Hz WaveformState timer for smooth waveform bars.
//
//  peekLevel is updated at most 12× per second via a timestamp gate inside push(rms:).
//  The gate costs nothing when peeking — no extra timer, no main-thread spin.
//

import Combine
import Foundation

@MainActor
final class IslandLevelBridge: ObservableObject {

    /// The shared HUD waveform model. Hand this straight to `WaveformView`.
    let waveform = WaveformState()

    /// Smoothed RMS for the peek nub glow. Updated at ≤12 Hz to minimise
    /// SwiftUI invalidations while the full waveform timer is stopped.
    @Published private(set) var peekLevel: Float = 0

    private var isMuted:  Bool = false
    private var isPaused: Bool = false

    /// Timestamp of the last peekLevel publish, for 12 Hz gate.
    private var lastPeekPublish: CFAbsoluteTime = 0
    private let peekPublishInterval: CFAbsoluteTime = 1.0 / 12.0

    // MARK: - Public API (called by IslandCoordinator)

    /// Receive latest linear RMS from AudioRecorder.onAmplitudeUpdate (already on main).
    func push(rms: Float) {
        waveform.push(amplitude: rms, isMuted: isMuted, isPaused: isPaused)

        // Update peekLevel at most 12 Hz (smoothed with a simple one-pole IIR).
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastPeekPublish >= peekPublishInterval {
            lastPeekPublish = now
            let target: Float = (isMuted || isPaused) ? 0 : rms
            peekLevel = peekLevel * 0.4 + target * 0.6   // fast-attack, medium-decay
        }
    }

    /// Start or resume the 60 Hz display timer. Call when the row is visible (compact/expanded).
    func startTimer() {
        waveform.startDisplayLink()
    }

    /// Stop the timer. `freezeAtCurrent` holds the last bars in place (pause); otherwise
    /// the waveform is zeroed (recording ended or retreated to peek).
    func stopTimer(freezeAtCurrent: Bool = false) {
        if freezeAtCurrent {
            waveform.freezeDisplayLink()
        } else {
            waveform.stopDisplayLink()
        }
    }

    /// Update mute/pause state so bars reflect them on the next tick.
    ///
    /// Deliberately does NOT push an amplitude. `IslandCoordinator.syncFromAppState` calls this
    /// on every `AppState.objectWillChange`, which is far more often than audio arrives — pushing
    /// a placeholder amplitude alongside them flatlines the waveform between real samples.
    func setState(isMuted: Bool, isPaused: Bool) {
        self.isMuted  = isMuted
        self.isPaused = isPaused
        waveform.setGating(isMuted: isMuted, isPaused: isPaused)
        // Silence the peek glow immediately on mute/pause.
        if isMuted || isPaused {
            peekLevel = peekLevel * 0.3   // rapid decay toward zero
        }
    }
}
