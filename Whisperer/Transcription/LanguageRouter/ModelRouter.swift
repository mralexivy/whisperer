//
//  ModelRouter.swift
//  Whisperer
//
//  Maps language decisions to concrete model profiles
//

import Foundation

// MARK: - ModelProfile

/// Identity is (model, backend, language). isSpecialized is descriptive only.
struct ModelProfile: Hashable {
    let model: WhisperModel
    let backend: BackendType
    let language: TranscriptionLanguage
    let isSpecialized: Bool

    static func == (lhs: ModelProfile, rhs: ModelProfile) -> Bool {
        lhs.model == rhs.model && lhs.backend == rhs.backend && lhs.language == rhs.language
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(model)
        hasher.combine(backend)
        hasher.combine(language)
    }
}

// MARK: - ModelRouteDecision

struct ModelRouteDecision {
    let lang: TranscriptionLanguage
    let profile: ModelProfile
    let confidence: Float
    let isFallback: Bool
}

// MARK: - ModelRouter

final class ModelRouter {
    private let languageModelMap: [TranscriptionLanguage: ModelProfile]
    private let fallbackProfile: ModelProfile

    /// Initialize with language-to-model mapping and a multilingual fallback.
    /// Debug precondition validates fallback is multilingual.
    /// Real user-facing safety is in preloadLanguageRouting() at startup.
    init(
        languageModelMap: [TranscriptionLanguage: ModelProfile],
        fallbackProfile: ModelProfile
    ) {
        precondition(fallbackProfile.model.isMultilingual,
                     "Fallback profile must be a multilingual model, got \(fallbackProfile.model.displayName)")
        self.languageModelMap = languageModelMap
        self.fallbackProfile = fallbackProfile
    }

    /// Resolve a language decision to a model routing decision.
    ///
    /// - If target profile is warm → return it directly (isFallback = false)
    /// - If target is cold → return fallbackProfile (isFallback = true)
    /// - If no mapping → return fallbackProfile
    ///
    /// enOnlyThreshold is NOT used here. All cold targets route to fallback equally.
    /// The threshold exists for future use when block-waiting for an English-only model
    /// may be justified by quality gains.
    func resolve(
        decision: RouteDecision,
        warmProfiles: Set<ModelProfile>
    ) -> ModelRouteDecision {
        // Look up target profile for the detected language
        guard let targetProfile = languageModelMap[decision.lang] else {
            Logger.debug("No model mapping for \(decision.lang.displayName), using fallback", subsystem: .transcription)
            return ModelRouteDecision(
                lang: decision.lang,
                profile: fallbackProfile,
                confidence: decision.confidence,
                isFallback: true
            )
        }

        // If target uses the same model binary as fallback (or any warm profile),
        // it's already loaded — just use it with the routed language.
        // Language is passed at transcription time, not model load time.
        if targetProfile.model == fallbackProfile.model && targetProfile.backend == fallbackProfile.backend {
            Logger.debug("Route: \(decision.lang.displayName) → \(targetProfile.model.displayName) (same model as fallback, warm)", subsystem: .transcription)
            return ModelRouteDecision(
                lang: decision.lang,
                profile: targetProfile,
                confidence: decision.confidence,
                isFallback: false
            )
        }

        // Check if target profile (or same model binary) is warm
        let isWarm = warmProfiles.contains(targetProfile) ||
                     warmProfiles.contains(where: { $0.model == targetProfile.model && $0.backend == targetProfile.backend })
        if isWarm {
            Logger.debug("Route: \(decision.lang.displayName) → \(targetProfile.model.displayName) (warm)", subsystem: .transcription)
            return ModelRouteDecision(
                lang: decision.lang,
                profile: targetProfile,
                confidence: decision.confidence,
                isFallback: false
            )
        }

        // Target is truly cold (different model binary) — use fallback
        Logger.debug("Route: \(decision.lang.displayName) → fallback (\(fallbackProfile.model.displayName)), target \(targetProfile.model.displayName) cold", subsystem: .transcription)
        return ModelRouteDecision(
            lang: decision.lang,
            profile: targetProfile,
            confidence: decision.confidence,
            isFallback: true
        )
    }
}
