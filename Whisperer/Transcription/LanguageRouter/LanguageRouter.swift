//
//  LanguageRouter.swift
//  Whisperer
//
//  Stateful language classifier with session-lock state machine
//

import Foundation

// MARK: - Types

struct RouteDecision {
    let lang: TranscriptionLanguage
    let confidence: Float
    let source: DecisionSource
}

enum DecisionSource {
    case detection
    case sessionLock
    case userOverride
}

enum RouterState {
    case undecided
    case locked(TranscriptionLanguage)
    case suspectedSwitch(candidate: TranscriptionLanguage, checkCount: Int)
}

// MARK: - Thresholds

enum RoutingThresholds {
    static let routeThreshold: Float = 0.75
    static let switchMargin: Float = 0.20
    static let switchConfirmations = 2
    static let redetectCooldown: TimeInterval = 8.0
    static let silenceForRedetect: TimeInterval = 3.0

    // Detection window — the encoder always runs a full 30 s pass, so a longer window is free.
    // V3 at 3 s is wrong (ro 0.58 on Hebrew); at 10 s it reaches 0.93; at 30 s it is 0.98-0.99.
    static let minDetectionSamples  = 160_000  // 10 s — below this do not probe at all
    static let fullDetectionSamples = 480_000  // 30 s — 0.98-0.99 on measured data
    static let minVoicedDetectionSamples = 160_000  // 10 s of voiced audio required for detection
    static let fastPathMargin: Float = 0.30    // Top must beat runner-up by this for early lock (empirical)

    // Scoring weights — initial routing (no transcript yet)
    static let initialProbWeight: Float = 0.875
    static let initialPriorWeight: Float = 0.125

    // Scoring weights — post-chunk stabilization (transcript available)
    static let probWeight: Float = 0.70
    static let scriptWeight: Float = 0.20
    static let priorWeight: Float = 0.10

    // Session prior bonuses
    static let primaryLanguageBonus: Float = 0.05
    static let lockedLanguageBonus: Float = 0.08
    static let lastSessionBonus: Float = 0.02
}

// MARK: - LanguageRouter

// `nonisolated` for the same reason as `VADSegmenter` and `SafeLock` — see the long note in
// `VADSegmenter.swift`. This router is pure scoring over a probability dictionary plus a
// `UserDefaults` read/write; it owns no UI and is driven from the transcriber's background
// detection path, so the project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` was never
// accurate for it. It also gave the class an *isolated* deinit, and releasing such an object
// outside any Swift task — exactly what a synchronous XCTest method does — aborts in
// `swift_task_deinitOnExecutor` with `pointer being freed was not allocated` inside
// `TaskLocal::StopLookupScope::~StopLookupScope`. That crashed every `LanguageDetectionTests`
// case that constructed a router.
nonisolated final class LanguageRouter {
    let allowedLanguages: [TranscriptionLanguage]
    let primaryLanguage: TranscriptionLanguage?
    private(set) var state: RouterState = .undecided
    private var lastDetectionTime: Date?

    private var lastSessionLanguage: TranscriptionLanguage? {
        guard let raw = UserDefaults.standard.string(forKey: "lastSessionLanguage"),
              let lang = TranscriptionLanguage(rawValue: raw) else { return nil }
        return lang
    }

    /// Short per-instance tag for the log. One router can log "Language routed to …" at most once,
    /// because that transition leaves `.undecided` for good — so two such lines in one session mean
    /// two routers, and therefore two transcribers. The 2026-08-23 15:37 log has exactly that
    /// (`conf=0.818` and `conf=0.811`, 240 ms apart) and no way to attribute the `auto-detect`
    /// decodes interleaved after them. This makes the next log answer it outright.
    let tag: String

    private static let counterLock = NSLock()
    private static var counter = 0

    init(allowed: [TranscriptionLanguage], primary: TranscriptionLanguage?) {
        self.allowedLanguages = allowed
        self.primaryLanguage = primary
        Self.counterLock.lock()
        Self.counter += 1
        tag = "R\(Self.counter)"
        Self.counterLock.unlock()
    }

    /// Core decision method.
    /// transcriptText may be empty (initial routing) — script hint is zero in that case.
    /// shortWindow: true when voiced audio was below targetDetectionSamples — requires wider margin for early lock.
    func decide(allProbs: [String: Float], transcriptText: String, shortWindow: Bool = false) -> RouteDecision? {
        // 1. Filter to allowed languages only
        var filtered: [(TranscriptionLanguage, Float)] = []
        for lang in allowedLanguages {
            if let prob = allProbs[lang.rawValue] {
                filtered.append((lang, prob))
            }
        }
        guard !filtered.isEmpty else { return nil }

        // 2. Renormalize
        let sum = filtered.reduce(Float(0)) { $0 + $1.1 }
        guard sum > 0 else { return nil }
        let normalized = filtered.map { ($0.0, $0.1 / sum) }

        // 3. Compute script hints (zero if no transcript)
        let scriptHints = ScriptAnalyzer.dominantScript(in: transcriptText, allowedLanguages: allowedLanguages)
        let hasScriptSignal = !scriptHints.isEmpty

        // 4. Compute composite scores
        var scores: [(TranscriptionLanguage, Float)] = []
        for (lang, normProb) in normalized {
            let scriptHint = scriptHints[lang] ?? 0
            let prior = computePrior(for: lang)

            let score: Float
            if hasScriptSignal {
                // Post-chunk: full formula
                score = RoutingThresholds.probWeight * normProb
                     + RoutingThresholds.scriptWeight * scriptHint
                     + RoutingThresholds.priorWeight * prior
            } else {
                // Initial routing: no script available
                score = RoutingThresholds.initialProbWeight * normProb
                     + RoutingThresholds.initialPriorWeight * prior
            }
            scores.append((lang, score))
        }

        // Sort by score descending
        scores.sort { $0.1 > $1.1 }
        guard let top = scores.first else { return nil }

        // 5. Apply state machine
        lastDetectionTime = Date()

        switch state {
        case .undecided:
            if top.1 >= RoutingThresholds.routeThreshold {
                // Short window fast-path gate: require wider margin over runner-up
                if shortWindow {
                    let runnerUp = scores.count > 1 ? scores[1].1 : 0
                    let margin = top.1 - runnerUp
                    if margin < RoutingThresholds.fastPathMargin {
                        Logger.debug("Fast-path rejected: margin \(String(format: "%.3f", margin)) < \(RoutingThresholds.fastPathMargin), buffering more audio", subsystem: .transcription)
                        return nil
                    }
                }
                state = .locked(top.0)
                saveLastSessionLanguage(top.0)
                Logger.info("[\(tag)] Language routed to \(top.0.displayName) (conf=\(String(format: "%.3f", top.1)))", subsystem: .transcription)
                return RouteDecision(lang: top.0, confidence: top.1, source: .detection)
            }
            // Confidence too low — stay undecided
            Logger.debug("[\(tag)] Detection undecided: top=\(top.0.displayName) (conf=\(String(format: "%.3f", top.1)) < \(RoutingThresholds.routeThreshold))", subsystem: .transcription)
            return nil

        case .locked(let currentLang):
            // Check if a different language beats current by switchMargin
            if top.0 != currentLang {
                let currentScore = scores.first(where: { $0.0 == currentLang })?.1 ?? 0
                if top.1 - currentScore >= RoutingThresholds.switchMargin {
                    state = .suspectedSwitch(candidate: top.0, checkCount: 1)
                    Logger.debug("Suspected switch to \(top.0.displayName) (margin=\(String(format: "%.3f", top.1 - currentScore)))", subsystem: .transcription)
                }
            }
            // Stay locked
            return RouteDecision(lang: currentLang, confidence: top.1, source: .sessionLock)

        case .suspectedSwitch(let candidate, let checkCount):
            if top.0 == candidate {
                if checkCount + 1 >= RoutingThresholds.switchConfirmations {
                    // Confirmed switch
                    state = .locked(candidate)
                    saveLastSessionLanguage(candidate)
                    Logger.info("Language switch confirmed to \(candidate.displayName) after \(checkCount + 1) checks", subsystem: .transcription)
                    return RouteDecision(lang: candidate, confidence: top.1, source: .detection)
                } else {
                    state = .suspectedSwitch(candidate: candidate, checkCount: checkCount + 1)
                    Logger.debug("Switch check \(checkCount + 1)/\(RoutingThresholds.switchConfirmations) for \(candidate.displayName)", subsystem: .transcription)
                    // Return current locked language while waiting for confirmation
                    if case .suspectedSwitch = state {
                        // Find the previous locked language from before suspectedSwitch
                        // We still transcribe with the old language during confirmation
                    }
                    return nil
                }
            } else {
                // Candidate not confirmed — revert to locked
                // Find what we were locked to before the suspected switch
                Logger.debug("Switch to \(candidate.displayName) not confirmed, reverting", subsystem: .transcription)
                state = .locked(top.0)
                return RouteDecision(lang: top.0, confidence: top.1, source: .sessionLock)
            }
        }
    }

    /// Lock the session to `lang` on the authority of something that saw more evidence than one
    /// probability distribution.
    ///
    /// `decide` scores a single detection from a single detector, which is why it needs 0.75 and
    /// why three sub-threshold windows used to leave a whole meeting unrouted.
    /// `LiveLanguageArbiter` fuses every detector in the process — including the large model,
    /// which the live path never asked — so when the two disagree the fused verdict is the one to
    /// honour. Returns the decision to route with, or nil when the lock already says this and
    /// there is nothing to do.
    func adopt(_ lang: TranscriptionLanguage, confidence: Float) -> RouteDecision? {
        if case .locked(let current) = state, current == lang { return nil }
        state = .locked(lang)
        lastDetectionTime = Date()
        saveLastSessionLanguage(lang)
        return RouteDecision(lang: lang, confidence: confidence, source: .detection)
    }

    /// Check if re-detection should be triggered.
    /// newUtteranceAfterSilence: explicit VAD signal that speech resumed after >= 3s silence.
    func shouldRedetect(scriptMismatches: Int, newUtteranceAfterSilence: Bool) -> Bool {
        // Must be locked to consider re-detection
        guard case .locked = state else { return false }

        // Check cooldown
        if let lastTime = lastDetectionTime,
           Date().timeIntervalSince(lastTime) < RoutingThresholds.redetectCooldown {
            return false
        }

        // Trigger conditions
        if scriptMismatches >= 3 {
            Logger.debug("Re-detection triggered: \(scriptMismatches) script mismatches", subsystem: .transcription)
            return true
        }
        if newUtteranceAfterSilence {
            Logger.debug("Re-detection triggered: new utterance after silence", subsystem: .transcription)
            return true
        }

        return false
    }

    func reset() {
        state = .undecided
        lastDetectionTime = nil
    }

    // MARK: - Private

    private func computePrior(for lang: TranscriptionLanguage) -> Float {
        var prior: Float = 0
        if lang == primaryLanguage {
            prior += RoutingThresholds.primaryLanguageBonus
        }
        if case .locked(let locked) = state, lang == locked {
            prior += RoutingThresholds.lockedLanguageBonus
        }
        if lang == lastSessionLanguage {
            prior += RoutingThresholds.lastSessionBonus
        }
        return min(prior, 1.0)
    }

    private func saveLastSessionLanguage(_ lang: TranscriptionLanguage) {
        UserDefaults.standard.set(lang.rawValue, forKey: "lastSessionLanguage")
    }
}
