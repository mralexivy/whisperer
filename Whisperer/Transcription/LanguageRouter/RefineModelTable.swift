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

    /// Languages where a fine-tuned Whisper specialist is **measured** to beat Qwen3, and so
    /// still earns a second decode after a Qwen3 meeting.
    ///
    /// Qwen3 leads the Open ASR Leaderboard, so for most languages re-decoding its output with
    /// a general Whisper model trades a better transcript for a worse one plus a 547 MB download
    /// and minutes of GPU. The entries here are the exceptions, and each one must be backed by
    /// `Qwen3GateBenchmarkTests.testHebrewSpecialistVersusQwen3` (or its equivalent for another
    /// language) having been run and read — not by assumption. An unmeasured language belongs
    /// out of this table, where it costs nothing.
    ///
    /// Empty is a valid and expected state: it means no cleanup pass runs at all, which is the
    /// right outcome for a user who dictates only in languages Qwen3 already leads.
    static let specialistsBeatingQwen3: [TranscriptionLanguage: WhisperModel] = [
        // Hebrew: ivrit-ai's fine-tune is the long-standing specialist. Seeded here pending the
        // gate benchmark; remove it if the dump shows Qwen3 reading better.
        .hebrew: .ivritLargeTurbo,
    ]

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

    /// The model that should re-decode this language, or `nil` when the live transcript is
    /// already the best available and a second decode would be a downgrade.
    ///
    /// - Parameters:
    ///   - language: the window's detected language.
    ///   - liveEngine: the backend that produced the live transcript. Only `.qwen3asr` suppresses
    ///     the pass; every other engine keeps the old unconditional behaviour, because the
    ///     measurement that justifies skipping is specific to Qwen3.
    ///   - config: caller may pass a cached copy; defaults to a fresh load.
    static func refineModel(
        for language: TranscriptionLanguage,
        liveEngine: BackendType,
        config: LanguageRoutingConfig = .load()
    ) -> WhisperModel? {
        // An explicit user override is a deliberate choice and always wins, including over the
        // "Qwen3 is already better" rule. Someone who pinned a model for a language asked for it.
        if let overrideRaw = config.languageModelOverrides[language.rawValue],
           let override = WhisperModel(rawValue: overrideRaw) {
            return override
        }
        guard liveEngine == .qwen3asr else { return model(for: language, config: config) }
        return specialistsBeatingQwen3[language]
    }

    /// All models the cleanup pass could need, deduplicated.
    ///
    /// After a Qwen3 meeting this is only the measured specialists for the configured languages
    /// — frequently empty, in which case no model is downloaded and no pass runs. After any
    /// other engine it is the baseline plus the per-language table, as before.
    static func modelsForCurrentConfig(liveEngine: BackendType = .whisperCpp) -> [WhisperModel] {
        let routing = LanguageRoutingConfig.load()

        guard liveEngine == .qwen3asr else {
            var models: [WhisperModel] = [baseline]
            guard routing.isRoutingEnabled else { return models }
            for language in routing.allowedLanguages where language != .auto {
                let m = model(for: language)
                if !models.contains(m) { models.append(m) }
            }
            return models
        }

        // Auto-detect with routing off means any language is possible, so every specialist in
        // the table is in scope. Narrowing to "none" there would silently skip the Hebrew pass
        // for a user who simply never configured a shortlist.
        let candidates: [TranscriptionLanguage] = routing.isRoutingEnabled
            ? routing.allowedLanguages.filter { $0 != .auto }
            : Array(specialistsBeatingQwen3.keys)
        var models: [WhisperModel] = []
        for language in candidates {
            guard let m = refineModel(for: language, liveEngine: .qwen3asr, config: routing) else { continue }
            if !models.contains(m) { models.append(m) }
        }
        return models
    }
}
