//
//  WaveformGenerator.swift
//  Whisperer
//
//  Generate waveform visualization data from audio files using chunked reads.
//  Reads the file in small windows at evenly spaced positions — never loads the
//  entire file into memory, so long meeting recordings (40-60 min) are handled
//  without risk of OOM failure.
//

import Foundation
import AVFoundation
import Accelerate

struct WaveformGenerator {
    /// Generate waveform samples from audio file.
    /// Returns array of normalized amplitudes (0.0 to 1.0).
    /// Uses chunked reads — safe for files of any length.
    static func generateWaveform(from url: URL, sampleCount: Int = 100) -> [Float] {
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            return Array(repeating: 0.15, count: sampleCount)
        }

        let totalFrames = audioFile.length
        guard totalFrames > 0 else {
            return Array(repeating: 0.15, count: sampleCount)
        }

        let format = audioFile.processingFormat
        // Read ~1024 frames per bin — enough for a good RMS estimate, tiny in memory
        let chunkSize = AVAudioFrameCount(1024)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
            return Array(repeating: 0.15, count: sampleCount)
        }

        var waveform = [Float](repeating: 0, count: sampleCount)

        for binIndex in 0..<sampleCount {
            // Seek to the center frame of each bin
            let binCenterFrame = AVAudioFramePosition(
                Int64(totalFrames) * Int64(binIndex) / Int64(sampleCount) +
                Int64(totalFrames) / Int64(sampleCount * 2)
            )
            let seekFrame = max(0, min(binCenterFrame, totalFrames - 1))
            audioFile.framePosition = seekFrame

            buffer.frameLength = 0
            guard (try? audioFile.read(into: buffer, frameCount: chunkSize)) != nil,
                  buffer.frameLength > 0,
                  let channelData = buffer.floatChannelData?[0] else {
                continue
            }

            let samples = UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength))
            var rms: Float = 0
            vDSP_measqv(samples.baseAddress!, 1, &rms, vDSP_Length(samples.count))
            waveform[binIndex] = sqrt(rms)
        }

        // Normalize to 0.0...1.0 with a minimum floor so flat-silence recordings
        // still render visible bars instead of nothing
        let peak = waveform.max() ?? 0
        if peak > 0 {
            let scale = 1.0 / peak
            waveform = waveform.map { max(0.05, $0 * scale) }
        } else {
            waveform = Array(repeating: 0.15, count: sampleCount)
        }

        return waveform
    }
}
