//
//  WhisperKitBridge.swift
//  Whisperer
//
//  TranscriptionBackend wrapper for WhisperKit (Argmax CoreML pipeline).
//  Uses snapshot semantics for live preview: each progress callback completely
//  replaces the provisional chunk text instead of appending deltas.
//

#if canImport(WhisperKit)
import Foundation
import WhisperKit

// MARK: - Snapshot progress (ordering-stamped for monotonic delivery)

struct PartialTranscription: Sendable {
    let sessionGeneration: UInt64
    let chunkGeneration: UInt64
    let windowId: Int
    let tokenCount: Int
    let text: String
}

struct WhisperKitStreamingWord: Sendable {
    let text: String
    let tokens: [Int]
    let start: Float
    let end: Float
    let probability: Float
}

struct WhisperKitStreamingResult: Sendable {
    let text: String
    let words: [WhisperKitStreamingWord]
    let averageLogProbability: Float?
    let language: String?
    let languageIsLocked: Bool
    let pipelineDuration: Double
}

// MARK: - CallbackGate
// NSLock-protected, @Sendable-safe gate. Owns abort flag, session/chunk
// generation counters, and the snapshot callback. All fields readable from
// the TranscriptionCallback without actor overhead.

private final class CallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _sessionGeneration: UInt64 = 0
    private var _chunkGeneration: UInt64 = 0
    private var _lastWindowId: Int = -1
    private var _lastTokenCount: Int = -1
    private var _lastAverageLogProbability: Float?
    private var _shouldAbort: Bool = false
    private var _callback: ((PartialTranscription) -> Void)?

    func reset(sessionGeneration: UInt64, chunkGeneration: UInt64) {
        lock.lock(); defer { lock.unlock() }
        _sessionGeneration = sessionGeneration
        _chunkGeneration = chunkGeneration
        _lastWindowId = -1
        _lastTokenCount = -1
        _lastAverageLogProbability = nil
        _shouldAbort = false
        _callback = nil
    }

    func setCallback(_ cb: @escaping (PartialTranscription) -> Void, chunkGeneration: UInt64) {
        lock.lock(); defer { lock.unlock() }
        _chunkGeneration = chunkGeneration
        _lastWindowId = -1
        _lastTokenCount = -1
        _lastAverageLogProbability = nil
        _callback = cb
    }

    func clearCallback() {
        lock.lock(); defer { lock.unlock() }
        _callback = nil
    }

    // Returns false (stop decoder) if aborted; nil (continue) otherwise.
    // Also delivers a snapshot if the progress passes the monotonic filter.
    func handle(progress: TranscriptionProgress) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard !_shouldAbort else { return false }
        let text = progress.text
        guard !text.isEmpty else { return nil }
        let wid = progress.windowId
        let tc = progress.tokens.count
        _lastAverageLogProbability = progress.avgLogprob
        guard (wid, tc) > (_lastWindowId, _lastTokenCount) else { return nil }
        _lastWindowId = wid
        _lastTokenCount = tc
        let snap = PartialTranscription(
            sessionGeneration: _sessionGeneration,
            chunkGeneration: _chunkGeneration,
            windowId: wid,
            tokenCount: tc,
            text: text
        )
        _callback?(snap)
        return nil
    }

    var shouldAbort: Bool { lock.withLock { _shouldAbort } }
    func requestAbort() { lock.lock(); defer { lock.unlock() }; _shouldAbort = true }
    func resetAbort() { lock.lock(); defer { lock.unlock() }; _shouldAbort = false }
    var currentSessionGeneration: UInt64 { lock.withLock { _sessionGeneration } }
    var lastAverageLogProbability: Float? { lock.withLock { _lastAverageLogProbability } }

    func nextSessionGeneration() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        _sessionGeneration &+= 1
        return _sessionGeneration
    }
}

// MARK: - Runtime actor
// Owns the WhisperKit instance and the active transcription Task.

private actor WhisperKitRuntime {
    let whisperKit: WhisperKit
    private var _isShuttingDown = false
    private var _sessionDetectedLanguage: String?
    private var _preparedSessionGeneration: UInt64 = 0
    private var _languageCandidate: String?
    private var _languageCandidateConfirmations: Int = 0
    private var _activeTranscriptionTask: Task<[TranscriptionResult], Error>?
    private var _activeTranscriptionID: UUID?

    init(whisperKit: WhisperKit) { self.whisperKit = whisperKit }

    func setDetectedLanguage(_ lang: String?) { _sessionDetectedLanguage = lang }
    func detectedLanguage() -> String? { _sessionDetectedLanguage }
    func prepareSession(generation: UInt64) {
        guard generation != _preparedSessionGeneration else { return }
        _preparedSessionGeneration = generation
        _sessionDetectedLanguage = nil
        _languageCandidate = nil
        _languageCandidateConfirmations = 0
    }

    func observeStreamingLanguage(_ language: String, eligibleForLock: Bool) -> (
        candidate: String?, confirmations: Int, locked: String?
    ) {
        guard _sessionDetectedLanguage == nil, eligibleForLock else {
            return (_languageCandidate, _languageCandidateConfirmations, _sessionDetectedLanguage)
        }
        if _languageCandidate == language {
            _languageCandidateConfirmations += 1
        } else {
            _languageCandidate = language
            _languageCandidateConfirmations = 1
        }
        // Short streaming windows can easily confuse related languages or English.
        // Lock only after two independent, sufficiently long windows agree.
        if _languageCandidateConfirmations >= 2 {
            _sessionDetectedLanguage = language
        }
        return (_languageCandidate, _languageCandidateConfirmations, _sessionDetectedLanguage)
    }
    func isHealthy() -> Bool { !_isShuttingDown }

    func encodePromptTokens(_ text: String) -> [Int]? {
        whisperKit.tokenizer?.encode(text: text)
    }

    func transcribe(
        audioArray: [Float],
        options: DecodingOptions,
        callback: TranscriptionCallback?
    ) async throws -> [TranscriptionResult] {
        guard !_isShuttingDown else { return [] }
        let task = Task<[TranscriptionResult], Error> { [whisperKit] in
            try await whisperKit.transcribe(audioArray: audioArray, decodeOptions: options, callback: callback)
        }
        let taskID = UUID()
        _activeTranscriptionTask = task
        _activeTranscriptionID = taskID
        defer {
            if _activeTranscriptionID == taskID {
                _activeTranscriptionTask = nil
                _activeTranscriptionID = nil
            }
        }
        return try await task.value
    }

    func cancelActiveTask() async {
        guard let task = _activeTranscriptionTask,
              let taskID = _activeTranscriptionID else { return }
        task.cancel()
        _ = await task.result
        if _activeTranscriptionID == taskID {
            _activeTranscriptionTask = nil
            _activeTranscriptionID = nil
        }
    }

    func shutdown() async {
        _isShuttingDown = true
        await cancelActiveTask()
        await whisperKit.unloadModels()
    }
}

// MARK: - WhisperKitBridge

final class WhisperKitBridge: TranscriptionBackend {

    // MARK: Static model config

    static var modelVariant: String = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let modelRepo = "argmaxinc/whisperkit-coreml"
    private static let folderDefaultsKey = "whisperKitModelFolder"

    static func persistedModelFolder() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: folderDefaultsKey) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func isModelCached() -> Bool {
        guard let folder = persistedModelFolder() else { return false }
        return FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("AudioEncoder.mlmodelc").path
        )
    }

    static func download(progressCallback: @escaping (Double) -> Void) async throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whisperer/whisperkit")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let folder = try await WhisperKit.download(
            variant: modelVariant,
            downloadBase: base,
            from: modelRepo,
            progressCallback: { progress in progressCallback(progress.fractionCompleted) }
        )
        UserDefaults.standard.set(folder.path, forKey: folderDefaultsKey)
        Logger.info("[WhisperKitBridge] Download complete: \(folder.lastPathComponent)", subsystem: .model)
    }

    static func loadFromCache() async throws -> WhisperKitBridge {
        guard let folder = persistedModelFolder(), isModelCached() else {
            throw WhisperKitBridgeError.modelNotCached
        }
        Logger.info("[WhisperKitBridge] Loading \(modelVariant)…", subsystem: .model)
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            verbose: false,
            prewarm: false,  // sine wave warmup in AppState covers this (silence triggers noSpeechThreshold early-exit, never JITs decoder)
            load: true,
            download: false
        )
        let wk = try await WhisperKit(config)
        Logger.info("[WhisperKitBridge] Ready", subsystem: .model)
        return WhisperKitBridge(runtime: WhisperKitRuntime(whisperKit: wk))
    }

    // MARK: Instance

    private let runtime: WhisperKitRuntime
    private let gate = CallbackGate()

    private init(runtime: WhisperKitRuntime) { self.runtime = runtime }

    // MARK: Session lifecycle — synchronous (gate-only, no actor hop)

    // Called once per recording from AppState BEFORE StreamingTranscriber is created.
    // Synchronous so there is no race between session reset and first audio samples.
    func beginSession() {
        let gen = gate.nextSessionGeneration()
        gate.clearCallback()
        gate.resetAbort()
        Logger.debug("[WhisperKitBridge] beginSession gen=\(gen)", subsystem: .transcription)
    }

    func setChunkCallback(_ cb: @escaping (PartialTranscription) -> Void, chunkGeneration: UInt64) {
        gate.setCallback(cb, chunkGeneration: chunkGeneration)
    }

    func clearCallbacks() { gate.clearCallback() }

    func detectedLanguage() async -> String? { await runtime.detectedLanguage() }
    var lastAverageLogProbability: Float? { gate.lastAverageLogProbability }

    /// Encodes `text` into token IDs for richer tail reconciliation decoder context.
    func encodeText(_ text: String) async -> [Int]? {
        await runtime.encodePromptTokens(text)
    }

    // MARK: TranscriptionBackend protocol

    var lastDetectedLanguage: String? { nil } // async path via detectedLanguage() instead

    func transcribe(
        samples: [Float], initialPrompt: String?,
        language: TranscriptionLanguage, singleSegment: Bool, maxTokens: Int32
    ) -> String {
        let sem = DispatchSemaphore(value: 0)
        var result = ""
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { sem.signal(); return }
            result = await self.performTranscription(
                samples: samples, initialPrompt: initialPrompt,
                language: language, maxTokens: maxTokens
            )
            sem.signal()
        }
        sem.wait()
        return result
    }

    func transcribeAsync(
        samples: [Float], initialPrompt: String?,
        language: TranscriptionLanguage, singleSegment: Bool, maxTokens: Int32,
        completion: @escaping (String) -> Void
    ) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { completion(""); return }
            let text = await self.performTranscription(
                samples: samples, initialPrompt: initialPrompt,
                language: language, maxTokens: maxTokens
            )
            completion(text)
        }
    }

    /// Native async entry point used by the final tail pass. The protocol's synchronous
    /// adapter exists for older callers, but blocking on its semaphore during Core ML
    /// inference can starve the app's main-thread health checks.
    func transcribeDirectAsync(
        samples: [Float], initialPrompt: String?,
        language: TranscriptionLanguage, maxTokens: Int32 = 0
    ) async -> String {
        await performTranscription(
            samples: samples, initialPrompt: initialPrompt,
            language: language, maxTokens: maxTokens
        )
    }

    /// Timestamped inference used by the eager streaming state machine. `clipSeconds`
    /// skips audio that has already reached cross-window agreement, while the two
    /// boundary words are supplied as decoder prefix tokens for linguistic continuity.
    func transcribeStreamingAsync(
        samples: [Float], language: TranscriptionLanguage,
        clipSeconds: Float, prefixTokens: [Int]?, maxTokens: Int = 96
    ) async -> WhisperKitStreamingResult? {
        await performStreamingTranscription(
            samples: samples, language: language, clipSeconds: clipSeconds,
            prefixTokens: prefixTokens, maxTokens: maxTokens
        )
    }

    func transcribeStreamingAsync(
        samples: [Float], language: TranscriptionLanguage,
        clipSeconds: Float, prefixTokens: [Int]?, maxTokens: Int = 96,
        completion: @escaping (WhisperKitStreamingResult?) -> Void
    ) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { completion(nil); return }
            let result = await self.transcribeStreamingAsync(
                samples: samples, language: language, clipSeconds: clipSeconds,
                prefixTokens: prefixTokens, maxTokens: maxTokens
            )
            completion(result)
        }
    }

    private func performTranscription(
        samples: [Float], initialPrompt: String?,
        language: TranscriptionLanguage, maxTokens: Int32
    ) async -> String {
        guard await runtime.isHealthy(), !gate.shouldAbort else { return "" }
        gate.resetAbort()
        await runtime.prepareSession(generation: gate.currentSessionGeneration)

        var options = DecodingOptions()
        options.task = .transcribe
        options.temperature = 0.0
        options.temperatureFallbackCount = 0
        options.suppressBlank = true
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        options.noSpeechThreshold = 0.6
        options.compressionRatioThreshold = 2.4
        options.logProbThreshold = -1.0
        if maxTokens > 0 { options.sampleLength = Int(maxTokens) }

        let cachedLang = await runtime.detectedLanguage()
        switch language {
        case .auto:
            if let cached = cachedLang {
                options.language = cached
                options.detectLanguage = false
            } else {
                options.detectLanguage = true
            }
        default:
            options.language = language.rawValue
            options.detectLanguage = false
        }

        if let prompt = initialPrompt, !prompt.isEmpty {
            if let tokens = await runtime.encodePromptTokens(prompt) {
                options.promptTokens = tokens
                options.usePrefillPrompt = true
            }
        }

        let gateRef = gate
        let callback: TranscriptionCallback = { progress in
            return gateRef.handle(progress: progress)
        }

        do {
            let results = try await runtime.transcribe(
                audioArray: samples, options: options, callback: callback
            )
            if let detected = results.first?.language {
                await runtime.setDetectedLanguage(detected)
                Logger.debug("[WhisperKitBridge] Detected language: \(detected)", subsystem: .transcription)
            }
            return results.compactMap { $0.text }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            return ""
        } catch {
            Logger.error("[WhisperKitBridge] Transcription error: \(error)", subsystem: .transcription)
            return ""
        }
    }

    private func performStreamingTranscription(
        samples: [Float], language: TranscriptionLanguage,
        clipSeconds: Float, prefixTokens: [Int]?, maxTokens: Int
    ) async -> WhisperKitStreamingResult? {
        guard await runtime.isHealthy(), !gate.shouldAbort else { return nil }
        gate.resetAbort()
        await runtime.prepareSession(generation: gate.currentSessionGeneration)

        var options = DecodingOptions()
        options.task = .transcribe
        options.temperature = 0.0
        options.temperatureFallbackCount = 0
        options.suppressBlank = true
        options.skipSpecialTokens = true
        options.withoutTimestamps = false
        options.wordTimestamps = true
        options.noSpeechThreshold = 0.6
        options.compressionRatioThreshold = 2.4
        options.logProbThreshold = -1.0
        options.sampleLength = maxTokens
        options.chunkingStrategy = .none  // Our window is already short; prevent internal VAD chunking from interfering with clipTimestamps
        if clipSeconds > 0 { options.clipTimestamps = [clipSeconds] }
        if let prefixTokens, !prefixTokens.isEmpty {
            options.prefixTokens = prefixTokens
        }

        let cachedLang = await runtime.detectedLanguage()
        switch language {
        case .auto:
            if let cached = cachedLang {
                options.language = cached
                options.detectLanguage = false
            } else {
                options.detectLanguage = true
            }
        default:
            options.language = language.rawValue
            options.detectLanguage = false
        }

        do {
            let results = try await runtime.transcribe(
                audioArray: samples, options: options, callback: nil
            )
            guard !results.isEmpty else { return nil }
            var languageIsLocked = language != .auto
            if let detected = results.first?.language {
                let uncertainAudioSeconds = Float(samples.count) / 16_000.0 - clipSeconds
                // Ignore the very first short-window guess, but start consensus as
                // soon as there is enough speech for a useful language decision.
                // Two matching passes are still required, so a transient English
                // guess cannot pin a Russian/Hebrew session to the wrong language.
                let eligibleForLock = language == .auto && uncertainAudioSeconds >= 1.5 &&
                    Float(samples.count) / 16_000.0 >= 1.5
                let languageState = await runtime.observeStreamingLanguage(
                    detected, eligibleForLock: eligibleForLock
                )
                if language == .auto {
                    languageIsLocked = languageState.locked != nil
                    Logger.debug(
                        "[WhisperKitBridge] Streaming language candidate=\(detected) " +
                        "confirmations=\(languageState.confirmations) " +
                        "locked=\(languageState.locked ?? "none") " +
                        "eligible=\(eligibleForLock)",
                        subsystem: .transcription
                    )
                }
            }
            let words = results.flatMap(\.segments).flatMap { $0.words ?? [] }.map {
                WhisperKitStreamingWord(
                    text: $0.word, tokens: $0.tokens, start: $0.start,
                    end: $0.end, probability: $0.probability
                )
            }
            let segments = results.flatMap(\.segments)
            let weightedLogProbability: Float? = {
                let weighted = segments.reduce(into: (sum: Float(0), count: Int(0))) { partial, segment in
                    let weight = max(1, segment.tokens.count)
                    partial.sum += segment.avgLogprob * Float(weight)
                    partial.count += weight
                }
                return weighted.count > 0 ? weighted.sum / Float(weighted.count) : nil
            }()
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let duration = results.reduce(0.0) { $0 + $1.timings.fullPipeline }
            return WhisperKitStreamingResult(
                text: text, words: words, averageLogProbability: weightedLogProbability,
                language: results.first?.language, languageIsLocked: languageIsLocked,
                pipelineDuration: duration
            )
        } catch is CancellationError {
            return nil
        } catch {
            Logger.error("[WhisperKitBridge] Streaming transcription error: \(error)", subsystem: .transcription)
            return nil
        }
    }

    func isContextHealthy() -> Bool { true }

    func prepareForShutdown() {
        Logger.debug("[WhisperKitBridge] prepareForShutdown", subsystem: .model)
        gate.requestAbort()
        gate.clearCallback()
        Task { [runtime] in await runtime.shutdown() }
    }

    func requestAbort() {
        gate.requestAbort()
    }

    /// Cancels and drains the current decode before a replacement decode is allowed to
    /// start. Without this barrier, the old fire-and-forget cancellation could arrive
    /// after the tail pass began and cancel the user's final transcription instead.
    func cancelActiveTranscription() async {
        gate.requestAbort()
        gate.clearCallback()
        await runtime.cancelActiveTask()
        Logger.debug("[WhisperKitBridge] Active transcription cancelled and drained", subsystem: .transcription)
    }

    func resetAbort() { gate.resetAbort() }
}

// MARK: - Error

enum WhisperKitBridgeError: Error, LocalizedError {
    case modelNotCached
    var errorDescription: String? {
        "WhisperKit model not downloaded. Please download it in the Models tab."
    }
}

#endif
