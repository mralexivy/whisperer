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

    // Track how far streaming has processed for tail-only final pass
    private var lastProcessedSampleIndex: Int = 0

    // Context carrying - last transcription used as prompt (see thread-safe properties above)
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

    private var _lastTranscriptionContext: String = ""
    private var lastTranscriptionContext: String {
        get {
            do {
                return try transcriptionLock.withLock(timeout: 1.0) { _lastTranscriptionContext }
            } catch {
                Logger.error("Failed to get lastTranscriptionContext: \(error.localizedDescription)", subsystem: .transcription)
                return ""
            }
        }
        set {
            do {
                try transcriptionLock.withLock(timeout: 1.0) { _lastTranscriptionContext = newValue }
            } catch {
                Logger.error("Failed to set lastTranscriptionContext: \(error.localizedDescription)", subsystem: .transcription)
            }
        }
    }

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
        lastProcessedSampleIndex = 0

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

        // VAD check: skip whisper transcription if chunk contains no speech
        // Uses lightweight hasSpeech() to avoid full segment computation
        if let vad = vad, !vad.hasSpeech(samples: chunk) {
            Logger.debug("VAD: No speech in chunk (\(chunk.count) samples), skipping transcription", subsystem: .transcription)
            isProcessing = false
            return
        }

        Logger.debug("Processing chunk of \(chunk.count) samples (with \(overlapSize) overlap)...", subsystem: .transcription)

        // Get context from last transcription
        let context = lastTranscriptionContext

        // Transcribe in background with context, language, and single-segment mode for short chunks
        whisper.transcribeAsync(samples: chunk, initialPrompt: context.isEmpty ? nil : context, language: language, singleSegment: true) { [weak self] text in
            guard let self = self else { return }

            Logger.debug("Transcription result: '\(text)'", subsystem: .transcription)

            // Update processed sample index (streaming has covered up to this point)
            do {
                try self.allSamplesLock.withLock {
                    self.lastProcessedSampleIndex = self.allRecordedSamples.count
                }
            } catch {
                Logger.error("Failed to update lastProcessedSampleIndex: \(error.localizedDescription)", subsystem: .transcription)
            }

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

    /// Stop and perform tail-only final pass on unprocessed audio
    /// Instead of re-transcribing everything, only process audio that arrived after the last chunk.
    func stop() -> String {
        Logger.debug("Stopping StreamingTranscriber...", subsystem: .transcription)

        // Mark as not processing to prevent new chunks
        isProcessing = false

        // Get unprocessed tail audio (samples after the last fully processed chunk)
        var tailSamples: [Float] = []
        var totalDuration: Double = 0
        do {
            try allSamplesLock.withLock {
                totalDuration = Double(allRecordedSamples.count) / sampleRate
                if lastProcessedSampleIndex < allRecordedSamples.count {
                    tailSamples = Array(allRecordedSamples[lastProcessedSampleIndex...])
                }
            }
        } catch {
            Logger.error("Failed to acquire allSamplesLock in stop(): \(error.localizedDescription)", subsystem: .transcription)
        }

        let tailDuration = Double(tailSamples.count) / sampleRate
        Logger.debug("Final pass: \(String(format: "%.1f", tailDuration))s tail of \(String(format: "%.1f", totalDuration))s total", subsystem: .transcription)

        // Only transcribe tail if it's long enough to contain meaningful speech (>0.3s)
        let minTailSamples = Int(0.3 * sampleRate)  // 4800 samples
        if tailSamples.count >= minTailSamples {
            // VAD-filter the tail to skip silence
            let samplesToTranscribe: [Float]
            if let vad = vad {
                let speechSegments = vad.detectSpeechSegments(samples: tailSamples)

                if speechSegments.isEmpty {
                    Logger.debug("VAD: No speech in tail, skipping tail transcription", subsystem: .transcription)
                    samplesToTranscribe = []
                } else {
                    var speechAudio: [Float] = []
                    for segment in speechSegments {
                        let start = min(segment.startSample, tailSamples.count)
                        let end = min(segment.endSample, tailSamples.count)
                        guard start < end else { continue }
                        speechAudio.append(contentsOf: tailSamples[start..<end])
                    }
                    samplesToTranscribe = speechAudio
                }
            } else {
                samplesToTranscribe = tailSamples
            }

            if !samplesToTranscribe.isEmpty {
                // Use streaming context as prompt for continuity
                let context = lastTranscriptionContext
                let tailText = whisper.transcribe(
                    samples: samplesToTranscribe,
                    initialPrompt: context.isEmpty ? nil : context,
                    language: language
                )

                if !tailText.isEmpty {
                    let deduplicatedTail = deduplicateText(newText: tailText, previousContext: context)
                    if !deduplicatedTail.isEmpty {
                        fullTranscription += deduplicatedTail + " "
                    }
                }
            }
        } else if !tailSamples.isEmpty {
            Logger.debug("Tail too short (\(String(format: "%.2f", tailDuration))s), skipping tail transcription", subsystem: .transcription)
        }

        // Apply dictionary corrections to the combined streaming + tail result
        let rawResult = fullTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalResult: String
        if !rawResult.isEmpty {
            finalResult = DictionaryManager.shared.correctText(rawResult)
        } else if vad != nil {
            // Check if the full recording had any speech at all
            var allSamples: [Float] = []
            do {
                try allSamplesLock.withLock {
                    allSamples = allRecordedSamples
                }
            } catch {
                Logger.error("Failed to acquire allSamplesLock for VAD check: \(error.localizedDescription)", subsystem: .transcription)
            }

            if !allSamples.isEmpty && !vad!.containsSpeech(samples: allSamples) {
                Logger.debug("VAD: No speech in entire recording", subsystem: .transcription)
                finalResult = ""
            } else {
                finalResult = rawResult
            }
        } else {
            finalResult = rawResult
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

        Logger.debug("StreamingTranscriber stopped (\(finalResult.count) chars)", subsystem: .transcription)

        return finalResult
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
