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

    // Feedback sound window — skip initial samples containing start sound
    // Sound plays at T=0, lasts ~100ms. Use 150ms margin for safety.
    private let feedbackSoundDuration: Double = 0.15  // 150ms
    private var feedbackSoundSamples: Int { Int(feedbackSoundDuration * sampleRate) }  // 2400 samples

    // Memory bounds - maximum recording duration
    private let maxRecordingDuration: Double = 5.0 * 60.0  // 5 minutes
    private var maxRecordingSamples: Int { Int(maxRecordingDuration * sampleRate) }
    private var memoryLimitReached = false

    // Full recording — single source of truth
    private var allRecordedSamples: [Float] = []
    private let allSamplesLock = SafeLock()

    // VAD-chunked pipeline state
    private let vad: SileroVAD?  // Separate ref for language detection filtering
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
    var isProcessing: Bool {
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
    var onLanguageDetected: ((TranscriptionLanguage) -> Void)?

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
    private var previewTask: Task<Void, Never>?
    private var isStopped: Bool = false
    private var lastPreviewedSampleIndex: Int = 0
    private var previewAccumulatedText: String = ""
    private var previewPassID: Int = 0

    // Filler word removal (applied in final pass)
    private var fillerWordRemovalEnabled: Bool

    // VAD scan interval
    private let vadScanInterval: UInt64 = 500_000_000  // 500ms

    // MARK: - Language Routing

    private var modelPool: ModelPool?
    private var languageRouter: LanguageRouter?
    private var modelRouter: ModelRouter?
    private var previewBridge: WhisperBridge?  // CPU-only tiny model for live preview
    private var routeDecision: ModelRouteDecision?
    private var detectionAttempts: Int = 0
    private var lastDetectionSampleCount: Int = 0
    private var scriptMismatchCount: Int = 0
    private var chunkLangMismatchCount: Int = 0  // Weak signal from whisper_full_lang_id
    private var lastSilenceStart: Date?
    private var newUtteranceAfterSilence: Bool = false

    // Promotion state — serialized via promotionQueue
    private let promotionQueue = DispatchQueue(label: "streaming.promotion")
    private var pendingPromotion: (backend: TranscriptionBackend, profile: ModelProfile)?

    /// Effective language for transcription — driven by router or fallback to configured language
    private var effectiveLanguage: TranscriptionLanguage {
        routeDecision?.lang ?? language
    }

    /// Initialize with a pre-loaded backend
    init(
        backend: TranscriptionBackend,
        vad: SileroVAD? = nil,
        language: TranscriptionLanguage = .english,
        initialPrompt: String? = nil,
        fillerWordRemovalEnabled: Bool = false,
        firstRetranscriptionDelay: UInt64 = 1_000_000_000,
        retranscriptionInterval: UInt64 = 1_500_000_000,
        modelPool: ModelPool? = nil,
        languageRouter: LanguageRouter? = nil,
        modelRouter: ModelRouter? = nil,
        previewBridge: WhisperBridge? = nil
    ) {
        self.whisper = backend
        self.vad = vad
        self.language = language
        self.initialPrompt = initialPrompt
        self.fillerWordRemovalEnabled = fillerWordRemovalEnabled
        self.modelPool = modelPool
        self.languageRouter = languageRouter
        self.previewBridge = previewBridge
        self.modelRouter = modelRouter
        self.vadSegmenter = VADSegmenter(vad: vad, targetChunkDuration: 6.0, silenceForFinalization: 0.5)
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
        routeDecision = nil
        detectionAttempts = 0
        lastDetectionSampleCount = 0
        scriptMismatchCount = 0
        chunkLangMismatchCount = 0
        lastSilenceStart = nil
        newUtteranceAfterSilence = false
        pendingPromotion = nil
        languageRouter?.reset()
        // Start indices after feedback sound window to skip start sound capture
        lastVADScanIndex = feedbackSoundSamples
        lastTranscribedSampleIndex = feedbackSoundSamples
        lastClaimedSampleIndex = feedbackSoundSamples
        completedChunkTexts = []
        currentChunkLiveText = ""
        pendingChunks = []
        isTranscribingChunk = false
        lastPreviewedSampleIndex = feedbackSoundSamples  // Skip feedback sound window
        previewAccumulatedText = ""
        previewPassID = 0

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

        // Start preview after language detection resolves (state-machine gate)
        previewTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Wait for language detection or 5s timeout
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms poll
                guard let self, !self.isStopped else { return }
                if self.routeDecision != nil || self.modelPool == nil { break }
            }

            // Preview loop — every 1s
            while !Task.isCancelled {
                guard let self, !self.isStopped else { break }
                self.runLivePreviewPass()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        Logger.debug("StreamingTranscriber started (VAD-chunked pipeline + live preview)", subsystem: .transcription)
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

        // Language detection — detect before first chunk, retry if undecided
        if routeDecision == nil,
           detectionAttempts < RoutingThresholds.maxDetectionAttempts,
           let pool = modelPool, let langRouter = languageRouter, let mdlRouter = modelRouter {
            // First attempt at 4s, retries at +2s intervals
            let targetSamples = RoutingThresholds.targetDetectionSamples
                + (detectionAttempts * RoutingThresholds.retryGrowth)
            if allSamples.count >= targetSamples, allSamples.count > lastDetectionSampleCount {
                lastDetectionSampleCount = allSamples.count
                // Use latest audio (suffix) — has more speech signal than beginning
                let windowSize = min(allSamples.count, RoutingThresholds.targetDetectionSamples)
                let wasAttempted = performLanguageDetection(
                    samples: Array(allSamples.suffix(windowSize)),
                    pool: pool,
                    langRouter: langRouter,
                    mdlRouter: mdlRouter
                )
                // Only consume retry budget when detection was actually attempted
                // (not skipped due to insufficient voiced audio)
                if wasAttempted {
                    detectionAttempts += 1
                }
                if routeDecision == nil {
                    Logger.debug("Detection attempt \(detectionAttempts)/\(RoutingThresholds.maxDetectionAttempts) undecided, will retry with more audio", subsystem: .transcription)
                }
            }
        }

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

        // Check for deferred model promotion at chunk boundary
        drainPromotionQueue()

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

        let normalizedSamples = normalizeSamples(chunk.samples)

        whisper.transcribeAsync(
            samples: normalizedSamples,
            initialPrompt: prompt,
            language: effectiveLanguage,
            singleSegment: true
        ) { [weak self] text in
            guard let self = self else { return }

            // Clear live segment callback
            if let bridge = self.whisper as? WhisperBridge {
                bridge.onNewSegment = nil
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if !trimmed.isEmpty && !self.isHallucination(trimmed) {
                // Post-chunk script stabilizer — check for language mismatches
                self.checkScriptStability(chunkText: trimmed)

                // Weak reinforcement from whisper_full_lang_id (decoder state, not independent detection)
                if let bridge = self.whisper as? WhisperBridge,
                   let detectedCode = bridge.lastDetectedLanguage,
                   let detectedLang = TranscriptionLanguage(rawValue: detectedCode),
                   let langRouter = self.languageRouter,
                   case .locked(let lockedLang) = langRouter.state {
                    if detectedLang != lockedLang {
                        self.chunkLangMismatchCount += 1
                    } else {
                        self.chunkLangMismatchCount = max(0, self.chunkLangMismatchCount - 1)
                    }
                }

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
                // Clear preview accumulated text — chunk covers this audio now
                self.previewAccumulatedText = ""
                self.lastPreviewedSampleIndex = chunk.endSample
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

    // MARK: - Live Preview Pass

    /// Append-only live preview using tiny model.
    /// Transcribes only NEW audio since last pass with ~0.5s overlap for boundary quality.
    /// Text only grows (monotonic) — `SmoothTextUpdater.hasPrefix` always succeeds.
    private func runLivePreviewPass() {
        guard let preview = previewBridge, !isTranscribingChunk else { return }

        var allSamples: [Float] = []
        do {
            try allSamplesLock.withLock {
                allSamples = allRecordedSamples
            }
        } catch { return }

        // Compute start with 0.5s overlap for boundary quality
        let overlapSamples = Int(0.5 * sampleRate)
        let tailStart = max(lastTranscribedSampleIndex,
                           lastPreviewedSampleIndex > overlapSamples ? lastPreviewedSampleIndex - overlapSamples : 0)

        // Need at least 1s of new audio
        guard allSamples.count > tailStart + Int(1.0 * sampleRate) else { return }

        // Extract window (max 3s to keep it fast)
        let maxWindowSamples = Int(3.0 * sampleRate)
        let endIndex = min(allSamples.count, tailStart + maxWindowSamples)
        let windowSamples = Array(allSamples[tailStart..<endIndex])
        let candidateEndIndex = endIndex

        // VAD check: skip preview pass if no speech detected
        if let vad = vad, !vad.hasSpeech(samples: windowSamples) {
            return
        }

        let normalizedSamples = normalizeSamples(windowSamples)
        let lang = effectiveLanguage

        // Context prompt from accumulated preview text
        let prompt: String?
        if !previewAccumulatedText.isEmpty {
            var combined = ""
            if let ip = initialPrompt, !ip.isEmpty { combined = ip + " " }
            combined += String(previewAccumulatedText.suffix(50))
            prompt = combined
        } else if let prev = completedChunkTexts.last, !prev.isEmpty {
            var combined = ""
            if let ip = initialPrompt, !ip.isEmpty { combined = ip + " " }
            combined += String(prev.suffix(50))
            prompt = combined
        } else {
            prompt = initialPrompt
        }

        // Assign pass ID for ordering
        previewPassID += 1
        let currentPassID = previewPassID

        preview.transcribeAsync(
            samples: normalizedSamples,
            initialPrompt: prompt,
            language: lang,
            singleSegment: true,
            maxTokens: 0
        ) { [weak self] text in
            guard let self, !self.isStopped else { return }

            // Discard out-of-order callbacks
            guard currentPassID == self.previewPassID else { return }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !self.isHallucination(trimmed) else { return }

            // Dedup overlap between accumulated tail and new text
            let deduped = self.deduplicateOverlap(existing: self.previewAccumulatedText, new: trimmed)

            // Append (never replace)
            if !deduped.isEmpty {
                if self.previewAccumulatedText.isEmpty {
                    self.previewAccumulatedText = deduped
                } else {
                    self.previewAccumulatedText += " " + deduped
                }
            }

            // Advance sample index on success
            self.lastPreviewedSampleIndex = candidateEndIndex

            // Build display: completed chunks + accumulated preview
            var display = self.completedChunkTexts.joined(separator: " ")
            if !display.isEmpty && !self.previewAccumulatedText.isEmpty {
                display += " "
            }
            display += self.previewAccumulatedText

            self.fullTranscription = display

            DispatchQueue.main.async { [weak self] in
                self?.onTranscription?(display)
            }

            Logger.debug("LivePreview: +\(deduped.split(separator: " ").count) words (total \(display.count) chars)", subsystem: .transcription)
        }
    }

    /// Dedup overlap words between existing accumulated text and new preview text
    private func deduplicateOverlap(existing: String, new: String) -> String {
        let existingWords = existing.split(separator: " ")
        let newWords = new.split(separator: " ")
        guard !existingWords.isEmpty, !newWords.isEmpty else { return new }

        let maxOverlap = min(5, min(existingWords.count, newWords.count))
        for len in stride(from: maxOverlap, through: 1, by: -1) {
            if existingWords.suffix(len).elementsEqual(newWords.prefix(len)) {
                let remaining = newWords.dropFirst(len).joined(separator: " ")
                return remaining
            }
        }
        return new
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
        previewTask?.cancel()
        previewTask = nil

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

        // Energy check as secondary guard (when VAD is nil)
        if !hasEnergy(tailChunk.samples) {
            Logger.debug("Tail audio has no energy, skipping", subsystem: .transcription)
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
        let normalizedSamples = normalizeSamples(tailChunk.samples)
        let text = whisper.transcribe(
            samples: normalizedSamples,
            initialPrompt: prompt,
            language: effectiveLanguage,
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
        previewTask?.cancel()
        previewTask = nil

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

    // MARK: - Audio Normalization

    /// Peak-normalize samples to target amplitude for consistent Whisper input levels.
    /// Quiet recordings benefit significantly from normalization — Whisper's encoder
    /// produces stronger activations with higher-amplitude input.
    private func normalizeSamples(_ samples: [Float], targetPeak: Float = 0.707) -> [Float] {
        guard !samples.isEmpty else { return samples }

        var maxVal: Float = 0
        vDSP_maxmgv(samples, 1, &maxVal, vDSP_Length(samples.count))

        // Skip if effectively silent (below noise floor)
        guard maxVal > 0.001 else { return samples }
        // Skip if already near target level
        guard maxVal < targetPeak * 0.9 else { return samples }

        let gain = targetPeak / maxVal
        // Cap gain to prevent amplifying noise in very quiet recordings
        let cappedGain = min(gain, 20.0)  // Max 20x boost (~26dB)

        var result = [Float](repeating: 0, count: samples.count)
        var gainVar = cappedGain
        vDSP_vsmul(samples, 1, &gainVar, &result, 1, vDSP_Length(samples.count))

        Logger.debug("Audio normalized: peak \(String(format: "%.4f", maxVal)) → \(String(format: "%.4f", maxVal * cappedGain)), gain \(String(format: "%.1f", cappedGain))x", subsystem: .transcription)

        return result
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

    /// Trim non-speech prefix from audio samples (removes feedback sound capture)
    /// Uses VAD to find first speech onset and trims everything before it
    private func trimLeadingNonSpeech(_ samples: [Float]) -> [Float] {
        guard let vad = vad else { return samples }  // No VAD = no trim

        // Only analyze first 300ms (4800 samples at 16kHz)
        let analysisWindow = min(samples.count, Int(0.3 * sampleRate))
        guard analysisWindow > Int(0.1 * sampleRate) else { return samples }  // Too short to trim

        let windowSamples = Array(samples.prefix(analysisWindow))
        let segments = vad.detectSpeechSegments(samples: windowSamples)

        guard let firstSegment = segments.first else {
            // No speech in first 300ms — trim the feedback sound window
            if samples.count > feedbackSoundSamples {
                Logger.debug("No speech in first 300ms, trimming \(feedbackSoundSamples) samples", subsystem: .transcription)
                return Array(samples.dropFirst(feedbackSoundSamples))
            }
            return samples
        }

        // Find first speech onset sample
        let speechStartSample = firstSegment.startSample

        // Apply 50ms lookback for natural speech attack
        let lookbackSamples = Int(0.05 * sampleRate)  // 800 samples
        let trimPoint = max(0, speechStartSample - lookbackSamples)

        if trimPoint > 0 {
            Logger.debug("Trimming \(trimPoint) samples (\(Int(Double(trimPoint) / sampleRate * 1000))ms) of leading non-speech", subsystem: .transcription)
            return Array(samples.dropFirst(trimPoint))
        }

        return samples
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

        // Trim leading non-speech (feedback sound) from saved audio
        samples = trimLeadingNonSpeech(samples)

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

    // MARK: - Language Routing

    /// Perform initial language detection and model routing.
    /// Returns true if detection was actually attempted (voiced audio sufficient).
    @discardableResult
    private func performLanguageDetection(
        samples: [Float],
        pool: ModelPool,
        langRouter: LanguageRouter,
        mdlRouter: ModelRouter
    ) -> Bool {
        // VAD-filter detection audio — extract voiced segments only (single allocation)
        var detectionSamples = samples
        let isShortWindow: Bool
        if let vad = vad {
            let segments = vad.detectSpeechSegments(samples: samples)
            let totalVoiced = segments.reduce(0) { acc, seg in
                acc + min(seg.endSample, samples.count) - min(seg.startSample, samples.count)
            }
            let minVoiced = RoutingThresholds.minVoicedDetectionSamples
            guard totalVoiced >= minVoiced else {
                Logger.debug("Detection skipped: \(totalVoiced) voiced samples < \(minVoiced) required", subsystem: .transcription)
                return false
            }
            var voiced = [Float]()
            voiced.reserveCapacity(totalVoiced)
            for seg in segments {
                let start = min(seg.startSample, samples.count)
                let end = min(seg.endSample, samples.count)
                voiced.append(contentsOf: samples[start..<end])
            }
            detectionSamples = voiced
            isShortWindow = totalVoiced < RoutingThresholds.targetDetectionSamples
        } else {
            isShortWindow = samples.count < RoutingThresholds.targetDetectionSamples
        }

        // Detect language from audio
        guard let allProbs = pool.detectLanguage(samples: detectionSamples) else {
            Logger.warning("Language detection returned nil, using configured language", subsystem: .transcription)
            return true  // Detection was attempted but failed
        }

        // Route through language classifier (no transcript yet — initial routing)
        guard let langDecision = langRouter.decide(allProbs: allProbs, transcriptText: "", shortWindow: isShortWindow) else {
            Logger.debug("Language router undecided, using configured language", subsystem: .transcription)
            return true  // Detection was attempted
        }

        // Resolve to model profile
        let modelDecision = mdlRouter.resolve(decision: langDecision, warmProfiles: pool.warmProfiles)
        routeDecision = modelDecision

        // Notify live preview of detected language
        let detectedLang = langDecision.lang
        DispatchQueue.main.async { [weak self] in
            self?.onLanguageDetected?(detectedLang)
        }

        // Apply routing decision
        let activation = pool.routeTarget(for: modelDecision.profile)
        switch activation {
        case .warm(let backend):
            self.whisper = backend
            Logger.info("Routed to \(modelDecision.profile.model.displayName) for \(modelDecision.lang.displayName) (warm)", subsystem: .transcription)

        case .fallback(let fallbackBackend, let loadingTask):
            self.whisper = fallbackBackend
            Logger.info("Using fallback, loading \(modelDecision.profile.model.displayName) for \(modelDecision.lang.displayName)", subsystem: .transcription)

            // Deliver promotion result via serial promotionQueue
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let backend = try await loadingTask.value
                    self.promotionQueue.sync {
                        self.pendingPromotion = (backend, modelDecision.profile)
                    }
                } catch {
                    Logger.error("Failed to load target model: \(error)", subsystem: .transcription)
                }
            }
        }
        return true
    }

    /// Drain promotion queue and swap backend if promotion is ready
    private func drainPromotionQueue() {
        var promotion: (backend: TranscriptionBackend, profile: ModelProfile)?
        promotionQueue.sync { [self] in
            promotion = pendingPromotion
            pendingPromotion = nil
        }
        guard let promotion else { return }

        self.whisper = promotion.backend
        if var decision = routeDecision {
            // Update decision to reflect non-fallback status
            routeDecision = ModelRouteDecision(
                lang: decision.lang,
                profile: promotion.profile,
                confidence: decision.confidence,
                isFallback: false
            )
        }
        Logger.info("Promoted to \(promotion.profile.model.displayName) at chunk boundary", subsystem: .transcription)
    }

    /// Post-chunk script stabilizer — check if transcript script matches locked language
    private func checkScriptStability(chunkText: String) {
        guard let langRouter = languageRouter,
              let pool = modelPool,
              let mdlRouter = modelRouter,
              case .locked(let lockedLang) = langRouter.state else { return }

        let scriptHints = ScriptAnalyzer.dominantScript(in: chunkText, allowedLanguages: langRouter.allowedLanguages)
        guard !scriptHints.isEmpty else { return }

        // Check if dominant script disagrees with locked language
        let topScript = scriptHints.max(by: { $0.value < $1.value })
        if let top = topScript, top.key != lockedLang, top.value > 0.5 {
            scriptMismatchCount += 1
            Logger.debug("Script mismatch \(scriptMismatchCount): \(top.key.displayName) script vs locked \(lockedLang.displayName)", subsystem: .transcription)
        } else {
            // Reset on match
            scriptMismatchCount = 0
        }

        // Combine script + chunk-lang evidence (chunk-lang is weak — needs 5+ to trigger alone)
        let combinedMismatches = scriptMismatchCount + (chunkLangMismatchCount / 2)
        if langRouter.shouldRedetect(scriptMismatches: combinedMismatches, newUtteranceAfterSilence: newUtteranceAfterSilence) {
            newUtteranceAfterSilence = false  // Consume the signal
            scriptMismatchCount = 0
            chunkLangMismatchCount = 0

            // Get latest audio for re-detection
            var latestSamples: [Float] = []
            do {
                try allSamplesLock.withLock {
                    let targetSamples = 32000
                    if allRecordedSamples.count >= targetSamples {
                        latestSamples = Array(allRecordedSamples.suffix(targetSamples))
                    }
                }
            } catch { return }

            guard !latestSamples.isEmpty,
                  let allProbs = pool.detectLanguage(samples: latestSamples) else { return }

            let accumulatedText = completedChunkTexts.joined(separator: " ")
            if let newDecision = langRouter.decide(allProbs: allProbs, transcriptText: accumulatedText) {
                let modelDecision = mdlRouter.resolve(decision: newDecision, warmProfiles: pool.warmProfiles)

                // If language changed, schedule model swap
                if modelDecision.lang != routeDecision?.lang || modelDecision.profile != routeDecision?.profile {
                    routeDecision = modelDecision
                    let activation = pool.routeTarget(for: modelDecision.profile)
                    switch activation {
                    case .warm(let backend):
                        // Will swap at next chunk boundary via drainPromotionQueue
                        promotionQueue.sync { [self] in
                            pendingPromotion = (backend, modelDecision.profile)
                        }
                    case .fallback(_, let loadingTask):
                        Task.detached(priority: .userInitiated) { [weak self] in
                            guard let self else { return }
                            if let backend = try? await loadingTask.value {
                                self.promotionQueue.sync {
                                    self.pendingPromotion = (backend, modelDecision.profile)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
