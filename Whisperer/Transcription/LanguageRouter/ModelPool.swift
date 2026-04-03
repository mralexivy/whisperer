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
    // MARK: - Shared tiny bridge (CPU-only) — preview + language detection
    private(set) var previewBridge: WhisperBridge?

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

    // MARK: - Preview / Detection Bridge

    /// Load CPU-only tiny model for live preview and language detection.
    /// CPU-only = zero GPU contention with main model and UI rendering.
    /// ANE handles the CoreML encoder automatically when .mlmodelc is present.
    func loadPreviewBridge(modelPath: URL) throws {
        let startTime = CACurrentMediaTime()
        let bridge = try WhisperBridge(modelPath: modelPath, useGPU: false)
        // Warm up
        _ = bridge.transcribe(samples: [Float](repeating: 0, count: 16000))
        previewBridge = bridge
        let elapsed = (CACurrentMediaTime() - startTime) * 1000
        Logger.info("Preview/detector bridge loaded (CPU) in \(String(format: "%.0f", elapsed))ms", subsystem: .model)
    }

    /// Run language detection on audio samples via shared preview bridge.
    /// Serialized with preview transcription via ctxLock.
    func detectLanguage(samples: [Float]) -> [String: Float]? {
        previewBridge?.detectLanguage(samples: samples)
    }

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

        // Create new loading task
        let loadingTask = Task<TranscriptionBackend, Error> { [weak self] in
            guard let self else { throw ModelPoolError.modelLoadFailed("ModelPool deallocated") }

            let backend = try self.loadBackend(for: profile)

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
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let backend = try self.loadBackend(for: profile)
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

        // Shutdown all backends
        for (profile, backend) in warmBackends {
            backend.prepareForShutdown()
            Logger.debug("Released backend: \(profile.model.displayName)", subsystem: .model)
        }
        warmBackends.removeAll()
        fallbackProfile = nil

        // Shutdown preview/detector bridge
        previewBridge?.prepareForShutdown()
        previewBridge = nil

        Logger.info("ModelPool released all resources", subsystem: .model)
    }

    // MARK: - Internal

    private func loadBackend(for profile: ModelProfile) throws -> TranscriptionBackend {
        let modelPath = ModelDownloader.shared.modelPath(for: profile.model)
        let startTime = CACurrentMediaTime()

        let bridge = try WhisperBridge(modelPath: modelPath)

        // GPU warm-up
        let warmupSamples = [Float](repeating: 0, count: 16000)
        _ = bridge.transcribe(samples: warmupSamples)

        let elapsed = CACurrentMediaTime() - startTime
        Logger.info("\(profile.model.displayName) loaded in \(String(format: "%.2f", elapsed))s (includes GPU warm-up)", subsystem: .model)

        return bridge
    }
}
