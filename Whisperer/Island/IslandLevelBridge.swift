//
//  IslandLevelBridge.swift
//  Whisperer
//
//  Adapter between IslandCoordinator's lifecycle calls and the HUD's WaveformState.
//
//  The Island used to run its own 30 fps, dBFS-normalized, one-pole-smoothed bar stream.
//  Against the HUD's 60 fps raw-amplitude scroll it read as sluggish and mushy — the same
//  audio, visibly worse. There is no reason for two visualizers: this class now owns a
//  WaveformState and the Island renders the same WaveformView the HUD does, so speed,
//  curve, spacing and color are identical by construction rather than by coincidence.
//
//  Pipeline:
//    AudioRecorder.onAmplitudeUpdate (linear RMS, main thread, ~100 Hz)
//      → push(rms:)                → WaveformState.push
//      → WaveformState 60 Hz tick  → shifts the 20-bar window left, newest on the right
//      → WaveformView              → SwiftUI bars
//
//  The timer is stopped entirely when the Island is hidden or stopped — no idle timers.
//

import Combine
import Foundation

@MainActor
final class IslandLevelBridge: ObservableObject {

    /// The shared HUD waveform model. Hand this straight to `WaveformView`.
    let waveform = WaveformState()

    private var isMuted:  Bool = false
    private var isPaused: Bool = false

    // MARK: - Public API (called by IslandCoordinator)

    /// Receive latest linear RMS from AudioRecorder.onAmplitudeUpdate (already on main).
    func push(rms: Float) {
        waveform.push(amplitude: rms, isMuted: isMuted, isPaused: isPaused)
    }

    /// Start or resume the display timer. Call when Island becomes visible and recording.
    func startTimer() {
        waveform.startDisplayLink()
    }

    /// Stop the timer. `freezeAtCurrent` holds the last bars in place (pause); otherwise the
    /// waveform is zeroed (recording ended).
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
    /// a zero here overwrites the last real RMS between callbacks and flatlines the waveform.
    func setState(isMuted: Bool, isPaused: Bool) {
        self.isMuted  = isMuted
        self.isPaused = isPaused
        waveform.setGating(isMuted: isMuted, isPaused: isPaused)
    }
}
