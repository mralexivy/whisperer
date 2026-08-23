//
//  NemotronHebrewBridge.swift
//  Whisperer
//
//  Wraps StreamingNemotronMultilingualAsrManager for the Hebrew fine-tune model.
//  Same engine as NemotronBridge but downloads from a different HF repo and
//  stores models in a separate local directory (nemotron-hebrew/).
//

#if canImport(FluidAudio)
import Foundation
import FluidAudio

actor NemotronHebrewBridge {
    static let chunkMs = 1120

    private var sharedModels: SharedNemotronMultilingualModels?
    private var manager: StreamingNemotronMultilingualAsrManager?
    private var _isShuttingDown = false
    /// nil when metadata.json could not be read — bare codes are then passed through unchanged,
    /// which is the pre-existing behaviour. See `NemotronPromptDictionary`.
    private var promptDictionary: NemotronPromptDictionary?

    // MARK: - Static helpers

    static func isModelCached() -> Bool {
        FileManager.default.fileExists(atPath: modelDirectory().appendingPathComponent("metadata.json").path)
    }

    static func modelDirectory() -> URL {
        let standard = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/nemotron-hebrew/\(chunkMs)ms")
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.ivy.whisperer/Data/Library/Application Support")
            .appendingPathComponent("FluidAudio/Models/nemotron-hebrew/\(chunkMs)ms")
        if !FileManager.default.fileExists(atPath: standard.appendingPathComponent("metadata.json").path),
           FileManager.default.fileExists(atPath: container.appendingPathComponent("metadata.json").path) {
            return container
        }
        return standard
    }

    static func download(progressHandler: ProgressHandler? = nil) async throws {
        let dir = modelDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Download the coreml/ subfolder of the Hebrew repo directly into the local dir.
        // ModelHub.download strips the subPath prefix when saving locally, so files
        // land flat at dir/ (e.g. dir/encoder.mlmodelc, dir/metadata.json).
        try await ModelHub.download(
            .nemotronHebrew,
            subdirectory: "coreml",
            to: dir,
            progressHandler: progressHandler
        )
    }

    static func loadFromCache() async throws -> NemotronHebrewBridge {
        let dir = modelDirectory()
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("metadata.json").path) else {
            Logger.event(.modelLoad, .model, ["type": .string("nemotron-he"), "fail": .string("metadata_missing")], level: .error)
            throw NemotronHebrewError.modelNotCached
        }
        let bridge = NemotronHebrewBridge()
        let shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: dir)
        await bridge.setSharedModels(shared)
        let mgr = StreamingNemotronMultilingualAsrManager()
        try await mgr.loadFromShared(shared)
        await bridge.setManager(mgr)
        await bridge.setPromptDictionary(NemotronPromptDictionary(modelDirectory: dir))
        Logger.step(.modelLoad, .model, ["type": .string("nemotron-he")])
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
    }

    /// The dictionary key to force for `language`. Falls back to the bare code when the dictionary
    /// is unreadable — see `NemotronBridge.promptKey(for:)` for why the mapping matters.
    private func promptKey(for language: TranscriptionLanguage) -> String? {
        guard language != .auto else { return nil }
        guard let promptDictionary else { return language.rawValue }
        return promptDictionary.promptKey(for: language) ?? language.rawValue
    }

    var isContextHealthy: Bool {
        !_isShuttingDown && manager != nil
    }

    // MARK: - Session lifecycle

    private var _sessionSampleCount: Int = 0

    func beginSession(language: TranscriptionLanguage) async {
        guard let manager else {
            Logger.event(.asrFail, .transcription, ["at": .string("beginSession"), "err": .string("nil_mgr")], level: .warning)
            return
        }
        _sessionSampleCount = 0
        let langCode = promptKey(for: language)
        let useForcedPrefix = language != .auto
        await manager.setForcedPrefix(useForcedPrefix)
        await manager.setLanguage(langCode)
        await manager.reset()
        Logger.step(.asrStart, .transcription, ["lang": .string(langCode ?? "auto"), "forced": .bool(useForcedPrefix)])
    }

    func setPreviewCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        guard manager != nil else {
            Logger.event(.asrFail, .transcription, ["at": .string("setPreview"), "err": .string("nil_mgr")], level: .warning)
            return
        }
        await manager?.setPartialCallback(callback)
    }

    func feed(samples: [Float]) async {
        guard !_isShuttingDown, let manager, !samples.isEmpty else { return }
        _sessionSampleCount += samples.count
        try? await manager.process(samples: samples)
    }

    func endSession() async -> String {
        guard !_isShuttingDown, let manager else {
            Logger.event(.asrFail, .transcription, ["at": .string("endSession"), "err": .string("nil_mgr")], level: .warning)
            return ""
        }
        let audioSec = Double(_sessionSampleCount) / 16000.0
        do {
            let result = try await manager.finish()
            Logger.step(.asrDone, .transcription, ["chars": .int(result.count), "dur": .double(audioSec)])
            return result
        } catch {
            Logger.event(.asrFail, .transcription, ["at": .string("finish"), "err": .string(error.localizedDescription)], level: .error)
            return ""
        }
    }

    func detectedLanguageCode() async -> String? {
        await manager?.detectedLanguage()
    }

    /// See `NemotronBridging.pinLanguage`. No `reset()` — the session's decoded audio must
    /// survive; only the language choice changes from here on. The forced prefix is enabled
    /// alongside it, matching what `beginSession` does for an explicitly chosen language.
    func pinLanguage(_ code: String?) async {
        guard !_isShuttingDown, let manager else { return }
        await manager.setForcedPrefix(code != nil)
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
        Logger.step(.modelFree, .model, ["type": .string("nemotron-he")])
        let mgr = manager
        manager = nil
        sharedModels = nil
        Task { await mgr?.cleanup() }
    }
}

enum NemotronHebrewError: Error, LocalizedError {
    case modelNotCached
    var errorDescription: String? {
        switch self {
        case .modelNotCached: return "Nemotron Hebrew model not downloaded. Please download it in the Models tab."
        }
    }
}
#endif
