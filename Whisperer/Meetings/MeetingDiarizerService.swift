//
//  MeetingDiarizerService.swift
//  Whisperer
//
//  Owns the on-disk lifecycle of the Sortformer streaming diarization model:
//  readiness check + background prefetch at app start.
//

#if canImport(FluidAudio)
import Foundation
import Combine
import FluidAudio

/// Downloads, warms and owns the Sortformer speaker-diarization model.
///
/// The first `MLModel` load of the palettized bundle compiles an ANE program, so `warm()` pays
/// that once in the background at launch and **keeps the handle** (`models`);
/// `MeetingSpeakerCoordinator.start()` borrows it instead of loading its own.
///
/// ### Why the handle is retained rather than dropped
/// This originally loaded for the side effect on CoreML's on-disk compile cache and released
/// immediately, on the theory that the second load would be cheap. A session log falsified it:
/// the warm-up load took **518 ms** on an idle ANE, and the reload at the start of a meeting —
/// on the recording path, with Nemotron streaming — took **9299 ms**. The variable is ANE
/// contention, not the compile cache, and 9.3 s of a 57.5 s meeting recorded with no speaker
/// labels at all. The cost of holding it is the palettized bundle (~330 MB resident), the same
/// trade already accepted for the Whisper and Nemotron models.
@MainActor
final class MeetingDiarizerService: ObservableObject {
    static let shared = MeetingDiarizerService()

    /// The warmed model bundle, held for the app session. `nil` until `warm()` succeeds.
    /// Weights are read-only — sequential meetings each build a fresh `SortformerDiarizer`
    /// around this one handle.
    private(set) var models: SortformerModels?

    /// Adopts a bundle loaded elsewhere (the coordinator's fallback path) so the next meeting
    /// does not pay for it again.
    func adopt(_ loaded: SortformerModels) {
        guard models == nil else { return }
        models = loaded
    }

    /// True once the model bundle is present on disk. Recording never waits on this —
    /// when it is false, meetings simply record without speaker labels.
    @Published private(set) var isReady: Bool = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var statusText: String = ""

    private var prefetchTask: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private var hasWarmed = false

    private init() {
        isReady = Self.isModelCached()
    }

    // MARK: - Configuration

    /// `fastV2_1` is the library's default streaming variant ("lowest latency"); the
    /// palettized head is ~2.5x smaller on disk and ~330 MB resident (vs ~2.4 GB fp16)
    /// for ~+0.9 pp DER — the right trade for a menu bar app running alongside an ASR model.
    nonisolated static var config: SortformerConfig {
        var c = SortformerConfig.fastV2_1
        c.precision = .palettized
        return c
    }

    /// e.g. `v3/palettized/Sortformer_v2.1.mlmodelc`
    nonisolated static var bundleName: String? {
        ModelNames.Sortformer.bundle(for: config)
    }

    // MARK: - Cache location

    /// Root passed to FluidAudio as `cacheDirectory` — the parent of the per-repo folders.
    nonisolated static func modelsRoot() -> URL {
        let standard = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models")
        // Outside the sandbox (tests, Debug without entitlement) ApplicationSupport resolves
        // to ~/Library/Application Support/, but the model may have been downloaded by the
        // sandboxed app into its container. Same fallback as NemotronBridge.modelDirectory().
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.ivy.whisperer/Data/Library/Application Support")
            .appendingPathComponent("FluidAudio/Models")
        if !exists(in: standard), exists(in: container) {
            return container
        }
        return standard
    }

    nonisolated static func isModelCached() -> Bool {
        exists(in: modelsRoot())
    }

    /// A compiled CoreML bundle is a directory; `coremldata.bin` is the marker FluidAudio
    /// itself validates, so a half-unzipped directory does not read as cached.
    nonisolated private static func exists(in root: URL) -> Bool {
        guard let bundle = bundleName else { return false }
        let path = root
            .appendingPathComponent(Repo.sortformer.folderName)
            .appendingPathComponent(bundle)
            .appendingPathComponent("coremldata.bin")
        return FileManager.default.fileExists(atPath: path.path)
    }

    // MARK: - Prefetch

    /// Downloads the model if absent. Idempotent and safe to call on every launch —
    /// a cache hit resolves synchronously without touching the network.
    func prefetch() {
        guard prefetchTask == nil else { return }
        if Self.isModelCached() {
            isReady = true
            warm()
            return
        }
        guard let bundle = Self.bundleName else {
            Logger.error("Sortformer: no model bundle for the configured variant", subsystem: .model)
            return
        }

        let destination = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models")
        downloadProgress = 0
        statusText = "Preparing speaker detection…"
        Logger.info("Sortformer: downloading \(bundle)", subsystem: .model)

        prefetchTask = Task.detached(priority: .utility) { [weak self] in
            do {
                // Queued rather than slept behind a blind grace period: the ASR and LLM loads
                // this used to yield to now sit in the same queue, so the ordering is real.
                try await ModelWorkQueue.shared.run("sortformer-download") {
                    try await ModelHub.download(
                        .sortformer,
                        to: destination,
                        variant: bundle,
                        progressHandler: { progress in
                            let fraction = progress.fractionCompleted
                            Task { @MainActor [weak self] in
                                self?.downloadProgress = fraction
                            }
                        }
                    )
                }
                Logger.info("Sortformer: model ready", subsystem: .model)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.prefetchTask = nil
                    self.downloadProgress = 1
                    self.statusText = ""
                    self.isReady = Self.isModelCached()
                    self.warm()
                }
            } catch {
                // Non-fatal: meetings still record, just without speaker labels.
                Logger.error("Sortformer: download failed — \(error.localizedDescription)", subsystem: .model)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.prefetchTask = nil
                    self.downloadProgress = 0
                    self.statusText = ""
                    self.isReady = false
                }
            }
        }
    }

    // MARK: - Warm-up

    /// Loads the Sortformer bundle off the recording path and keeps it resident.
    ///
    /// Pays CoreML's one-time ANE specialization cost while nothing else is running, which is
    /// where it is cheapest, and hands the handle to `models` so no meeting ever has to load it.
    func warm() {
        guard !hasWarmed, warmTask == nil, models == nil, Self.isModelCached() else { return }
        hasWarmed = true

        let config = Self.config
        let root = Self.modelsRoot()
        warmTask = Task.detached(priority: .utility) { [weak self] in
            let started = Date()
            do {
                let loaded = try await ModelWorkQueue.shared.run("sortformer-warmup") {
                    try await SortformerModels.loadFromHuggingFace(config: config, cacheDirectory: root)
                }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                Logger.info("Sortformer: warm-up load in \(ms)ms — held resident", subsystem: .model)
                await MainActor.run { [weak self] in self?.adopt(loaded) }
            } catch {
                // Non-fatal — the coordinator will try again when a meeting starts.
                Logger.error("Sortformer: warm-up failed — \(error.localizedDescription)", subsystem: .model)
                await MainActor.run { [weak self] in self?.hasWarmed = false }
            }
            await MainActor.run { [weak self] in self?.warmTask = nil }
        }
    }
}
#endif
