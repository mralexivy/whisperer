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

// MARK: - NemotronPartialCounter

/// Thread-safe counter + deduplicator for Nemotron partial callbacks.
/// FluidAudio sometimes fires the callback twice for the same chunk (same text, ~1ms apart).
/// Uses a class so @Sendable closures can capture it without mutation warnings.
final class NemotronPartialCounter: @unchecked Sendable {
    private var _count = 0
    private var _lastText = ""
    private let lock = NSLock()

    /// Returns the new count if text is genuinely new, or nil if it's a duplicate.
    func incrementIfNew(_ text: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard text != _lastText else { return nil }
        _count += 1
        _lastText = text
        return _count
    }
}

// MARK: - NullTranscriptionBackend

/// Placeholder backend for the Nemotron path. Nemotron bypasses all TranscriptionBackend
/// calls — this struct satisfies the non-optional init requirement without doing any work.
final class NullTranscriptionBackend: TranscriptionBackend {
    func transcribe(samples: [Float], initialPrompt: String?, language: TranscriptionLanguage,
                    singleSegment: Bool, maxTokens: Int32) -> String { "" }
    func transcribeAsync(samples: [Float], initialPrompt: String?, language: TranscriptionLanguage,
                         singleSegment: Bool, maxTokens: Int32,
                         completion: @escaping (String) -> Void) { completion("") }
    func isContextHealthy() -> Bool { false }
    func prepareForShutdown() { }
}

// MARK: - TranscriptChunk

/// A committed piece of transcript together with the span of audio it covers.
///
/// `start`/`end` are seconds from the beginning of the recording measured on the **audio
/// clock** (`samplesReceived / sampleRate`), not wall-clock. Inference latency, model
/// promotion stalls and UI hitches therefore never skew them, and the gap between one
/// chunk's `end` and the next chunk's `start` is real silence for VAD-segmented backends.
struct TranscriptChunk {
    let text: String
    let start: Double
    let end: Double
    /// Total audio received when this chunk committed — for callers that need the session
    /// length rather than this chunk's own span.
    let recordedDuration: Double
}

// MARK: - StreamingTranscriber

class StreamingTranscriber {
    private var whisper: TranscriptionBackend

    private let sampleRate: Double = 16000.0

    // Feedback sound window — skip initial samples containing start sound
    // Sound plays at T=0, lasts ~100ms. Use 150ms margin for safety.
    private let feedbackSoundDuration: Double = 0.15  // 150ms
    private var feedbackSoundSamples: Int { Int(feedbackSoundDuration * sampleRate) }  // 2400 samples

    // Total samples ever received (monotonic counter — survives ring pruning)
    private var totalSamplesReceived: Int = 0

    // HealthReportable progress counter
    private(set) var transcriptionProgressCounter: UInt64 = 0
    private var stCurrentOp: String? = nil
    private var stOpStart: ContinuousClock.Instant = .now
    private var stOpDeadline: ContinuousClock.Instant = .now
    private var stOpID: UInt64 = 0

    // Ring buffer — holds recent audio only; pruned after each chunk to bound memory.
    // baseSampleIndex tracks absolute offset so all other indices remain absolute/monotonic.
    private struct RingBuffer {
        private var storage: [Float] = []
        private(set) var baseSampleIndex: Int = 0

        mutating func reset() { storage.removeAll(keepingCapacity: true); baseSampleIndex = 0 }
        mutating func append(_ s: [Float]) { storage.append(contentsOf: s) }
        mutating func dropFront(toAbsoluteIndex idx: Int) {
            let drop = max(0, idx - baseSampleIndex)
            guard drop > 0, drop <= storage.count else { return }
            storage.removeFirst(drop)
            baseSampleIndex += drop
        }
        func slice(fromAbsolute start: Int, toAbsolute end: Int) -> [Float] {
            let s = max(0, start - baseSampleIndex)
            let e = min(storage.count, end - baseSampleIndex)
            guard s < e else { return [] }
            return Array(storage[s..<e])
        }
        func toArray() -> [Float] { storage }
        var endAbsoluteIndex: Int { baseSampleIndex + storage.count }
        var inMemoryCount: Int { storage.count }
    }

    private var ring = RingBuffer()
    private let allSamplesLock = SafeLock()

    // VAD-chunked pipeline state
    private let vad: SileroVAD?  // Separate ref for language detection filtering
    private var vadSegmenter: VADSegmenter
    private var lastVADScanIndex: Int = 0
    private var lastTranscribedSampleIndex: Int = 0
    private var lastClaimedSampleIndex: Int = 0
    private var completedChunkTexts: [String] = []
    private var currentChunkLiveText: String = ""
    // WhisperKit snapshot path: each progress callback replaces this (never appended)
    private var provisionalChunkText: String = ""
    private var currentChunkGeneration: UInt64 = 0
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
    // Fires with ONLY the live preview tail (previewAccumulatedText), not the full accumulated display.
    // Used by MeetingSession to avoid echoing already-committed chunk text.
    var onPreviewTail: ((String) -> Void)?
    var onLanguageDetected: ((TranscriptionLanguage) -> Void)?
    // Fires when the active model has no prompt for the selected language, so transcription runs
    // unforced. Reported by closure rather than read from AppState — services never reach back.
    var onLanguageForcingUnavailable: ((TranscriptionLanguage) -> Void)?

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
    private let stopGateLock = NSLock()
    private var _isPreparingToStop: Bool = false
    private var isPreparingToStop: Bool {
        stopGateLock.withLock { _isPreparingToStop }
    }
    // Set to true only after Nemotron beginSession + setPreviewCallback complete.
    // Samples arriving before the session is open are dropped rather than sent to
    // an uninitialised RNNT state machine.
    private var isNemotronSessionReady: Bool = false
    private var lastPreviewedSampleIndex: Int = 0
    private var previewAccumulatedText: String = ""
    private var previewPassID: Int = 0
    private var latestWhisperKitPreviewText: String = ""
    private var lastPreviewVADCheckEndIndex: Int = 0
    private var latestWhisperKitPreviewStartIndex: Int = 0
    private var latestWhisperKitPreviewEndIndex: Int = 0
    private var latestWhisperKitPreviewAverageLogProbability: Float?
    private var latestWhisperKitPreviewLanguageIsLocked: Bool = false
    private var activeWhisperKitPreviewStartIndex: Int = 0
    private var activeWhisperKitPreviewEndIndex: Int = 0
    private var whisperKitPreviewAnchoredAtTailStart: Bool = false

    #if canImport(WhisperKit)
    private enum WhisperKitInferenceOwner: Equatable {
        case none
        case preview
        case chunk
    }
    private let whisperKitInferenceLock = NSLock()
    private var whisperKitInferenceOwner: WhisperKitInferenceOwner = .none
    #endif

    private var eagerEngine: EagerStreamEngine?

    // Filler word removal (applied in final pass)
    private var fillerWordRemovalEnabled: Bool

    // VAD scan interval
    private let vadScanInterval: UInt64 = 500_000_000  // 500ms

    // MARK: - Language Routing

    private var modelPool: ModelPool?
    private var languageRouter: LanguageRouter?
    private var modelRouter: ModelRouter?
    private var previewBridge: TranscriptionBackend?  // CPU-only tiny model (WhisperBridge) or streaming backend (FluidAudioBridge) for live preview
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

    // Nemotron bridge — when set, bypasses VAD chunking, ring buffer, and preview polling.
    // Audio is fed directly; preview fires via push callback; final text via endSession().
    // Holds either NemotronBridge (multilingual) or NemotronHebrewBridge via NemotronBridging protocol.
    #if canImport(FluidAudio)
    private var nemotronBridge: (any NemotronBridging)?
    // Serializes bridge.feed() calls. Each addSamples Task chains onto this, preventing
    // concurrent process(samples:) on the same actor (Swift re-entrancy → heap corruption).
    private var nemotronFeedTask: Task<Void, Never>?
    #endif

    // Session audio file on disk (set by AppState after creation, used for saveRecording and tail)
    var sessionAudioURL: URL?

    /// Fired after each committed chunk (and tail).
    /// Used by AppState to incrementally persist text to CoreData for crash recovery,
    /// and by MeetingSession to place transcript segments on the audio timeline.
    var onChunkCompleted: ((TranscriptChunk) -> Void)?

    /// Effective language for transcription — driven by router or fallback to configured language
    var effectiveLanguage: TranscriptionLanguage {
        routeDecision?.lang ?? language
    }

    private var usesEagerStream: Bool {
        UserDefaults.standard.bool(forKey: "whisperCppEagerStreaming") && whisper is WhisperBridge
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
        previewBridge: TranscriptionBackend? = nil,
        nemotronBridge: (any AnyObject)? = nil  // NemotronBridge — typed as AnyObject to avoid #if at call sites
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
        #if canImport(WhisperKit)
        let maxChunkDuration = backend is WhisperKitBridge ? 6.0 : 10.0
        #else
        let maxChunkDuration = 10.0
        #endif
        self.vadSegmenter = VADSegmenter(
            vad: vad,
            targetChunkDuration: 6.0,
            silenceForFinalization: 0.5,
            maxChunkDuration: maxChunkDuration
        )
        #if canImport(FluidAudio)
        self.nemotronBridge = (nemotronBridge as? NemotronBridge) ?? (nemotronBridge as? NemotronHebrewBridge)
        #endif
    }

    /// Start streaming transcription with VAD-chunked pipeline
    func start(onTranscription: @escaping (String) -> Void) {
        self.onTranscription = onTranscription

        do {
            try allSamplesLock.withLock {
                ring.reset()
            }
        } catch {
            Logger.error("Failed to acquire lock in start(): \(error.localizedDescription)", subsystem: .transcription)
        }

        totalSamplesReceived = 0
        fullTranscription = ""
        isProcessing = false
        isStopped = false
        stopGateLock.withLock { _isPreparingToStop = false }
        isNemotronSessionReady = false
        #if canImport(FluidAudio)
        nemotronFeedTask = nil
        #endif
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
        lastPreviewVADCheckEndIndex = feedbackSoundSamples
        previewAccumulatedText = ""
        previewPassID = 0
        latestWhisperKitPreviewText = ""
        latestWhisperKitPreviewStartIndex = 0
        latestWhisperKitPreviewEndIndex = 0
        latestWhisperKitPreviewAverageLogProbability = nil
        latestWhisperKitPreviewLanguageIsLocked = false
        activeWhisperKitPreviewStartIndex = 0
        activeWhisperKitPreviewEndIndex = 0
        whisperKitPreviewAnchoredAtTailStart = false
        #if canImport(WhisperKit)
        whisperKitInferenceLock.lock()
        whisperKitInferenceOwner = .none
        whisperKitInferenceLock.unlock()
        resetWhisperKitStreamingState(at: feedbackSoundSamples)
        #endif

        // Eager engine: used by both WhisperKit (always) and whisper.cpp (when flag on)
        #if canImport(WhisperKit)
        let needsEagerEngine = (whisper is WhisperKitBridge) || usesEagerStream
        #else
        let needsEagerEngine = usesEagerStream
        #endif
        eagerEngine = needsEagerEngine ? EagerStreamEngine() : nil
        eagerEngine?.reset(at: feedbackSoundSamples)

        // Nemotron path: preview is push-based; no VAD chunking needed.
        #if canImport(FluidAudio)
        if let nemotron = nemotronBridge {
            Task { [weak self] in
                guard let self else { return }
                let lang = self.language
                let partialCounter = NemotronPartialCounter()
                let callback: @Sendable (String) -> Void = { [weak self] accumulatedText in
                    // Guard: empty string means silence/no speech — never reset the live display.
                    guard let self, !accumulatedText.isEmpty else { return }
                    // Deduplicate: FluidAudio sometimes fires the callback twice for the
                    // same chunk result (same text, ~1ms apart). Skip the duplicate.
                    guard let n = partialCounter.incrementIfNew(accumulatedText) else {
                        Logger.debug("[Nemotron] Partial — DUPLICATE skipped", subsystem: .transcription)
                        return
                    }
                    let wordCount = accumulatedText.split(separator: " ").count
                    Logger.debug("[Nemotron] Partial #\(n): \(wordCount) words — \"\(accumulatedText.prefix(60))\"", subsystem: .transcription)
                    self.previewAccumulatedText = accumulatedText
                    DispatchQueue.main.async {
                        self.onTranscription?(accumulatedText)
                        self.onPreviewTail?(accumulatedText)
                    }
                }
                // Forcing a language the model has no prompt for is a silent no-op inside
                // FluidAudio: setLanguage falls back to the "auto" prompt and the forced-prefix
                // seed is skipped, so the session runs unconditioned while every log line reads
                // like success. Report it instead of pretending the language was applied.
                if let support = await nemotron.forcedLanguageSupport(for: lang), !support.isSupported {
                    Logger.warning("[Nemotron] Model has no prompt for '\(support.code)' (\(lang.displayName)) — transcribing unforced; accuracy will suffer", subsystem: .transcription)
                    DispatchQueue.main.async { [weak self] in
                        self?.onLanguageForcingUnavailable?(lang)
                    }
                }
                Logger.debug("[Nemotron] beginSession (language: \(lang.rawValue))", subsystem: .transcription)
                await nemotron.beginSession(language: lang)
                await nemotron.setPreviewCallback(callback)
                self.isNemotronSessionReady = true
                Logger.debug("[Nemotron] setPreviewCallback registered — ready for audio", subsystem: .transcription)
            }
            Logger.debug("StreamingTranscriber started (Nemotron streaming path)", subsystem: .transcription)
            return
        }
        #endif

        // Start VAD scan task
        vadScanTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Wait for initial audio to accumulate
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s

            while !Task.isCancelled {
                guard let self = self, !self.isStopped else { break }
                self.scanAndProcessChunks()
                do {
                    try await Task.sleep(nanoseconds: self.vadScanInterval)
                } catch {
                    break
                }
            }
        }

        // Start preview after language detection resolves (state-machine gate)
        previewTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Wait for language detection or 5s timeout
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms poll
                guard let self, !self.isStopped else { return }
                if self.routeDecision != nil || self.modelPool == nil ||
                    self.languageRouter == nil || self.modelRouter == nil { break }
            }

            // WhisperKit is a batch decoder. Start the next timestamped pass promptly
            // after completion so there is no extra dead period between hypotheses.
            // 40 ms balances responsiveness against the ~600-700 ms inference budget.
            #if canImport(WhisperKit)
            let previewInterval: UInt64 = self?.previewBridge is WhisperKitBridge
                ? 40_000_000
                : 500_000_000
            #else
            let previewInterval: UInt64 = 500_000_000
            #endif
            while !Task.isCancelled {
                guard let self, !self.isStopped, !self.isPreparingToStop else { break }
                self.runLivePreviewPass()
                do {
                    try await Task.sleep(nanoseconds: previewInterval)
                } catch {
                    break
                }
            }
        }

        let previewName = previewBridge.map { String(describing: type(of: $0)) } ?? "none"
        Logger.debug("StreamingTranscriber started (VAD-chunked pipeline, preview: \(previewName))", subsystem: .transcription)
    }

    /// Add audio samples from microphone
    func addSamples(_ samples: [Float]) {
        guard !samples.isEmpty, !isStopped else { return }

        #if canImport(FluidAudio)
        // Nemotron: feed directly, bypass ring buffer. Duration tracking still needs updating.
        if let nemotron = nemotronBridge {
            do {
                try allSamplesLock.withLock { totalSamplesReceived += samples.count }
            } catch {}
            // Drop samples until beginSession + setPreviewCallback have completed.
            // beginSession typically takes 1-8ms while audio engine setup takes 80-200ms,
            // so this guard only triggers if ANE is contended at session start.
            guard isNemotronSessionReady else { return }
            // Chain onto the previous feed task to serialize bridge.feed() calls.
            // Spawning independent Tasks causes concurrent process(samples:) on the same
            // actor (Swift re-entrancy via ANE encoder await) → shared-buffer heap corruption.
            let capturedSamples = samples
            nemotronFeedTask = Task { [weak self, prev = nemotronFeedTask] in
                _ = await prev?.value  // wait for previous feed to finish
                // No isStopped check here — pending tasks must complete their feed()
                // before endSession(). stopAsync() awaits this chain first.
                guard let self else { return }
                await self.nemotronBridge?.feed(samples: capturedSamples)
            }
            return
        }
        #endif

        do {
            try allSamplesLock.withLock {
                ring.append(samples)
                totalSamplesReceived += samples.count
            }
        } catch {
            Logger.error("Failed to acquire allSamplesLock: \(error.localizedDescription)", subsystem: .transcription)
        }
    }

    // MARK: - VAD Scan & Chunk Processing

    /// Scan new audio with VAD, emit chunks, transcribe them
    private func scanAndProcessChunks() {
        // Snapshot ring content + base for index mapping
        var ringContent: [Float] = []
        var ringBase: Int = 0
        do {
            try allSamplesLock.withLock {
                ringContent = ring.toArray()
                ringBase = ring.baseSampleIndex
            }
        } catch {
            Logger.error("Failed to acquire allSamplesLock in scanAndProcessChunks", subsystem: .transcription)
            return
        }

        // Map absolute indices to ring-relative for VADSegmenter (indexes into ringContent)
        let allSamples = ringContent
        guard allSamples.count > Int(0.5 * sampleRate) else { return }

        let fromRel = max(0, lastVADScanIndex - ringBase)
        let claimedRel = max(0, lastClaimedSampleIndex - ringBase)

        // Language detection — detect before first chunk, retry if undecided
        if routeDecision == nil,
           detectionAttempts < RoutingThresholds.maxDetectionAttempts,
           let pool = modelPool, let langRouter = languageRouter, let mdlRouter = modelRouter {
            let targetSamples = RoutingThresholds.targetDetectionSamples
                + (detectionAttempts * RoutingThresholds.retryGrowth)
            // Compare against total received so detection window grows monotonically
            let totalInRing = ringBase + allSamples.count
            if totalInRing >= targetSamples, totalInRing > lastDetectionSampleCount {
                lastDetectionSampleCount = totalInRing
                let windowSize = min(allSamples.count, RoutingThresholds.targetDetectionSamples)
                let wasAttempted = performLanguageDetection(
                    samples: Array(allSamples.suffix(windowSize)),
                    pool: pool,
                    langRouter: langRouter,
                    mdlRouter: mdlRouter
                )
                if wasAttempted { detectionAttempts += 1 }
                if routeDecision == nil {
                    EventRingBuffer.shared.record(
                        component: "StreamingTranscriber",
                        operation: "detectionUndecided",
                        kind: .state,
                        metadata: ["attempt": .int(detectionAttempts), "max": .int(RoutingThresholds.maxDetectionAttempts)]
                    )
                }
            }
        }

        #if canImport(WhisperKit)
        // WhisperKit has one serial Core ML runtime. Its eager word-agreement stream
        // is already the committed path, so scheduling a second VAD chunk decode here
        // would transcribe the same audio twice and stall live preview.
        if whisper is WhisperKitBridge {
            lastVADScanIndex = ringBase + allSamples.count
            return
        }
        #endif

        if usesEagerStream {
            lastVADScanIndex = ringBase + allSamples.count
            return
        }

        // Run VAD scan with ring-relative indices
        let result = vadSegmenter.scanAndEmitChunks(
            allSamples: allSamples,
            fromIndex: fromRel,
            lastTranscribedIndex: claimedRel
        )
        // Rebase newScanIndex back to absolute
        lastVADScanIndex = ringBase + result.newScanIndex

        // Rebase chunk indices to absolute and queue
        if !result.chunks.isEmpty {
            let absoluteChunks = result.chunks.map { chunk in
                VADSegmenter.AudioChunk(
                    startSample: chunk.startSample + ringBase,
                    endSample: chunk.endSample + ringBase,
                    samples: chunk.samples,
                    overlapPrefixSamples: chunk.overlapPrefixSamples
                )
            }
            pendingChunks.append(contentsOf: absoluteChunks)
            if let lastChunk = absoluteChunks.last {
                lastClaimedSampleIndex = max(lastClaimedSampleIndex, lastChunk.endSample)
            }
            EventRingBuffer.shared.record(
                component: "StreamingTranscriber",
                operation: "vadEmitted",
                kind: .progress,
                metadata: ["chunks": .int(result.chunks.count), "pending": .int(pendingChunks.count)]
            )
        }

        // Process next pending chunk if not busy
        processNextChunk()
    }

    /// Transcribe the next pending chunk
    private func processNextChunk() {
        guard !isStopped, !isTranscribingChunk, !pendingChunks.isEmpty else { return }
        guard !usesEagerStream else { return }

        #if canImport(WhisperKit)
        let usesWhisperKit = whisper is WhisperKitBridge
        // Preview and committed-chunk decodes share one WhisperKit runtime. Claim it
        // atomically so Core ML never receives overlapping decoder work.
        if usesWhisperKit, !claimWhisperKitInference(.chunk) { return }
        #endif

        // Check for deferred model promotion at chunk boundary
        drainPromotionQueue()

        let chunk = pendingChunks.removeFirst()
        isTranscribingChunk = true
        isProcessing = true

        let chunkDuration = Double(chunk.endSample - chunk.startSample) / sampleRate
        stOpID &+= 1
        stOpStart = .now
        stOpDeadline = .now + .milliseconds(Int(chunkDuration * 1000.0 * 2))
        stCurrentOp = "processingChunk"
        EventRingBuffer.shared.record(
            component: "StreamingTranscriber",
            operation: "chunkQueued",
            kind: .progress,
            metadata: ["durationSec": .double(chunkDuration), "samples": .int(chunk.samples.count), "backlog": .int(pendingChunks.count)]
        )

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

        // Reset abort flag on all backends before each chunk
        whisper.resetAbort()

        // Set up live text callback on WhisperBridge if available
        if let bridge = whisper as? WhisperBridge {
            currentChunkLiveText = ""
            bridge.onNewSegment = { [weak self] segmentText in
                guard let self = self else { return }
                self.currentChunkLiveText += (self.currentChunkLiveText.isEmpty ? "" : " ") + segmentText
                self.updateLivePreview()
            }
        }

        // WhisperKit snapshot path: each callback completely replaces provisional text
        #if canImport(WhisperKit)
        if let wkBridge = whisper as? WhisperKitBridge {
            provisionalChunkText = ""
            if initialPrompt?.isEmpty ?? true {
                currentChunkGeneration &+= 1
                let gen = currentChunkGeneration
                wkBridge.setChunkCallback({ [weak self] snapshot in
                    guard let self else { return }
                    guard snapshot.chunkGeneration == gen else { return }
                    let guarded = self.guardedWhisperKitPrefix(snapshot.text)
                    guard !guarded.isEmpty, !self.isHallucination(guarded),
                          guarded != self.provisionalChunkText else { return }
                    self.provisionalChunkText = guarded
                    self.updateProvisionalPreview()
                }, chunkGeneration: gen)
            } else {
                // The committed decode may use Prompt Words for proper-name accuracy,
                // but its intermediate tokens are prompt-biased and must never reach UI.
                wkBridge.clearCallbacks()
            }
        }
        #endif

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
            #if canImport(WhisperKit)
            if usesWhisperKit {
                (self.whisper as? WhisperKitBridge)?.clearCallbacks()
            }
            #endif

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
                    // VAD chunk boundaries are the exact voiced span, so the gap to the
                    // next chunk's start is genuine silence.
                    self.onChunkCompleted?(TranscriptChunk(
                        text: deduped,
                        start: Double(chunk.startSample) / self.sampleRate,
                        end: Double(chunk.endSample) / self.sampleRate,
                        recordedDuration: self.recordedDuration
                    ))
                }
            }

            // Only advance past this chunk when transcription produced text.
            // Empty results (abort or timeout) must NOT advance the index — the tail pass
            // will re-transcribe that audio. This is safe for all backends: Whisper's
            // abort fires with isStopped=true (tail covers it); Parakeet timeouts during
            // recording previously advanced the index incorrectly, losing audio.
            if !trimmed.isEmpty {
                self.lastTranscribedSampleIndex = chunk.endSample
                // Clear preview accumulated text — chunk covers this audio now
                self.previewAccumulatedText = ""
                self.lastPreviewedSampleIndex = chunk.endSample
                self.latestWhisperKitPreviewText = ""
                self.latestWhisperKitPreviewStartIndex = chunk.endSample
                self.latestWhisperKitPreviewEndIndex = chunk.endSample
                self.latestWhisperKitPreviewAverageLogProbability = nil
                self.latestWhisperKitPreviewLanguageIsLocked = false
                self.whisperKitPreviewAnchoredAtTailStart = false
                #if canImport(WhisperKit)
                self.resetWhisperKitStreamingState(at: chunk.endSample)
                #endif
            }
            self.currentChunkLiveText = ""
            self.provisionalChunkText = ""
            self.isTranscribingChunk = false
            self.isProcessing = false
            self.stCurrentOp = nil
            self.transcriptionProgressCounter &+= 1

            // Trim ring: drop samples safely before both transcribed and previewed positions.
            // Keep 1s overlap for chunk boundary quality on next chunk.
            let overlapSamples = Int(1.0 * self.sampleRate)
            let safeDrop = min(self.lastTranscribedSampleIndex, self.lastPreviewedSampleIndex) - overlapSamples
            if safeDrop > 0 {
                do {
                    try self.allSamplesLock.withLock {
                        self.ring.dropFront(toAbsoluteIndex: safeDrop)
                    }
                    EventRingBuffer.shared.record(
                        component: "StreamingTranscriber",
                        operation: "ringTrimmed",
                        kind: .state,
                        metadata: ["inMemory": .int(self.ring.inMemoryCount)]
                    )
                } catch {
                    Logger.error("Failed to trim ring: \(error.localizedDescription)", subsystem: .transcription)
                }
            }

            // Update live preview with completed chunks
            self.updateLivePreview()

            #if canImport(WhisperKit)
            if usesWhisperKit {
                self.releaseWhisperKitInference(.chunk)
            }
            #endif

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

    // WhisperKit snapshot path: provisional text completely replaces (never appended)
    private func updateProvisionalPreview() {
        var display = completedChunkTexts.joined(separator: " ")
        if !provisionalChunkText.isEmpty {
            if !display.isEmpty { display += " " }
            display += provisionalChunkText
        }
        fullTranscription = display
        let text = display
        DispatchQueue.main.async { [weak self] in
            self?.onTranscription?(text)
        }
    }

    /// WhisperKit's newest words are frequently revised while the decoder is still
    /// receiving context. Hold back that unstable edge, but publish the older words
    /// from token-progress callbacks so the overlay still advances continuously.
    private func guardedWhisperKitPrefix(_ hypothesis: String) -> String {
        let words = hypothesis.split(whereSeparator: { $0.isWhitespace })
        let unstableWordCount = 2
        guard words.count > unstableWordCount else { return "" }
        return words.dropLast(unstableWordCount).joined(separator: " ")
    }

    private func publishWhisperKitPreview(_ hypothesis: String, through sampleIndex: Int) {
        guard !isStopped else { return }
        let guarded = guardedWhisperKitPrefix(hypothesis)
        guard !guarded.isEmpty, !isHallucination(guarded) else { return }
        guard guarded != previewAccumulatedText else { return }

        previewAccumulatedText = guarded
        lastPreviewedSampleIndex = sampleIndex

        var display = completedChunkTexts.joined(separator: " ")
        if !display.isEmpty { display += " " }
        display += guarded
        fullTranscription = display

        DispatchQueue.main.async { [weak self] in
            self?.onTranscription?(display)
            self?.onPreviewTail?(guarded)
        }
        transcriptionProgressCounter &+= 1
    }

    // MARK: - Live Preview Pass

    /// Live preview pass. Two modes depending on backend:
    /// - FluidAudio: growing tail with replace semantics (runs even during chunk transcription — separate queue).
    /// - WhisperKit: growing tail from the last committed chunk with replace semantics.
    /// - whisper.cpp: append-only from last previewed position with 0.5s overlap.
    private func runLivePreviewPass() {
        guard !isStopped, !isPreparingToStop else { return }
        if usesEagerStream {
            runEagerStreamPass()
            return
        }
        guard let preview = previewBridge else { return }
        #if canImport(WhisperKit)
        let isWhisperKitPreview = preview is WhisperKitBridge
        // Avoid repeatedly copying, VAD-checking, and normalizing the same window while
        // the previous Core ML pass is still running.
        if isWhisperKitPreview, !isWhisperKitInferenceIdle() { return }
        #else
        let isWhisperKitPreview = false
        #endif
        #if canImport(FluidAudio)
        let isFluidAudio = preview is FluidAudioBridge
        #else
        let isFluidAudio = false
        #endif
        // Whisper shares the same queue as chunk transcription — block preview during chunks to avoid contention.
        // FluidAudio has a dedicated preview queue and triple-manager, so it can run concurrently.
        if !isFluidAudio, isTranscribingChunk { return }

        // Skip preview if main pipeline has a large backlog (>10s) — drop preview before dropping chunks
        let chunkBacklogSamples = lastClaimedSampleIndex - lastTranscribedSampleIndex
        guard chunkBacklogSamples <= Int(10.0 * sampleRate) else { return }

        var ringContent: [Float] = []
        var ringBase: Int = 0
        do {
            try allSamplesLock.withLock {
                ringContent = ring.toArray()
                ringBase = ring.baseSampleIndex
            }
        } catch { return }

        let ringEnd = ringBase + ringContent.count

        // Window computation differs by backend:
        // - FluidAudio: growing tail from the last committed chunk, replace semantics, low minimum guard (0.3s).
        // - WhisperKit: re-decode the uncommitted tail and replace the previous snapshot.
        //   This lets provisional words be corrected without appending overlapping rewrites.
        // - whisper.cpp: append from lastPreviewedSampleIndex with 0.5s overlap. 1s minimum guard.
        let tailStartAbs: Int
        let endAbsIndex: Int
        if isFluidAudio {
            // Growing window from last committed chunk to now, capped at 8s.
            // Replace semantics: each pass retranscribes the full tail so the model gets growing context
            // and text accumulates naturally without append/dedup heuristics.
            let maxGrowingSamples = Int(8.0 * sampleRate)
            tailStartAbs = max(lastTranscribedSampleIndex, ringEnd - maxGrowingSamples)
            guard ringEnd > tailStartAbs + Int(0.3 * sampleRate) else { return }
            endAbsIndex = ringEnd
        } else if isWhisperKitPreview {
            // Pass the complete uncommitted recording, but ask WhisperKit to seek to
            // the cross-window agreement point. This preserves file-relative word
            // timestamps while the encoder only processes the uncertain suffix.
            tailStartAbs = max(lastTranscribedSampleIndex, ringBase)
            // WhisperKit does not produce a usable timestamped result below roughly
            // one second. Starting sooner created a 40ms retry storm without improving
            // actual time-to-first-text.
            guard ringEnd > tailStartAbs + Int(1.0 * sampleRate) else { return }
            endAbsIndex = ringEnd
        } else {
            let overlapSamples = Int(0.5 * sampleRate)
            tailStartAbs = max(lastTranscribedSampleIndex,
                               lastPreviewedSampleIndex > overlapSamples ? lastPreviewedSampleIndex - overlapSamples : 0)
            guard ringEnd > tailStartAbs + Int(1.0 * sampleRate) else { return }
            let maxWindowSamples = Int(2.0 * sampleRate)
            endAbsIndex = min(ringEnd, tailStartAbs + maxWindowSamples)
        }
        let windowSamples = ring.slice(fromAbsolute: tailStartAbs, toAbsolute: endAbsIndex)
        guard !windowSamples.isEmpty else { return }
        let candidateEndIndex = endAbsIndex

        // Incremental VAD: only check new audio since the last pass (max 3 s).
        // Full-window VAD grew O(n) with recording length; now O(1) per pass.
        if let vad = vad {
            let vadStart = max(lastPreviewVADCheckEndIndex, ringEnd - Int(3.0 * sampleRate))
            if vadStart < ringEnd {
                let vadSamples = ring.slice(fromAbsolute: vadStart, toAbsolute: ringEnd)
                if !vadSamples.isEmpty {
                    lastPreviewVADCheckEndIndex = ringEnd
                    if !vad.hasSpeech(samples: vadSamples) { return }
                }
            }
        }

        let normalizedSamples = normalizeSamples(windowSamples)
        let lang = effectiveLanguage

        // Never feed WhisperKit provisional text or vocabulary prompt words into a
        // short preview window. Both strongly bias ambiguous audio. Only actual,
        // previously committed speech is safe context for provisional decoding.
        let prompt: String?
        if isWhisperKitPreview {
            if let prev = completedChunkTexts.last, !prev.isEmpty {
                prompt = String(prev.suffix(50))
            } else {
                prompt = nil
            }
        } else if !previewAccumulatedText.isEmpty {
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

        #if canImport(WhisperKit)
        if isWhisperKitPreview, !pendingChunks.isEmpty { return }
        // Admission is atomic with the release gate: either this pass owns the
        // runtime before stop preparation starts, or it cannot start at all.
        if isWhisperKitPreview, !claimWhisperKitPreviewInferenceUnlessStopping() { return }
        if isWhisperKitPreview {
            activeWhisperKitPreviewStartIndex = tailStartAbs
            activeWhisperKitPreviewEndIndex = candidateEndIndex
        }
        #endif

        // Assign the ordering ID only after claiming WhisperKit. Incrementing it for
        // skipped busy passes would make every slower Core ML callback look stale.
        previewPassID += 1
        let currentPassID = previewPassID

        let windowSecs = String(format: "%.2f", Double(windowSamples.count) / sampleRate)
        Logger.debug("Preview pass \(currentPassID): \(windowSamples.count) samples (\(windowSecs)s), backend=\(String(describing: type(of: preview)))", subsystem: .transcription)

        var doPreviewTranscribe: (@escaping (String) -> Void) -> Void = { cb in
            preview.transcribeAsync(samples: normalizedSamples, initialPrompt: prompt,
                language: lang, singleSegment: true, maxTokens: 0, completion: cb)
        }
        #if canImport(FluidAudio)
        if let fluidBridge = preview as? FluidAudioBridge {
            doPreviewTranscribe = { cb in fluidBridge.transcribePreviewAsync(samples: normalizedSamples, completion: cb) }
        }
        #endif
        #if canImport(WhisperKit)
        if let wkBridge = preview as? WhisperKitBridge {
            // Raw token callbacks are intentionally not shown: they are mutable beam
            // hypotheses and caused unrelated vocabulary to flash in the overlay.
            let agreementIndex = eagerEngine?.agreementStartIndex ?? tailStartAbs
            let clipSeconds = Float(max(0, agreementIndex - tailStartAbs)) / Float(sampleRate)
            // prefixTokens are NOT passed in preview passes: forced tokens receive
            // timestamp 0.0 rather than their acoustic position, which breaks the
            // agreement state machine (anchor=0 on every pass after first confirmation).
            // clipTimestamps alone is sufficient to advance the encoder to the
            // agreement boundary; the decoder then produces correct file-relative timestamps.
            // eagerEngine?.prefixTokens is still updated on each confirmation
            // and is used only on the stop-path tail reconciliation decode.
            wkBridge.clearCallbacks()
            wkBridge.transcribeStreamingAsync(
                samples: normalizedSamples,
                language: lang,
                clipSeconds: clipSeconds,
                prefixTokens: nil,
                maxTokens: 96
            ) { [weak self, weak wkBridge] result in
                guard let self else { return }
                defer {
                    wkBridge?.clearCallbacks()
                    self.activeWhisperKitPreviewStartIndex = 0
                    self.activeWhisperKitPreviewEndIndex = 0
                    self.releaseWhisperKitInference(.preview)
                }
                guard !self.isStopped,
                      currentPassID == self.previewPassID,
                      let result else { return }
                guard let text = self.consumeWhisperKitStreamingResult(
                    result, audioBaseIndex: tailStartAbs,
                    through: candidateEndIndex
                ) else { return }
                let latency = String(format: "%.0f", result.pipelineDuration * 1000)
                Logger.debug(
                    "WhisperKit eager preview \(currentPassID): \(result.words.count) words, " +
                    "pipeline=\(latency)ms clip=\(String(format: "%.2f", clipSeconds))s " +
                    "language=\(result.language ?? "unknown") locked=\(result.languageIsLocked)",
                    subsystem: .transcription
                )
                self.publishWhisperKitStreamingPreview(text, through: candidateEndIndex)
            }
            return
        }
        #endif

        doPreviewTranscribe { [weak self] text in
            guard let self else { return }
            #if canImport(WhisperKit)
            defer {
                if isWhisperKitPreview {
                    (preview as? WhisperKitBridge)?.clearCallbacks()
                    self.activeWhisperKitPreviewStartIndex = 0
                    self.activeWhisperKitPreviewEndIndex = 0
                    self.releaseWhisperKitInference(.preview)
                }
            }
            #endif
            guard !self.isStopped else { return }

            // Discard out-of-order callbacks
            guard currentPassID == self.previewPassID else {
                Logger.debug("Preview \(currentPassID) discarded (stale, current=\(self.previewPassID))", subsystem: .transcription)
                return
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let hallucination = !trimmed.isEmpty && self.isHallucination(trimmed)
            Logger.debug("Preview \(currentPassID) cb: '\(trimmed.prefix(50))' hallucination=\(hallucination)", subsystem: .transcription)
            if trimmed.isEmpty {
                if isWhisperKitPreview {
                    Logger.debug("WhisperKit preview empty; keeping previous provisional text", subsystem: .transcription)
                }
                return
            }
            guard !hallucination else { return }

            if isWhisperKitPreview {
                var cachedText = trimmed
                var cachedStartIndex = tailStartAbs
                if tailStartAbs > self.lastTranscribedSampleIndex,
                   self.whisperKitPreviewAnchoredAtTailStart,
                   self.latestWhisperKitPreviewStartIndex <= self.lastTranscribedSampleIndex,
                   let merged = self.mergeWhisperKitRollingPreview(
                       previous: self.latestWhisperKitPreviewText,
                       newWindow: trimmed
                   ) {
                    cachedText = merged
                    cachedStartIndex = self.latestWhisperKitPreviewStartIndex
                    Logger.debug("WhisperKit rolling preview preserved decoded prefix", subsystem: .transcription)
                }
                if tailStartAbs <= self.lastTranscribedSampleIndex,
                   candidateEndIndex - self.lastTranscribedSampleIndex <= Int(3.5 * self.sampleRate) {
                    self.whisperKitPreviewAnchoredAtTailStart = true
                }
                self.latestWhisperKitPreviewText = cachedText
                self.latestWhisperKitPreviewStartIndex = cachedStartIndex
                self.latestWhisperKitPreviewEndIndex = candidateEndIndex
                self.latestWhisperKitPreviewAverageLogProbability =
                    (preview as? WhisperKitBridge)?.lastAverageLogProbability
                // The progress callback has already exposed the safe prefix. Apply the
                // same edge guard to the completed hypothesis; never flash raw tail words.
                self.publishWhisperKitPreview(cachedText, through: candidateEndIndex)
                return
            }

            if isFluidAudio {
                // Replace semantics: the latest pass owns the whole provisional tail.
                // This allows normal decoder revisions without overlap/dedup drift.
                self.previewAccumulatedText = trimmed
            } else {
                // whisper.cpp append-only: dedup overlap and grow monotonically
                let deduped = self.deduplicateOverlap(existing: self.previewAccumulatedText, new: trimmed)
                if !deduped.isEmpty {
                    if self.previewAccumulatedText.isEmpty {
                        self.previewAccumulatedText = deduped
                    } else {
                        self.previewAccumulatedText += " " + deduped
                    }
                }
                self.lastPreviewedSampleIndex = candidateEndIndex
            }

            // Build display: completed chunks + accumulated preview
            var display = self.completedChunkTexts.joined(separator: " ")
            if !display.isEmpty && !self.previewAccumulatedText.isEmpty {
                display += " "
            }
            display += self.previewAccumulatedText

            self.fullTranscription = display
            let tail = self.previewAccumulatedText

            DispatchQueue.main.async { [weak self] in
                self?.onTranscription?(display)
                self?.onPreviewTail?(tail)
            }

            EventRingBuffer.shared.record(
                component: "StreamingTranscriber",
                operation: "previewWords",
                kind: .progress,
                metadata: ["words": .int(trimmed.split(separator: " ").count), "totalChars": .int(display.count)]
            )
            transcriptionProgressCounter &+= 1
        }
    }

    #if canImport(WhisperKit)
    private func resetWhisperKitStreamingState(at sampleIndex: Int) {
        eagerEngine?.reset(at: sampleIndex)
    }

    /// Converts a completed timestamped decode into an eager-streaming snapshot.
    /// Words agreed by two consecutive windows become immutable. The last two agreed
    /// words remain revisable and are also reused as decoder prefix tokens.
    private func consumeWhisperKitStreamingResult(
        _ result: WhisperKitStreamingResult,
        audioBaseIndex: Int,
        through candidateEndIndex: Int
    ) -> String? {
        guard let engine = eagerEngine else { return nil }
        let hypothesis = result.words.map { word -> EagerStreamWord in
            EagerStreamWord(
                text: word.text, tokens: word.tokens,
                startIndex: audioBaseIndex + Int(Double(word.start) * sampleRate),
                endIndex: audioBaseIndex + Int(Double(word.end) * sampleRate),
                probability: word.probability
            )
        }
        let outcome = engine.consume(hypothesis: hypothesis, audioBaseIndex: audioBaseIndex,
            languageIsLocked: result.languageIsLocked, lastCommittedIndex: lastTranscribedSampleIndex)
        if let commit = outcome.softCommit, !commit.text.isEmpty {
            completedChunkTexts.append(commit.text)
            onChunkCompleted?(TranscriptChunk(text: commit.text,
                start: Double(commit.startIndex) / sampleRate,
                end: Double(commit.endIndex) / sampleRate,
                recordedDuration: recordedDuration))
            lastTranscribedSampleIndex = commit.endIndex
            lastClaimedSampleIndex = commit.endIndex
            do { try allSamplesLock.withLock { ring.dropFront(toAbsoluteIndex: commit.endIndex) } }
            catch { Logger.warning("WhisperKit eager stream could not prune committed audio", subsystem: .transcription) }
            lastPreviewVADCheckEndIndex = max(lastPreviewVADCheckEndIndex, commit.endIndex)
        }
        guard let displayText = outcome.displayText else { return nil }
        guard !isHallucination(displayText) else { return nil }
        latestWhisperKitPreviewText = displayText
        latestWhisperKitPreviewStartIndex = lastTranscribedSampleIndex
        latestWhisperKitPreviewEndIndex = candidateEndIndex
        latestWhisperKitPreviewAverageLogProbability = result.averageLogProbability
        latestWhisperKitPreviewLanguageIsLocked = result.languageIsLocked
        whisperKitPreviewAnchoredAtTailStart = true
        return displayText
    }

    private func publishWhisperKitStreamingPreview(_ text: String, through sampleIndex: Int) {
        guard !isStopped, !text.isEmpty, text != previewAccumulatedText else { return }
        previewAccumulatedText = text
        lastPreviewedSampleIndex = sampleIndex
        var display = completedChunkTexts.joined(separator: " ")
        if !display.isEmpty { display += " " }
        display += text
        fullTranscription = display
        DispatchQueue.main.async { [weak self] in
            self?.onTranscription?(display)
            self?.onPreviewTail?(text)
        }
        transcriptionProgressCounter &+= 1
    }

    private func claimWhisperKitInference(_ owner: WhisperKitInferenceOwner) -> Bool {
        whisperKitInferenceLock.lock()
        defer { whisperKitInferenceLock.unlock() }
        guard whisperKitInferenceOwner == .none else { return false }
        whisperKitInferenceOwner = owner
        return true
    }

    private func claimWhisperKitPreviewInferenceUnlessStopping() -> Bool {
        stopGateLock.lock()
        defer { stopGateLock.unlock() }
        guard !_isPreparingToStop else { return false }
        return claimWhisperKitInference(.preview)
    }

    private func isWhisperKitInferenceIdle() -> Bool {
        whisperKitInferenceLock.lock()
        defer { whisperKitInferenceLock.unlock() }
        return whisperKitInferenceOwner == .none
    }

    private func releaseWhisperKitInference(_ owner: WhisperKitInferenceOwner) {
        whisperKitInferenceLock.lock()
        defer { whisperKitInferenceLock.unlock() }
        guard whisperKitInferenceOwner == owner else { return }
        whisperKitInferenceOwner = .none
    }
    #endif

    // MARK: - Eager Streaming (whisper.cpp main model)

    /// One live-preview pass for the whisper.cpp eager-streaming path.
    /// Called from `runLivePreviewPass` when `usesEagerStream` is true.
    private func runEagerStreamPass() {
        guard let bridge = whisper as? WhisperBridge else { return }
        guard !isTranscribingChunk else { return }

        var samples: [Float] = []
        var audioBaseIndex = 0
        var ringEnd = 0
        do {
            try allSamplesLock.withLock {
                audioBaseIndex = ring.baseSampleIndex
                samples = ring.toArray()
                ringEnd = audioBaseIndex + samples.count
            }
        } catch { return }

        // Require at least 1s of audio before attempting a decode.
        guard samples.count >= Int(1.0 * sampleRate) else { return }

        // Incremental VAD — only check new audio since the last pass (max 3s).
        if let vad {
            let vadStart = max(lastPreviewVADCheckEndIndex, ringEnd - Int(3.0 * sampleRate))
            if vadStart < ringEnd {
                var vadSamples: [Float] = []
                do {
                    try allSamplesLock.withLock {
                        vadSamples = ring.slice(fromAbsolute: vadStart, toAbsolute: ringEnd)
                    }
                } catch {}
                if !vadSamples.isEmpty {
                    lastPreviewVADCheckEndIndex = ringEnd
                    if !vad.hasSpeech(samples: vadSamples) { return }
                }
            }
        }

        let normalizedSamples = normalizeSamples(samples)
        let lang = effectiveLanguage
        let candidateEndIndex = audioBaseIndex + normalizedSamples.count
        let prompt = completedChunkTexts.last.map { String($0.suffix(100)) }

        isProcessing = true
        bridge.transcribeStreamingAsync(
            samples: normalizedSamples,
            language: lang,
            initialPrompt: prompt
        ) { [weak self] result in
            guard let self else { return }
            defer { self.isProcessing = false }
            guard let result else { return }
            self.applyEagerOutcome(result: result, audioBaseIndex: audioBaseIndex,
                candidateEndIndex: candidateEndIndex)
        }
    }

    private func applyEagerOutcome(
        result: WhisperStreamResult,
        audioBaseIndex: Int,
        candidateEndIndex: Int
    ) {
        guard let engine = eagerEngine else { return }
        let hypothesis = result.words.map { word -> EagerStreamWord in
            EagerStreamWord(
                text: word.text, tokens: word.tokens,
                startIndex: audioBaseIndex + Int(Double(word.start) * sampleRate),
                endIndex: audioBaseIndex + Int(Double(word.end) * sampleRate),
                probability: word.probability
            )
        }
        // Language is always locked for whisper.cpp eager (single-language model, fixed language).
        let outcome = engine.consume(hypothesis: hypothesis, audioBaseIndex: audioBaseIndex,
            languageIsLocked: true, lastCommittedIndex: lastTranscribedSampleIndex)
        if let commit = outcome.softCommit, !commit.text.isEmpty {
            completedChunkTexts.append(commit.text)
            onChunkCompleted?(TranscriptChunk(text: commit.text,
                start: Double(commit.startIndex) / sampleRate,
                end: Double(commit.endIndex) / sampleRate,
                recordedDuration: recordedDuration))
            lastTranscribedSampleIndex = commit.endIndex
            lastClaimedSampleIndex = commit.endIndex
            do { try allSamplesLock.withLock { ring.dropFront(toAbsoluteIndex: commit.endIndex) } }
            catch { Logger.warning("Eager stream (whisper.cpp) could not prune committed audio",
                subsystem: .transcription) }
            lastPreviewVADCheckEndIndex = max(lastPreviewVADCheckEndIndex, commit.endIndex)
        }
        guard let displayText = outcome.displayText, !displayText.isEmpty else { return }
        guard !isHallucination(displayText) else { return }
        let passID = previewPassID &+ 1
        previewPassID = passID
        previewAccumulatedText = displayText
        lastPreviewedSampleIndex = candidateEndIndex
        var display = completedChunkTexts.joined(separator: " ")
        if !display.isEmpty { display += " " }
        display += displayText
        fullTranscription = display
        DispatchQueue.main.async { [weak self] in
            guard let self, self.previewPassID == passID else { return }
            self.onTranscription?(display)
            self.onPreviewTail?(displayText)
        }
        transcriptionProgressCounter &+= 1
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
    func stop(skipCorrections: Bool = false) -> String {
        Logger.debug("Stopping StreamingTranscriber...", subsystem: .transcription)

        isStopped = true
        vadScanTask?.cancel()
        vadScanTask = nil
        previewTask?.cancel()
        previewTask = nil

        // Abort any in-flight transcription on all backends
        whisper.requestAbort()
        if let bridge = whisper as? WhisperBridge {
            bridge.onNewSegment = nil
        }
        #if canImport(WhisperKit)
        if let wkBridge = whisper as? WhisperKitBridge {
            wkBridge.clearCallbacks()
        }
        #endif
        provisionalChunkText = ""
        currentChunkGeneration &+= 1 // invalidate any in-flight snapshot deliveries

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

        // Skip dictionary correction when LLM post-processing is active — LLM handles
        // corrections, and CorrectionEngine can make wrong substitutions (e.g. "and it" → "audit")
        // that corrupt the text before the LLM sees it.
        var finalResult = skipCorrections ? rawText : DictionaryManager.shared.correctText(rawText)
        if fillerWordRemovalEnabled {
            finalResult = FillerWordFilter.removeFillers(from: finalResult)
        }

        return clearAndReturn(finalResult)
    }

    /// Transcribe remaining audio after the last completed chunk
    private func transcribeTail() {
        var ringContent: [Float] = []
        var ringBase: Int = 0
        do {
            try allSamplesLock.withLock {
                ringContent = ring.toArray()
                ringBase = ring.baseSampleIndex
            }
        } catch {
            Logger.error("Failed to acquire lock for tail transcription", subsystem: .transcription)
            return
        }

        // Map absolute lastTranscribedSampleIndex to ring-relative
        let tailRelIndex = max(0, lastTranscribedSampleIndex - ringBase)

        guard let tailChunk = vadSegmenter.finalizeTail(
            allSamples: ringContent,
            lastTranscribedIndex: tailRelIndex
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

        // Reset abort for tail transcription (unconditional — works for WhisperBridge and FluidAudioBridge)
        whisper.resetAbort()

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
                onChunkCompleted?(TranscriptChunk(
                    text: deduped,
                    start: Double(tailChunk.startSample) / sampleRate,
                    end: Double(tailChunk.endSample) / sampleRate,
                    recordedDuration: recordedDuration
                ))
            }
        }
    }

    private func clearAndReturn(_ result: String) -> String {
        Logger.debug("StreamingTranscriber stopped (\(result.count) chars)", subsystem: .transcription)
        return result
    }

    /// Cancel without final transcription. This must terminate the detached preview
    /// loop as well as audio capture; otherwise it keeps decoding a frozen ring buffer.
    func cancelAsync() async {
        guard !isStopped else { return }
        Logger.debug("Cancelling StreamingTranscriber without final pass...", subsystem: .transcription)

        stopGateLock.withLock { _isPreparingToStop = true }
        isStopped = true
        vadScanTask?.cancel()
        vadScanTask = nil
        previewTask?.cancel()
        previewTask = nil
        pendingChunks.removeAll()
        previewPassID &+= 1
        currentChunkGeneration &+= 1
        provisionalChunkText = ""
        previewAccumulatedText = ""

        whisper.requestAbort()
        if let bridge = whisper as? WhisperBridge {
            bridge.onNewSegment = nil
        }
        #if canImport(WhisperKit)
        if let wkBridge = whisper as? WhisperKitBridge {
            wkBridge.clearCallbacks()
            await wkBridge.cancelActiveTranscription()
        }
        #endif
        Logger.debug("StreamingTranscriber cancelled", subsystem: .transcription)
    }

    /// Begin non-destructive stop work while AudioRecorder drains its final hardware
    /// buffer. A stale WhisperKit pass can be cancelled in parallel with that drain;
    /// a pass close enough to the release boundary is preserved for hybrid reuse.
    func prepareForStopAsync() async {
        // Close the preview admission gate before the audio drain begins. Task
        // cancellation alone is insufficient because an interrupted sleep used to
        // fall through and launch one final, immediately-cancelled model pass.
        stopGateLock.withLock { _isPreparingToStop = true }
        #if canImport(WhisperKit)
        guard let wkBridge = whisper as? WhisperKitBridge else { return }
        vadScanTask?.cancel()
        vadScanTask = nil
        previewTask?.cancel()
        previewTask = nil

        guard !isWhisperKitInferenceIdle() else { return }
        guard !shouldWaitForActiveEagerPreviewAtStop() else {
            Logger.debug("Hybrid pre-stop preserved near-boundary WhisperKit preview", subsystem: .transcription)
            return
        }
        await wkBridge.cancelActiveTranscription()
        Logger.debug("Hybrid pre-stop cancelled stale WhisperKit preview", subsystem: .transcription)
        #endif
    }

    /// Stop asynchronously with proper cleanup
    func stopAsync(skipCorrections: Bool = false) async -> String {
        Logger.debug("Stopping StreamingTranscriber (async)...", subsystem: .transcription)

        stopGateLock.withLock { _isPreparingToStop = true }
        vadScanTask?.cancel()
        vadScanTask = nil
        previewTask?.cancel()
        previewTask = nil

        #if canImport(WhisperKit)
        if let wkBridge = whisper as? WhisperKitBridge {
            // A decode often starts just before Fn is released and already includes the
            // complete spoken tail. Give it a short chance to finish rather than canceling
            // it and paying for an almost identical final Core ML pass.
            var waitIterations = 0
            let shouldWaitForPreview = shouldWaitForActiveEagerPreviewAtStop()
            while shouldWaitForPreview, !isWhisperKitInferenceIdle(), waitIterations < 100 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                waitIterations += 1
            }
            if waitIterations > 0 {
                Logger.debug("Hybrid stop waited \(waitIterations * 10)ms for active WhisperKit decode", subsystem: .transcription)
            }

            if canReuseEagerPreviewAtStop() {
                isStopped = true
                wkBridge.clearCallbacks()
                pendingChunks.removeAll()
                provisionalChunkText = ""
                appendTailTranscription(latestWhisperKitPreviewText)
                Logger.info("Hybrid stop reused high-confidence WhisperKit preview", subsystem: .transcription)
                return finalizeCompletedChunks(skipCorrections: skipCorrections)
            }
        }
        #endif

        isStopped = true

        // Abort in-flight chunk transcription on all backends
        whisper.requestAbort()

        #if canImport(WhisperKit)
        // WhisperKit cancellation must be a barrier. Its previous fire-and-forget actor
        // hop could race with resetAbort() and cancel the newly-started tail decode.
        if let wkBridge = whisper as? WhisperKitBridge {
            await wkBridge.cancelActiveTranscription()
        }
        #endif

        // Wait for in-flight chunk to complete (abort fires within ms)
        var waitCount = 0
        while isTranscribingChunk && waitCount < 40 {  // Max 400ms
            try? await Task.sleep(nanoseconds: 10_000_000)
            waitCount += 1
        }

        if isTranscribingChunk {
            Logger.warning("In-flight chunk still transcribing after 400ms, proceeding anyway", subsystem: .transcription)
        } else if waitCount > 0 {
            Logger.debug("In-flight chunk completed after \(waitCount * 10)ms", subsystem: .transcription)
        }

        // Nemotron: get complete transcript from finish(), skip tail transcription.
        #if canImport(FluidAudio)
        if let nemotron = nemotronBridge {
            // Wait for all pending feed() calls to complete before ending the session.
            // Without this, endSession() could race with in-flight feeds.
            await nemotronFeedTask?.value
            nemotronFeedTask = nil
            let durationSec = Double(totalSamplesReceived) / sampleRate
            Logger.debug("[Nemotron] endSession — \(String(format: "%.1f", durationSec))s recorded, calling finish()", subsystem: .transcription)
            var text = await nemotron.endSession()
            Logger.debug("[Nemotron] finish() returned \(text.count) chars", subsystem: .transcription)
            if text.isEmpty {
                // finish() threw or returned nothing. Keep previewAccumulatedText so AppState's
                // fallback (currentTranscription) can recover partial results from streaming.
                Logger.warning("[Nemotron] finish() returned empty — partial text may be used as fallback", subsystem: .transcription)
            } else {
                previewAccumulatedText = ""
                if !skipCorrections {
                    text = DictionaryManager.shared.correctText(text)
                    if fillerWordRemovalEnabled { text = FillerWordFilter.removeFillers(from: text) }
                }
                completedChunkTexts = [text]
                // Nemotron returns the whole session in one blob at stop, so the span is
                // the entire recording. Consumers that need finer granularity subdivide it.
                onChunkCompleted?(TranscriptChunk(
                    text: text,
                    start: 0,
                    end: durationSec,
                    recordedDuration: durationSec
                ))
            }
            return clearAndReturn(text)
        }
        #endif

        // SpeechAnalyzer: use direct async path
        if #available(macOS 26.0, *), let speechBridge = whisper as? SpeechAnalyzerBridge {
            return await stopWithSpeechAnalyzer(speechBridge, skipCorrections: skipCorrections)
        }

        #if canImport(WhisperKit)
        if let wkBridge = whisper as? WhisperKitBridge {
            return await stopWithWhisperKit(wkBridge, skipCorrections: skipCorrections)
        }
        #endif

        // Dispatch stop() — which runs synchronous whisper.cpp tail inference — off the main actor.
        // By this point all in-flight chunks are done, so completedChunkTexts/allSamplesLock are stable.
        return await withCheckedContinuation { [weak self] continuation in
            guard let self else {
                continuation.resume(returning: "")
                return
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    continuation.resume(returning: "")
                    return
                }
                continuation.resume(returning: self.stop(skipCorrections: skipCorrections))
            }
        }
    }

    #if canImport(WhisperKit)
    private func currentRingEndIndex() -> Int? {
        do {
            return try allSamplesLock.withLock {
                ring.baseSampleIndex + ring.inMemoryCount
            }
        } catch {
            return nil
        }
    }

    private func shouldWaitForActiveEagerPreviewAtStop() -> Bool {
        guard activeWhisperKitPreviewEndIndex > 0,
              activeWhisperKitPreviewStartIndex <= lastTranscribedSampleIndex,
              let ringEnd = currentRingEndIndex() else { return false }
        let uncoveredSamples = max(0, ringEnd - activeWhisperKitPreviewEndIndex)
        return uncoveredSamples <= Int(0.40 * sampleRate) &&
            !containsSpeech(from: activeWhisperKitPreviewEndIndex, until: ringEnd)
    }

    private func canReuseEagerPreviewAtStop() -> Bool {
        guard !latestWhisperKitPreviewText.isEmpty,
              let averageLogProbability = latestWhisperKitPreviewAverageLogProbability else {
            return false
        }

        guard let ringEnd = currentRingEndIndex() else { return false }

        let maximumUncoveredSamples = Int(0.40 * sampleRate)
        let uncoveredSamples = max(0, ringEnd - latestWhisperKitPreviewEndIndex)
        let coversUncommittedStart = latestWhisperKitPreviewStartIndex <= lastTranscribedSampleIndex
        let hasStrongConfidence = averageLogProbability >= -0.65
        let uncoveredContainsSpeech = containsSpeech(
            from: latestWhisperKitPreviewEndIndex,
            until: ringEnd
        )
        let canReuse = coversUncommittedStart &&
            whisperKitPreviewAnchoredAtTailStart &&
            (effectiveLanguage != .auto || latestWhisperKitPreviewLanguageIsLocked) &&
            uncoveredSamples <= maximumUncoveredSamples && hasStrongConfidence &&
            !uncoveredContainsSpeech

        let gapSeconds = String(format: "%.2f", Double(uncoveredSamples) / sampleRate)
        let confidence = String(format: "%.2f", averageLogProbability)
        Logger.debug(
            "Hybrid preview check: gap=\(gapSeconds)s avgLogProb=\(confidence) " +
            "gapSpeech=\(uncoveredContainsSpeech) reuse=\(canReuse)",
            subsystem: .transcription
        )
        return canReuse
    }

    private func containsSpeech(from startIndex: Int, until endIndex: Int) -> Bool {
        guard endIndex > startIndex else { return false }
        let samples: [Float]
        do {
            samples = try allSamplesLock.withLock {
                ring.slice(fromAbsolute: startIndex, toAbsolute: endIndex)
            }
        } catch {
            return true
        }
        guard !samples.isEmpty else { return false }
        if let vad {
            return vad.hasSpeech(samples: samples)
        }
        return hasEnergy(samples)
    }

    /// WhisperKit-specific final pass stays async end-to-end. This avoids the synchronous
    /// TranscriptionBackend semaphore and guarantees the cancelled chunk is fully drained
    /// before the tail decode starts.
    private func stopWithWhisperKit(
        _ wkBridge: WhisperKitBridge,
        skipCorrections: Bool
    ) async -> String {
        wkBridge.clearCallbacks()
        provisionalChunkText = ""
        currentChunkGeneration &+= 1
        pendingChunks.removeAll()

        // The rolling preview has already paid for the expensive high-quality decode
        // of most of the uncommitted tail. Reconcile only the audio that arrived after
        // that snapshot (plus a short word-boundary overlap) instead of decoding the
        // complete tail again. Both pieces come from the same WhisperKit model.
        if let reconciliation = await prepareWhisperKitTailReconciliation(bridge: wkBridge) {
            wkBridge.resetAbort()
            let suffix = await wkBridge.transcribeStreamingAsync(
                samples: reconciliation.samples,
                language: effectiveLanguage,
                clipSeconds: 0,
                prefixTokens: reconciliation.prefixTokens,
                maxTokens: 64
            )
            if let suffix,
               let stitched = stitchWhisperKitTimestampedTail(
                prefix: reconciliation.prefix,
                suffix: suffix,
                boundarySeconds: reconciliation.boundarySeconds
            ) {
                Logger.info(
                    "Hybrid stop timestamp-reconciled \(String(format: "%.1f", reconciliation.duration))s " +
                    "of the release tail (saved \(String(format: "%.1f", reconciliation.savedDuration))s)",
                    subsystem: .transcription
                )
                appendTailTranscription(stitched)
                return finalizeCompletedChunks(skipCorrections: skipCorrections)
            }
            Logger.debug("Hybrid tail reconciliation returned no usable suffix; using full tail", subsystem: .transcription)
        }

        guard let input = prepareTailTranscription() else {
            return finalizeCompletedChunks(skipCorrections: skipCorrections)
        }

        wkBridge.resetAbort()
        let text = await wkBridge.transcribeDirectAsync(
            samples: input.samples,
            initialPrompt: input.prompt,
            language: effectiveLanguage
        )
        Logger.debug("WhisperKit tail transcription returned \(text.count) chars", subsystem: .transcription)
        appendTailTranscription(text)
        return finalizeCompletedChunks(skipCorrections: skipCorrections)
    }

    private func prepareWhisperKitTailReconciliation(bridge: WhisperKitBridge) async -> (
        samples: [Float], prefix: String, prefixTokens: [Int]?,
        boundarySeconds: Float, duration: Double, savedDuration: Double
    )? {
        guard !latestWhisperKitPreviewText.isEmpty,
              let confidence = latestWhisperKitPreviewAverageLogProbability,
              confidence >= -0.65,
              whisperKitPreviewAnchoredAtTailStart,
              (effectiveLanguage != .auto || latestWhisperKitPreviewLanguageIsLocked),
              latestWhisperKitPreviewStartIndex <= lastTranscribedSampleIndex else {
            return nil
        }

        let overlapSamples = Int(0.8 * sampleRate)
        let maximumGapSamples = Int(2.0 * sampleRate)
        var samples: [Float] = []
        var ringEnd = 0
        var reconciliationStart = 0
        do {
            try allSamplesLock.withLock {
                ringEnd = ring.baseSampleIndex + ring.inMemoryCount
                let gap = max(0, ringEnd - latestWhisperKitPreviewEndIndex)
                guard gap > Int(0.20 * sampleRate), gap <= maximumGapSamples else { return }
                reconciliationStart = max(
                    lastTranscribedSampleIndex,
                    latestWhisperKitPreviewEndIndex - overlapSamples
                )
                samples = ring.slice(fromAbsolute: reconciliationStart, toAbsolute: ringEnd)
            }
        } catch {
            return nil
        }
        guard !samples.isEmpty, ringEnd > reconciliationStart, hasEnergy(samples) else { return nil }

        let fullTailDuration = Double(ringEnd - lastTranscribedSampleIndex) / sampleRate
        let duration = Double(samples.count) / sampleRate
        let boundarySeconds = Float(latestWhisperKitPreviewEndIndex - reconciliationStart) /
            Float(sampleRate)
        // Encode last 10 confirmed words for richer decoder context (30-50 tokens).
        // Falls back to the 2-word boundary tokens if encoding fails or produces nothing.
        let contextWords = latestWhisperKitPreviewText
            .split(whereSeparator: { $0.isWhitespace }).suffix(10).joined(separator: " ")
        let prefixTokens: [Int]?
        if !contextWords.isEmpty,
           let encoded = await bridge.encodeText(contextWords), !encoded.isEmpty {
            prefixTokens = encoded
        } else {
            let stored = eagerEngine?.prefixTokens ?? []
            prefixTokens = stored.isEmpty ? nil : stored
        }
        Logger.debug(
            "Hybrid tail reconciliation: gap=" +
            "\(String(format: "%.2f", Double(ringEnd - latestWhisperKitPreviewEndIndex) / sampleRate))s " +
            "decode=\(String(format: "%.2f", duration))s " +
            "boundary=\(String(format: "%.2f", boundarySeconds))s",
            subsystem: .transcription
        )
        return (
            normalizeSamples(samples), latestWhisperKitPreviewText, prefixTokens,
            boundarySeconds,
            duration, max(0, fullTailDuration - duration)
        )
    }

    /// Join by acoustic time, not by an assumed text match. The suffix decode includes
    /// 800ms of overlap, so only words beginning at/after the cached preview boundary
    /// are new. Text overlap is still removed when present, but is never required.
    private func stitchWhisperKitTimestampedTail(
        prefix: String,
        suffix: WhisperKitStreamingResult,
        boundarySeconds: Float
    ) -> String? {
        guard suffix.averageLogProbability.map({ $0 >= -0.8 }) ?? false else {
            Logger.debug("Hybrid timestamped suffix rejected for low confidence", subsystem: .transcription)
            return nil
        }

        let prefixWords = prefix.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let suffixWords = suffix.words.map(\.text)
        guard !prefixWords.isEmpty, !suffixWords.isEmpty else { return nil }

        func normalized(_ word: String) -> String {
            word.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        let maximumOverlap = min(15, prefixWords.count, suffixWords.count)
        for count in stride(from: maximumOverlap, through: 1, by: -1) {
            let left = prefixWords.suffix(count).map(normalized)
            let right = suffixWords.prefix(count).map(normalized)
            guard !left.contains(where: { $0.isEmpty }) else { continue }
            if left == right {
                // Replace the acoustic overlap with the final suffix decode instead
                // of retaining provisional punctuation at the seam.
                let stablePrefix = prefixWords.dropLast(count).joined(separator: " ")
                let replacement = suffixWords.joined()
                let combined = joinWhisperKitText(stablePrefix, replacement)
                guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !isHallucination(combined) else { return nil }
                Logger.debug(
                    "Hybrid timestamped suffix replaced \(count)-word acoustic overlap",
                    subsystem: .transcription
                )
                return combined.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Word timestamps are relative to the reconciliation audio. A word spoken
        // across the cached-preview boundary is new final evidence even though its
        // start timestamp belongs to the overlap. Using only `start` discarded that
        // word and unnecessarily triggered a second full-tail decode at release.
        let boundaryTolerance: Float = 0.05
        var newWords = suffix.words.filter {
            $0.end > boundarySeconds + boundaryTolerance
        }

        // If the first retained word crosses the boundary, replace the provisional
        // final prefix word with the final decode. This avoids both duplicating it
        // and preserving stale punctuation. Keep the conservative append behavior
        // for scripts without whitespace-delimited words.
        var stablePrefix = prefix
        if let firstNew = newWords.first,
           firstNew.start < boundarySeconds - boundaryTolerance,
           prefixWords.count > 1 {
            stablePrefix = prefixWords.dropLast().joined(separator: " ")
        }
        if let lastPrefix = prefixWords.last, let firstNew = newWords.first,
           normalized(lastPrefix) == normalized(firstNew.text) {
            newWords.removeFirst()
            stablePrefix = prefix
        }
        let addition = newWords.map(\.text).joined()
        guard !addition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Logger.debug("Hybrid timestamped suffix had no words beyond boundary", subsystem: .transcription)
            return nil
        }
        let combined = joinWhisperKitText(stablePrefix, addition)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isHallucination(combined) else { return nil }
        Logger.debug(
            "Hybrid timestamped suffix reconciled \(newWords.count) boundary/post-boundary words",
            subsystem: .transcription
        )
        return combined
    }

    private func joinWhisperKitText(_ prefix: String, _ addition: String) -> String {
        guard !prefix.isEmpty else { return addition }
        guard !addition.isEmpty else { return prefix }
        if prefix.last?.isWhitespace == true || addition.first?.isWhitespace == true {
            return prefix + addition
        }
        // Whisper word timings normally preserve their leading whitespace. If a model
        // omits it, add a separator only for adjacent ASCII word characters; CJK and
        // punctuation must retain their native no-space formatting.
        if let left = prefix.unicodeScalars.last,
           let right = addition.unicodeScalars.first,
           left.value < 128, right.value < 128,
           CharacterSet.alphanumerics.contains(left),
           CharacterSet.alphanumerics.contains(right) {
            return prefix + " " + addition
        }
        return prefix + addition
    }

    /// Preserve text that falls off the front of WhisperKit's capped rolling window.
    /// Finds a stable word sequence shared by the previous hypothesis and the new
    /// shifted window, then replaces the overlapping region with the newer decode.
    private func mergeWhisperKitRollingPreview(previous: String, newWindow: String) -> String? {
        let previousWords = previous.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let newWords = newWindow.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !previousWords.isEmpty, !newWords.isEmpty else { return nil }

        func normalized(_ word: String) -> String {
            word.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        let previousSearchStart = max(0, previousWords.count - 40)
        let newSearchEnd = min(newWords.count, 40)
        let normalizedPrevious = previousWords.map(normalized)
        let normalizedNew = newWords.map(normalized)
        var bestPreviousIndex = 0
        var bestNewIndex = 0
        var bestLength = 0

        // Prefer an anchor nearest the beginning of the new window. Choosing a later,
        // longer match can align to a repeated phrase (for example "it should be") and
        // accidentally discard valid words immediately before it.
        for newIndex in 0..<newSearchEnd {
            var bestLengthAtThisOffset = 0
            var bestPreviousAtThisOffset = 0
            for previousIndex in previousSearchStart..<previousWords.count {
                var length = 0
                while previousIndex + length < normalizedPrevious.count,
                      newIndex + length < normalizedNew.count,
                      !normalizedPrevious[previousIndex + length].isEmpty,
                      normalizedPrevious[previousIndex + length] == normalizedNew[newIndex + length] {
                    length += 1
                }
                if length > bestLengthAtThisOffset {
                    bestPreviousAtThisOffset = previousIndex
                    bestLengthAtThisOffset = length
                }
            }
            if bestLengthAtThisOffset >= 2 {
                bestPreviousIndex = bestPreviousAtThisOffset
                bestNewIndex = newIndex
                bestLength = bestLengthAtThisOffset
                break
            }
        }

        // Two matching consecutive words are enough to establish the time-shifted
        // window boundary while avoiding accidental one-word joins.
        guard bestLength >= 2 else { return nil }
        let estimatedNewStart = max(0, bestPreviousIndex - bestNewIndex)
        return (Array(previousWords.prefix(estimatedNewStart)) + newWords).joined(separator: " ")
    }

    private func prepareTailTranscription() -> (samples: [Float], prompt: String?)? {
        var ringContent: [Float] = []
        var ringBase = 0
        do {
            try allSamplesLock.withLock {
                ringContent = ring.toArray()
                ringBase = ring.baseSampleIndex
            }
        } catch {
            Logger.error("Failed to acquire lock for tail transcription", subsystem: .transcription)
            return nil
        }

        let tailRelIndex = max(0, lastTranscribedSampleIndex - ringBase)
        guard let tailChunk = vadSegmenter.finalizeTail(
            allSamples: ringContent,
            lastTranscribedIndex: tailRelIndex
        ) else {
            Logger.debug("No tail audio to transcribe", subsystem: .transcription)
            return nil
        }
        guard hasEnergy(tailChunk.samples) else {
            Logger.debug("Tail audio has no energy, skipping", subsystem: .transcription)
            return nil
        }

        let duration = Double(tailChunk.endSample - tailChunk.startSample) / sampleRate
        Logger.debug("Transcribing tail asynchronously: \(String(format: "%.1f", duration))s", subsystem: .transcription)

        let prompt: String?
        if let previous = completedChunkTexts.last, !previous.isEmpty {
            let prefix = initialPrompt.map { $0.isEmpty ? "" : $0 + " " } ?? ""
            prompt = prefix + String(previous.suffix(100))
        } else {
            prompt = initialPrompt
        }
        return (normalizeSamples(tailChunk.samples), prompt)
    }

    private func appendTailTranscription(_ result: String) {
        let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isHallucination(text) else { return }

        let deduped: String
        if let previous = completedChunkTexts.last, !previous.isEmpty {
            deduped = VADSegmenter.deduplicateOverlap(previousText: previous, newText: text)
        } else {
            deduped = text
        }
        guard !deduped.isEmpty else { return }
        completedChunkTexts.append(deduped)
        // The tail is by definition everything not yet committed, so it spans from the
        // last commit boundary to the end of the captured audio.
        onChunkCompleted?(TranscriptChunk(
            text: deduped,
            start: Double(lastTranscribedSampleIndex) / sampleRate,
            end: recordedDuration,
            recordedDuration: recordedDuration
        ))
    }

    private func finalizeCompletedChunks(skipCorrections: Bool) -> String {
        let rawText = completedChunkTexts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else { return clearAndReturn("") }

        var result = skipCorrections ? rawText : DictionaryManager.shared.correctText(rawText)
        if fillerWordRemovalEnabled {
            result = FillerWordFilter.removeFillers(from: result)
        }
        return clearAndReturn(result)
    }
    #endif

    /// SpeechAnalyzer-specific async final pass
    @available(macOS 26.0, *)
    private func stopWithSpeechAnalyzer(_ speechBridge: SpeechAnalyzerBridge, skipCorrections: Bool = false) async -> String {
        isProcessing = false

        // If samples were pruned (long recording), the ring only holds the recent tail.
        // SpeechAnalyzer can't re-transcribe the full session — fall through to chunk-based text.
        var wasPruned: Bool = false
        var allSamples: [Float] = []
        do {
            try allSamplesLock.withLock {
                wasPruned = totalSamplesReceived > ring.inMemoryCount
                allSamples = ring.toArray()
            }
        } catch {
            Logger.error("Failed to acquire allSamplesLock in stopWithSpeechAnalyzer", subsystem: .transcription)
        }

        if wasPruned {
            Logger.info("SpeechAnalyzer skipped — audio was pruned during long recording; using chunk-based text", subsystem: .transcription)
            transcribeTail()
            let rawText = fullTranscription
            guard !rawText.isEmpty else { return clearAndReturn("") }
            var result = skipCorrections ? rawText : DictionaryManager.shared.correctText(rawText)
            if fillerWordRemovalEnabled {
                result = FillerWordFilter.removeFillers(from: result)
            }
            return clearAndReturn(result)
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
            finalResult = skipCorrections ? rawText : DictionaryManager.shared.correctText(rawText)
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
        #if canImport(FluidAudio)
        // For Nemotron, fullTranscription is only populated after finish() in stopAsync().
        // previewAccumulatedText holds the last partial pushed by the callback — use it
        // as fallback so AppState's empty-result path can recover streaming text.
        if nemotronBridge != nil && !previewAccumulatedText.isEmpty {
            return previewAccumulatedText
        }
        #endif
        return fullTranscription
    }

    var recordedDuration: Double {
        // totalSamplesReceived is written only in addSamples under allSamplesLock,
        // but reading a single Int is safe without locking here.
        return Double(totalSamplesReceived) / sampleRate
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

    /// Save the recorded audio to `url`.
    ///
    /// The session file is already written in the archive format, so this is a copy —
    /// there is no transcode step and no second encode of the same audio. Falls back to
    /// writing the in-memory ring buffer for very short recordings that were never pruned.
    func saveRecording(to url: URL) -> Bool {
        // Prefer the complete disk-backed session file
        if let srcURL = sessionAudioURL, FileManager.default.fileExists(atPath: srcURL.path) {
            do {
                if AudioArchiveFormat.isAlreadyArchived(srcURL) {
                    try FileManager.default.copyItem(at: srcURL, to: url)
                    Logger.debug("Recording copied to: \(url.lastPathComponent)", subsystem: .transcription)
                    return true
                }
                // A session file left over from a pre-Opus build — encode it once on the way out.
                try AudioArchiveFormat.transcode(from: srcURL, to: url)
                Logger.debug("Legacy session file transcoded to: \(url.lastPathComponent)", subsystem: .transcription)
                return true
            } catch {
                Logger.error("Failed to save recording from disk: \(error.localizedDescription)", subsystem: .transcription)
                return false
            }
        }

        // Fallback: write ring buffer (short recordings not yet pruned)
        var samples: [Float] = []
        do {
            try allSamplesLock.withLock {
                samples = ring.toArray()
            }
        } catch {
            Logger.error("Failed to acquire lock for saveRecording: \(error.localizedDescription)", subsystem: .transcription)
            return false
        }

        guard !samples.isEmpty else {
            Logger.warning("No audio samples to save", subsystem: .transcription)
            return false
        }

        samples = trimLeadingNonSpeech(samples)

        let format = AudioArchiveFormat.pcmFormat
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
            let writer = try AudioArchiveFormat.makeWriter(at: url)
            try writer.write(buffer)
            writer.close()
            Logger.debug("Recording saved (ring buffer) to: \(url.lastPathComponent)", subsystem: .transcription)
            return true
        } catch {
            Logger.error("Failed to save recording: \(error.localizedDescription)", subsystem: .transcription)
            try? FileManager.default.removeItem(at: url)
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

            // Get latest audio for re-detection (2s window from ring)
            var latestSamples: [Float] = []
            do {
                try allSamplesLock.withLock {
                    let targetSamples = 32000
                    let endIdx = ring.endAbsoluteIndex
                    let startIdx = max(ring.baseSampleIndex, endIdx - targetSamples)
                    if endIdx - startIdx >= targetSamples {
                        latestSamples = ring.slice(fromAbsolute: startIdx, toAbsolute: endIdx)
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

// MARK: - HealthReportable

extension StreamingTranscriber: HealthReportable {

    var componentName: String { "StreamingTranscriber" }

    var healthState: ComponentHealth {
        let seq = transcriptionProgressCounter
        let now = ContinuousClock.now

        guard let opName = stCurrentOp else {
            var h = ComponentHealth()
            h.progress = ProgressInfo(sequence: seq, completedWork: 1.0, lastUpdate: now)
            return h
        }

        let deadline = stOpDeadline
        let status: ComponentStatus
        if now < deadline {
            status = .healthy
        } else if isTranscribingChunk {
            status = .busy  // waiting on WhisperBridge
        } else {
            status = .stalled
        }

        var op = OperationInfo(
            id: stOpID,
            name: opName,
            started: stOpStart,
            deadline: deadline,
            queueBacklog: pendingChunks.count
        )
        op.deadline = deadline

        var h = ComponentHealth()
        h.status = status
        h.operation = op
        h.progress = ProgressInfo(sequence: seq, completedWork: isTranscribingChunk ? 0.5 : 1.0, lastUpdate: now)
        h.dependencies = isTranscribingChunk ? ["WhisperBridge"] : []
        h.metadata = ["backlog": .int(pendingChunks.count), "isStopped": .bool(isStopped)]
        return h
    }
}
