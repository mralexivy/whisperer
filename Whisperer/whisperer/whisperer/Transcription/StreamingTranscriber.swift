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
    private let bufferLock = NSLock()

    // Chunk configuration
    private let chunkDuration: Double = 2.0       // Process every 2 seconds
    private let overlapDuration: Double = 0.5     // 0.5 second overlap between chunks
    private let sampleRate: Double = 16000.0

    private var chunkSize: Int { Int(chunkDuration * sampleRate) }       // 32000 samples
    private var overlapSize: Int { Int(overlapDuration * sampleRate) }   // 8000 samples

    // Overlap buffer - carries audio from previous chunk for continuity
    private var overlapBuffer: [Float] = []

    // Full recording for final pass refinement
    private var allRecordedSamples: [Float] = []
    private let allSamplesLock = NSLock()

    // Context carrying - last transcription used as prompt
    private var lastTranscriptionContext: String = ""
    private let contextMaxLength = 100  // Characters to carry as context

    // Thread-safe processing flag
    private let processingLock = NSLock()
    private var _isProcessing = false
    private var isProcessing: Bool {
        get {
            processingLock.lock()
            defer { processingLock.unlock() }
            return _isProcessing
        }
        set {
            processingLock.lock()
            _isProcessing = newValue
            processingLock.unlock()
        }
    }

    private var onTranscription: ((String) -> Void)?
    private var fullTranscription: String = ""

    // VAD state
    private var vadEnabled: Bool = false
    private var lastVADCheckTime: Date = Date()
    private var isSpeechDetected: Bool = true  // Assume speech by default

    /// Initialize with a pre-loaded WhisperBridge and optional VAD
    init(whisperBridge: WhisperBridge, vad: SileroVAD? = nil) {
        self.whisper = whisperBridge
        self.vad = vad
        self.vadEnabled = vad != nil
    }

    /// Start streaming transcription
    func start(onTranscription: @escaping (String) -> Void) {
        self.onTranscription = onTranscription
        bufferLock.lock()
        audioBuffer.removeAll()
        overlapBuffer.removeAll()
        bufferLock.unlock()

        allSamplesLock.lock()
        allRecordedSamples.removeAll()
        allSamplesLock.unlock()

        fullTranscription = ""
        lastTranscriptionContext = ""
        isProcessing = false
        isSpeechDetected = true
        print("StreamingTranscriber started (overlap: \(overlapDuration)s, VAD: \(vadEnabled))")
    }

    /// Add audio samples from microphone (should be 16kHz mono float32)
    func addSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        // Store all samples for final pass
        allSamplesLock.lock()
        allRecordedSamples.append(contentsOf: samples)
        allSamplesLock.unlock()

        bufferLock.lock()
        audioBuffer.append(contentsOf: samples)
        let currentCount = audioBuffer.count
        bufferLock.unlock()

        // Only log periodically to reduce overhead
        if currentCount % 16000 < 2000 {
            print("📊 Buffer: \(currentCount)/\(chunkSize) samples (\(Int(Double(currentCount)/Double(chunkSize)*100))%)")
        }

        // Check if we should process a chunk
        if currentCount >= chunkSize && !isProcessing {
            // VAD is disabled for now - it was blocking all speech detection
            // The final pass refinement handles transcription accurately without it
            // TODO: Re-enable VAD when we can resolve the chunk_len < n_window issue

            print("🚀 Buffer full, processing chunk...")
            processChunk()
        }
    }

    private func processChunk() {
        isProcessing = true

        bufferLock.lock()
        // Prepend overlap from previous chunk for continuity
        var chunk = overlapBuffer + audioBuffer

        // Save overlap for next chunk (last 0.5s of current buffer)
        overlapBuffer = Array(audioBuffer.suffix(overlapSize))
        audioBuffer.removeAll()
        bufferLock.unlock()

        guard !chunk.isEmpty else {
            print("⚠️ Skipping chunk: empty")
            isProcessing = false
            return
        }

        print("🔄 Processing chunk of \(chunk.count) samples (with \(overlapSize) overlap)...")

        // Get context from last transcription
        let context = lastTranscriptionContext

        // Transcribe in background with context
        whisper.transcribeAsync(samples: chunk, initialPrompt: context.isEmpty ? nil : context) { [weak self] text in
            guard let self = self else { return }

            print("📝 Transcription result: '\(text)'")

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
            print("🔀 Deduplicated: removed \(overlapCount) overlapping words")
            return deduplicated
        }

        return newText
    }

    /// Stop and perform final pass transcription on complete audio
    func stop() -> String {
        print("⏹️ Stopping StreamingTranscriber...")

        // Wait for any in-flight async transcription to complete
        let startTime = Date()
        var waitCount = 0
        while isProcessing && Date().timeIntervalSince(startTime) < 3.0 {
            Thread.sleep(forTimeInterval: 0.05)
            waitCount += 1
        }

        if isProcessing {
            print("⚠️ Timeout waiting for in-flight transcription after \(waitCount * 50)ms")
        } else if waitCount > 0 {
            print("✅ In-flight transcription completed after \(waitCount * 50)ms")
        }

        // Get all recorded audio for final pass
        allSamplesLock.lock()
        let allSamples = allRecordedSamples
        allSamplesLock.unlock()

        // Final pass: re-transcribe entire audio for best accuracy
        if !allSamples.isEmpty {
            print("🎯 Final pass: transcribing \(allSamples.count) total samples...")
            let finalText = whisper.transcribe(samples: allSamples)
            if !finalText.isEmpty {
                // Use final pass result as it's more accurate with full context
                fullTranscription = finalText
                print("✅ Final pass completed: '\(finalText)'")
            }
        }

        // Clear buffers
        bufferLock.lock()
        audioBuffer.removeAll()
        overlapBuffer.removeAll()
        bufferLock.unlock()

        print("✅ StreamingTranscriber stopped. Final: '\(fullTranscription)'")

        return fullTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Get current full transcription (streaming result, before final pass)
    var currentTranscription: String {
        return fullTranscription
    }

    /// Get total recorded audio duration in seconds
    var recordedDuration: Double {
        allSamplesLock.lock()
        let count = allRecordedSamples.count
        allSamplesLock.unlock()
        return Double(count) / sampleRate
    }

    /// Save recorded audio to WAV file
    /// - Parameter url: Destination URL for the WAV file
    /// - Returns: True if save was successful
    func saveRecording(to url: URL) -> Bool {
        allSamplesLock.lock()
        let samples = allRecordedSamples
        allSamplesLock.unlock()

        guard !samples.isEmpty else {
            print("⚠️ No audio samples to save")
            return false
        }

        // Create WAV file format: 16kHz mono PCM float32
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            print("❌ Failed to create audio format")
            return false
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            print("❌ Failed to create audio buffer")
            return false
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        // Copy samples to buffer
        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { ptr in
                channelData[0].update(from: ptr.baseAddress!, count: samples.count)
            }
        }

        // Write to file
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            print("✅ Recording saved to: \(url.path)")
            return true
        } catch {
            print("❌ Failed to save recording: \(error)")
            return false
        }
    }
}
