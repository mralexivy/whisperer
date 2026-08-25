//
//  MeetingEngines.swift
//  Whisperer
//
//  Dedicated engine lifecycle for meeting features: download + warm the four model
//  engines (speech/Nemotron, cleanup/WhisperBridge, intelligence/LLM, speakers/Sortformer)
//  so meeting AI works even when the user's dictation LLM toggle is off.
//

#if canImport(FluidAudio)
import Foundation
import Combine
import Hub
import MLXLLM
import MLXLMCommon

// MARK: - MeetingEngine

enum MeetingEngine: CaseIterable {
    case speech, cleanup, intelligence, speakers

    /// User-visible role label. Never use raw model display names for these —
    /// both "Whisperer V3" LLM variant and "Whisperer V3" Whisper model share
    /// that display string and would be confusing unqualified.
    var roleLabel: String {
        switch self {
        case .speech:       return "Live transcription"
        case .cleanup:      return "Transcription cleanup"
        case .intelligence: return "Meeting intelligence"
        case .speakers:     return "Speaker detection"
        }
    }

    /// One-line description of what this engine does for the user.
    var roleDescription: String {
        switch self {
        case .speech:       return "Converts your voice to text in real time during the meeting."
        case .cleanup:      return "Re-transcribes the recording after the meeting for accuracy."
        case .intelligence: return "Generates the title, summary, decisions and answers your questions."
        case .speakers:     return "Identifies who is speaking in the transcript."
        }
    }

    /// Approximate download size string shown in the UI.
    var downloadSizeLabel: String {
        switch self {
        case .speech:       return "~1.5 GB"
        case .cleanup:
            // Computed from the actual model set so the UI stays honest as specialists change.
            let totalBytes = MeetingEngines.cleanupModelSet()
                .filter { !ModelDownloader.shared.isModelDownloaded($0) }
                .map { $0.approximateDownloadBytes }
                .reduce(0.0, +)
            let totalMB = Int(totalBytes / 1_000_000)
            return totalMB > 0 ? "~\(totalMB) MB" : "~547 MB"
        case .intelligence: return "~3.2 GB"
        case .speakers:     return "~330 MB"
        }
    }

    /// Byte size used for weighted progress calculation.
    var downloadBytes: Double {
        switch self {
        case .speech:       return 1_500_000_000
        case .cleanup:
            return MeetingEngines.cleanupModelSet()
                .map { $0.approximateDownloadBytes }
                .reduce(0.0, +)
        case .intelligence: return 3_200_000_000
        case .speakers:     return 330_000_000
        }
    }
}

// MARK: - EngineReadiness

enum EngineReadiness: Equatable {
    case ready
    case needsDownload(String)  // message explaining why
    case needsWarmup            // on disk, but its first-run compile has not been paid yet
    case downloading(Double)    // 0.0 – 1.0
    case preparing              // warm pass in progress (after download)
    case unavailable(String)    // error message
}

// MARK: - MeetingEngines

/// Downloads, warms and vends the four model engines meeting features depend on.
///
/// Modelled on `MeetingDiarizerService`: same `ModelWorkQueue` pattern, same
/// `[weak self]` discipline, same single published snapshot rather than four
/// separate `@Published Double`s. Callers observe `readiness` and `statusText`
/// to drive UI.
@MainActor
final class MeetingEngines: ObservableObject {
    static let shared = MeetingEngines()

    /// Model behind the `.intelligence` engine (title, overview, Ask AI). Reverting a quality
    /// regression is a one-line change here. Keep `downloadSizeLabel` / `downloadBytes` in sync
    /// — `MeetingPrepView`'s progress rail is weighted by those.
    static let intelligenceVariant: LLMModelVariant = .qwen3_5_4B_mtp

    // MARK: - Published state

    /// One snapshot drives the whole UI — never four separate @Published Doubles.
    @Published private(set) var readiness: [MeetingEngine: EngineReadiness] = {
        var r: [MeetingEngine: EngineReadiness] = [:]
        for e in MeetingEngine.allCases { r[e] = .needsDownload("") }
        return r
    }()

    @Published private(set) var statusText: String = ""

    // MARK: - Private state

    /// In-flight prefetch/warm task per engine — guard against double-submission.
    private var engineTasks: [MeetingEngine: Task<Void, Never>] = [:]

    /// Combine subscriptions that mirror Sortformer readiness into the .speakers slot.
    private var cancellables = Set<AnyCancellable>()

    // MARK: - LLM borrow/release

    private var llmInstance: LLMPostProcessor?
    private var llmRefcount: Int = 0
    private var llmIdleTask: Task<Void, Never>?
    /// True while the idle-unload body (unloadModel + nil assignment) is executing.
    /// Guards borrowLLM() from calling loadModel() concurrently with an in-flight unload.
    private var isUnloading: Bool = false

    // MARK: - init

    private init() {
        refreshReadiness()

        // Mirror Sortformer readiness into .speakers
        MeetingDiarizerService.shared.$isReady
            .sink { [weak self] isReady in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Don't overwrite an in-progress download state.
                    switch self.readiness[.speakers] {
                    case .downloading, .preparing: return
                    default: break
                    }
                    self.readiness[.speakers] = isReady ? .ready : .needsDownload("")
                    self.updateStatusText()
                }
            }
            .store(in: &cancellables)

        // Throttle to 100 ms — Sortformer fires progress on every URLSession delegate
        // callback, which can be several hundred times per second on a fast link.
        // With DispatchQueue.main as the scheduler, the sink fires on the main queue
        // so we can touch @MainActor state directly without an extra Task hop.
        MeetingDiarizerService.shared.$downloadProgress
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] progress in
                guard let self = self, progress > 0, progress < 1 else { return }
                self.readiness[.speakers] = .downloading(progress)
                self.updateStatusText()
            }
            .store(in: &cancellables)
    }

    // MARK: - Computed properties

    /// True when any engine is not `.ready`.
    var needsPreparation: Bool {
        readiness.values.contains {
            if case .ready = $0 { return false }
            return true
        }
    }

    /// Weighted progress 0..1 across all engines (by download byte size).
    /// Each engine contributes its weight proportionally; `.ready` = full weight,
    /// `.downloading(p)` = 90% of weight × p, `.preparing` = 90% of weight.
    var overallProgress: Double {
        let total = MeetingEngine.allCases.map(\.downloadBytes).reduce(0, +)
        guard total > 0 else { return 0 }
        let sum = MeetingEngine.allCases.reduce(0.0) { acc, engine in
            let w = engine.downloadBytes / total
            switch readiness[engine] {
            case .ready:              return acc + w
            case .downloading(let p): return acc + w * p * 0.9
            case .preparing:          return acc + w * 0.9
            default:                  return acc
            }
        }
        return min(1.0, sum)
    }

    // MARK: - Cleanup warm markers

    /// Per-model warm marker key. Records that this machine has already paid the model's
    /// first-run Core ML compile. Keyed by model rawValue so a model change forces re-warm.
    private static func cleanupWarmKey(for model: WhisperModel) -> String {
        "meetingCleanupWarm.\(model.rawValue)"
    }

    private static func isCleanupModelWarm(_ model: WhisperModel) -> Bool {
        let key = cleanupWarmKey(for: model)
        let expected = ModelDownloader.shared.modelPath(for: model).lastPathComponent
        return UserDefaults.standard.string(forKey: key) == expected
    }

    private static func markCleanupModelWarm(_ model: WhisperModel) {
        let key = cleanupWarmKey(for: model)
        let value = ModelDownloader.shared.modelPath(for: model).lastPathComponent
        UserDefaults.standard.set(value, forKey: key)
    }

    /// All models the cleanup pass needs — baseline plus a specialist per allowed language.
    static func cleanupModelSet() -> [WhisperModel] {
        RefineModelTable.modelsForCurrentConfig()
    }

    // MARK: - Readiness checks

    /// Snapshot the current on-disk readiness state for each engine.
    /// Never downgrades an in-progress download or warm pass.
    private func refreshReadiness() {
        // .speech — Nemotron on disk
        switch readiness[.speech] {
        case .downloading, .preparing: break
        default:
            readiness[.speech] = NemotronBridge.isModelCached()
                ? .ready
                : .needsDownload("Download the Nemotron model from the Models tab.")
        }

        // .cleanup — baseline (Whisperer V3) plus any language specialists, all on disk AND
        // with their first-run Core ML compile paid. "Downloaded" is not "ready" — see the
        // note on `cleanupWarmKey(for:)` for the 40s compile story.
        switch readiness[.cleanup] {
        case .downloading, .preparing: break
        default:
            let models = Self.cleanupModelSet()
            let missingDownload = models.first { !ModelDownloader.shared.isModelDownloaded($0) }
            if let missing = missingDownload {
                readiness[.cleanup] = .needsDownload("Download \(missing.displayName) from the Models tab.")
            } else if models.allSatisfy({ Self.isCleanupModelWarm($0) }) {
                readiness[.cleanup] = .ready
            } else {
                readiness[.cleanup] = .needsWarmup
            }
        }

        // .intelligence — Qwen3.5-4B MTP model directory on disk
        switch readiness[.intelligence] {
        case .downloading, .preparing: break
        default:
            readiness[.intelligence] = isIntelligenceModelOnDisk()
                ? .ready
                : .needsDownload("The meeting intelligence model (~3.2 GB) will be downloaded on first use.")
        }

        // .speakers — delegate entirely to MeetingDiarizerService
        switch readiness[.speakers] {
        case .downloading, .preparing: break
        default:
            readiness[.speakers] = MeetingDiarizerService.shared.isReady
                ? .ready
                : .needsDownload("")
        }

        updateStatusText()
    }

    /// Replicates the HubApi directory probe from `LLMPostProcessor.loadModel` without
    /// importing or instantiating LLMPostProcessor. Returns true when config.json is present.
    private func isIntelligenceModelOnDisk() -> Bool {
        let hub = HubApi()
        let idConfig = ModelConfiguration(id: Self.intelligenceVariant.huggingFaceId)
        let localDir = idConfig.modelDirectory(hub: hub)
        return FileManager.default.fileExists(
            atPath: localDir.appendingPathComponent("config.json").path)
    }

    private func updateStatusText() {
        for engine in MeetingEngine.allCases {
            switch readiness[engine] {
            case .downloading(let p):
                statusText = "Downloading \(engine.roleLabel)… \(Int(p * 100))%"
                return
            case .preparing:
                statusText = "Preparing \(engine.roleLabel)…"
                return
            default: break
            }
        }
        statusText = ""
    }

    // MARK: - Prefetch (idempotent)

    /// Downloads and warms each engine that is not yet ready. Idempotent and safe to call
    /// on every app launch and on every meeting detection event.
    func prefetch() {
        // Not from a test host. This warms all three engines: a Nemotron load, a model download
        // followed by a blocking Core ML compile the cleanup path itself measures at ~40s, and
        // an MLX LLM load/unload. It is reachable at launch *and* from meeting detection — and
        // recording tests turn the microphone on, which is exactly what the detector watches, so
        // a test suite can trigger it at an arbitrary moment. Same failure mode as the Sortformer
        // warm-up that broke `testAbortCancelsTranscription`, three times over.
        if AppEnvironment.isRunningTests {
            Logger.info("Meeting engine prefetch skipped — test environment", subsystem: .model)
            return
        }

        // Speakers fully delegated to MeetingDiarizerService — it handles download + warm.
        MeetingDiarizerService.shared.prefetch()

        // Speech, cleanup, intelligence: start a background task unless one is already
        // in-flight or the engine is already ready.
        for engine in [MeetingEngine.speech, .cleanup, .intelligence] {
            guard engineTasks[engine] == nil else { continue }
            switch readiness[engine] {
            case .ready, .downloading, .preparing: continue
            default: break
            }
            startEngine(engine)
        }
    }

    private func startEngine(_ engine: MeetingEngine) {
        let task = Task.detached(priority: .utility) { [weak self] in
            switch engine {
            case .speech:       await self?.runSpeech()
            case .cleanup:      await self?.runCleanup()
            case .intelligence: await self?.runIntelligence()
            case .speakers:     break  // handled by MeetingDiarizerService
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.engineTasks.removeValue(forKey: engine)
                self.refreshReadiness()
            }
        }
        engineTasks[engine] = task
    }

    // MARK: - Per-engine warm passes
    //
    // All three methods are @MainActor (inherited from the class). State properties
    // (readiness, statusText, llmInstance, etc.) are accessed directly — no MainActor.run
    // wrappers needed. After each `await`, execution resumes on the main actor.

    private func runSpeech() async {
        guard NemotronBridge.isModelCached() else {
            Logger.info("MeetingEngines: speech model not on disk, skipping warm", subsystem: .model)
            return
        }
        readiness[.speech] = .preparing
        statusText = "Preparing \(MeetingEngine.speech.roleLabel)…"
        // prepareMeetingBackend manages its own ModelWorkQueue slot ("nemotron-load").
        // Do NOT wrap in an outer MWQ job — that would deadlock (outer slot held, inner
        // "nemotron-load" queued behind it and never dequeued).
        let success = await AppState.shared.prepareMeetingBackend()
        Logger.info("MeetingEngines: speech warm \(success ? "succeeded" : "failed")", subsystem: .model)
        if success {
            readiness[.speech] = .ready
        } else {
            readiness[.speech] = .unavailable("Nemotron could not be loaded.")
        }
    }

    private func runCleanup() async {
        let models = Self.cleanupModelSet()
        // Capture weak reference before closures that cross actor boundaries.
        weak var weakSelf: MeetingEngines? = self

        for model in models {
            // 1. Download if not on disk.
            // Downloads run plain (not inside ModelWorkQueue) — URLSession transfer contends with
            // nothing, and the queue's 120 s watchdog fires on multi-GB transfers.
            if !ModelDownloader.shared.isModelDownloaded(model) {
                readiness[.cleanup] = .downloading(0)
                updateStatusText()
                do {
                    try await ModelDownloader.shared.downloadModel(model, progressCallback: { fraction in
                        Task { @MainActor in
                            weakSelf?.readiness[.cleanup] = .downloading(fraction)
                            weakSelf?.updateStatusText()
                        }
                    })
                } catch {
                    Logger.error("MeetingEngines: cleanup download failed for \(model.displayName) — \(error.localizedDescription)", subsystem: .model)
                    readiness[.cleanup] = .unavailable(error.localizedDescription)
                    return
                }
            }

            // 2. Warm pass: pay the CoreML/ANE first-run compile cost so subsequent loads
            //    hit the on-disk cache and finish in ~2s instead of ~40s.
            //    Skip if already warm — the user paid this compile on a previous launch.
            guard !Self.isCleanupModelWarm(model) else { continue }

            readiness[.cleanup] = .preparing
            statusText = "Preparing \(MeetingEngine.cleanup.roleLabel)…"
            let modelPath = ModelDownloader.shared.modelPath(for: model)
            let warmStart = Date()
            do {
                try await ModelWorkQueue.shared.runBlocking("meeting-engine-warm-cleanup-\(model.rawValue)") {
                    let bridge = try WhisperBridge(modelPath: modelPath, useGPU: false)
                    bridge.prepareForShutdown()
                }
            } catch {
                Logger.error("MeetingEngines: cleanup warm failed for \(model.displayName) — \(error.localizedDescription)", subsystem: .model)
                readiness[.cleanup] = .unavailable(error.localizedDescription)
                return
            }
            // Marker written only on success — a failed warm must re-run on the next launch.
            Self.markCleanupModelWarm(model)
            Logger.info(
                "MeetingEngines: \(model.displayName) warm done in \(Int(Date().timeIntervalSince(warmStart) * 1000))ms",
                subsystem: .model
            )
        }

        readiness[.cleanup] = .ready
    }

    private func runIntelligence() async {
        // Drop the "model on disk" guard: let loadModel handle the download from HuggingFace
        // Hub automatically. The Combine bridge below mirrors loadModel's own progress into
        // our readiness slot so the UI shows accurate download state.
        readiness[.intelligence] = .preparing
        statusText = "Preparing \(MeetingEngine.intelligence.roleLabel)…"

        let processor = LLMPostProcessor()  // @MainActor — created directly

        // Bridge LLMPostProcessor's download progress to our .intelligence readiness slot.
        // processor.$loadPhase publishes on the main actor; the sink fires there too.
        var bridgeCancellable: AnyCancellable? = processor.$loadPhase
            .compactMap { phase -> EngineReadiness? in
                if case .downloading(let p) = phase { return .downloading(p) }
                return nil
            }
            .sink { [weak self] r in
                self?.readiness[.intelligence] = r
                self?.updateStatusText()
            }
        defer { bridgeCancellable?.cancel(); bridgeCancellable = nil }

        do {
            // loadModel downloads (if needed) then loads weights into memory.
            // unloadModel frees GPU memory and Metal resources.
            // Both hop to main actor inside the ModelWorkQueue body — the slot is held
            // for the full download+load+unload pass so no other model work overlaps.
            try await ModelWorkQueue.shared.run("meeting-engine-warm-intelligence") {
                try await processor.loadModel(Self.intelligenceVariant)
                await processor.unloadModel()
                Logger.info("MeetingEngines: intelligence warm done — weights paged in+out", subsystem: .model)
            }
        } catch {
            Logger.error("MeetingEngines: intelligence warm failed — \(error.localizedDescription)", subsystem: .model)
            readiness[.intelligence] = .unavailable(error.localizedDescription)
            return
        }
        readiness[.intelligence] = .ready
    }

    // MARK: - LLM borrow/release (refcounted)

    /// Returns a loaded `LLMPostProcessor` for the meeting intelligence model, or `nil`
    /// if the model is not on disk. Callers MUST call `releaseLLM()` after they finish.
    ///
    /// The instance is shared across borrowers via refcounting. A 60-second idle window
    /// after the last release frees GPU memory. For now this always vends a dedicated
    /// instance rather than borrowing from the dictation path.
    func borrowLLM() async -> LLMPostProcessor? {
        guard case .ready = readiness[.intelligence] else {
            Logger.info("MeetingEngines: borrowLLM — intelligence engine not ready", subsystem: .model)
            return nil
        }
        // Cancel any pending idle-release.
        llmIdleTask?.cancel()
        llmIdleTask = nil
        llmRefcount += 1

        // If the idle-unload body is executing concurrently (cancel() cannot interrupt an
        // already-suspended unloadModel() call), yield until it finishes. Without this guard,
        // borrowLLM() would call loadModel() while unloadModel() is still in flight, and the
        // subsequent `self.llmInstance = nil` at the end of the idle task would orphan the
        // freshly loaded model, causing the next borrow to build a third LLMPostProcessor.
        while isUnloading {
            await Task.yield()
        }

        // Reuse an existing instance if already loaded.
        if let existing = llmInstance, existing.isModelLoaded {
            return existing
        }

        // Create a new instance if none exists yet.
        if llmInstance == nil {
            llmInstance = LLMPostProcessor()
        }
        guard let processor = llmInstance else {
            llmRefcount -= 1
            return nil
        }

        // Load inside a ModelWorkQueue slot — same serialization as the warm pass,
        // prevents contention with other concurrent model work.
        if !processor.isModelLoaded {
            do {
                try await ModelWorkQueue.shared.run("meeting-engine-borrow-llm") {
                    try await processor.loadModel(Self.intelligenceVariant)
                }
            } catch {
                Logger.error("MeetingEngines: borrowLLM load failed — \(error.localizedDescription)", subsystem: .model)
                llmRefcount -= 1
                return nil
            }
        }
        return processor
    }

    /// Decrements the borrow refcount. When it reaches zero, schedules an unload
    /// after a 60-second idle window to free GPU memory between meetings.
    func releaseLLM() {
        llmRefcount = max(0, llmRefcount - 1)
        guard llmRefcount == 0, llmInstance != nil else { return }
        llmIdleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, self.llmRefcount == 0 else { return }
            self.isUnloading = true
            await self.llmInstance?.unloadModel()
            self.llmInstance = nil
            self.isUnloading = false
            Logger.info("MeetingEngines: LLM unloaded after 60s idle", subsystem: .model)
        }
    }
}
#endif
