//
//  WaveformGenerator.swift
//  Whisperer
//
//  Generate waveform visualization data from audio files
//

import Foundation
import AVFoundation
import Accelerate

struct WaveformGenerator {
    /// Generate waveform samples from audio file
    /// Returns array of normalized amplitudes (0.0 to 1.0)
    static func generateWaveform(from url: URL, sampleCount: Int = 100) -> [Float] {
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            return Array(repeating: 0, count: sampleCount)
        }

        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return Array(repeating: 0, count: sampleCount)
        }

        do {
            try audioFile.read(into: buffer)
        } catch {
            Logger.error("Failed to read audio file: \(error)", subsystem: .app)
            return Array(repeating: 0, count: sampleCount)
        }

        guard let channelData = buffer.floatChannelData?[0] else {
            return Array(repeating: 0, count: sampleCount)
        }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))

        // Downsample to requested sample count
        let samplesPerBin = samples.count / sampleCount
        var waveform: [Float] = []

        for i in 0..<sampleCount {
            let start = i * samplesPerBin
            let end = min(start + samplesPerBin, samples.count)

            if start < samples.count {
                let slice = Array(samples[start..<end])
                let rms = calculateRMS(slice)
                waveform.append(rms)
            } else {
                waveform.append(0)
            }
        }

        // Normalize to 0.0...1.0
        if let maxValue = waveform.max(), maxValue > 0 {
            waveform = waveform.map { $0 / maxValue }
        }

        return waveform
    }

    private static func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        var rms: Float = 0
        vDSP_measqv(samples, 1, &rms, vDSP_Length(samples.count))
        return sqrt(rms)
    }
}
