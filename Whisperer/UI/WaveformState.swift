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

    // MARK: - Public API

    /// Store latest amplitude from onAmplitudeUpdate (main thread). Timer reads on next tick.
    func push(amplitude: Float, isMuted: Bool, isPaused: Bool) {
        lastAmplitude = amplitude
        self.isMuted = isMuted
        self.isPaused = isPaused
    }

    /// Start 60Hz updates. Call when recording begins.
    func startDisplayLink() {
        guard displayTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        displayTimer = t
    }

    /// Stop updates and silence waveform. Call when recording ends.
    func stopDisplayLink() {
        displayTimer?.invalidate()
        displayTimer = nil
        amplitudes = Array(repeating: 0, count: 20)
        lastAmplitude = 0
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
