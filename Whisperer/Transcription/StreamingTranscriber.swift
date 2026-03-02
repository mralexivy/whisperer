//
//  StreamingTranscriber.swift
//  Whisperer
//
//  Real-time audio transcription using whisper.cpp with periodic re-transcription.
//  Instead of processing short chunks (which lack context and produce wrong words),
//  this re-transcribes ALL accumulated audio every ~2s — giving whisper full context
//  for accurate live preview. The final pass on stop is unchanged.
//

import Foundation
import AVFoundation
import Accelerate

class StreamingTranscriber {
    private var whisper: WhisperBridge
    private var vad: SileroVAD?

    private let sampleRate: Double = 16000.0

    // Memory bounds - maximum recording duration
    private let maxRecordingDuration: Double = 5.0 * 60.0  // 5 minutes
    private var maxRecordingSamples: Int { Int(maxRecordingDuration * sampleRate) }  // 4,800,000 samples (~19MB)
    private var memoryLimitReached = false

    // Full recording — the single source of truth for all transcription
    private var allRecordedSamples: [Float] = []
    private let allSamplesLock = SafeLock()

    // Thread-safe processing flag — prevents overlapping re-transcriptions
    private let processingLock = SafeLock()
    private var _isProcessing = false
    private var isProcessing: Bool {
        get {
            do {
                return try processingLock.withLock(timeout: 1.0) { _isProcessing }
            } catch {
                Logger.error("Failed to get isProcessing: \(error.localizedDescription)", subsystem: .transcription)
                return false
            }
        }
        set {
            do {
                try processingLock.withLock(timeout: 1.0) { _isProcessing = newValue }
            } catch {
                Logger.error("Failed to set isProcessing: \(error.localizedDescription)", subsystem: .transcription)
            }
        }
    }

    private var onTranscription: ((String) -> Void)?

    // Thread-safe transcription state
    private let transcriptionLock = SafeLock()
    private var _fullTranscription: String = ""
    private var fullTranscription: String {
        get {
            do {
                return try transcriptionLock.withLock(timeout: 1.0) { _fullTranscription }
            } catch {
                Logger.error("Failed to get fullTranscription: \(error.localizedDescription)", subsystem: .transcription)
                return ""
            }
        }
        set {
            do {
                try transcriptionLock.withLock(timeout: 1.0) { _fullTranscription = newValue }
            } catch {
                Logger.error("Failed to set fullTranscription: \(error.localizedDescription)", subsystem: .transcription)
            }
        }
    }

    // Language for transcription
    private var language: TranscriptionLanguage

    // Periodic re-transcription timer
    private var reTranscriptionTask: Task<Void, Never>?
    private var isStopped: Bool = false
    private let firstRetranscriptionDelay: UInt64 = 1_500_000_000  // 1.5s
    private let retranscriptionInterval: UInt64 = 2_000_000_000    // 2.0s

    /// Initialize with a pre-loaded WhisperBridge, optional VAD, and language setting
    init(whisperBridge: WhisperBridge, vad: SileroVAD? = nil, language: TranscriptionLanguage = .english) {
        self.whisper = whisperBridge
        self.vad = vad
        self.language = language
    }

    /// Start streaming transcription with periodic re-transcription
    func start(onTranscription: @escaping (String) -> Void) {
        self.onTranscription = onTranscription

        do {
            try allSamplesLock.withLock {
                allRecordedSamples.removeAll()
            }
        } catch {
            Logger.error("Failed to acquire lock in start(): \(error.localizedDescription)", subsystem: .transcription)
        }

        fullTranscription = ""
        isProcessing = false
        isStopped = false
        memoryLimitReached = false

        // Start periodic re-transcription timer
        reTranscriptionTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Wait for initial audio to accumulate
            try? await Task.sleep(nanoseconds: self?.firstRetranscriptionDelay ?? 1_500_000_000)

            while !Task.isCancelled {
                guard let self = self, !self.isStopped else { break }

                if !self.isProcessing {
                    self.performReTranscription()
                }

                try? await Task.sleep(nanoseconds: self.retranscriptionInterval)
            }
        }

        Logger.debug("StreamingTranscriber started (periodic re-transcription mode, VAD: \(vad != nil))", subsystem: .transcription)
    }

    /// Add audio samples from microphone (should be 16kHz mono float32)
    func addSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        guard !isStopped else { return }

        if memoryLimitReached { return }

        do {
            try allSamplesLock.withLock {
                if allRecordedSamples.count + samples.count > maxRecordingSamples {
                    Logger.warning("Memory limit reached (\(String(format: "%.1f", maxRecordingDuration/60))min), stopping sample collection", subsystem: .transcription)
                    memoryLimitReached = true

                    let remainingCapacity = maxRecordingSamples - allRecordedSamples.count
                    if remainingCapacity > 0 {
                        allRecordedSamples.append(contentsOf: samples.prefix(remainingCapacity))
                    }
                } else {
                    allRecordedSamples.append(contentsOf: samples)
                }
            }
        } catch {
            Logger.error("Failed to acquire allSamplesLock: \(error.localizedDescription)", subsystem: .transcription)
        }
    }

    // MARK: - Periodic Re-transcription

    /// Re-transcribe all accumulated audio for accurate live preview.
    /// Each re-transcription has full audio context (like the final pass),
    /// producing much more accurate text than short chunk-based processing.
    private func performReTranscription() {
        isProcessing = true

        // Snapshot all recorded audio
        var samples: [Float] = []
        do {
            try allSamplesLock.withLock {
                samples = allRecordedSamples
            }
        } catch {
            Logger.error("Failed to acquire allSamplesLock in performReTranscription: \(error.localizedDescription)", subsystem: .transcription)
            isProcessing = false
            return
        }

        // Need minimum audio for meaningful transcription (0.5s)
        let minSamples = Int(0.5 * sampleRate)
        guard samples.count >= minSamples else {
            isProcessing = false
            return
        }

        let duration = Double(samples.count) / sampleRate
        Logger.debug("Re-transcribing \(String(format: "%.1f", duration))s of audio...", subsystem: .transcription)

        // Re-transcribe ALL audio — singleSegment:false, no initialPrompt, no maxTokens limit
        // This matches the final pass parameters for maximum accuracy
        whisper.transcribeAsync(samples: samples, language: language) { [weak self] text in
            guard let self = self else { return }
            defer { self.isProcessing = false }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmed.isEmpty else { return }

            guard !self.isHallucination(trimmed) else {
                Logger.debug("Re-transcription hallucination filtered: '\(trimmed.prefix(50))'", subsystem: .transcription)
                return
            }

            // REPLACE fullTranscription (not append) — each re-transcription is a complete result
            self.fullTranscription = trimmed

            let transcription = trimmed
            DispatchQueue.main.async {
                self.onTranscription?(transcription)
            }

            Logger.debug("Re-transcription result (\(String(format: "%.1f", duration))s): '\(trimmed.prefix(80))\(trimmed.count > 80 ? "..." : "")'", subsystem: .transcription)
        }
    }

    // MARK: - Energy Detection

    /// Fast RMS energy check using vDSP
    /// Threshold 0.003: built-in MacBook mic at arm's length produces speech RMS ~0.005-0.02.
    private func hasEnergy(_ samples: [Float], threshold: Float = 0.003) -> Bool {
        guard !samples.isEmpty else { return false }
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        let rms = sqrt(meanSquare)
        return rms > threshold
    }

    // MARK: - Hallucination Detection

    /// Known whisper hallucination patterns — common outputs on silence or noise
    private static let hallucinationPatterns: [String] = [
        "thank you for watching",
        "thanks for watching",
        "subscribe",
        "like and subscribe",
        "please subscribe",
        "thank you for listening",
        "thanks for listening",
        "see you next time",
        "see you in the next",
        "bye bye",
        "goodbye",
    ]

    /// Check if transcription text is a known hallucination pattern
    private func isHallucination(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return true }

        // Single punctuation or very short meaningless output
        if lower.count <= 2 && !lower.contains(where: { $0.isLetter }) {
            return true
        }

        // Check against known patterns
        for pattern in Self.hallucinationPatterns {
            if lower == pattern || lower.hasPrefix(pattern) {
                Logger.debug("Hallucination detected: '\(text)' matches pattern '\(pattern)'", subsystem: .transcription)
                return true
            }
        }

        // Check for repeated single word (e.g., "the the the the")
        let words = lower.split(separator: " ")
        if words.count >= 3 {
            let uniqueWords = Set(words)
            if uniqueWords.count == 1 {
                Logger.debug("Hallucination detected: repeated word '\(words.first ?? "")'", subsystem: .transcription)
                return true
            }
        }

        // Check for repeating phrase pattern (e.g., "I'm going to be like, I'm going to be like")
        let maxPhraseLen = words.count / 3
        if maxPhraseLen >= 3 {
            for phraseLen in 3...min(6, maxPhraseLen) {
                let phrase = words.prefix(phraseLen).joined(separator: " ")
                let phraseCount = lower.components(separatedBy: phrase).count - 1
                if phraseCount >= 3 {
                    Logger.debug("Hallucination detected: phrase '\(phrase)' repeated \(phraseCount) times", subsystem: .transcription)
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Stop & Final Pass

    /// Stop streaming and produce final transcription by re-transcribing the full recording.
    /// The final pass uses VAD filtering and dictionary corrections for highest quality.
    func stop() -> String {
        Logger.debug("Stopping StreamingTranscriber...", subsystem: .transcription)

        // Cancel re-transcription timer
        isStopped = true
        reTranscriptionTask?.cancel()
        reTranscriptionTask = nil
        isProcessing = false

        // Get the complete recording for final transcription
        var allSamples: [Float] = []
        do {
            try allSamplesLock.withLock {
                allSamples = allRecordedSamples
            }
        } catch {
            Logger.error("Failed to acquire allSamplesLock in stop(): \(error.localizedDescription)", subsystem: .transcription)
        }

        let totalDuration = Double(allSamples.count) / sampleRate
        Logger.debug("Final pass: re-transcribing \(String(format: "%.1f", totalDuration))s of audio", subsystem: .transcription)

        // Need minimum audio length for meaningful transcription
        let minSamples = Int(0.3 * sampleRate)  // 300ms
        guard allSamples.count >= minSamples else {
            Logger.debug("Recording too short (\(String(format: "%.2f", totalDuration))s), skipping", subsystem: .transcription)
            return clearAndReturn("")
        }

        // VAD check: skip transcription if no speech detected in entire recording
        if let vad = vad, !vad.containsSpeech(samples: allSamples) {
            Logger.debug("VAD: No speech in recording", subsystem: .transcription)
            return clearAndReturn("")
        }

        // Full re-transcription of the complete recording
        let rawText = whisper.transcribe(
            samples: allSamples,
            language: language
        )

        let finalResult: String
        if !rawText.isEmpty {
            finalResult = DictionaryManager.shared.correctText(rawText)
        } else {
            finalResult = ""
        }

        return clearAndReturn(finalResult)
    }

    /// Clear state and return the final result
    private func clearAndReturn(_ result: String) -> String {
        Logger.debug("StreamingTranscriber stopped (\(result.count) chars)", subsystem: .transcription)
        return result
    }

    /// Stop asynchronously with proper cleanup (waits for in-flight re-transcription)
    func stopAsync() async -> String {
        Logger.debug("Stopping StreamingTranscriber (async)...", subsystem: .transcription)

        // Cancel the re-transcription timer first
        isStopped = true
        reTranscriptionTask?.cancel()
        reTranscriptionTask = nil

        // Wait for any in-flight re-transcription to complete
        var waitCount = 0
        while isProcessing && waitCount < 40 {  // Max 2 seconds (40 * 50ms)
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            waitCount += 1
        }

        if isProcessing {
            Logger.warning("In-flight re-transcription still running after 2s, proceeding anyway", subsystem: .transcription)
        } else if waitCount > 0 {
            Logger.debug("In-flight re-transcription completed after \(waitCount * 50)ms", subsystem: .transcription)
        }

        // Now do the synchronous stop (final pass)
        return stop()
    }

    /// Get current full transcription (streaming result, before final pass)
    var currentTranscription: String {
        return fullTranscription
    }

    /// Get total recorded audio duration in seconds
    var recordedDuration: Double {
        do {
            return try allSamplesLock.withLock {
                return Double(allRecordedSamples.count) / sampleRate
            }
        } catch {
            Logger.error("Failed to get recordedDuration: \(error.localizedDescription)", subsystem: .transcription)
            return 0
        }
    }

    /// Save recorded audio to WAV file
    /// - Parameter url: Destination URL for the WAV file
    /// - Returns: True if save was successful
    func saveRecording(to url: URL) -> Bool {
        var samples: [Float] = []
        do {
            try allSamplesLock.withLock {
                samples = allRecordedSamples
            }
        } catch {
            Logger.error("Failed to acquire lock for saveRecording: \(error.localizedDescription)", subsystem: .transcription)
            return false
        }

        guard !samples.isEmpty else {
            Logger.warning("No audio samples to save", subsystem: .transcription)
            return false
        }

        // Create WAV file format: 16kHz mono PCM float32
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            Logger.error("Failed to create audio format", subsystem: .transcription)
            return false
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            Logger.error("Failed to create audio buffer", subsystem: .transcription)
            return false
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        // Copy samples to buffer
        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { ptr in
                guard let baseAddress = ptr.baseAddress else { return }
                channelData[0].update(from: baseAddress, count: samples.count)
            }
        }

        // Write to file
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            Logger.debug("Recording saved to: \(url.lastPathComponent)", subsystem: .transcription)
            return true
        } catch {
            Logger.error("Failed to save recording: \(error.localizedDescription)", subsystem: .transcription)
            return false
        }
    }
}
