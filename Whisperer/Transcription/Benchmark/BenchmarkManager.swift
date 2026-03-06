//
//  BenchmarkManager.swift
//  Whisperer
//
//  Utilities for transcription performance benchmarking (used by XCTest performance tests)
//

import Foundation
import Accelerate
import AVFoundation

enum BenchmarkUtilities {

    // MARK: - Memory Measurement

    static func currentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576.0
    }

    // MARK: - Synthetic Audio Generation

    /// Generate synthetic audio with speech-like frequency content for reproducible benchmarks.
    /// Uses a combination of formant frequencies modulated to mimic speech patterns.
    static func generateTestAudio(duration: BenchmarkDuration) -> [Float] {
        let sampleRate: Double = 16000.0
        let totalSamples = duration.sampleCount
        var samples = [Float](repeating: 0, count: totalSamples)

        // Speech-like frequencies (formants: F1~500Hz, F2~1500Hz, F3~2500Hz)
        let frequencies: [(freq: Double, amp: Float)] = [
            (250.0, 0.3),
            (500.0, 0.25),
            (1000.0, 0.15),
            (1500.0, 0.1),
            (2500.0, 0.05),
        ]

        for i in 0..<totalSamples {
            let t = Double(i) / sampleRate
            var sample: Float = 0

            // Amplitude modulation at ~4Hz (syllable rate)
            let envelope = Float(0.5 + 0.5 * sin(2.0 * .pi * 4.0 * t))

            for (freq, amp) in frequencies {
                let wobble = 1.0 + 0.02 * sin(2.0 * .pi * 0.5 * t)
                sample += amp * Float(sin(2.0 * .pi * freq * wobble * t))
            }

            samples[i] = sample * envelope * 0.3
        }

        // Add light noise
        var noise = [Float](repeating: 0, count: totalSamples)
        for i in 0..<totalSamples {
            noise[i] = Float.random(in: -0.02...0.02)
        }
        vDSP_vadd(samples, 1, noise, 1, &samples, 1, vDSP_Length(totalSamples))

        return samples
    }

    // MARK: - WAV File Loading

    /// Load Float32 samples from a WAV recording file
    static func loadSamplesFromRecording(at url: URL) -> [Float]? {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let frameCount = AVAudioFrameCount(audioFile.length)
            guard frameCount > 0 else { return nil }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
                return nil
            }
            try audioFile.read(into: buffer)

            guard let channelData = buffer.floatChannelData else { return nil }
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
            return samples
        } catch {
            Logger.error("Failed to load recording: \(error)", subsystem: .transcription)
            return nil
        }
    }

    // MARK: - Formatting

    static func formattedLatency(_ ms: Double) -> String {
        if ms < 1000 {
            return String(format: "%.0fms", ms)
        } else {
            return String(format: "%.1fs", ms / 1000.0)
        }
    }

    static func formattedRTF(_ rtf: Double) -> String {
        String(format: "%.2fx", rtf)
    }

    static func formattedMemory(_ mb: Double) -> String {
        if abs(mb) < 1 {
            return String(format: "%.1f MB", mb)
        } else {
            return String(format: "%.0f MB", mb)
        }
    }
}
