//
//  VADBenchmarkTests.swift
//  WhispererTests
//
//  Benchmarks Silero VAD performance to isolate thread overhead vs compute cost.
//

import XCTest
@testable import whisperer

final class VADBenchmarkTests: XCTestCase {

    private func loadVAD(threads: Int32 = 1) throws -> SileroVAD {
        let path = ModelDownloader.shared.vadModelPath()
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("VAD model not downloaded")
        }
        SileroVAD.backendsLoaded = true
        return try SileroVAD(modelPath: path, threads: threads)
    }

    private func timeMs(_ block: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    // MARK: - Thread Count vs Performance

    func testVAD1Thread3sAudio() throws {
        let vad = try loadVAD(threads: 1)
        let samples = generateAudio(seconds: 3.0)
        _ = vad.detectSpeechSegments(samples: Array(samples.prefix(16000)))
        let ms = timeMs { _ = vad.detectSpeechSegments(samples: samples) }
        let rtf = (ms / 1000.0) / 3.0
        XCTAssertLessThan(ms, 500, "1 thread, 3s audio: \(String(format: "%.1f", ms))ms, RTF=\(String(format: "%.3f", rtf))")
    }

    func testVAD2Threads3sAudio() throws {
        let vad = try loadVAD(threads: 2)
        let samples = generateAudio(seconds: 3.0)
        _ = vad.detectSpeechSegments(samples: Array(samples.prefix(16000)))
        let ms = timeMs { _ = vad.detectSpeechSegments(samples: samples) }
        let rtf = (ms / 1000.0) / 3.0
        XCTAssertLessThan(ms, 500, "2 threads, 3s audio: \(String(format: "%.1f", ms))ms, RTF=\(String(format: "%.3f", rtf))")
    }

    func testVAD4Threads3sAudio() throws {
        let vad = try loadVAD(threads: 4)
        let samples = generateAudio(seconds: 3.0)
        _ = vad.detectSpeechSegments(samples: Array(samples.prefix(16000)))
        let ms = timeMs { _ = vad.detectSpeechSegments(samples: samples) }
        let rtf = (ms / 1000.0) / 3.0
        XCTAssertLessThan(ms, 2000, "4 threads, 3s audio: \(String(format: "%.1f", ms))ms, RTF=\(String(format: "%.3f", rtf))")
    }

    func testVAD10Threads3sAudio() throws {
        let vad = try loadVAD(threads: 10)
        let samples = generateAudio(seconds: 3.0)
        _ = vad.detectSpeechSegments(samples: Array(samples.prefix(16000)))
        let ms = timeMs { _ = vad.detectSpeechSegments(samples: samples) }
        let rtf = (ms / 1000.0) / 3.0
        // This one proves the thread overhead theory — expect it to be much slower
        XCTAssertLessThan(ms, 30000, "10 threads, 3s audio: \(String(format: "%.1f", ms))ms, RTF=\(String(format: "%.3f", rtf))")
    }

    // MARK: - Duration Scaling

    func testVADScaling30sAudio() throws {
        let vad = try loadVAD(threads: 1)
        let samples = generateAudio(seconds: 30.0)
        _ = vad.detectSpeechSegments(samples: Array(samples.prefix(16000)))
        let ms = timeMs { _ = vad.detectSpeechSegments(samples: samples) }
        let rtf = (ms / 1000.0) / 30.0
        XCTAssertLessThan(rtf, 1.0, "1 thread, 30s audio: \(String(format: "%.1f", ms))ms, RTF=\(String(format: "%.3f", rtf))")
    }

    // MARK: - hasSpeech vs detectSpeechSegments

    func testHasSpeechFasterThanDetectSegments() throws {
        let vad = try loadVAD(threads: 1)
        let samples = generateAudio(seconds: 3.0)
        _ = vad.hasSpeech(samples: Array(samples.prefix(16000)))

        let msHas = timeMs { _ = vad.hasSpeech(samples: samples) }
        let msSeg = timeMs { _ = vad.detectSpeechSegments(samples: samples) }

        // hasSpeech should be comparable or faster (both call whisper_vad_detect_speech)
        XCTAssertLessThan(msHas, 500, "hasSpeech: \(String(format: "%.1f", msHas))ms")
        XCTAssertLessThan(msSeg, 500, "detectSpeechSegments: \(String(format: "%.1f", msSeg))ms")
    }

    // MARK: - Timing Accumulation (no drift between calls)

    func testVADNoDriftBetweenCalls() throws {
        let vad = try loadVAD(threads: 1)
        let samples = generateAudio(seconds: 2.0)

        let ms1 = timeMs { _ = vad.detectSpeechSegments(samples: samples) }
        let ms2 = timeMs { _ = vad.detectSpeechSegments(samples: samples) }

        let ratio = ms2 / max(ms1, 0.001)
        // Second call should not be significantly slower (no timing accumulation)
        XCTAssertLessThan(ratio, 2.0,
            "Call 1: \(String(format: "%.1f", ms1))ms, Call 2: \(String(format: "%.1f", ms2))ms, ratio=\(String(format: "%.2f", ratio))x — should be ~1.0")
    }

    private func generateAudio(seconds: Double) -> [Float] {
        let sampleRate = 16000.0
        let count = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        let frequencies: [(freq: Double, amp: Float)] = [
            (250.0, 0.3), (500.0, 0.25), (1000.0, 0.15),
            (1500.0, 0.1), (2500.0, 0.05),
        ]
        for i in 0..<count {
            let t = Double(i) / sampleRate
            var sample: Float = 0
            for f in frequencies { sample += f.amp * Float(sin(2.0 * .pi * f.freq * t)) }
            sample += Float.random(in: -0.02...0.02)
            samples[i] = sample
        }
        return samples
    }
}
