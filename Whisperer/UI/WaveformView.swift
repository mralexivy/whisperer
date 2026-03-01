//
//  WaveformView.swift
//  Whisperer
//
//  Live waveform visualization - FaceTime style
//

import SwiftUI

struct WaveformView: View {
    let amplitudes: [Float]
    private let barCount = 20
    private let barSpacing: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    let amplitude = index < amplitudes.count ? amplitudes[index] : 0
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(red: 0.357, green: 0.424, blue: 0.969)) // #5B6CF7 blue accent
                        .frame(
                            width: barWidth(for: geometry.size.width),
                            height: barHeight(
                                for: amplitude,
                                maxHeight: geometry.size.height
                            )
                        )
                        .animation(.easeOut(duration: 0.08), value: amplitude)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .accessibilityLabel("Audio waveform")
        .accessibilityValue("Recording level visualization")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func barWidth(for totalWidth: CGFloat) -> CGFloat {
        let totalSpacing = barSpacing * CGFloat(barCount - 1)
        return max((totalWidth - totalSpacing) / CGFloat(barCount), 2)
    }

    private func barHeight(for amplitude: Float, maxHeight: CGFloat) -> CGFloat {
        let minHeight: CGFloat = 3
        let normalizedAmplitude = CGFloat(min(max(amplitude, 0), 1))
        // Perceptual power curve — boosts quiet speech visibility
        // (e.g., 0.05 → 0.27, 0.1 → 0.40, 0.8 → 0.88)
        let curved = pow(normalizedAmplitude, 0.4)
        return minHeight + (curved * (maxHeight - minHeight))
    }
}

#Preview {
    WaveformView(amplitudes: [0.2, 0.5, 0.8, 0.6, 0.3, 0.7, 0.9, 0.4, 0.5, 0.6])
        .frame(width: 100, height: 30)
        .padding()
        .background(Color(red: 0.078, green: 0.078, blue: 0.169))
}
