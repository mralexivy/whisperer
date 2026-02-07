//
//  StreamingTranscriber.swift
//  Whisperer
//
//  Real-time audio transcription using whisper.cpp
//  Features: chunk overlap, context carrying, VAD integration, final pass refinement
//

import Foundation
import AVFoundation

class StreamingTranscriber {
    private var whisper: WhisperBridge
    private var vad: SileroVAD?
    private var audioBuffer: [Float] = []
    private let bufferLock = SafeLock()

    // Chunk configuration
    private let chunkDuration: Double = 2.0       // Process every 2 seconds
    private let overlapDuration: Double = 0.5     // 0.5 second overlap between chunks
    private let sampleRate: Double = 16000.0

    private var chunkSize: Int { Int(chunkDuration * sampleRate) }       // 32000 samples
    private var overlapSize: Int { Int(overlapDuration * sampleRate) }   // 8000 samples

    // Memory bounds - maximum recording duration
    private let maxRecordingDuration: Double = 5.0 * 60.0  // 5 minutes
    private var maxRecordingSamples: Int { Int(maxRecordingDuration * sampleRate) }  // 4,800,000 samples (~19MB)
    private var memoryLimitReached = false

    // Overlap buffer - carries audio from previous chunk for continuity
    private var overlapBuffer: [Float] = []

    // Full recording for final pass refinement
    private var allRecordedSamples: [Float] = []
    private let allSamplesLock = SafeLock()

    // Context carrying - last transcription used as prompt
    private var lastTranscriptionContext: String = ""
    private let contextMaxLength = 100  // Characters to carry as context

    // Thread-safe processing flag
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
    private var fullTranscription: String = ""

    // VAD state
    private var vadEnabled: Bool = false
    private var lastVADCheckTime: Date = Date()
    private var isSpeechDetected: Bool = true  // Assume speech by default

    // Language for transcription
    private var language: TranscriptionLanguage

    /// Initialize with a pre-loaded WhisperBridge, optional VAD, and language setting
    init(whisperBridge: WhisperBridge, vad: SileroVAD? = nil, language: TranscriptionLanguage = .english) {
        self.whisper = whisperBridge
        self.vad = vad
        self.vadEnabled = vad != nil
        self.language = language
    }

    /// Start streaming transcription
    func start(onTranscription: @escaping (String) -> Void) {
        self.onTranscription = onTranscription

        do {
            try bufferLock.withLock {
                audioBuffer.removeAll()
                overlapBuffer.removeAll()
            }

            try allSamplesLock.withLock {
                allRecordedSamples.removeAll()
            }
        } catch {
            Logger.error("Failed to acquire lock in start(): \(error.localizedDescription)", subsystem: .transcription)
        }

        fullTranscription = ""
        lastTranscriptionContext = ""
        isProcessing = false
        isSpeechDetected = true
        memoryLimitReached = false

        Logger.debug("StreamingTranscriber started (overlap: \(overlapDuration)s, VAD: \(vadEnabled))", subsystem: .transcription)
    }

    /// Add audio samples from microphone (should be 16kHz mono float32)
    func addSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        // Check memory limit first
        if memoryLimitReached {
            // Silently drop samples if we've reached the limit
            return
        }

        // Store all samples for final pass
        var totalCount = 0
        do {
            try allSamplesLock.withLock {
                // Check if adding these samples would exceed the limit
                if allRecordedSamples.count + samples.count > maxRecordingSamples {
                    Logger.warning("Memory limit reached (\(String(format: "%.1f", maxRecordingDuration/60))min), stopping sample collection", subsystem: .transcription)
                    memoryLimitReached = true

                    // Add what we can up to the limit
                    let remainingCapacity = maxRecordingSamples - allRecordedSamples.count
                    if remainingCapacity > 0 {
                        allRecordedSamples.append(contentsOf: samples.prefix(remainingCapacity))
                    }
                    totalCount = allRecordedSamples.count
                } else {
                    allRecordedSamples.append(contentsOf: samples)
                    totalCount = allRecordedSamples.count
                }
            }
        } catch {
            Logger.error("Failed to acquire allSamplesLock: \(error.localizedDescription)", subsystem: .transcription)
            return
        }

        // If we just hit the limit, warn the user
        if memoryLimitReached {
            Logger.warning("Recording has reached maximum duration of \(String(format: "%.1f", maxRecordingDuration/60)) minutes", subsystem: .transcription)
            return
        }

        // Add to processing buffer
        var currentCount = 0
        do {
            try bufferLock.withLock {
                audioBuffer.append(contentsOf: samples)
                currentCount = audioBuffer.count
            }
        } catch {
            Logger.error("Failed to acquire bufferLock: \(error.localizedDescription)", subsystem: .transcription)
            return
        }

        // Only log periodically to reduce overhead
        if currentCount % 16000 < 2000 {
            let progress = Int(Double(currentCount)/Double(chunkSize)*100)
            let duration = Double(totalCount) / sampleRate
            Logger.debug("Buffer: \(currentCount)/\(chunkSize) samples (\(progress)%), total: \(String(format: "%.1f", duration))s", subsystem: .transcription)
        }

        // Check if we should process a chunk
        if currentCount >= chunkSize && !isProcessing {
            Logger.debug("Buffer full, processing chunk...", subsystem: .transcription)
            processChunk()
        }
    }

    private func processChunk() {
        isProcessing = true

        var chunk: [Float] = []
        do {
            try bufferLock.withLock {
                // Prepend overlap from previous chunk for continuity
                chunk = overlapBuffer + audioBuffer

                // Save overlap for next chunk (last 0.5s of current buffer)
                overlapBuffer = Array(audioBuffer.suffix(overlapSize))
                audioBuffer.removeAll()
            }
        } catch {
            Logger.error("Failed to acquire bufferLock in processChunk: \(error.localizedDescription)", subsystem: .transcription)
            isProcessing = false
            return
        }

        guard !chunk.isEmpty else {
            Logger.warning("Skipping chunk: empty", subsystem: .transcription)
            isProcessing = false
            return
        }

        Logger.debug("Processing chunk of \(chunk.count) samples (with \(overlapSize) overlap)...", subsystem: .transcription)

        // Get context from last transcription
        let context = lastTranscriptionContext

        // Transcribe in background with context and language
        whisper.transcribeAsync(samples: chunk, initialPrompt: context.isEmpty ? nil : context, language: language) { [weak self] text in
            guard let self = self else { return }

            Logger.debug("Transcription result: '\(text)'", subsystem: .transcription)

            if !text.isEmpty {
                // Deduplicate text if there's overlap
                let deduplicatedText = self.deduplicateText(newText: text, previousContext: context)

                self.fullTranscription += deduplicatedText + " "

                // Update context for next chunk (last N characters)
                let fullText = self.fullTranscription
                if fullText.count > self.contextMaxLength {
                    self.lastTranscriptionContext = String(fullText.suffix(self.contextMaxLength))
                } else {
                    self.lastTranscriptionContext = fullText
                }

                // Dispatch UI callback to main queue
                let transcription = self.fullTranscription
                DispatchQueue.main.async {
                    self.onTranscription?(transcription)
                }
            }

            self.isProcessing = false
        }
    }

    /// Remove duplicate text that might appear due to overlap
    private func deduplicateText(newText: String, previousContext: String) -> String {
        guard !previousContext.isEmpty else { return newText }

        // Find common suffix of context and prefix of new text
        let contextWords = previousContext.split(separator: " ").map(String.init)
        let newWords = newText.split(separator: " ").map(String.init)

        guard !contextWords.isEmpty && !newWords.isEmpty else { return newText }

        // Check for word overlap at boundary
        var overlapCount = 0
        for i in 1...min(5, contextWords.count, newWords.count) {
            let contextSuffix = contextWords.suffix(i)
            let newPrefix = newWords.prefix(i)

            // Check if they match (case-insensitive)
            let contextStr = contextSuffix.joined(separator: " ").lowercased()
            let newStr = newPrefix.joined(separator: " ").lowercased()

            if contextStr == newStr {
                overlapCount = i
            }
        }

        if overlapCount > 0 {
            // Remove overlapping words from new text
            let deduplicated = newWords.dropFirst(overlapCount).joined(separator: " ")
            Logger.debug("Deduplicated: removed \(overlapCount) overlapping words", subsystem: .transcription)
            return deduplicated
        }

        return newText
    }

    /// Stop and perform final pass transcription on complete audio (non-blocking)
    func stop() -> String {
        Logger.debug("Stopping StreamingTranscriber...", subsystem: .transcription)

        // Mark as not processing to prevent new chunks
        isProcessing = false

        // Get all recorded audio for final pass
        var allSamples: [Float] = []
        do {
            try allSamplesLock.withLock {
                allSamples = allRecordedSamples
            }
        } catch {
            Logger.error("Failed to acquire allSamplesLock in stop(): \(error.localizedDescription)", subsystem: .transcription)
        }

        // Final pass: re-transcribe entire audio for best accuracy
        // This runs on whisper's background queue, not blocking main thread
        if !allSamples.isEmpty {
            let duration = Double(allSamples.count) / sampleRate
            Logger.debug("Final pass: \(String(format: "%.1f", duration))s of audio", subsystem: .transcription)
            let rawText = whisper.transcribe(samples: allSamples, language: language)
            if !rawText.isEmpty {
                // Apply dictionary corrections if enabled
                let finalText = DictionaryManager.shared.correctText(rawText)
                // Use final pass result as it's more accurate with full context
                fullTranscription = finalText
            }
        }

        // Clear buffers
        do {
            try bufferLock.withLock {
                audioBuffer.removeAll()
                overlapBuffer.removeAll()
            }
        } catch {
            Logger.error("Failed to acquire bufferLock in stop(): \(error.localizedDescription)", subsystem: .transcription)
        }

        Logger.debug("StreamingTranscriber stopped (\(fullTranscription.count) chars)", subsystem: .transcription)

        return fullTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stop asynchronously with proper cleanup (waits for in-flight operations)
    func stopAsync() async -> String {
        Logger.debug("Stopping StreamingTranscriber (async)...", subsystem: .transcription)

        // Wait briefly for any in-flight transcription
        var waitCount = 0
        while isProcessing && waitCount < 40 {  // Max 2 seconds (40 * 50ms)
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            waitCount += 1
        }

        if isProcessing {
            Logger.warning("In-flight transcription still running after 2s, proceeding anyway", subsystem: .transcription)
        } else if waitCount > 0 {
            Logger.debug("In-flight transcription completed after \(waitCount * 50)ms", subsystem: .transcription)
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
