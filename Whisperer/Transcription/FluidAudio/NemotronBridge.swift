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
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/nemotron-multilingual/multilingual/\(chunkMs)ms")
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
            throw NemotronError.modelNotCached
        }
        let bridge = NemotronBridge()
        let shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: dir)
        await bridge.setSharedModels(shared)
        let mgr = StreamingNemotronMultilingualAsrManager()
        try await mgr.loadFromShared(shared)
        await bridge.setManager(mgr)
        Logger.step(.modelLoad, .model, ["type": .string("nemotron"), "lang": .string("multilingual")])
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

    /// Returns whether the model has a prompt for the given language.
    /// Returns nil for auto-mode or when the new FluidAudio API no longer exposes prompt metadata.
    func forcedLanguageSupport(for language: TranscriptionLanguage) async -> (code: String, isSupported: Bool)? {
        // The new FluidAudio API no longer exposes config.promptId — return nil (auto mode).
        return nil
    }

    func beginSession(language: TranscriptionLanguage) async {
        guard let manager else { return }
        await manager.reset()
        let langCode: String? = (language == .auto) ? nil : language.rawValue
        await manager.setLanguage(langCode)
        Logger.step(.asrStart, .transcription, ["lang": .string(langCode ?? "auto")])
    }

    func setPreviewCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        await manager?.setPartialCallback(callback)
    }

    /// Feed raw 16kHz Float32 samples from the microphone.
    /// Nemotron buffers internally and processes in 1120ms chunks automatically.
    func feed(samples: [Float]) async {
        guard !_isShuttingDown, let manager, !samples.isEmpty else { return }
        try? await manager.process(samples: samples)
    }

    /// Returns complete session transcript since last beginSession().
    func endSession() async -> String {
        guard !_isShuttingDown, let manager else { return "" }
        return (try? await manager.finish()) ?? ""
    }

    func detectedLanguageCode() async -> String? {
        await manager?.detectedLanguage()
    }

    func isForcedPrefixEnabled() async -> Bool {
        await manager?.forcedPrefixEnabled() ?? false
    }

    func prepareForShutdown() {
        _isShuttingDown = true
        let mgr = manager
        manager = nil
        sharedModels = nil
        Task { await mgr?.cleanup() }
    }
}

enum NemotronError: Error, LocalizedError {
    case modelNotCached
    var errorDescription: String? {
        switch self {
        case .modelNotCached: return "Nemotron model not downloaded. Please download it in the Models tab."
        }
    }
}

extension NemotronBridge: NemotronBridging {}
#endif
