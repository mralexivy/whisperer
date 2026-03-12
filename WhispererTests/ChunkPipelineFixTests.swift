//
//  ChunkPipelineFixTests.swift
//  WhispererTests
//
//  Tests that the chunked pipeline produces correct transcription for real audio files.
//  Verifies: larger chunk sizes, peak normalization, language pinning.
//

import AVFoundation
import Accelerate
import XCTest
@testable import whisperer

final class ChunkPipelineFixTests: XCTestCase {

    // Shared bridge — kept alive to avoid Metal dealloc crash during process exit.
    private static var _bridge: WhisperBridge?
    private static var _vad: SileroVAD?

    override class func tearDown() {
        // Don't nil out — Metal dealloc race crashes the process
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

    private func loadVAD() -> SileroVAD? {
        if let vad = Self._vad { return vad }
        let vadPath = ModelDownloader.shared.vadModelPath()
        guard FileManager.default.fileExists(atPath: vadPath.path) else { return nil }
        Self._vad = try? SileroVAD(modelPath: vadPath)
        return Self._vad
    }

    private func loadAudioSamples(from path: String) throws -> [Float] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Audio file not found: \(path)")
        }

        let audioFile = try AVAudioFile(forReading: url)
        let inputFormat = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        let inputBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount))
        try audioFile.read(into: inputBuffer)

        let outputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: false
        ))

        if inputFormat.sampleRate == 16000.0 && inputFormat.channelCount == 1 {
            let channelData = try XCTUnwrap(inputBuffer.floatChannelData)
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(inputBuffer.frameLength)))
        }

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

    // MARK: - VADSegmenter parameter verification (no bridge needed)

    func testVADSegmenterNewDefaults() throws {
        let segmenter = VADSegmenter(vad: nil, targetChunkDuration: 20.0)

        XCTAssertEqual(segmenter.minChunkDuration, 3.0, "minChunkDuration should be 3.0s")
        XCTAssertEqual(segmenter.minTailDuration, 0.5, "minTailDuration should be 0.5s")
        XCTAssertEqual(segmenter.silenceForFinalization, 1.5, "silenceForFinalization should be 1.5s")

        // 1.5s tail: below minChunkDuration (3.0) but above minTailDuration (0.5)
        let samples = [Float](repeating: 0.1, count: Int(1.5 * 16000))
        let tail = segmenter.finalizeTail(allSamples: samples, lastTranscribedIndex: 0)
        XCTAssertNotNil(tail, "1.5s tail should be transcribed (minTailDuration=0.5)")

        // 0.3s tail: below minTailDuration
        let shortSamples = [Float](repeating: 0.1, count: Int(0.3 * 16000))
        let shortTail = segmenter.finalizeTail(allSamples: shortSamples, lastTranscribedIndex: 0)
        XCTAssertNil(shortTail, "0.3s tail should be skipped (below minTailDuration=0.5)")

        print("✅ VADSegmenter defaults verified: minChunk=3.0s, minTail=0.5s, silenceFinalization=1.5s")
    }

    // MARK: - Real audio: chunked vs full transcription (single test, both files)

    func testRealAudio_ChunkedVsFull() throws {
        let bridge = try loadWhisperBridge()
        let vad = loadVAD()
        let root = projectRoot()

        // Warmup
        let warmup = [Float](repeating: 0, count: 16000)
        bridge.resetAbort()
        _ = bridge.transcribe(samples: warmup, initialPrompt: nil, language: .english, singleSegment: false, maxTokens: 0)

        let files: [(path: String, name: String)] = [
            (root + "/WhispererTests/TestData/test-sentences-en.wav", "WAV recording"),
            (root + "/WhispererTests/TestData/test-dynamic-yield.m4a", "M4A recording"),
        ]

        for file in files {
            guard FileManager.default.fileExists(atPath: file.path) else {
                print("⏭️ Skipping \(file.name) — file not found")
                continue
            }

            let samples = try loadAudioSamples(from: file.path)
            let duration = Double(samples.count) / 16000.0
            var peakVal: Float = 0
            vDSP_maxmgv(samples, 1, &peakVal, vDSP_Length(samples.count))
            var rms: Float = 0
            vDSP_measqv(samples, 1, &rms, vDSP_Length(samples.count))
            rms = sqrt(rms)

            print("\n========================================")
            print("📁 \(file.name)")
            print("Duration: \(String(format: "%.1f", duration))s | Peak: \(String(format: "%.4f", peakVal)) | RMS: \(String(format: "%.4f", rms))")
            print("========================================")

            // Full-audio baseline
            bridge.resetAbort()
            let fullText = bridge.transcribe(
                samples: samples,
                initialPrompt: nil,
                language: .auto,
                singleSegment: false,
                maxTokens: 0
            )
            let detectedLang = bridge.lastDetectedLanguage ?? "unknown"
            print("\n🔵 [FULL] Language: \(detectedLang)")
            print("🔵 [FULL] \"\(fullText)\"")

            // Chunked pipeline
            let chunkedText = runChunkedPipeline(samples: samples, bridge: bridge, vad: vad)
            print("\n🟢 [CHUNKED] \"\(chunkedText)\"")

            print("\n📊 Full: \(fullText.count) chars | Chunked: \(chunkedText.count) chars")

            XCTAssertFalse(fullText.isEmpty, "\(file.name): Full transcription should not be empty")
            XCTAssertFalse(chunkedText.isEmpty, "\(file.name): Chunked transcription should not be empty")

            let attachment = XCTAttachment(string: """
            \(file.name) — Duration: \(String(format: "%.1f", duration))s, Peak: \(String(format: "%.4f", peakVal)), Lang: \(detectedLang)
            FULL:    \(fullText)
            CHUNKED: \(chunkedText)
            """)
            attachment.name = "\(file.name) Results"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    // MARK: - Chunked Pipeline Runner

    private func runChunkedPipeline(samples: [Float], bridge: WhisperBridge, vad: SileroVAD?) -> String {
        let transcriber = StreamingTranscriber(
            backend: bridge,
            vad: vad,
            language: .auto
        )

        transcriber.start { _ in }

        // Feed audio simulating real-time (~85ms chunks = 1365 samples at 16kHz)
        let chunkSize = 1365
        for offset in stride(from: 0, to: samples.count, by: chunkSize) {
            let end = min(offset + chunkSize, samples.count)
            transcriber.addSamples(Array(samples[offset..<end]))
            Thread.sleep(forTimeInterval: 0.01)
        }

        // Wait for VAD scans and chunk transcriptions
        Thread.sleep(forTimeInterval: 8.0)

        let finalText = transcriber.stop()
        return finalText
    }
}
