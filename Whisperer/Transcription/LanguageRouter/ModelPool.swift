//
//  ModelPool.swift
//  Whisperer
//
//  Single owner of all whisper_context instances — preview/detector, active, fallback, and standby backends
//

import Foundation
import QuartzCore  // CACurrentMediaTime

// MARK: - RouteActivation

/// Result of routing a target profile through ModelPool
enum RouteActivation {
    /// Target model is warm — use this backend directly
    case warm(TranscriptionBackend)

    /// Target model is cold — use fallback now, loading task will produce target backend
    case fallback(
        backend: TranscriptionBackend,
        loading: Task<TranscriptionBackend, Error>
    )
}

// MARK: - ModelPool Errors

enum ModelPoolError: Error, LocalizedError {
    case fallbackNotMultilingual
    case fallbackNotLoaded
    case modelLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .fallbackNotMultilingual:
            return "Fallback profile must be a multilingual model"
        case .fallbackNotLoaded:
            return "Fallback backend is not loaded"
        case .modelLoadFailed(let name):
            return "Failed to load model: \(name)"
        }
    }
}

// MARK: - ModelPool

final class ModelPool {
    // MARK: - Warm backends, keyed by ModelProfile
    private var warmBackends: [ModelProfile: TranscriptionBackend] = [:]

    // MARK: - In-flight loads (deduplication)
    private var inFlightLoads: [ModelProfile: Task<TranscriptionBackend, Error>] = [:]
    private let inFlightLock = SafeLock(defaultTimeout: 2.0)

    // MARK: - Multilingual fallback (always loaded when routing is active)
    private(set) var fallbackProfile: ModelProfile?

    /// Memory headroom required before admitting a standby model
    static let standbyHeadroomGB: Double = 1.0

    /// Profiles currently warm (for ModelRouter queries)
    var warmProfiles: Set<ModelProfile> {
        Set(warmBackends.keys)
    }

    init() {}

    // MARK: - Backend Lifecycle

    /// Load the multilingual fallback backend.
    /// Must be called before routing starts. Validates profile.model.isMultilingual.
    func loadFallback(profile: ModelProfile, backend: TranscriptionBackend) throws {
        guard profile.model.isMultilingual else {
            throw ModelPoolError.fallbackNotMultilingual
        }
        fallbackProfile = profile
        warmBackends[profile] = backend
        Logger.info("Fallback loaded: \(profile.model.displayName)", subsystem: .model)
    }

    /// Register an already-loaded backend as warm (e.g., the initial bridge from AppState)
    func registerWarm(profile: ModelProfile, backend: TranscriptionBackend) {
        warmBackends[profile] = backend
        Logger.debug("Registered warm backend: \(profile.model.displayName)", subsystem: .model)
    }

    /// Route a target profile. Returns warm backend or fallback + async loading task.
    /// Deduplicates in-flight loads for the same profile.
    func routeTarget(for profile: ModelProfile) -> RouteActivation {
        // Check if target is already warm (exact profile match)
        if let backend = warmBackends[profile] {
            return .warm(backend)
        }

        // Check if the same model binary is warm under a different profile
        // (e.g., same model with language: .auto vs language: .english)
        if let match = warmBackends.first(where: { $0.key.model == profile.model && $0.key.backend == profile.backend }) {
            Logger.debug("Reusing warm backend for \(profile.model.displayName) (different language profile)", subsystem: .model)
            return .warm(match.value)
        }

        // Target is truly cold (different model binary) — get fallback backend
        guard let fbProfile = fallbackProfile, let fbBackend = warmBackends[fbProfile] else {
            // This should never happen if preloadLanguageRouting() ran correctly
            Logger.error("Fallback backend not available during routing", subsystem: .model)
            // Return any available backend as emergency fallback
            if let anyBackend = warmBackends.values.first {
                return .warm(anyBackend)
            }
            fatalError("ModelPool has no loaded backends")
        }

        // Check for existing in-flight load (deduplication)
        let existingTask: Task<TranscriptionBackend, Error>? = {
            do {
                return try inFlightLock.withLock { inFlightLoads[profile] }
            } catch {
                return nil
            }
        }()

        if let existing = existingTask {
            Logger.debug("Reusing in-flight load for \(profile.model.displayName)", subsystem: .model)
            return .fallback(backend: fbBackend, loading: existing)
        }

        // Create new loading task.
        //
        // A plain `Task {}` on purpose, not `Task.detached`: this type is implicitly `@MainActor`
        // (SWIFT_DEFAULT_ACTOR_ISOLATION), so the task inherits main isolation and the
        // `warmBackends` / in-flight bookkeeping below is race-free. The expensive part —
        // `WhisperBridge.init` plus a warm-up decode, blocking C and possibly a first-run
        // CoreML/ANE encoder compile — is pushed off the main thread by `loadBackend` itself.
        let loadingTask = Task<TranscriptionBackend, Error> { [weak self] in
            guard let self else { throw ModelPoolError.modelLoadFailed("ModelPool deallocated") }

            let backend = try await self.loadBackend(for: profile)

            // Register as warm and clean up in-flight
            self.warmBackends[profile] = backend
            do {
                try self.inFlightLock.withLock {
                    self.inFlightLoads.removeValue(forKey: profile)
                }
            } catch {
                Logger.warning("Failed to clean up in-flight load entry", subsystem: .model)
            }

            return backend
        }

        // Store in-flight task
        do {
            try inFlightLock.withLock {
                inFlightLoads[profile] = loadingTask
            }
        } catch {
            Logger.warning("Failed to store in-flight load entry", subsystem: .model)
        }

        Logger.info("Loading \(profile.model.displayName) for \(profile.language.displayName) (async)", subsystem: .model)
        return .fallback(backend: fbBackend, loading: loadingTask)
    }

    /// Get a warm backend for a profile, or nil if cold.
    func warmBackend(for profile: ModelProfile) -> TranscriptionBackend? {
        warmBackends[profile]
    }

    /// Pre-load a standby model if memory allows.
    func preloadStandby(profile: ModelProfile) {
        guard warmBackends[profile] == nil else { return }

        let available = SystemMemory.availableGB()
        let required = profile.model.requiredMemoryGB + Self.standbyHeadroomGB
        guard available >= required else {
            Logger.debug("Skipping standby preload for \(profile.model.displayName): available \(String(format: "%.1f", available))GB < required \(String(format: "%.1f", required))GB", subsystem: .model)
            return
        }

        Logger.info("Preloading standby: \(profile.model.displayName)", subsystem: .model)
        // Priority is set explicitly but the task is NOT detached — it stays on this main-actor
        // type so the `warmBackends` write below is not a cross-isolation mutation. The blocking
        // load inside `loadBackend` is what runs off the main thread.
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let backend = try await self.loadBackend(for: profile)
                self.warmBackends[profile] = backend
                Logger.info("Standby ready: \(profile.model.displayName)", subsystem: .model)
            } catch {
                Logger.warning("Standby preload failed for \(profile.model.displayName): \(error)", subsystem: .model)
            }
        }
    }

    /// Evict standby backends (not fallback) under memory pressure.
    func evictStandby() {
        let profilesToEvict = warmBackends.keys.filter { $0 != fallbackProfile }
        for profile in profilesToEvict {
            if let backend = warmBackends.removeValue(forKey: profile) {
                backend.prepareForShutdown()
                Logger.info("Evicted standby: \(profile.model.displayName)", subsystem: .model)
            }
        }
    }

    /// Release all resources (shutdown).
    func releaseAll() {
        // Cancel in-flight loads
        do {
            try inFlightLock.withLock {
                for (_, task) in inFlightLoads {
                    task.cancel()
                }
                inFlightLoads.removeAll()
            }
        } catch {
            Logger.warning("Failed to cancel in-flight loads during shutdown", subsystem: .model)
        }

        // Shutdown all backends — skip fallback (AppState owns its lifecycle, not ModelPool)
        for (profile, backend) in warmBackends {
            guard profile != fallbackProfile else { continue }
            backend.prepareForShutdown()
            Logger.debug("Released backend: \(profile.model.displayName)", subsystem: .model)
        }
        warmBackends.removeAll()
        fallbackProfile = nil

        Logger.info("ModelPool released all resources", subsystem: .model)
    }

    // MARK: - Internal

    /// Loads and warms a target backend off the main thread.
    ///
    /// `runBlocking`, not `run`: `WhisperBridge.init` and the warm-up decode are blocking C, and on
    /// the first launch after a model is installed the init is a ~40s synchronous-XPC CoreML/ANE
    /// encoder compile. Both call sites reach here from a main-actor `Task`, whose isolation an
    /// unannotated `async` body would inherit — see the note on `ModelWorkQueue`. Going through the
    /// queue also stops a cold target load from contending with a live meeting; the caller is
    /// already serving the fallback backend while this runs, so waiting costs nothing.
    private func loadBackend(for profile: ModelProfile) async throws -> TranscriptionBackend {
        // Download the model file if it is not already on disk. This runs plain (not inside
        // ModelWorkQueue) because URLSession contends with nothing; the queue is for whisper
        // context work only, and the 120 s watchdog would fire on any multi-GB transfer.
        if !ModelDownloader.shared.isModelDownloaded(profile.model) {
            Logger.info("Downloading \(profile.model.displayName) for routing target", subsystem: .model)
            try await ModelDownloader.shared.downloadModel(profile.model, progressCallback: { fraction in
                Logger.debug("Routing target \(profile.model.displayName) download: \(Int(fraction * 100))%", subsystem: .model)
            })
        }

        let modelPath = ModelDownloader.shared.modelPath(for: profile.model)
        let startTime = CACurrentMediaTime()

        let bridge = try await ModelWorkQueue.shared.runBlocking("routing-target-load") {
            let bridge = try WhisperBridge(modelPath: modelPath)
            // GPU warm-up
            _ = bridge.transcribe(samples: [Float](repeating: 0, count: 16000))
            return bridge
        }

        let elapsed = CACurrentMediaTime() - startTime
        Logger.info("\(profile.model.displayName) loaded in \(String(format: "%.2f", elapsed))s (includes GPU warm-up)", subsystem: .model)

        return bridge
    }
}
