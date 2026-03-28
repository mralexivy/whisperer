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

final class LanguageRouter {
    let allowedLanguages: [TranscriptionLanguage]
    let primaryLanguage: TranscriptionLanguage?
    private(set) var state: RouterState = .undecided
    private var lastDetectionTime: Date?

    private var lastSessionLanguage: TranscriptionLanguage? {
        guard let raw = UserDefaults.standard.string(forKey: "lastSessionLanguage"),
              let lang = TranscriptionLanguage(rawValue: raw) else { return nil }
        return lang
    }

    init(allowed: [TranscriptionLanguage], primary: TranscriptionLanguage?) {
        self.allowedLanguages = allowed
        self.primaryLanguage = primary
    }

    /// Core decision method.
    /// transcriptText may be empty (initial routing) — script hint is zero in that case.
    func decide(allProbs: [String: Float], transcriptText: String) -> RouteDecision? {
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
        let scriptHints = ScriptAnalyzer.dominantScript(in: transcriptText)
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
                state = .locked(top.0)
                saveLastSessionLanguage(top.0)
                Logger.info("Language routed to \(top.0.displayName) (conf=\(String(format: "%.3f", top.1)))", subsystem: .transcription)
                return RouteDecision(lang: top.0, confidence: top.1, source: .detection)
            }
            // Confidence too low — stay undecided
            Logger.debug("Detection undecided: top=\(top.0.displayName) (conf=\(String(format: "%.3f", top.1)) < \(RoutingThresholds.routeThreshold))", subsystem: .transcription)
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
