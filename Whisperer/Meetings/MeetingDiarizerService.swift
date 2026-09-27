//
//  MeetingDiarizerService.swift
//  Whisperer
//
//  Owns the on-disk lifecycle of the Nemotron-3 streaming diarization model:
//  readiness check + background prefetch at app start.
//

#if canImport(FluidAudio)
import Foundation
import Combine
import FluidAudio

/// Downloads, warms and owns the Nemotron-3 speaker-diarization model.
///
/// The first `MLModel` load compiles an ANE program, so `warm()` pays that once in the
/// background at launch and **keeps the handle** (`models`);
/// `MeetingSpeakerCoordinator.start()` borrows it instead of loading its own.
///
/// ### Why the handle is retained rather than dropped
/// This originally loaded for the side effect on CoreML's on-disk compile cache and released
/// immediately, on the theory that the second load would be cheap. A session log falsified it:
/// the warm-up load took **518 ms** on an idle ANE, and the reload at the start of a meeting —
/// on the recording path, with Nemotron ASR streaming — took **9299 ms**. The variable is ANE
/// contention, not the compile cache, and 9.3 s of a 57.5 s meeting recorded with no speaker
/// labels at all. The cost of holding it is the INT8 bundle (~103 MB resident), the same
/// trade already accepted for the Whisper and Nemotron models.
@MainActor
final class MeetingDiarizerService: ObservableObject {
    static let shared = MeetingDiarizerService()

    /// The warmed model bundle, held for the app session. `nil` until `warm()` succeeds.
    /// Weights are read-only — sequential meetings each build a fresh `Nemotron3Diarizer`
    /// around this one handle.
    private(set) var models: Nemotron3Models?

    /// Adopts a bundle loaded elsewhere (the coordinator's fallback path) so the next meeting
    /// does not pay for it again.
    func adopt(_ loaded: Nemotron3Models) {
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

    /// `.fast` preset: `chunkLen: 9, chunkRightContext: 4, fifoLen: 40` → 1.04 s input latency.
    /// Chosen to keep per-second ANE cost proportionate to the prior Sortformer v2.1 load,
    /// while supporting 8 speakers and providing better DER.
    nonisolated static var config: Nemotron3Config { .fast }

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

    /// Checks that both a preset bundle and the weights-version marker are present.
    /// A partial download (no marker) is treated as uncached so it re-downloads cleanly.
    nonisolated private static func exists(in root: URL) -> Bool {
        let repoDir = root.appendingPathComponent(Repo.nemotron3Diarization.folderName)
        let bundleDir = repoDir.appendingPathComponent(config.hubSubdirectory)
            .appendingPathComponent(config.modelFileName)
        let markerFile = repoDir.appendingPathComponent(ModelNames.Nemotron3.weightsVersionFile)
        let fm = FileManager.default
        return fm.fileExists(atPath: bundleDir.appendingPathComponent("coremldata.bin").path)
            && fm.fileExists(atPath: markerFile.path)
    }

    // MARK: - Prefetch

    /// Downloads the model if absent. Idempotent and safe to call on every launch —
    /// a cache hit resolves synchronously without touching the network.
    func prefetch() {
        if AppEnvironment.isRunningTests { return }
        guard prefetchTask == nil else { return }
        if Self.isModelCached() {
            isReady = true
            warm()
            return
        }

        let destination = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models")
        downloadProgress = 0
        statusText = "Preparing speaker detection…"
        let config = Self.config
        Logger.info("Nemotron-3 Diarizer: downloading preset \(config.modelFileName)", subsystem: .model)

        prefetchTask = Task.detached(priority: .utility) { [weak self] in
            do {
                // loadFromHuggingFace downloads (if absent) then loads the bundle.
                // We adopt the result so warm() is a no-op and the bundle is available immediately.
                let loaded = try await ModelWorkQueue.shared.run("nemotron3-diarizer-download") {
                    try await Nemotron3Models.loadFromHuggingFace(
                        config: config,
                        cacheDirectory: destination,
                        progressHandler: { progress in
                            let fraction = progress.fractionCompleted
                            Task { @MainActor [weak self] in
                                self?.downloadProgress = fraction
                            }
                        }
                    )
                }
                Logger.info("Nemotron-3 Diarizer: model ready", subsystem: .model)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.prefetchTask = nil
                    self.downloadProgress = 1
                    self.statusText = ""
                    self.isReady = Self.isModelCached()
                    self.hasWarmed = true  // prevent warm() from double-loading
                    self.adopt(loaded)
                }
            } catch {
                // Non-fatal: meetings still record, just without speaker labels.
                Logger.error("Nemotron-3 Diarizer: download failed — \(error.localizedDescription)", subsystem: .model)
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

    /// Loads the Nemotron-3 bundle off the recording path and keeps it resident.
    ///
    /// Pays CoreML's one-time ANE specialization cost while nothing else is running, which is
    /// where it is cheapest, and hands the handle to `models` so no meeting ever has to load it.
    func warm() {
        // Never warm inside the test host. Loading the bundle costs ANE specialization time
        // and can interfere with latency measurements. Mirrors the guard in
        // `AppState.preloadModel()`.
        if AppEnvironment.isRunningTests {
            Logger.info("Skipping Nemotron-3 Diarizer warm-up in test environment", subsystem: .model)
            return
        }
        guard !hasWarmed, warmTask == nil, models == nil, Self.isModelCached() else { return }
        hasWarmed = true

        let config = Self.config
        let root = Self.modelsRoot()
        warmTask = Task.detached(priority: .utility) { [weak self] in
            let started = Date()
            do {
                let loaded = try await ModelWorkQueue.shared.run("nemotron3-diarizer-warmup") {
                    try await Nemotron3Models.loadFromHuggingFace(config: config, cacheDirectory: root)
                }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                Logger.info("Nemotron-3 Diarizer: warm-up load in \(ms)ms — held resident", subsystem: .model)
                await MainActor.run { [weak self] in self?.adopt(loaded) }
            } catch {
                // Non-fatal — the coordinator will try again when a meeting starts.
                Logger.error("Nemotron-3 Diarizer: warm-up failed — \(error.localizedDescription)", subsystem: .model)
                await MainActor.run { [weak self] in self?.hasWarmed = false }
            }
            await MainActor.run { [weak self] in self?.warmTask = nil }
        }
    }
}
#endif
