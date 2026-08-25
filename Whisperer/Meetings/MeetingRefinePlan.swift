//
//  MeetingRefinePlan.swift
//  Whisperer
//
//  Decides which model decodes which windows, applying dominance rules that
//  keep loanwords and short asides from fracturing a monolingual meeting.
//

import Foundation

// MARK: - RefineGroup

struct RefineGroup {
    let model: WhisperModel
    let language: TranscriptionLanguage
    var windows: [MeetingRefineWindow]
}

// MARK: - MeetingRefinePlan

struct MeetingRefinePlan {
    /// Groups in decode order: baseline first, specialists after.
    let groups: [RefineGroup]
    /// Models that need to be downloaded before decode can begin.
    let modelsToFetch: [WhisperModel]
}

// MARK: - DominanceRules

struct DominanceRules {
    /// Above this share the meeting is declared monolingual. Minority spans are overridden,
    /// not merely un-promoted — "Bye bye" at the end of a Hebrew meeting stays Hebrew.
    var monolingualShare: Float = 0.85
    /// A minority must clear all three thresholds below to earn its own model.
    var minMinorityShare: Float = 0.20
    var minMinoritySeconds: Double = 120
    var minMinorityConfidence: Float = 0.75
    /// …and be composed of real spans, not scattered probes.
    var minContributingSpan: Double = 15

    static let `default` = DominanceRules()
}

// MARK: - Plan builder

extension MeetingRefinePlan {

    /// Build a plan from a language timeline and a set of windows.
    ///
    /// - Parameters:
    ///   - windows: from `MeetingRefineWindow.plan(_:maxDuration:)`.
    ///   - timeline: from `MeetingLanguageScanner.scan(...)` or `.empty`.
    ///   - baseLanguage: the decoder's configured language — used when the timeline abstains.
    ///   - downloaded: models currently on disk.
    ///   - availableGB: free RAM, for per-model memory gate.
    ///   - freeDiskBytes: free disk space (unused for now, gated in download step).
    ///   - rules: dominance rules; defaults to `.default`.
    ///   - config: routing config for user overrides; defaults to a fresh load.
    static func build(
        windows: [MeetingRefineWindow],
        timeline: MeetingLanguageTimeline,
        baseLanguage: TranscriptionLanguage,
        downloaded: Set<WhisperModel>,
        availableGB: Double,
        freeDiskBytes: Int64 = Int64.max,
        rules: DominanceRules = .default,
        config: LanguageRoutingConfig = .load()
    ) -> MeetingRefinePlan {
        guard !windows.isEmpty else {
            return MeetingRefinePlan(groups: [], modelsToFetch: [])
        }

        // --- 1. Choose which languages get groups ---
        let grouped = languageGroups(
            timeline: timeline,
            baseLanguage: baseLanguage,
            windows: windows,
            rules: rules,
            availableGB: availableGB,
            config: config
        )

        // --- 2. Decide which models to fetch ---
        var toFetch: [WhisperModel] = []
        for group in grouped where !downloaded.contains(group.model) {
            if !toFetch.contains(group.model) { toFetch.append(group.model) }
        }

        return MeetingRefinePlan(groups: grouped, modelsToFetch: toFetch)
    }

    // MARK: - Grouping

    private static func languageGroups(
        timeline: MeetingLanguageTimeline,
        baseLanguage: TranscriptionLanguage,
        windows: [MeetingRefineWindow],
        rules: DominanceRules,
        availableGB: Double,
        config: LanguageRoutingConfig
    ) -> [RefineGroup] {
        // If the timeline is empty (forced-language run or routing disabled), one group.
        guard !timeline.isEmpty, timeline.dominant != .auto else {
            let lang = baseLanguage == .auto ? .auto : baseLanguage
            let model = RefineModelTable.model(for: lang, config: config)
            let gated = memoryGated(model: model, availableGB: availableGB, config: config)
            return [RefineGroup(model: gated, language: lang, windows: windows)]
        }

        // Confidence-weighted duration per language across smoothed spans.
        var weightedDuration: [TranscriptionLanguage: Double] = [:]
        var spanDuration: [TranscriptionLanguage: Double] = [:]
        for span in timeline.spans where span.language != .auto {
            let duration = span.end - span.start
            weightedDuration[span.language, default: 0] += Double(span.confidence) * duration
            spanDuration[span.language, default: 0] += duration
        }
        let totalWeighted = weightedDuration.values.reduce(0, +)
        guard totalWeighted > 0 else {
            let model = RefineModelTable.model(for: timeline.dominant, config: config)
            let gated = memoryGated(model: model, availableGB: availableGB, config: config)
            return [RefineGroup(model: gated, language: timeline.dominant, windows: windows)]
        }

        let dominant = weightedDuration.max(by: { $0.value < $1.value })!.key
        let dominantShare = Float(weightedDuration[dominant, default: 0] / totalWeighted)

        // --- Monolingual fast path ---
        if dominantShare >= rules.monolingualShare {
            Logger.info(
                "Refine plan: monolingual collapse (\(dominant.displayName) \(String(format: "%.0f", dominantShare * 100))% ≥ \(Int(rules.monolingualShare * 100))% threshold) — all windows decoded as \(dominant.displayName)",
                subsystem: .transcription
            )
            let model = RefineModelTable.model(for: dominant, config: config)
            let gated = memoryGated(model: model, availableGB: availableGB, config: config)
            // Force every window to dominant — overrides minority spans.
            return [RefineGroup(model: gated, language: dominant, windows: windows)]
        }

        // --- Multilingual: dominant group + qualified minorities ---
        var groups: [RefineGroup] = []

        // Dominant group.
        let dominantModel = RefineModelTable.model(for: dominant, config: config)
        let dominantGated = memoryGated(model: dominantModel, availableGB: availableGB, config: config)
        var dominantWindows: [MeetingRefineWindow] = []

        // Per-minority evaluation.
        var minorityGroups: [RefineGroup] = []
        for (language, wDuration) in weightedDuration where language != dominant {
            let share = Float(wDuration / totalWeighted)
            let seconds = spanDuration[language, default: 0]
            let maxSpanDuration = timeline.spans
                .filter { $0.language == language }
                .map { $0.end - $0.start }
                .max() ?? 0

            guard share >= rules.minMinorityShare else {
                Logger.info("Refine plan: \(language.displayName) share \(String(format: "%.1f", share * 100))% < \(Int(rules.minMinorityShare * 100))% — folded into \(dominant.displayName)", subsystem: .transcription)
                continue
            }
            guard seconds >= rules.minMinoritySeconds else {
                Logger.info("Refine plan: \(language.displayName) \(String(format: "%.0f", seconds))s < \(Int(rules.minMinoritySeconds))s — folded into \(dominant.displayName)", subsystem: .transcription)
                continue
            }
            guard maxSpanDuration >= rules.minContributingSpan else {
                Logger.info("Refine plan: \(language.displayName) max span \(String(format: "%.0f", maxSpanDuration))s < \(Int(rules.minContributingSpan))s — folded into \(dominant.displayName)", subsystem: .transcription)
                continue
            }
            // Need a confidence check — compute average confidence for this language's spans.
            let langSpans = timeline.spans.filter { $0.language == language }
            let avgConfidence = langSpans.isEmpty ? Float(0) :
                langSpans.reduce(Float(0)) { $0 + $1.confidence } / Float(langSpans.count)
            guard avgConfidence >= rules.minMinorityConfidence else {
                Logger.info("Refine plan: \(language.displayName) confidence \(String(format: "%.2f", avgConfidence)) < \(rules.minMinorityConfidence) — folded into \(dominant.displayName)", subsystem: .transcription)
                continue
            }

            let minModel = RefineModelTable.model(for: language, config: config)
            let minGated = memoryGated(model: minModel, availableGB: availableGB, config: config)
            Logger.info("Refine plan: \(language.displayName) qualifies (\(String(format: "%.1f", share * 100))%, \(String(format: "%.0f", seconds))s) → \(minGated.displayName)", subsystem: .transcription)
            minorityGroups.append(RefineGroup(model: minGated, language: language, windows: []))
        }

        // Assign each window to its language group (or dominant if unqualified).
        let minorityLanguages = Set(minorityGroups.map(\.language))
        for window in windows {
            let mid = (window.start + window.end) / 2
            let spanLang = timeline.language(at: mid)
            if spanLang != .auto && spanLang != dominant && minorityLanguages.contains(spanLang) {
                let idx = minorityGroups.firstIndex(where: { $0.language == spanLang })!
                minorityGroups[idx].windows.append(window)
            } else {
                dominantWindows.append(window)
            }
        }

        groups.append(RefineGroup(model: dominantGated, language: dominant, windows: dominantWindows))

        // Only include minority groups that actually got windows.
        for group in minorityGroups where !group.windows.isEmpty {
            groups.append(group)
        }

        return groups
    }

    /// Demote a model to the baseline if there is not enough RAM to load it alongside the
    /// meeting backend. Logs the demotion so it can be diagnosed from a user's log.
    private static func memoryGated(
        model: WhisperModel,
        availableGB: Double,
        config: LanguageRoutingConfig
    ) -> WhisperModel {
        let required = model.requiredMemoryGB + 1.0  // 1 GB headroom for OS and other processes
        guard availableGB < required, model != RefineModelTable.baseline else { return model }
        Logger.info(
            "Refine plan: \(model.displayName) needs \(String(format: "%.1f", required))GB, only \(String(format: "%.1f", availableGB))GB available — demoted to \(RefineModelTable.baseline.displayName)",
            subsystem: .transcription
        )
        return RefineModelTable.baseline
    }
}
