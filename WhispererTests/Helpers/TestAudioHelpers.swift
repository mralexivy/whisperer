//
//  TestAudioHelpers.swift
//  WhispererTests
//
//  Shared utilities for audio loading, whisper model discovery, and text
//  quality metrics. Factored here to avoid duplication across test files.
//

import AVFoundation
import XCTest
@testable import whisperer

// MARK: - Audio loading

/// Load audio samples at 16 kHz mono Float32 from any supported file format.
/// Resamples if needed. Throws XCTSkip if the file is not found.
func loadAudioSamples(from url: URL) throws -> [Float] {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw XCTSkip("Audio file not found: \(url.lastPathComponent)")
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

    // Already 16 kHz mono — return directly
    if inputFormat.sampleRate == 16000.0 && inputFormat.channelCount == 1 {
        let channelData = try XCTUnwrap(inputBuffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(inputBuffer.frameLength)))
    }

    // Resample
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

// MARK: - Model discovery

/// Returns the first WhisperBridge whose model file is on disk, trying best-quality first.
/// Throws XCTSkip if nothing is downloaded.
func loadWhisperBridge() throws -> WhisperBridge {
    let priority: [WhisperModel] = [.largeTurboQ5, .largeTurbo, .medium, .small, .base, .tiny]
    for model in priority {
        let path = ModelDownloader.shared.modelPath(for: model)
        guard FileManager.default.fileExists(atPath: path.path) else { continue }
        return try WhisperBridge(modelPath: path)
    }
    throw XCTSkip("No whisper model downloaded — run the app first")
}

/// Returns SileroVAD if the VAD model is downloaded; nil otherwise.
func loadVAD() -> SileroVAD? {
    let path = ModelDownloader.shared.vadModelPath()
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    return try? SileroVAD(modelPath: path)
}

// MARK: - Text metrics

/// Split a block of text into ~N-word chunks to simulate Whisper streaming output.
func simulateChunks(_ text: String, wordsPerChunk: Int = 20) -> [String] {
    let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    var chunks: [String] = []
    var i = 0
    while i < words.count {
        let slice = words[i..<min(i + wordsPerChunk, words.count)]
        chunks.append(slice.joined(separator: " "))
        i += wordsPerChunk
    }
    return chunks
}

/// Word-bag F1 (order-independent): how many words appear in both texts.
func wordOverlapF1(_ a: String, _ b: String) -> Double {
    func bag(_ text: String) -> [String: Int] {
        var d: [String: Int] = [:]
        for w in text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map({ $0.filter { $0.isLetter || $0.isNumber } })
            .filter({ !$0.isEmpty }) {
            d[w, default: 0] += 1
        }
        return d
    }
    let bagA = bag(a), bagB = bag(b)
    let shared = bagA.keys.reduce(0) { $0 + min(bagA[$1]!, bagB[$1, default: 0]) }
    let totalA = bagA.values.reduce(0, +)
    let totalB = bagB.values.reduce(0, +)
    guard totalA > 0, totalB > 0 else { return 0 }
    let p = Double(shared) / Double(totalA)
    let r = Double(shared) / Double(totalB)
    guard p + r > 0 else { return 0 }
    return 2 * p * r / (p + r)
}

// MARK: - StreamingTranscriber feed helper

/// Feeds samples into a running StreamingTranscriber in real-time-like chunks (85 ms / chunk).
func feedAudioToTranscriber(_ transcriber: StreamingTranscriber, samples: [Float]) {
    let chunkSize = 1365  // ~85 ms at 16 kHz
    for offset in stride(from: 0, to: samples.count, by: chunkSize) {
        let end = min(offset + chunkSize, samples.count)
        transcriber.addSamples(Array(samples[offset..<end]))
        Thread.sleep(forTimeInterval: 0.01)
    }
}
