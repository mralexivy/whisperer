//
//  SpeechAnalyzerDiagnostics.swift
//  Whisperer
//
//  Live microphone test for SpeechAnalyzer transcription pipeline
//

#if canImport(Speech)
import Combine
import Foundation
import AVFoundation
import Speech

@available(macOS 26.0, *)
@MainActor
final class SpeechAnalyzerDiagnostics: ObservableObject {

    enum TestState: Equatable {
        case idle
        case preparing
        case recording
        case transcribing
        case done(text: String, latencyMs: Double)
        case error(String)
    }

    @Published var state: TestState = .idle
    @Published var recordingDuration: TimeInterval = 0

    private var audioEngine: AVAudioEngine?
    private var recordedSamples: [Float] = []
    private var bridge: SpeechAnalyzerBridge?
    private var durationTimer: Timer?
    private var recordingStartTime: Date?

    private static let maxDuration: TimeInterval = 15

    func startTest() {
        guard state == .idle || isTerminalState else { return }

        state = .preparing
        recordingDuration = 0
        recordedSamples.removeAll()

        Task { [weak self] in
            guard let self = self else { return }

            // Prepare bridge
            do {
                self.bridge = try await SpeechAnalyzerBridge.prepare()
            } catch {
                self.state = .error("Failed to prepare: \(error.localizedDescription)")
                return
            }

            // Set up audio capture
            do {
                try self.setupAudioCapture()
                self.state = .recording
                self.recordingStartTime = Date()
                self.startDurationTimer()
            } catch {
                self.state = .error("Mic error: \(error.localizedDescription)")
            }
        }
    }

    func stopTest() {
        guard state == .recording else { return }
        stopAudioCapture()
        transcribeRecordedAudio()
    }

    func reset() {
        stopAudioCapture()
        state = .idle
        recordingDuration = 0
        recordedSamples.removeAll()
    }

    private var isTerminalState: Bool {
        switch state {
        case .done, .error: return true
        default: return false
        }
    }

    // MARK: - Audio Capture

    private func setupAudioCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Force audio unit creation
        _ = inputNode.outputFormat(forBus: 0)

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0 else {
            throw NSError(domain: "SpeechAnalyzerDiagnostics", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Invalid audio format"])
        }

        // Target: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "SpeechAnalyzerDiagnostics", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Cannot create target format"])
        }

        let converter = AVAudioConverter(from: recordingFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            if let converter = converter {
                let ratio = targetFormat.sampleRate / recordingFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

                var nsError: NSError?
                var consumed = false
                converter.convert(to: convertedBuffer, error: &nsError) { _, statusPtr in
                    defer { consumed = true }
                    statusPtr.pointee = consumed ? .noDataNow : .haveData
                    return consumed ? nil : buffer
                }

                if let data = convertedBuffer.floatChannelData {
                    let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(convertedBuffer.frameLength)))
                    DispatchQueue.main.async { [weak self] in
                        self?.recordedSamples.append(contentsOf: samples)
                        self?.enforceMaxDuration()
                    }
                }
            } else if let data = buffer.floatChannelData {
                let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
                DispatchQueue.main.async { [weak self] in
                    self?.recordedSamples.append(contentsOf: samples)
                    self?.enforceMaxDuration()
                }
            }
        }

        try engine.start()
        audioEngine = engine
    }

    private func stopAudioCapture() {
        durationTimer?.invalidate()
        durationTimer = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let start = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func enforceMaxDuration() {
        let currentDuration = Double(recordedSamples.count) / 16_000.0
        if currentDuration >= Self.maxDuration {
            stopTest()
        }
    }

    // MARK: - Transcription

    private func transcribeRecordedAudio() {
        guard !recordedSamples.isEmpty else {
            state = .error("No audio recorded")
            return
        }

        state = .transcribing
        let samples = recordedSamples

        Task { [weak self] in
            guard let self = self, let bridge = self.bridge else {
                self?.state = .error("Bridge not ready")
                return
            }

            let start = CFAbsoluteTimeGetCurrent()
            let text = await bridge.transcribeDirectAsync(samples: samples, language: .auto)
            let latencyMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

            if text.isEmpty {
                self.state = .done(text: "(no speech detected)", latencyMs: latencyMs)
            } else {
                self.state = .done(text: text, latencyMs: latencyMs)
            }

            Logger.info("SpeechAnalyzer test: '\(text)' (\(String(format: "%.0f", latencyMs))ms)", subsystem: .transcription)
        }
    }
}
#endif
