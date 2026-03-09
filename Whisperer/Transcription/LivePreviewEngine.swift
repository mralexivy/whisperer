//
//  LivePreviewEngine.swift
//  Whisperer
//
//  Dedicated live preview engine using FluidAudio's Parakeet EOU streaming model.
//  Runs on Neural Engine alongside the main transcription engine (GPU).
//

import AVFoundation
import CoreML
import FluidAudio
import Foundation

nonisolated class LivePreviewEngine {

    private var eouManager: StreamingEouAsrManager?
    private var onPartialTranscript: ((String) -> Void)?
    private var isRunning = false

    // Cached AVAudioFormat — 16kHz mono Float32, reused for every feedAudio call
    private let audioFormat: AVAudioFormat?

    // Buffer samples to reduce Task/actor dispatch overhead.
    // Only accessed from the audio callback thread (feedAudio) and
    // from main thread when audio is stopped (start/stop).
    private var sampleBuffer: [Float] = []
    private let bufferThreshold = 5120  // 320ms at 16kHz — ~4 audio callbacks per batch

    init() {
        self.audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )
    }

    // MARK: - Model Lifecycle

    /// Load EOU models from cached directory
    func loadModel(modelDir: URL) async throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all  // Neural Engine + CPU
        let manager = StreamingEouAsrManager(
            configuration: config,
            chunkSize: .ms320,
            eouDebounceMs: 1280
        )
        try await manager.loadModels(modelDir: modelDir)

        // Pre-warm: process a tiny silent buffer to trigger CoreML compilation.
        // Without this, the first real inference takes ~275ms instead of ~45ms.
        if let fmt = audioFormat,
           let warmupBuffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1600) {
            warmupBuffer.frameLength = 1600
            memset(warmupBuffer.floatChannelData![0], 0, 1600 * MemoryLayout<Float>.size)
            _ = try? await manager.process(audioBuffer: warmupBuffer)
            _ = try? await manager.finish()
            await manager.reset()
        }

        self.eouManager = manager
        Logger.info("LivePreviewEngine: EOU 320ms model loaded", subsystem: .transcription)
    }

    var isModelLoaded: Bool { eouManager != nil }

    // MARK: - Recording Lifecycle

    /// Start live preview for a recording session.
    /// Must be awaited — ensures reset + callback are set before audio flows.
    func start(onPartialTranscript: @escaping (String) -> Void) async {
        self.onPartialTranscript = onPartialTranscript
        self.sampleBuffer.removeAll(keepingCapacity: true)
        self.isRunning = true

        guard let manager = eouManager else { return }
        await manager.reset()
        await manager.setPartialCallback { [weak self] text in
            guard let self, self.isRunning else { return }
            let cbTime = CACurrentMediaTime()
            Logger.debug("LivePreview: partialCallback fired (\(text.count) chars) t=\(String(format: "%.3f", cbTime))", subsystem: .transcription)
            self.onPartialTranscript?(text)
        }
    }

    /// Feed audio samples from AudioRecorder callback. Non-blocking.
    /// Accumulates samples and dispatches to actor in ~300ms batches.
    func feedAudio(_ samples: [Float]) {
        guard isRunning, let manager = eouManager, let format = audioFormat else { return }
        guard !samples.isEmpty else { return }

        sampleBuffer.append(contentsOf: samples)
        guard sampleBuffer.count >= bufferThreshold else { return }

        // Drain buffer into AVAudioPCMBuffer
        let count = sampleBuffer.count
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(count)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        guard let channelData = buffer.floatChannelData else { return }
        sampleBuffer.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            channelData[0].update(from: base, count: count)
        }
        sampleBuffer.removeAll(keepingCapacity: true)

        // Fire-and-forget — actor serializes internally
        let dispatchTime = CACurrentMediaTime()
        Logger.debug("LivePreview: dispatching \(count) samples (\(String(format: "%.0f", Double(count) / 16.0))ms audio)", subsystem: .transcription)
        Task {
            _ = try? await manager.process(audioBuffer: buffer)
            let processTime = CACurrentMediaTime()
            Logger.debug("LivePreview: process() returned in \(String(format: "%.0f", (processTime - dispatchTime) * 1000))ms", subsystem: .transcription)
        }
    }

    /// Stop live preview. Flushes remaining audio and clears state.
    /// Called after audioRecorder.stopRecording() so no more feedAudio calls.
    /// MUST be awaited before starting final transcription — the EOU model's finish()
    /// runs on ANE, and concurrent ANE access with the main TDT model causes corrupted
    /// inference (wrong language output, e.g. Cyrillic instead of English).
    func stop() async {
        isRunning = false
        onPartialTranscript = nil
        sampleBuffer.removeAll()

        guard let manager = eouManager else { return }
        _ = try? await manager.finish()
        await manager.reset()
    }

    /// Release model from memory
    func unloadModel() {
        isRunning = false
        onPartialTranscript = nil
        sampleBuffer.removeAll()
        eouManager = nil
        Logger.debug("LivePreviewEngine: model unloaded", subsystem: .transcription)
    }
}
