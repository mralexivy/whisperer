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
    // 8Hz is perceptually smooth for waveform animation while halving update cost vs 16Hz
    private let updateInterval: Double = 1.0 / 8.0

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
