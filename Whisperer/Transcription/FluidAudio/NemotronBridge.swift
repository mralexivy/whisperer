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
    /// nil when metadata.json could not be read — "unknown", never "unsupported".
    private var promptDictionary: NemotronPromptDictionary?

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
        await bridge.setPromptDictionary(NemotronPromptDictionary(modelDirectory: dir))
        Logger.step(.modelLoad, .model, ["type": .string("nemotron"), "lang": .string("multilingual")])
        return bridge
    }

    private func setSharedModels(_ models: SharedNemotronMultilingualModels) {
        sharedModels = models
    }

    private func setManager(_ mgr: StreamingNemotronMultilingualAsrManager) {
        manager = mgr
    }

    private func setPromptDictionary(_ dictionary: NemotronPromptDictionary?) {
        promptDictionary = dictionary
        if dictionary == nil {
            Logger.warning("[Nemotron] Could not read prompt_dictionary from metadata.json — language forcing cannot be validated", subsystem: .transcription)
        }
    }

    var isContextHealthy: Bool {
        !_isShuttingDown && manager != nil
    }

    // MARK: - Session lifecycle

    /// Returns whether the model has a prompt for the given language.
    /// Returns nil for auto-mode, or when metadata.json could not be read and the question
    /// therefore cannot be answered — see `NemotronPromptDictionary`.
    func forcedLanguageSupport(for language: TranscriptionLanguage) async -> (code: String, isSupported: Bool)? {
        guard language != .auto, let promptDictionary else { return nil }
        if let key = promptDictionary.promptKey(for: language) {
            return (code: key, isSupported: true)
        }
        return (code: language.rawValue, isSupported: false)
    }

    func beginSession(language: TranscriptionLanguage) async {
        guard let manager else { return }
        await manager.reset()
        let langCode = promptKey(for: language)
        await manager.setLanguage(langCode)
        Logger.step(.asrStart, .transcription, [
            "lang": .string(langCode ?? "auto"),
            "requested": .string(language.rawValue)
        ])
    }

    /// The dictionary key to force for `language`, or nil for auto / unsupported.
    ///
    /// Passing the bare code straight through is what broke Hebrew: the model holds `"he-IL"` and
    /// no `"he"`, so FluidAudio silently used the auto prompt. When the dictionary is unreadable
    /// the bare code is still the best available guess.
    private func promptKey(for language: TranscriptionLanguage) -> String? {
        guard language != .auto else { return nil }
        guard let promptDictionary else { return language.rawValue }
        return promptDictionary.promptKey(for: language)
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

    /// See `NemotronBridging.pinLanguage`. No `reset()` — the session's decoded audio must
    /// survive; only the language choice changes from here on.
    func pinLanguage(_ code: String?) async {
        guard !_isShuttingDown, let manager else { return }
        // Resolve through the dictionary for the same reason `beginSession` does: a pin the model
        // has no key for is applied as `auto` without complaint.
        let key = code.flatMap { promptDictionary?.promptKey(forTag: $0) ?? $0 }
        await manager.setLanguage(key)
        Logger.step(.asrStart, .transcription, [
            "lang": .string(key ?? "auto"),
            "requested": .string(code ?? "auto"),
            "pin": .bool(true)
        ])
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
