//
//  FluidAudioBridge.swift
//  Whisperer
//
//  TranscriptionBackend implementation using FluidAudio Parakeet TDT for ASR.
//  Uses dual AsrManager pattern: streaming manager (fast, no vocab boosting)
//  and final manager (accurate, with CTC vocabulary boosting).
//

#if canImport(FluidAudio)
import Foundation
import FluidAudio
import AVFoundation

nonisolated class FluidAudioBridge: TranscriptionBackend {

    // MARK: - Dual AsrManager

    /// Streaming manager: lightweight, no vocab boosting — used during periodic re-transcription
    private var streamingManager: AsrManager?
    /// Final manager: separate instance with CTC vocab boosting — used for final pass on stop.
    /// Shares underlying MLModel objects (reference types), so memory overhead is ~100KB decoder state.
    private var finalManager: AsrManager?

    // Vocabulary boosting state (configured via configureVocabularyBoosting, applied as post-processing)
    private var customVocabulary: CustomVocabularyContext?
    private var ctcSpotter: CtcKeywordSpotter?
    private var vocabularyRescorer: VocabularyRescorer?

    /// Controls which AsrManager handles transcription calls
    enum TranscriptionMode {
        case streaming
        case finalPass
    }

    private let modeLock = SafeLock()
    private var _currentMode: TranscriptionMode = .streaming

    /// Set the transcription mode (streaming vs final pass)
    func setMode(_ mode: TranscriptionMode) {
        do {
            try modeLock.withLock { _currentMode = mode }
        } catch {
            Logger.error("Failed to set transcription mode: \(error.localizedDescription)", subsystem: .transcription)
        }
    }

    private var currentMode: TranscriptionMode {
        do {
            return try modeLock.withLock { _currentMode }
        } catch {
            return .streaming
        }
    }

    private let queue = DispatchQueue(label: "fluidaudio.transcribe", qos: .userInteractive)
    private let ctxLock = SafeLock(defaultTimeout: 30.0)
    private let lockTimeout: TimeInterval = 30.0

    // Write-once flag — only transitions false→true, never back.
    // Accessed from multiple threads (caller thread, queue, deinit) so guarded by modeLock.
    private var _isShuttingDown = false

    /// Model variant (v2=English-only, v3=multilingual)
    private let variant: ParakeetModelVariant

    /// Prevents repeated language mismatch warnings (log once per session).
    /// Write-once flag, guarded by modeLock for thread safety.
    private var _didLogLanguageWarning = false

    /// Thread-safe read of shutdown flag
    private var isShuttingDown: Bool {
        do { return try modeLock.withLock { _isShuttingDown } }
        catch { return true }
    }

    /// Thread-safe check-and-set for language warning dedup
    private func shouldLogLanguageWarning() -> Bool {
        do {
            return try modeLock.withLock {
                guard !_didLogLanguageWarning else { return false }
                _didLogLanguageWarning = true
                return true
            }
        } catch { return false }
    }

    private init(streamingManager: AsrManager, finalManager: AsrManager, variant: ParakeetModelVariant) {
        self.streamingManager = streamingManager
        self.finalManager = finalManager
        self.variant = variant
    }

    // MARK: - Model Loading

    /// Check if Parakeet models are already downloaded for a given variant
    static func isModelCached(variant: ParakeetModelVariant) -> Bool {
        let version: AsrModelVersion = variant == .v2 ? .v2 : .v3
        let cacheDir = AsrModels.defaultCacheDirectory(for: version)
        return AsrModels.modelsExist(at: cacheDir, version: version)
    }

    /// Cache directory for a given Parakeet variant
    static func cacheDirectory(for variant: ParakeetModelVariant) -> URL {
        let version: AsrModelVersion = variant == .v2 ? .v2 : .v3
        return AsrModels.defaultCacheDirectory(for: version)
    }

    /// Download Parakeet models without loading them
    static func downloadModel(variant: ParakeetModelVariant) async throws {
        let version: AsrModelVersion = variant == .v2 ? .v2 : .v3
        try await AsrModels.download(version: version)
    }

    /// Load Parakeet models from cache and initialize dual ASR managers
    static func loadFromCache(variant: ParakeetModelVariant) async throws -> FluidAudioBridge {
        let version: AsrModelVersion = variant == .v2 ? .v2 : .v3
        let models = try await AsrModels.loadFromCache(version: version)

        let streamingMgr = AsrManager(config: .default)
        try await streamingMgr.loadModels(models)

        let finalMgr = AsrManager(config: .default)
        try await finalMgr.loadModels(models)

        Logger.info("FluidAudio Parakeet \(variant.displayName) loaded from cache (dual manager)", subsystem: .model)
        return FluidAudioBridge(streamingManager: streamingMgr, finalManager: finalMgr, variant: variant)
    }

    /// Download (if needed) and load Parakeet models, then initialize dual ASR managers
    static func load(variant: ParakeetModelVariant = .v3) async throws -> FluidAudioBridge {
        let version: AsrModelVersion = variant == .v2 ? .v2 : .v3
        let models = try await AsrModels.downloadAndLoad(version: version)

        let streamingMgr = AsrManager(config: .default)
        try await streamingMgr.loadModels(models)

        let finalMgr = AsrManager(config: .default)
        try await finalMgr.loadModels(models)

        Logger.info("FluidAudio Parakeet \(variant.displayName) loaded (dual manager)", subsystem: .model)
        return FluidAudioBridge(streamingManager: streamingMgr, finalManager: finalMgr, variant: variant)
    }

    // MARK: - Vocabulary Boosting

    /// Configure CTC vocabulary boosting for post-processing on final pass.
    /// Components are stored locally and applied as a post-processing step after transcription.
    func configureVocabularyBoosting(
        vocabulary: CustomVocabularyContext,
        ctcModels: CtcModels
    ) async throws {
        self.customVocabulary = vocabulary
        let blankId = ctcModels.vocabulary.count
        self.ctcSpotter = CtcKeywordSpotter(models: ctcModels, blankId: blankId)
        let ctcModelDir = CtcModels.defaultCacheDirectory(for: ctcModels.variant)
        self.vocabularyRescorer = try await VocabularyRescorer.create(
            spotter: ctcSpotter!,
            vocabulary: vocabulary,
            config: .default,
            ctcModelDirectory: ctcModelDir
        )
        Logger.info("Vocabulary boosting configured with \(vocabulary.terms.count) terms (final pass only)", subsystem: .transcription)
    }

    // MARK: - TranscriptionBackend

    /// Runs transcription on the GCD queue with lock + semaphore bridge.
    /// Must ONLY be called from the GCD `queue` — never from a cooperative thread.
    private func performTranscription(samples: [Float]) -> String {
        do {
            return try ctxLock.withLock(timeout: lockTimeout) { [weak self] in
                guard let self = self else { return "" }

                // Capture vocabulary boosting state for use inside Task
                let isFinalPass = self.currentMode == .finalPass
                let rescorer = self.vocabularyRescorer
                let spotter = self.ctcSpotter
                let vocabulary = self.customVocabulary

                // Select manager based on current mode
                guard let manager = (isFinalPass ? self.finalManager : self.streamingManager) else { return "" }

                // FluidAudio's transcribe is async — semaphore bridges to sync.
                // Safe here because we're on a GCD thread, not a cooperative thread.
                let semaphore = DispatchSemaphore(value: 0)
                var result = ""

                Task {
                    do {
                        let asrResult = try await manager.transcribe(samples, source: .microphone)
                        var text = asrResult.text

                        // Apply vocabulary boosting as post-processing for final pass only
                        if isFinalPass,
                           let rescorer = rescorer,
                           let spotter = spotter,
                           let vocabulary = vocabulary,
                           let tokenTimings = asrResult.tokenTimings,
                           !tokenTimings.isEmpty {
                            do {
                                // Run CTC inference for log probabilities
                                let spotResult = try await spotter.spotKeywordsWithLogProbs(
                                    audioSamples: samples,
                                    customVocabulary: vocabulary
                                )

                                // Rescore transcript if we have valid log probs
                                if !spotResult.logProbs.isEmpty {
                                    let rescored = rescorer.ctcTokenRescore(
                                        transcript: text,
                                        tokenTimings: tokenTimings,
                                        logProbs: spotResult.logProbs,
                                        frameDuration: spotResult.frameDuration
                                    )
                                    text = rescored.text
                                }
                            } catch {
                                Logger.warning("Vocabulary rescoring failed: \(error.localizedDescription)", subsystem: .transcription)
                                // Continue with original text
                            }
                        }

                        result = text
                    } catch {
                        Logger.error("FluidAudio transcription failed: \(error)", subsystem: .transcription)
                    }
                    semaphore.signal()
                }

                if semaphore.wait(timeout: .now() + 5.0) == .timedOut {
                    Logger.error("FluidAudio transcription hung — bailing out", subsystem: .transcription)
                    return ""
                }
                return result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch SafeLockError.timeout {
            Logger.error("FluidAudio lock timeout after \(lockTimeout)s", subsystem: .transcription)
            return ""
        } catch {
            Logger.error("FluidAudio lock error: \(error.localizedDescription)", subsystem: .transcription)
            return ""
        }
    }

    func transcribe(
        samples: [Float],
        initialPrompt: String?,
        language: TranscriptionLanguage,
        singleSegment: Bool,
        maxTokens: Int32
    ) -> String {
        guard !isShuttingDown else { return "" }
        guard !samples.isEmpty else { return "" }

        // Parakeet handles language internally — warn once when user's selection doesn't match
        if language != .auto && language != .english && variant == .v2 && shouldLogLanguageWarning() {
            Logger.warning("Parakeet v2 is English-only, ignoring language '\(language.displayName)'", subsystem: .transcription)
        }

        // Dispatch to GCD queue to avoid cooperative thread deadlock.
        // The inner semaphore (in performTranscription) waits on a GCD thread
        // while the Task runs on the cooperative pool — no contention.
        let outerSemaphore = DispatchSemaphore(value: 0)
        var result = ""

        queue.async { [weak self] in
            guard let self = self else {
                outerSemaphore.signal()
                return
            }
            result = self.performTranscription(samples: samples)
            outerSemaphore.signal()
        }

        if outerSemaphore.wait(timeout: .now() + 4.0) == .timedOut {
            Logger.error("FluidAudio transcription timed out — returning empty", subsystem: .transcription)
            return ""
        }
        return result
    }

    func transcribeAsync(
        samples: [Float],
        initialPrompt: String?,
        language: TranscriptionLanguage,
        singleSegment: Bool,
        maxTokens: Int32,
        completion: @escaping (String) -> Void
    ) {
        guard !isShuttingDown else {
            completion("")
            return
        }
        guard !samples.isEmpty else {
            completion("")
            return
        }

        // Log language mismatch warning once per session (same dedup as synchronous transcribe)
        if language != .auto && language != .english && variant == .v2 && shouldLogLanguageWarning() {
            Logger.warning("Parakeet v2 is English-only, ignoring language '\(language.displayName)'", subsystem: .transcription)
        }

        queue.async { [weak self] in
            guard let self = self else {
                completion("")
                return
            }
            let text = self.performTranscription(samples: samples)
            completion(text)
        }
    }

    func isContextHealthy() -> Bool {
        !isShuttingDown && streamingManager != nil
    }

    func prepareForShutdown() {
        do { try modeLock.withLock { _isShuttingDown = true } }
        catch { _isShuttingDown = true }
        queue.sync { }
        // cleanup() is actor-isolated — fire-and-forget async cleanup
        let streaming = streamingManager
        let final = finalManager
        Task {
            await streaming?.cleanup()
            await final?.cleanup()
        }
        // Nil references immediately so ARC can deallocate when Task completes
        streamingManager = nil
        finalManager = nil
        // Clear vocabulary boosting state
        customVocabulary = nil
        ctcSpotter = nil
        vocabularyRescorer = nil
    }

    deinit {
        // No lock needed in deinit — sole owner at this point
        _isShuttingDown = true
        // Don't call cleanup() — it's actor-isolated and can't be called from deinit
        // prepareForShutdown() should have been called, or ARC handles dealloc
        streamingManager = nil
        finalManager = nil
        Logger.debug("FluidAudioBridge deallocated", subsystem: .model)
    }
}
#endif
