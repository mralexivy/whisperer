//
//  RefineModelTable.swift
//  Whisperer
//
//  Per-language model selection for the post-meeting refine pass.
//  Accuracy-first: this path runs off the latency path and can wait.
//
//  Precedence: user override → built-in table → baseline (Whisperer V3).
//

import Foundation

enum RefineModelTable {
    /// Accuracy-first model per language. Independent of the live-routing table
    /// (AppState.buildLanguageModelMap), which answers "what is warm right now?" —
    /// a different question under different constraints.
    static let builtin: [TranscriptionLanguage: WhisperModel] = [
        // English refines on the multilingual baseline — V3 is its strongest language, already
        // resident, and adding largeV3 (2.9 GB) for a marginal gain triggers a 4-minute background
        // download that trips the ModelWorkQueue 120 s watchdog.
        .hebrew: .ivritLargeTurbo,    // 1.5 GB, fine-tuned for Hebrew by ivrit-ai
    ]

    /// Multilingual catch-all. Used when no specialised model exists or when the specialised
    /// model cannot be loaded (not enough RAM, download failed).
    static let baseline: WhisperModel = .largeTurboQ5

    /// Resolve the best model for a language, honouring user overrides.
    ///
    /// - Parameter config: caller may pass a cached copy; defaults to a fresh load.
    static func model(
        for language: TranscriptionLanguage,
        config: LanguageRoutingConfig = .load()
    ) -> WhisperModel {
        // 1. User override — stored as rawValue strings.
        if let overrideRaw = config.languageModelOverrides[language.rawValue],
           let override = WhisperModel(rawValue: overrideRaw) {
            return override
        }
        // 2. Built-in table.
        if let builtin = builtin[language] { return builtin }
        // 3. Baseline.
        return baseline
    }

    /// All models required by the current routing config, deduplicated, baseline first.
    static func modelsForCurrentConfig() -> [WhisperModel] {
        let routing = LanguageRoutingConfig.load()
        var models: [WhisperModel] = [baseline]
        guard routing.isRoutingEnabled else { return models }
        for language in routing.allowedLanguages where language != .auto {
            let m = model(for: language)
            if !models.contains(m) { models.append(m) }
        }
        return models
    }
}
