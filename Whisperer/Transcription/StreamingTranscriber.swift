//
//  StreamingTranscriber.swift
//  Whisperer
//
//  VAD-chunked transcription pipeline. VAD pre-segments audio into speech regions,
//  merges into bounded chunks (~20s), transcribes each chunk exactly once, stitches results.
//  Replaces the O(n²) re-transcription-of-everything approach.
//

import Foundation
import AVFoundation
import Accelerate

class StreamingTranscriber {
    private var whisper: TranscriptionBackend

    private let sampleRate: Double = 16000.0

    // Memory bounds - maximum recording duration
    private let maxRecordingDuration: Double = 5.0 * 60.0  // 5 minutes
    private var maxRecordingSamples: Int { Int(maxRecordingDuration * sampleRate) }
    private var memoryLimitReached = false

    // Full recording — single source of truth
    private var allRecordedSamples: [Float] = []
    private let allSamplesLock = SafeLock()

    // VAD-chunked pipeline state
    private var vadSegmenter: VADSegmenter
    private var lastVADScanIndex: Int = 0
    private var lastTranscribedSampleIndex: Int = 0
    private var lastClaimedSampleIndex: Int = 0
    private var completedChunkTexts: [String] = []
    private var currentChunkLiveText: String = ""
    private var pendingChunks: [VADSegmenter.AudioChunk] = []
    private var isTranscribingChunk: Bool = false

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

    // Language for transcription
    private var language: TranscriptionLanguage

    // Prompt words for whisper.cpp initial_prompt
    private var initialPrompt: String?

    // VAD scan task
    private var vadScanTask: Task<Void, Never>?
    private var isStopped: Bool = false

    // Filler word removal (applied in final pass)
    private var fillerWordRemovalEnabled: Bool

    // VAD scan interval
    private let vadScanInterval: UInt64 = 500_000_000  // 500ms

    /// Initialize with a pre-loaded backend
    init(
        backend: TranscriptionBackend,
        vad: SileroVAD? = nil,
        language: TranscriptionLanguage = .english,
        initialPrompt: String? = nil,
        fillerWordRemovalEnabled: Bool = false,
        firstRetranscriptionDelay: UInt64 = 1_000_000_000,
        retranscriptionInterval: UInt64 = 1_500_000_000
    ) {
        self.whisper = backend
        self.language = language
        self.initialPrompt = initialPrompt
        self.fillerWordRemovalEnabled = fillerWordRemovalEnabled
        self.vadSegmenter = VADSegmenter(vad: vad, targetChunkDuration: 20.0, silenceForFinalization: 0.8)
    }

    /// Start streaming transcription with VAD-chunked pipeline
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
        lastVADScanIndex = 0
        lastTranscribedSampleIndex = 0
        lastClaimedSampleIndex = 0
        completedChunkTexts = []
        currentChunkLiveText = ""
        pendingChunks = []
        isTranscribingChunk = false

        // Start VAD scan task
        vadScanTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Wait for initial audio to accumulate
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s

            while !Task.isCancelled {
                guard let self = self, !self.isStopped else { break }
                self.scanAndProcessChunks()
                try? await Task.sleep(nanoseconds: self.vadScanInterval)
            }
        }

        Logger.debug("StreamingTranscriber started (VAD-chunked pipeline)", subsystem: .transcription)
    }

    /// Add audio samples from microphone
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

    // MARK: - VAD Scan & Chunk Processing

    /// Scan new audio with VAD, emit chunks, transcribe them
    private func scanAndProcessChunks() {
        // Snapshot audio
        var allSamples: [Float] = []
        do {
            try allSamplesLock.withLock {
                allSamples = allRecordedSamples
            }
        } catch {
            Logger.error("Failed to acquire allSamplesLock in scanAndProcessChunks", subsystem: .transcription)
            return
        }

        guard allSamples.count > Int(0.5 * sampleRate) else { return }

        // Run VAD scan on new audio
        let result = vadSegmenter.scanAndEmitChunks(
            allSamples: allSamples,
            fromIndex: lastVADScanIndex,
            lastTranscribedIndex: lastClaimedSampleIndex
        )
        lastVADScanIndex = result.newScanIndex

        // Queue new chunks and advance claimed index
        if !result.chunks.isEmpty {
            pendingChunks.append(contentsOf: result.chunks)
            if let lastChunk = result.chunks.last {
                lastClaimedSampleIndex = max(lastClaimedSampleIndex, lastChunk.endSample)
            }
            Logger.debug("VAD emitted \(result.chunks.count) chunk(s), \(pendingChunks.count) pending, claimed up to \(lastClaimedSampleIndex)", subsystem: .transcription)
        }

        // Process next pending chunk if not busy
        processNextChunk()
    }

    /// Transcribe the next pending chunk
    private func processNextChunk() {
        guard !isStopped, !isTranscribingChunk, !pendingChunks.isEmpty else { return }

        let chunk = pendingChunks.removeFirst()
        isTranscribingChunk = true
        isProcessing = true

        let chunkDuration = Double(chunk.endSample - chunk.startSample) / sampleRate
        Logger.debug("Transcribing chunk: \(String(format: "%.1f", chunkDuration))s (\(chunk.samples.count) samples)", subsystem: .transcription)

        // Context from previous chunk
        let prevText = completedChunkTexts.last
        let prompt: String?
        if let prev = prevText, !prev.isEmpty {
            // Combine user's initial prompt words with context from previous chunk
            var combinedPrompt = ""
            if let ip = initialPrompt, !ip.isEmpty {
                combinedPrompt = ip + " "
            }
            combinedPrompt += String(prev.suffix(100))
            prompt = combinedPrompt
        } else {
            prompt = initialPrompt
        }

        // Set up live text callback on WhisperBridge if available
        if let bridge = whisper as? WhisperBridge {
            currentChunkLiveText = ""
            bridge.onNewSegment = { [weak self] segmentText in
                guard let self = self else { return }
                self.currentChunkLiveText += (self.currentChunkLiveText.isEmpty ? "" : " ") + segmentText
                self.updateLivePreview()
            }
            bridge.resetAbort()
        }

        whisper.transcribeAsync(
            samples: chunk.samples,
            initialPrompt: prompt,
            language: language,
            singleSegment: true
        ) { [weak self] text in
            guard let self = self else { return }

            // Clear live segment callback
            if let bridge = self.whisper as? WhisperBridge {
                bridge.onNewSegment = nil
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if !trimmed.isEmpty && !self.isHallucination(trimmed) {
                // Deduplicate overlap with previous chunk
                let deduped: String
                if let prevText = self.completedChunkTexts.last, !prevText.isEmpty {
                    deduped = VADSegmenter.deduplicateOverlap(previousText: prevText, newText: trimmed)
                } else {
                    deduped = trimmed
                }

                if !deduped.isEmpty {
                    self.completedChunkTexts.append(deduped)
                }
            }

            // Only advance past this chunk if transcription produced text or we're still
            // recording. During stop, requestAbort() kills in-flight chunks — if we advance
            // the index on an aborted (empty) chunk, the tail pass can't re-transcribe it.
            if !trimmed.isEmpty || !self.isStopped {
                self.lastTranscribedSampleIndex = chunk.endSample
            }
            self.currentChunkLiveText = ""
            self.isTranscribingChunk = false
            self.isProcessing = false

            // Update live preview with completed chunks
            self.updateLivePreview()

            // Process next pending chunk
            self.processNextChunk()
        }
    }

    /// Compose live preview from completed chunks + current chunk text
    private func updateLivePreview() {
        var preview = completedChunkTexts.joined(separator: " ")
        if !currentChunkLiveText.isEmpty {
            if !preview.isEmpty { preview += " " }
            preview += currentChunkLiveText
        }

        fullTranscription = preview

        let text = preview
        DispatchQueue.main.async { [weak self] in
            self?.onTranscription?(text)
        }
    }

    // MARK: - Hallucination Detection

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

    private func isHallucination(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return true }

        if lower.count <= 2 && !lower.contains(where: { $0.isLetter }) {
            return true
        }

        for pattern in Self.hallucinationPatterns {
            if lower == pattern || lower.hasPrefix(pattern) {
                Logger.debug("Hallucination detected: '\(text)' matches pattern '\(pattern)'", subsystem: .transcription)
                return true
            }
        }

        let words = lower.split(separator: " ")
        if words.count >= 3 {
            let uniqueWords = Set(words)
            if uniqueWords.count == 1 {
                return true
            }
        }

        let maxPhraseLen = words.count / 3
        if maxPhraseLen >= 3 {
            for phraseLen in 3...min(6, maxPhraseLen) {
                let phrase = words.prefix(phraseLen).joined(separator: " ")
                let phraseCount = lower.components(separatedBy: phrase).count - 1
                if phraseCount >= 3 {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Stop & Final Pass

    /// Stop streaming and return the best transcription.
    func stop() -> String {
        Logger.debug("Stopping StreamingTranscriber...", subsystem: .transcription)

        isStopped = true
        vadScanTask?.cancel()
        vadScanTask = nil

        // Abort any in-flight transcription
        if let bridge = whisper as? WhisperBridge {
            bridge.requestAbort()
            bridge.onNewSegment = nil
        }

        // Discard any pending chunks — the tail pass will cover unprocessed audio
        pendingChunks.removeAll()

        // Transcribe tail audio (unprocessed samples after last chunk)
        transcribeTail()

        // Combine all chunks
        let rawText = completedChunkTexts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawText.isEmpty else {
            return clearAndReturn("")
        }

        var finalResult = DictionaryManager.shared.correctText(rawText)
        if fillerWordRemovalEnabled {
            finalResult = FillerWordFilter.removeFillers(from: finalResult)
        }

        return clearAndReturn(finalResult)
    }

    /// Transcribe remaining audio after the last completed chunk
    private func transcribeTail() {
        var allSamples: [Float] = []
        do {
            try allSamplesLock.withLock {
                allSamples = allRecordedSamples
            }
        } catch {
            Logger.error("Failed to acquire lock for tail transcription", subsystem: .transcription)
            return
        }

        guard let tailChunk = vadSegmenter.finalizeTail(
            allSamples: allSamples,
            lastTranscribedIndex: lastTranscribedSampleIndex
        ) else {
            Logger.debug("No tail audio to transcribe", subsystem: .transcription)
            return
        }

        let tailDuration = Double(tailChunk.endSample - tailChunk.startSample) / sampleRate
        Logger.debug("Transcribing tail: \(String(format: "%.1f", tailDuration))s", subsystem: .transcription)

        // Context from last chunk
        let prompt: String?
        if let prev = completedChunkTexts.last, !prev.isEmpty {
            var combinedPrompt = ""
            if let ip = initialPrompt, !ip.isEmpty {
                combinedPrompt = ip + " "
            }
            combinedPrompt += String(prev.suffix(100))
            prompt = combinedPrompt
        } else {
            prompt = initialPrompt
        }

        // Reset abort for tail transcription
        if let bridge = whisper as? WhisperBridge {
            bridge.resetAbort()
        }

        // Synchronous transcription for the tail
        let text = whisper.transcribe(
            samples: tailChunk.samples,
            initialPrompt: prompt,
            language: language,
            singleSegment: false,
            maxTokens: 0
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if !text.isEmpty && !isHallucination(text) {
            let deduped: String
            if let prevText = completedChunkTexts.last, !prevText.isEmpty {
                deduped = VADSegmenter.deduplicateOverlap(previousText: prevText, newText: text)
            } else {
                deduped = text
            }
            if !deduped.isEmpty {
                completedChunkTexts.append(deduped)
            }
        }
    }

    private func clearAndReturn(_ result: String) -> String {
        Logger.debug("StreamingTranscriber stopped (\(result.count) chars)", subsystem: .transcription)
        return result
    }

    /// Stop asynchronously with proper cleanup
    func stopAsync() async -> String {
        Logger.debug("Stopping StreamingTranscriber (async)...", subsystem: .transcription)

        isStopped = true
        vadScanTask?.cancel()
        vadScanTask = nil

        // Abort in-flight chunk transcription
        if let bridge = whisper as? WhisperBridge {
            bridge.requestAbort()
        }

        // Wait for in-flight chunk to complete (abort fires within ms)
        var waitCount = 0
        while isTranscribingChunk && waitCount < 40 {  // Max 2 seconds
            try? await Task.sleep(nanoseconds: 50_000_000)
            waitCount += 1
        }

        if isTranscribingChunk {
            Logger.warning("In-flight chunk still transcribing after 2s, proceeding anyway", subsystem: .transcription)
        } else if waitCount > 0 {
            Logger.debug("In-flight chunk completed after \(waitCount * 50)ms", subsystem: .transcription)
        }

        // SpeechAnalyzer: use direct async path
        if #available(macOS 26.0, *), let speechBridge = whisper as? SpeechAnalyzerBridge {
            return await stopWithSpeechAnalyzer(speechBridge)
        }

        return stop()
    }

    /// SpeechAnalyzer-specific async final pass
    @available(macOS 26.0, *)
    private func stopWithSpeechAnalyzer(_ speechBridge: SpeechAnalyzerBridge) async -> String {
        isProcessing = false

        var allSamples: [Float] = []
        do {
            try allSamplesLock.withLock {
                allSamples = allRecordedSamples
            }
        } catch {
            Logger.error("Failed to acquire allSamplesLock in stopWithSpeechAnalyzer", subsystem: .transcription)
        }

        let totalDuration = Double(allSamples.count) / sampleRate
        Logger.debug("SpeechAnalyzer final pass (async): \(String(format: "%.1f", totalDuration))s of audio", subsystem: .transcription)

        let minSamples = Int(0.3 * sampleRate)
        guard allSamples.count >= minSamples else {
            return clearAndReturn("")
        }

        if !hasEnergy(allSamples) {
            return clearAndReturn("")
        }

        let finalPassResult = await speechBridge.transcribeDirectAsync(
            samples: allSamples,
            language: language
        )

        let rawText: String
        if !finalPassResult.isEmpty {
            rawText = finalPassResult
        } else {
            rawText = fullTranscription
        }

        var finalResult: String
        if !rawText.isEmpty {
            finalResult = DictionaryManager.shared.correctText(rawText)
            if fillerWordRemovalEnabled {
                finalResult = FillerWordFilter.removeFillers(from: finalResult)
            }
        } else {
            finalResult = ""
        }

        return clearAndReturn(finalResult)
    }

    // MARK: - Energy Detection

    private func hasEnergy(_ samples: [Float], threshold: Float = 0.003) -> Bool {
        guard !samples.isEmpty else { return false }
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        let rms = sqrt(meanSquare)
        return rms > threshold
    }

    // MARK: - Public Properties

    var currentTranscription: String {
        return fullTranscription
    }

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

        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { ptr in
                guard let baseAddress = ptr.baseAddress else { return }
                channelData[0].update(from: baseAddress, count: samples.count)
            }
        }

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
