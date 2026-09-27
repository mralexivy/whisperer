//
//  MeetingDiarizerIntegrationTests.swift
//  WhispererTests
//
//  Integration tests for the Nemotron-3-Diarization-100M CoreML diarizer.
//
//  These tests require the model to be cached on disk. They are skipped in CI
//  (or any machine without the bundle) via `XCTSkipUnless(MeetingDiarizerService.isModelCached())`.
//
//  Run with:
//    xcodebuild test -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
//      -destination "platform=macOS" \
//      -only-testing:WhispererTests/MeetingDiarizerIntegrationTests
//

import XCTest
import AVFoundation
@testable import whisperer

#if canImport(FluidAudio)
import FluidAudio

final class MeetingDiarizerIntegrationTests: XCTestCase {

    // MARK: - Setup

    private static let sampleRate: Double = 16_000
    private static let turnSeconds: Double = 4.0
    private static let pitchFactor: Float = 0.80   // ≈ 3 semitones lower — enough to shift embeddings

    // MARK: - Helpers

    /// Read `test-sentences-en.wav` from the test bundle and return 16 kHz mono floats.
    private func loadFixtureAudio() throws -> [Float] {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "test-sentences-en", withExtension: "wav") else {
            // Try the TestData subdirectory path used when the file group is synced
            let direct = URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("TestData/test-sentences-en.wav")
            if FileManager.default.fileExists(atPath: direct.path) {
                return try Self.readPCM(url: direct)
            }
            throw XCTSkip("test-sentences-en.wav not found in test bundle")
        }
        return try Self.readPCM(url: url)
    }

    private static func readPCM(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: 1, interleaved: false)!
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Re-read with conversion if needed
        let srcFormat = file.processingFormat
        if srcFormat == format {
            try file.read(into: buffer)
        } else {
            let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount)!
            try file.read(into: srcBuf)
            guard let converter = AVAudioConverter(from: srcFormat, to: format),
                  let dst = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var error: NSError?
            var inputDone = false
            converter.convert(to: dst, error: &error) { _, status in
                if inputDone { status.pointee = .noDataNow; return nil }
                status.pointee = .haveData
                inputDone = true
                return srcBuf
            }
            if let e = error { throw e }
            let ptr = dst.floatChannelData![0]
            return Array(UnsafeBufferPointer(start: ptr, count: Int(dst.frameLength)))
        }
        let ptr = buffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: ptr, count: Int(buffer.frameLength)))
    }

    /// Pitch-shift audio by resampling (time-domain, no phase vocoder needed at this precision).
    ///
    /// Resampling at `factor` compresses the waveform so played-back at the original rate it sounds
    /// higher (factor > 1) or lower (factor < 1). At 0.8× the voiced-formant pattern shifts ~3
    /// semitones — sufficient to cluster as a different speaker in Nemotron-3's embedding space.
    private static func pitchShift(_ samples: [Float], factor: Float) -> [Float] {
        let srcCount = samples.count
        let dstCount = Int(Float(srcCount) * factor)
        guard dstCount > 0 else { return [] }
        var result = [Float](repeating: 0, count: dstCount)
        let ratio = Float(srcCount - 1) / max(Float(dstCount - 1), 1)
        for i in 0..<dstCount {
            let src = Float(i) * ratio
            let lo = Int(src)
            let hi = min(lo + 1, srcCount - 1)
            let frac = src - Float(lo)
            result[i] = samples[lo] * (1 - frac) + samples[hi] * frac
        }
        return result
    }

    /// Build a 2-speaker fixture: A, B, A, B — each `turnSeconds` long.
    ///
    /// Returns (audio, boundaries) where boundaries[i] is the start time in seconds of turn i.
    private static func buildTwoSpeakerFixture(
        speaker: [Float], turnSamples: Int
    ) -> (audio: [Float], boundaries: [Double]) {
        let speakerA = Array(speaker.prefix(turnSamples))
            + [Float](repeating: 0, count: max(0, turnSamples - speaker.count))
        let speakerB = pitchShift(speakerA, factor: pitchFactor)
            .prefix(turnSamples) + [Float]()
        let paddedB = Array(speakerB.prefix(turnSamples))
            + [Float](repeating: 0, count: max(0, turnSamples - speakerB.count))

        let audio = speakerA + paddedB + speakerA + paddedB
        let dt = Double(turnSamples) / sampleRate
        return (audio, [0, dt, 2 * dt, 3 * dt])
    }

    // MARK: - Test: processComplete path

    func testProcessCompleteFrameCountAndTwoSpeakers() async throws {
        try XCTSkipUnless(MeetingDiarizerService.isModelCached(),
                          "Nemotron-3 model not cached on this machine — skipping")

        let root = MeetingDiarizerService.modelsRoot()
        let config = MeetingDiarizerService.config
        let models = try await Nemotron3Models.loadFromHuggingFace(
            config: config, cacheDirectory: root)

        let diarizer = Nemotron3Diarizer(config: config, models: models)

        let fixture = try loadFixtureAudio()
        let turnSamples = Int(Self.turnSeconds * Self.sampleRate)
        let (audio, boundaries) = Self.buildTwoSpeakerFixture(
            speaker: fixture, turnSamples: turnSamples)

        let (probabilities, frameCount) = try diarizer.processComplete(audio)

        // frameCount must be consistent with audio duration at 10 ms per frame
        let expectedMinFrames = Int(Double(audio.count) / Self.sampleRate / 0.01) - 2
        let expectedMaxFrames = Int(Double(audio.count) / Self.sampleRate / 0.01) + 2
        XCTAssertGreaterThanOrEqual(frameCount, expectedMinFrames,
            "frameCount \(frameCount) too small for \(audio.count) samples")
        XCTAssertLessThanOrEqual(frameCount, expectedMaxFrames,
            "frameCount \(frameCount) too large for \(audio.count) samples")
        XCTAssertEqual(probabilities.count, frameCount * config.numSpeakers,
            "probabilities array size mismatch")

        // Must see at least 2 distinct active speakers
        let segments = Nemotron3Diarizer.segments(probabilities: probabilities, frameCount: frameCount)
        let activeSpeakers = Set(segments.map(\.speakerIndex))
        XCTAssertGreaterThanOrEqual(activeSpeakers.count, 2,
            "Expected ≥2 distinct speakers, got \(activeSpeakers.count) in \(segments.count) segments")

        // Each known turn window should be dominated by a single consistent speaker
        // and adjacent turns must differ.
        let dt = Self.turnSeconds
        let turnSpeakers: [Int?] = boundaries.map { start in
            let mid = start + dt * 0.3
            let end = start + dt * 0.7
            // speaker with most time in the middle of this turn
            var totals: [Int: Float] = [:]
            for seg in segments {
                let lo = max(Float(mid), seg.startSeconds)
                let hi = min(Float(end), seg.endSeconds)
                if hi > lo { totals[seg.speakerIndex, default: 0] += hi - lo }
            }
            return totals.max(by: { $0.value < $1.value })?.key
        }

        for (i, spk) in turnSpeakers.enumerated() {
            XCTAssertNotNil(spk, "Turn \(i) has no dominant speaker")
        }
        // Turns A-B-A-B: adjacent turns must differ, turns 0 and 2 should match
        if let s0 = turnSpeakers[0], let s1 = turnSpeakers[1] {
            XCTAssertNotEqual(s0, s1, "Turns 0 and 1 should be different speakers")
        }
        if let s2 = turnSpeakers[2], let s3 = turnSpeakers[3] {
            XCTAssertNotEqual(s2, s3, "Turns 2 and 3 should be different speakers")
        }
        if let s0 = turnSpeakers[0], let s2 = turnSpeakers[2] {
            XCTAssertEqual(s0, s2, "Turns 0 and 2 should be the same speaker (A-B-A-B pattern)")
        }

        // Turn boundaries: speaker change should land within ~1.5 s of each splice
        let splicePoints = boundaries.dropFirst()  // boundaries at 4s, 8s, 12s
        for splice in splicePoints {
            let near = segments.first { seg in
                let mid = (Double(seg.startSeconds) + Double(seg.endSeconds)) / 2
                return abs(mid - splice) < 2.0
            }
            // We don't hard-fail here because boundary detection can lag by up to 1 chunk.
            if near == nil {
                XCTFail("No segment activity within 2 s of splice at \(splice) s")
            }
        }
    }

    // MARK: - Test: streaming path agrees with processComplete

    func testStreamingPathAgreesWithProcessComplete() async throws {
        try XCTSkipUnless(MeetingDiarizerService.isModelCached(),
                          "Nemotron-3 model not cached on this machine — skipping")

        let root = MeetingDiarizerService.modelsRoot()
        let config = MeetingDiarizerService.config
        let models = try await Nemotron3Models.loadFromHuggingFace(
            config: config, cacheDirectory: root)

        let fixture = try loadFixtureAudio()
        let turnSamples = Int(Self.turnSeconds * Self.sampleRate)
        let (audio, _) = Self.buildTwoSpeakerFixture(
            speaker: fixture, turnSamples: turnSamples)

        // processComplete baseline
        let d1 = Nemotron3Diarizer(config: config, models: models)
        let (batchProbs, batchFrames) = try d1.processComplete(audio)
        let batchSegments = Nemotron3Diarizer.segments(probabilities: batchProbs, frameCount: batchFrames)
        let batchSpeakers = Set(batchSegments.map(\.speakerIndex))

        // Streaming path: feed in 1-second chunks
        let d2 = Nemotron3Diarizer(config: config, models: models)
        let chunkSize = Int(Self.sampleRate)  // 1 s at 16 kHz
        var streamChunks: [Nemotron3ChunkResult] = []
        var offset = 0
        while offset < audio.count {
            let end = min(offset + chunkSize, audio.count)
            d2.appendAudio(Array(audio[offset..<end]))
            streamChunks += (try? d2.processBufferedAudio()) ?? []
            offset = end
        }
        streamChunks += (try? d2.finishStream()) ?? []

        // Reconstruct speaker-probability array from chunk results for segment extraction
        var streamProbs: [Float] = []
        var streamFrames = 0
        for chunk in streamChunks {
            streamProbs += chunk.probabilities
            streamFrames += chunk.frameCount
        }
        let streamSegments = Nemotron3Diarizer.segments(probabilities: streamProbs, frameCount: streamFrames)
        let streamSpeakers = Set(streamSegments.map(\.speakerIndex))

        // Both paths must see the same speaker count (allow off-by-one for edge chunks)
        XCTAssertGreaterThanOrEqual(streamSpeakers.count, 2,
            "Streaming path found \(streamSpeakers.count) speaker(s); expected ≥2")
        XCTAssertEqual(streamSpeakers.count, batchSpeakers.count,
            "Speaker count mismatch: batch=\(batchSpeakers.count) streaming=\(streamSpeakers.count)")
    }
}

#endif  // canImport(FluidAudio)
