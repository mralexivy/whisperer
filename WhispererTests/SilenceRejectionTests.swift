//
//  SilenceRejectionTests.swift
//  WhispererTests
//
//  Verifies that silent recordings produce empty transcription output.
//  Uses 4 real silent recordings that previously produced hallucinations.
//

import AVFoundation
import Accelerate
import XCTest
@testable import whisperer

final class SilenceRejectionTests: XCTestCase {

    private static var _bridge: WhisperBridge?
    private static var _vad: SileroVAD?

    override class func tearDown() {
        if let bridge = _bridge {
            bridge.prepareForShutdown()
        }
        super.tearDown()
    }

    private func loadWhisperBridge() throws -> WhisperBridge {
        if let bridge = Self._bridge { return bridge }
        let models: [WhisperModel] = [.largeTurboQ5, .largeTurbo, .medium, .small, .base, .tiny]
        for model in models {
            let path = ModelDownloader.shared.modelPath(for: model)
            if FileManager.default.fileExists(atPath: path.path) {
                let bridge = try WhisperBridge(modelPath: path)
                Self._bridge = bridge
                return bridge
            }
        }
        throw XCTSkip("No whisper model downloaded")
    }

    private func loadVAD() throws -> SileroVAD {
        if let vad = Self._vad { return vad }
        let vadPath = ModelDownloader.shared.vadModelPath()
        guard FileManager.default.fileExists(atPath: vadPath.path) else {
            throw XCTSkip("VAD model not downloaded")
        }
        let vad = try SileroVAD(modelPath: vadPath)
        Self._vad = vad
        return vad
    }

    private func projectRoot() -> String {
        let bundle = Bundle(for: type(of: self))
        var dir = URL(fileURLWithPath: bundle.bundlePath)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Whisperer.xcodeproj").path) {
                return dir.path
            }
        }
        return "/Users/alexanderi/Downloads/whisperer"
    }

    private func loadAudioSamples(from path: String) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Audio file not found: \(path)")
        }

        let url = URL(fileURLWithPath: path)
        let audioFile = try AVAudioFile(forReading: url)
        let inputFormat = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        let inputBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount))
        try audioFile.read(into: inputBuffer)

        if inputFormat.sampleRate == 16000.0 && inputFormat.channelCount == 1 {
            let channelData = try XCTUnwrap(inputBuffer.floatChannelData)
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(inputBuffer.frameLength)))
        }

        let outputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: false
        ))

        let converter = try XCTUnwrap(AVAudioConverter(from: inputFormat, to: outputFormat))
        let ratio = 16000.0 / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio) + 1
        let outputBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount))

        var inputConsumed = false
        var convError: NSError?
        converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            inputConsumed = true
            return inputBuffer
        }

        if let convError { throw convError }
        let channelData = try XCTUnwrap(outputBuffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }

    private func silenceFiles() -> [(path: String, name: String)] {
        let root = projectRoot()
        return [
            (root + "/WhispererTests/TestData/silence-1.wav", "silence-1 (was: Thank you)"),
            (root + "/WhispererTests/TestData/silence-2.wav", "silence-2 (was: Thank you)"),
            (root + "/WhispererTests/TestData/silence-3.wav", "silence-3 (was: E a)"),
            (root + "/WhispererTests/TestData/silence-4.wav", "silence-4 (was: Soustitrage ST 501)"),
        ]
    }

    // MARK: - Energy Check

    func testSilentRecordingsHaveNoEnergy() throws {
        for file in silenceFiles() {
            let samples = try loadAudioSamples(from: file.path)

            var rms: Float = 0
            vDSP_measqv(samples, 1, &rms, vDSP_Length(samples.count))
            rms = sqrt(rms)

            XCTAssertLessThan(rms, 0.003, "\(file.name): RMS \(rms) should be below energy threshold 0.003")
        }
    }

    // MARK: - VAD Check

    func testSilentRecordingsVADMostlyRejectsSilence() throws {
        let vad = try loadVAD()

        var rejected = 0
        for file in silenceFiles() {
            let samples = try loadAudioSamples(from: file.path)
            if !vad.containsSpeech(samples: samples) {
                rejected += 1
            }
        }

        // VAD should reject most silent recordings. Occasional false positives are
        // expected on near-threshold noise — the energy check in StreamingTranscriber
        // catches those cases (verified in testSilentRecordingsProduceEmptyTranscription).
        XCTAssertGreaterThanOrEqual(rejected, 3, "VAD should reject at least 3 of 4 silent recordings (got \(rejected))")
    }

    // MARK: - Full Pipeline

    func testSilentRecordingsProduceEmptyTranscription() throws {
        let bridge = try loadWhisperBridge()
        let vad = try loadVAD()

        // Warmup
        bridge.resetAbort()
        _ = bridge.transcribe(samples: [Float](repeating: 0, count: 16000), initialPrompt: nil, language: .english, singleSegment: false, maxTokens: 0)

        for file in silenceFiles() {
            let samples = try loadAudioSamples(from: file.path)

            let transcriber = StreamingTranscriber(
                backend: bridge,
                vad: vad,
                language: .english
            )

            transcriber.start { _ in }

            // Feed audio in small chunks simulating real-time
            let chunkSize = 1365
            for offset in stride(from: 0, to: samples.count, by: chunkSize) {
                let end = min(offset + chunkSize, samples.count)
                transcriber.addSamples(Array(samples[offset..<end]))
                Thread.sleep(forTimeInterval: 0.01)
            }

            // Wait for VAD scan
            Thread.sleep(forTimeInterval: 3.0)

            bridge.resetAbort()
            let result = transcriber.stop()

            XCTAssertTrue(result.isEmpty, "\(file.name): Silent recording should produce empty transcription, got: \"\(result)\"")
        }
    }
}
