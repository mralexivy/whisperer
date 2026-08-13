//
//  NemotronBridge.swift
//  Whisperer
//
//  Wraps StreamingNemotronMultilingualAsrManager for Whisperer's recording lifecycle.
//  One model handles everything: audio fed continuously via feed(samples:), preview
//  text pushed per 1120ms chunk via setPartialCallback, full text from endSession().
//

#if canImport(FluidAudio)
import Foundation
import FluidAudio

actor NemotronBridge {
    static let chunkMs = 1120

    private var sharedModels: SharedNemotronMultilingualModels?
    private var manager: StreamingNemotronMultilingualAsrManager?
    private var _isShuttingDown = false

    // MARK: - Static helpers

    static func isModelCached() -> Bool {
        FileManager.default.fileExists(atPath: modelDirectory().appendingPathComponent("metadata.json").path)
    }

    static func modelDirectory() -> URL {
        let standard = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/nemotron-multilingual/multilingual/\(chunkMs)ms")
        // When running outside the sandbox (e.g. tests, Debug without entitlement),
        // ApplicationSupport resolves to ~/Library/Application Support/ but the model
        // may have been downloaded by the sandboxed app into its container. Fall back to
        // the container path so tests see the same model as the running app.
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.ivy.whisperer/Data/Library/Application Support")
            .appendingPathComponent("FluidAudio/Models/nemotron-multilingual/multilingual/\(chunkMs)ms")
        if !FileManager.default.fileExists(atPath: standard.appendingPathComponent("metadata.json").path),
           FileManager.default.fileExists(atPath: container.appendingPathComponent("metadata.json").path) {
            return container
        }
        return standard
    }

    static func download(progressHandler: ProgressHandler? = nil) async throws {
        _ = try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
            languageCode: "auto",
            chunkMs: chunkMs,
            progressHandler: progressHandler
        )
    }

    static func loadFromCache() async throws -> NemotronBridge {
        let dir = modelDirectory()
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("metadata.json").path) else {
            Logger.error("[Nemotron] loadFromCache: metadata.json missing at \(dir.path)", subsystem: .model)
            throw NemotronError.modelNotCached
        }
        Logger.info("[Nemotron] Loading shared weights from \(dir.lastPathComponent)...", subsystem: .model)
        let bridge = NemotronBridge()
        let shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: dir)
        await bridge.setSharedModels(shared)
        let mgr = StreamingNemotronMultilingualAsrManager()
        try await mgr.loadFromShared(shared)
        await bridge.setManager(mgr)
        Logger.info("[Nemotron] NemotronBridge loaded (1120ms multilingual)", subsystem: .model)
        return bridge
    }

    private func setSharedModels(_ models: SharedNemotronMultilingualModels) {
        sharedModels = models
    }

    private func setManager(_ mgr: StreamingNemotronMultilingualAsrManager) {
        manager = mgr
    }

    var isContextHealthy: Bool {
        !_isShuttingDown && manager != nil
    }

    // MARK: - Session lifecycle

    private var _sessionSampleCount: Int = 0

    /// Whether the loaded model has a prompt for `language`.
    ///
    /// `setLanguage` falls back to `defaultPromptId` (the "auto" prompt) for anything missing from
    /// the prompt dictionary and reports success either way, so the only way to know the encoder
    /// was actually conditioned is to compare the resolved id against that default.
    func forcedLanguageSupport(for language: TranscriptionLanguage) async -> (code: String, isSupported: Bool)? {
        guard language != .auto, let manager else { return nil }
        let code = language.rawValue
        let config = await manager.config
        return (code, config.promptId(forLanguage: code) != config.defaultPromptId)
    }

    func beginSession(language: TranscriptionLanguage) async {
        guard let manager else {
            Logger.warning("[Nemotron] beginSession called but manager is nil", subsystem: .transcription)
            return
        }
        _sessionSampleCount = 0
        let langCode: String? = (language == .auto) ? nil : language.rawValue
        let useForcedPrefix = language != .auto
        Logger.debug("[Nemotron] beginSession: setForcedPrefix(\(useForcedPrefix)) + setLanguage(\(langCode ?? "auto")) + reset", subsystem: .transcription)
        // Order matters: set flag and language BEFORE reset so that reset()'s internal
        // applyForcedPrefixIfNeeded() seeds the freshly-zeroed LSTM with the correct lang-tag.
        // Wrong order (reset first) would seed with stale state from the prior session.
        // Auto mode: forced prefix disabled — prompt-101 seeding produces garbage tokens before real
        // speech content, corrupting the accumulated preview text for the entire session.
        await manager.setForcedPrefix(useForcedPrefix)
        await manager.setLanguage(langCode)
        await manager.reset()
        Logger.debug("[Nemotron] beginSession complete — ready for audio", subsystem: .transcription)
    }

    func setPreviewCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        guard manager != nil else {
            Logger.warning("[Nemotron] setPreviewCallback called but manager is nil", subsystem: .transcription)
            return
        }
        // Register directly — no async dispatch. FluidAudio calls the callback
        // synchronously from process(); any Task/actor hop here delays delivery
        // and disrupts the 1120ms chunk cadence.
        await manager?.setPartialCallback(callback)
        Logger.debug("[Nemotron] setPreviewCallback registered on manager", subsystem: .transcription)
    }

    /// Feed raw 16kHz Float32 samples from the microphone.
    /// Nemotron buffers internally and processes in 1120ms chunks automatically.
    func feed(samples: [Float]) async {
        guard !_isShuttingDown, let manager, !samples.isEmpty else { return }
        _sessionSampleCount += samples.count
        try? await manager.process(samples: samples)
    }

    /// Returns complete session transcript since last beginSession().
    func endSession() async -> String {
        guard !_isShuttingDown, let manager else {
            Logger.warning("[Nemotron] endSession called but bridge is shutting down or manager nil", subsystem: .transcription)
            return ""
        }
        let samples = _sessionSampleCount
        let audioSec = Double(samples) / 16000.0
        Logger.debug("[Nemotron] endSession: finish() called (\(String(format: "%.1f", audioSec))s audio)", subsystem: .transcription)
        do {
            let result = try await manager.finish()
            Logger.debug("[Nemotron] finish() → \(result.count) chars", subsystem: .transcription)
            return result
        } catch {
            Logger.error("[Nemotron] finish() threw — text will be lost: \(error)", subsystem: .transcription)
            return ""
        }
    }

    func detectedLanguageCode() async -> String? {
        await manager?.detectedLanguage()
    }

    /// Returns whether the manager's forced-prefix flag is currently armed.
    /// Used by tests to verify beginSession call order without needing audio.
    func isForcedPrefixEnabled() async -> Bool {
        await manager?.forcedPrefixEnabled() ?? false
    }

    func prepareForShutdown() {
        Logger.debug("[Nemotron] prepareForShutdown — releasing manager and shared models", subsystem: .model)
        _isShuttingDown = true
        let mgr = manager
        manager = nil
        sharedModels = nil
        Task { await mgr?.cleanup() }
    }
}

extension NemotronBridge: NemotronBridging {}

enum NemotronError: Error, LocalizedError {
    case modelNotCached
    var errorDescription: String? {
        switch self {
        case .modelNotCached: return "Nemotron model not downloaded. Please download it in the Models tab."
        }
    }
}
#endif
