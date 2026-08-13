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

    // MARK: - Static helpers

    static func isModelCached() -> Bool {
        FileManager.default.fileExists(atPath: modelDirectory().appendingPathComponent("metadata.json").path)
    }

    // The directory that ModelHub.download writes into.
    // ModelHub appends file.path from the repo root (e.g. "coreml/build_int8_1120ms/metadata.json"),
    // so the actual model files land one level below this at the nested HF subfolder.
    private static func downloadBase() -> URL {
        let standard = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/nemotron-hebrew/\(chunkMs)ms")
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.ivy.whisperer/Data/Library/Application Support")
            .appendingPathComponent("FluidAudio/Models/nemotron-hebrew/\(chunkMs)ms")
        // Prefer container path if it exists (sandboxed app writes there)
        return FileManager.default.fileExists(atPath: container.path) ? container : standard
    }

    // The directory containing the model files (metadata.json, *.mlmodelc / *.mlpackage).
    // After download, files land in a subfolder nested under downloadBase() —
    // e.g. .../1120ms/coreml/build_int8_1120ms/ — so we search for metadata.json.
    static func modelDirectory() -> URL {
        let base = downloadBase()
        if let found = findMetadataDir(under: base) { return found }
        // Pre-download default (allows isModelCached() to return false cleanly)
        return base
    }

    private static func findMetadataDir(under base: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "metadata.json" {
                return url.deletingLastPathComponent()
            }
        }
        return nil
    }

    static func download(progressHandler: ProgressHandler? = nil) async throws {
        let base = downloadBase()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // ModelHub.download appends file.path (from repo root) to base, so
        // "coreml/build_int8_1120ms/encoder.mlpackage" lands at base/coreml/build_int8_1120ms/.
        // modelDirectory() finds the nested folder via findMetadataDir after download.
        try await ModelHub.download(
            .nemotronHebrew,
            subdirectory: "coreml",
            to: base,
            progressHandler: progressHandler
        )
    }

    static func loadFromCache() async throws -> NemotronHebrewBridge {
        let dir = modelDirectory()
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("metadata.json").path) else {
            Logger.error("[NemotronHebrew] loadFromCache: metadata.json missing at \(dir.path)", subsystem: .model)
            throw NemotronHebrewError.modelNotCached
        }
        Logger.info("[NemotronHebrew] Loading shared weights from \(dir.lastPathComponent)...", subsystem: .model)
        let bridge = NemotronHebrewBridge()
        let shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: dir)
        await bridge.setSharedModels(shared)
        let mgr = StreamingNemotronMultilingualAsrManager()
        try await mgr.loadFromShared(shared)
        await bridge.setManager(mgr)
        Logger.info("[NemotronHebrew] NemotronHebrewBridge loaded (1120ms hebrew)", subsystem: .model)
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

    /// This bridge always forces `he`, whatever the caller asks for — so that, and not the
    /// requested language, is what has to be present in the fine-tune's prompt dictionary.
    func forcedLanguageSupport(for language: TranscriptionLanguage) async -> (code: String, isSupported: Bool)? {
        guard let manager else { return nil }
        let config = await manager.config
        return ("he", config.promptId(forLanguage: "he") != config.defaultPromptId)
    }

    func beginSession(language: TranscriptionLanguage) async {
        guard let manager else {
            Logger.warning("[NemotronHebrew] beginSession called but manager is nil", subsystem: .transcription)
            return
        }
        _sessionSampleCount = 0
        // Hebrew fine-tune is trained exclusively for Hebrew — always force the Hebrew
        // language prompt regardless of the user's selectedLanguage setting.
        // Auto mode uses prompt ID 64 (generic) which bypasses the Hebrew-specific
        // training and produces phonetic garbage / hallucinations.
        Logger.debug("[NemotronHebrew] beginSession: setForcedPrefix(true) + setLanguage(he) + reset (always forced — Hebrew fine-tune)", subsystem: .transcription)
        await manager.setForcedPrefix(true)
        await manager.setLanguage("he")
        await manager.reset()
        Logger.debug("[NemotronHebrew] beginSession complete — ready for audio", subsystem: .transcription)
    }

    func setPreviewCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        guard manager != nil else {
            Logger.warning("[NemotronHebrew] setPreviewCallback called but manager is nil", subsystem: .transcription)
            return
        }
        await manager?.setPartialCallback(callback)
        Logger.debug("[NemotronHebrew] setPreviewCallback registered on manager", subsystem: .transcription)
    }

    func feed(samples: [Float]) async {
        guard !_isShuttingDown, let manager, !samples.isEmpty else { return }
        _sessionSampleCount += samples.count
        try? await manager.process(samples: samples)
    }

    func endSession() async -> String {
        guard !_isShuttingDown, let manager else {
            Logger.warning("[NemotronHebrew] endSession called but bridge is shutting down or manager nil", subsystem: .transcription)
            return ""
        }
        let samples = _sessionSampleCount
        let audioSec = Double(samples) / 16000.0
        Logger.debug("[NemotronHebrew] endSession: finish() called (\(String(format: "%.1f", audioSec))s audio)", subsystem: .transcription)
        do {
            let result = try await manager.finish()
            Logger.debug("[NemotronHebrew] finish() → \(result.count) chars", subsystem: .transcription)
            return result
        } catch {
            Logger.error("[NemotronHebrew] finish() threw — text will be lost: \(error)", subsystem: .transcription)
            return ""
        }
    }

    func detectedLanguageCode() async -> String? {
        await manager?.detectedLanguage()
    }

    func isForcedPrefixEnabled() async -> Bool {
        await manager?.forcedPrefixEnabled() ?? false
    }

    func prepareForShutdown() {
        Logger.debug("[NemotronHebrew] prepareForShutdown — releasing manager and shared models", subsystem: .model)
        _isShuttingDown = true
        let mgr = manager
        manager = nil
        sharedModels = nil
        Task { await mgr?.cleanup() }
    }
}

extension NemotronHebrewBridge: NemotronBridging {}

enum NemotronHebrewError: Error, LocalizedError {
    case modelNotCached
    var errorDescription: String? {
        switch self {
        case .modelNotCached: return "Nemotron Hebrew model not downloaded. Please download it in the Models tab."
        }
    }
}
#endif
