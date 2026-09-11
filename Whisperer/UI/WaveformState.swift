//
//  WaveformState.swift
//  Whisperer
//
//  Isolated observable for waveform amplitudes — decoupled from AppState
//  so amplitude updates only invalidate WaveformView, not every AppState observer.
//
//  Timer-driven at 60Hz: audio tap pushes amplitude to instance vars (main thread);
//  displayTimer reads on each tick — consistent rate, no async-queue jitter.
//  CADisplayLink is not available on macOS; CVDisplayLink would work but Timer is simpler
//  and sufficient for a 20-bar waveform.
//

import Combine
import QuartzCore
import SwiftUI

@MainActor
final class WaveformState: ObservableObject {
    @Published var amplitudes: [Float] = Array(repeating: 0, count: 20)

    private var lastAmplitude: Float = 0
    private var isMuted: Bool = false
    private var isPaused: Bool = false

    private var displayTimer: Timer?

    /// Reference count of active renderers. Timer runs iff count > 0.
    /// Fail-safe: an unregistered renderer wastes energy (timer keeps running) but never
    /// produces a frozen UI (which is the worse outcome).
    private var rendererCount: Int = 0

    // MARK: - Public API

    /// Store latest amplitude from onAmplitudeUpdate (main thread). Timer reads on next tick.
    func push(amplitude: Float, isMuted: Bool, isPaused: Bool) {
        lastAmplitude = amplitude
        self.isMuted = isMuted
        self.isPaused = isPaused
    }

    /// Register a renderer. Starts the 60 Hz timer when the first renderer attaches.
    /// Call from `.onAppear` in every view that reads `amplitudes`.
    func addRenderer() {
        rendererCount += 1
        if rendererCount == 1 { startDisplayLink() }
    }

    /// Deregister a renderer. Stops the timer when the last renderer detaches.
    /// Call from `.onDisappear` in every view that reads `amplitudes`.
    func removeRenderer() {
        rendererCount = max(0, rendererCount - 1)
        if rendererCount == 0 { stopDisplayLink() }
    }

    /// Zero the stored amplitudes without touching the timer or renderer count.
    /// Use instead of `stopDisplayLink()` when recording ends but a renderer may still be attached.
    func resetAmplitudes() {
        amplitudes = Array(repeating: 0, count: 20)
        lastAmplitude = 0
    }

    /// Start 60Hz updates directly. Used by IslandLevelBridge for its own WaveformState instance
    /// (separate from the renderer-counted AppState.waveformState path).
    func startDisplayLink() {
        guard displayTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        displayTimer = t
    }

    /// Stop updates and silence waveform. Does not touch `rendererCount` — prefer
    /// `removeRenderer()` for renderer-driven teardown, and `resetAmplitudes()` when a renderer
    /// is still attached and only the data should be cleared.
    func stopDisplayLink() {
        displayTimer?.invalidate()
        displayTimer = nil
        amplitudes = Array(repeating: 0, count: 20)
        lastAmplitude = 0
    }

    /// Update the mute / pause gates without touching the stored amplitude. Callers that learn
    /// about these flags on a different cadence than audio arrives must use this — pushing a
    /// placeholder amplitude alongside them flatlines the waveform between real samples.
    func setGating(isMuted: Bool, isPaused: Bool) {
        self.isMuted = isMuted
        self.isPaused = isPaused
    }

    /// Stop updates but leave the bars where they are. Used when a recording is paused, so the
    /// waveform holds its last shape instead of collapsing to a flat line.
    func freezeDisplayLink() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    /// Backward-compatible entry point — routes through push(); timer drives timing.
    func update(amplitude: Float, isMuted: Bool, isPaused: Bool) {
        push(amplitude: amplitude, isMuted: isMuted, isPaused: isPaused)
    }

    func reset() {
        amplitudes = Array(repeating: 0, count: 20)
        lastAmplitude = 0
    }

    // MARK: - Private

    private func tick() {
        amplitudes.removeFirst()
        amplitudes.append((isMuted || isPaused) ? 0 : lastAmplitude)
    }
}
