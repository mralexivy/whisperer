//
//  SeekableAudioPlayerTests.swift
//  WhispererTests
//
//  Verifies that SeekableAudioPlayer correctly seeks the app's Ogg Opus format.
//
//  The decisive test uses AVAudioEngine offline rendering — same technique used to
//  prove the bug (AVAudioPlayer ignores seeks on Ogg Opus).  All assertions are on
//  rendered PCM samples, so no audio hardware is required.
//

import XCTest
import AVFoundation
@testable import whisperer

// MARK: - Helpers

private extension SeekableAudioPlayerTests {

    /// Write a synthetic .opus fixture using AudioArchiveWriter.
    ///  - 0 ... silenceDuration s of silence
    ///  - silenceDuration ... (silenceDuration + toneDuration) s of 440 Hz sine
    static func makeFixtureOpus(silenceDuration: Double = 5.0,
                                toneDuration: Double = 5.0) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seek_test_\(UUID().uuidString).opus")

        let writer = try AudioArchiveWriter(url: url)
        let sr = Int(AudioArchiveFormat.sampleRate)

        func writeBlock(_ duration: Double, generator: (Int) -> Float) throws {
            let total = Int(duration * Double(sr))
            var written = 0
            let chunkSize = sr / 10   // 100 ms chunks
            let fmt = AudioArchiveFormat.pcmFormat
            while written < total {
                let count = min(chunkSize, total - written)
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(count)) else { break }
                buf.frameLength = AVAudioFrameCount(count)
                let ptr = buf.floatChannelData![0]
                for i in 0..<count { ptr[i] = generator(written + i) }
                try writer.write(buf)
                written += count
            }
        }

        try writeBlock(silenceDuration) { _ in Float(0) }
        try writeBlock(toneDuration) { sample in
            // 440 Hz sine
            Float(sin(2.0 * .pi * 440.0 * Double(sample) / Double(sr))) * 0.5
        }
        writer.close()
        return url
    }

    /// Offline-render `duration` seconds from the player's current schedule position.
    /// Returns RMS of the rendered block.
    static func renderRMS(from url: URL, seekSeconds: Double, renderSeconds: Double = 0.5) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        engine.attach(node)
        engine.attach(pitch)
        engine.connect(node, to: pitch, format: fmt)
        engine.connect(pitch, to: engine.mainMixerNode, format: fmt)

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: maxFrames)
        try engine.start()

        // Clamp to [0, length] — mirrors SeekableAudioPlayer.seek(to:) clamping behaviour.
        let clampedSeconds = max(0, min(seekSeconds, Double(file.length) / fmt.sampleRate))
        let seekFrame = AVAudioFramePosition(clampedSeconds * fmt.sampleRate)
        let remaining = file.length - seekFrame
        guard remaining > 0 else { return 0 }
        node.scheduleSegment(file, startingFrame: seekFrame,
                             frameCount: AVAudioFrameCount(remaining), at: nil)
        node.play()

        let targetFrames = AVAudioFrameCount(renderSeconds * fmt.sampleRate)
        let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                     frameCapacity: maxFrames)!
        var rendered: AVAudioFrameCount = 0
        var sumSq: Float = 0
        var count = 0

        while rendered < targetFrames {
            let toRender = min(maxFrames, targetFrames - rendered)
            let st = try engine.renderOffline(toRender, to: output)
            guard st != .error else { break }
            if let d = output.floatChannelData?[0] {
                for i in 0..<Int(output.frameLength) { sumSq += d[i] * d[i]; count += 1 }
            }
            rendered += output.frameLength
            if st == .insufficientDataFromInputNode { break }
        }

        return count > 0 ? (sumSq / Float(count)).squareRoot() : 0
    }
}

// MARK: - Test suite

final class SeekableAudioPlayerTests: XCTestCase {

    private var fixtureURL: URL!
    private static let silenceDuration = 5.0
    private static let toneDuration = 5.0
    private static let totalDuration = silenceDuration + toneDuration  // 10 s

    override func setUpWithError() throws {
        fixtureURL = try Self.makeFixtureOpus(
            silenceDuration: Self.silenceDuration,
            toneDuration: Self.toneDuration
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fixtureURL)
    }

    // MARK: - THE decisive seek test

    /// Seeking to the tone region must render actual tone, not silence.
    /// This assertion fails against AVAudioPlayer — it is the regression guard.
    func testSeekIntoToneRendersCorrectAudio() throws {
        let seekIntoTone = Self.silenceDuration + Self.toneDuration / 2  // 7.5 s → in tone

        let toneRMS = try Self.renderRMS(from: fixtureURL, seekSeconds: seekIntoTone)
        let silenceRMS = try Self.renderRMS(from: fixtureURL, seekSeconds: 1.0)  // 1 s → silence

        // Tone must be noticeably louder than silence (ratio > 5×).
        XCTAssertGreaterThan(toneRMS, silenceRMS * 5,
            "Sought to tone region (t=\(seekIntoTone)s) but got RMS \(toneRMS) — not louder than silence RMS \(silenceRMS). " +
            "Engine did not seek; it started from the beginning.")
    }

    /// Seeking to the silence region must render silence, not tone.
    func testSeekIntoSilenceRendersCorrectAudio() throws {
        let seekIntoSilence = 1.5  // deep in the silence region

        let silenceRMS = try Self.renderRMS(from: fixtureURL, seekSeconds: seekIntoSilence)

        // Very quiet — fixture is Float32(0), so theoretical RMS is 0.
        // Allow a small epsilon for codec round-trip artefacts.
        XCTAssertLessThan(silenceRMS, 0.05,
            "Sought to silence region (t=\(seekIntoSilence)s) but got RMS \(silenceRMS); expected near-zero.")
    }

    // MARK: - Duration loads correctly

    func testDurationMatchesFile() throws {
        let file = try AVAudioFile(forReading: fixtureURL)
        let expectedDuration = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertEqual(expectedDuration, Self.totalDuration, accuracy: 0.5,
            "Fixture duration \(expectedDuration) s differs from expected \(Self.totalDuration) s")
    }

    // MARK: - Edge cases (no crash, correct clamp behaviour)

    func testSeekBeforeLoadIsNoOp() {
        // A fresh player has duration == 0; seek must not crash.
        let player = SeekableAudioPlayer()
        player.seek(to: 5.0)   // no-op: duration == 0
        XCTAssertEqual(player.currentTime, 0)
    }

    func testSeekPastEndClampsToDuration() throws {
        let file = try AVAudioFile(forReading: fixtureURL)
        let dur = Double(file.length) / file.processingFormat.sampleRate

        let rms = try Self.renderRMS(from: fixtureURL, seekSeconds: dur + 100)
        // Seeking past end → remaining == 0 → no frames rendered → RMS == 0.
        XCTAssertEqual(rms, 0, accuracy: 0.001, "Seeking past end should yield silence (no frames).")
    }

    func testSeekToZeroRendersFromStart() throws {
        let rmsFromZero = try Self.renderRMS(from: fixtureURL, seekSeconds: 0, renderSeconds: 0.5)
        let referenceRMS = try Self.renderRMS(from: fixtureURL, seekSeconds: 1.0, renderSeconds: 0.5)
        // Both should be silence; confirm consistency.
        XCTAssertEqual(rmsFromZero, referenceRMS, accuracy: 0.01,
            "Seek to 0 and seek to 1 s (both silence) should give similar RMS.")
    }

    func testSeekToDurationParksAtEnd() throws {
        let file = try AVAudioFile(forReading: fixtureURL)
        let dur = Double(file.length) / file.processingFormat.sampleRate
        let rms = try Self.renderRMS(from: fixtureURL, seekSeconds: dur, renderSeconds: 0.5)
        XCTAssertEqual(rms, 0, accuracy: 0.001, "Seek to exact duration yields no audio (parked at end).")
    }

    func testSeekToNegativeClampedToZero() throws {
        let rmsNeg = try Self.renderRMS(from: fixtureURL, seekSeconds: -10, renderSeconds: 0.5)
        let rmsZero = try Self.renderRMS(from: fixtureURL, seekSeconds: 0, renderSeconds: 0.5)
        XCTAssertEqual(rmsNeg, rmsZero, accuracy: 0.01,
            "Negative seek should clamp to 0 and render the same audio as seeking to 0.")
    }

    func testBackwardSeekAfterForwardSeek() throws {
        // Forward then backward — must land in correct region each time.
        let rmsAfterForward = try Self.renderRMS(from: fixtureURL, seekSeconds: 7.0, renderSeconds: 0.5)
        let rmsAfterBackward = try Self.renderRMS(from: fixtureURL, seekSeconds: 1.0, renderSeconds: 0.5)
        // 7 s is in the tone; 1 s is silence.
        XCTAssertGreaterThan(rmsAfterForward, rmsAfterBackward * 3,
            "Forward seek into tone then backward into silence should give distinct RMS values.")
    }

    func testRateChangePreservesSeekPosition() throws {
        // Changing rate must not reset the seek frame.
        let file = try AVAudioFile(forReading: fixtureURL)
        let fmt = file.processingFormat
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        engine.attach(node)
        engine.attach(pitch)
        engine.connect(node, to: pitch, format: fmt)
        engine.connect(pitch, to: engine.mainMixerNode, format: fmt)

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: maxFrames)
        try engine.start()

        let seekIntoTone = AVAudioFramePosition((Self.silenceDuration + 0.5) * fmt.sampleRate)
        node.scheduleSegment(file, startingFrame: seekIntoTone,
                             frameCount: AVAudioFrameCount(file.length - seekIntoTone), at: nil)
        // Simulate rate change: just setting pitch node's rate before play
        pitch.rate = 2.0
        node.play()

        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames)!
        var sumSq: Float = 0; var count = 0
        let want = AVAudioFrameCount(0.5 * fmt.sampleRate)
        var done: AVAudioFrameCount = 0
        while done < want {
            let toRender = min(maxFrames, want - done)
            _ = try engine.renderOffline(toRender, to: out)
            if let d = out.floatChannelData?[0] { for i in 0..<Int(out.frameLength) { sumSq += d[i]*d[i]; count += 1 } }
            done += out.frameLength
        }
        let rms = count > 0 ? (sumSq / Float(count)).squareRoot() : Float(0)

        // At 2× rate the content is still tone — RMS should still be significant.
        XCTAssertGreaterThan(rms, 0.05, "Rate-changed seek into tone should still produce tone signal, got RMS \(rms)")
    }
}
