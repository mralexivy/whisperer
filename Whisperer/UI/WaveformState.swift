//
//  WaveformState.swift
//  Whisperer
//
//  Isolated observable for waveform amplitudes — decoupled from AppState
//  so amplitude updates (~8Hz) only invalidate WaveformView, not every AppState observer.
//

import Combine
import QuartzCore
import SwiftUI

@MainActor
final class WaveformState: ObservableObject {
    @Published var amplitudes: [Float] = Array(repeating: 0, count: 20)

    private var lastUpdateTime: Double = 0
    // 16Hz — smooth scrolling waveform without over-rendering; WaveformState isolation
    // already limits re-renders to WaveformView only, so we don't need aggressive throttling.
    private let updateInterval: Double = 1.0 / 16.0

    func update(amplitude: Float, isMuted: Bool, isPaused: Bool) {
        let now = CACurrentMediaTime()
        guard now - lastUpdateTime >= updateInterval else { return }
        lastUpdateTime = now

        amplitudes.removeFirst()
        amplitudes.append((isMuted || isPaused) ? 0 : amplitude)
    }

    func reset() {
        amplitudes = Array(repeating: 0, count: 20)
    }
}
