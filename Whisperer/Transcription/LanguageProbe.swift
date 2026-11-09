//
//  LanguageProbe.swift
//  Whisperer
//
//  Spoken-language identification for the built-in engine (Apple dictation), which cannot
//  detect language and must be told one locale per analyzer. It only picks the language; Apple
//  produces the live text.
//
//  Runs on the user's main engine, whichever is loaded — no model of its own:
//  - Qwen3-ASR: the logits of each candidate's name token after `language` (one prefill,
//    ~125 ms on the GPU).
//  - Whisper V3 (whisper.cpp): `WhisperBridge.detectLanguage` (one encode, ~670 ms).
//  Scores are restricted to the user's languages and silence-calibrated: the engine's scores on
//  1 s of silence, times `calibration`, are subtracted, which cancels its prior.
//
//  Measured 2026-11-04 on the user's own 9 dictations (en/he/ru) with the session rule:
//  Qwen3 (calibration 1.0) 9/9, no confident wrong window; whisper V3 9/9 at calibration 0.5
//  (fully calibrated it pulled accented English to ru). Small acoustic LID models scored worse
//  on accented English: SpeechBrain ECAPA 6/9, NVIDIA AmberNet 7/9.
//

import Foundation

/// Decides when a running live-text session has drifted into the wrong language, from periodic
/// re-probes of its most recent audio.
///
/// The start-of-session probe answers from the first 2–3 s and was final: a meeting that opened
/// on English words ("OK, this is Sasha and Keren") streamed Apple dictation in English for 53
/// minutes of Hebrew, and a Russian meeting likewise (2026-11-08). Re-probing fixes that, but one
/// English phrase inside a Hebrew meeting must not flip it, so a switch needs consecutive
/// confident answers for the same other language. Unsure answers count for nothing either way.
nonisolated struct LanguageReprobeTracker: Equatable {
    static let confidentProbability: Float = 0.85
    static let agreeingProbes = 2

    private(set) var challenger: TranscriptionLanguage?
    private(set) var run = 0

    mutating func reset() {
        challenger = nil
        run = 0
    }

    /// One re-probe's answer. Returns the language to switch to, or nil to stay.
    mutating func observe(language: TranscriptionLanguage, probability: Float,
                          current: TranscriptionLanguage?) -> TranscriptionLanguage? {
        guard probability >= Self.confidentProbability else { return nil }
        guard language != current else {
            reset()
            return nil
        }
        if challenger == language { run += 1 } else { challenger = language; run = 1 }
        guard run >= Self.agreeingProbes else { return nil }
        reset()
        return language
    }
}

/// Finds where a new spoken turn begins, from per-buffer levels: speech after a pause.
///
/// A meeting changes language at a turn — someone else answers, or the same person switches as
/// they start a new thought. Probing a turn's first seconds catches a switch in ~4 s; a timer
/// alone caught it 29 s late (2026-11-09) and probing on a short timer would keep the GPU busy.
/// Levels only, no model: the floor follows the quiet buffers, speech is well above it.
nonisolated struct SpeechTurnDetector: Equatable {
    /// A pause at least this long ends a turn.
    static let pauseSeconds = 0.6
    /// Speech a new turn needs before it is probed. V3 is reliable from about this much.
    static let probeAfterSeconds = 3.0
    static let minimumThreshold: Float = 0.0015

    /// Recent buffer levels; the quietest of them is the floor. A running average seeded from
    /// the first buffer learned the floor from speech, so its threshold sat above the speech
    /// itself and pauses between phrases were never seen.
    private var recentLevels: [Float] = []
    static let floorWindow = 64
    var noiseFloor: Float? { recentLevels.min() }
    private var quietSeconds = 0.0
    private var armed = false
    private var turnSpeechSeconds = 0.0

    /// One buffer. True when a new turn has just gathered `probeAfterSeconds` of speech.
    mutating func observe(rms: Float, seconds: Double) -> Bool {
        recentLevels.append(rms)
        if recentLevels.count > Self.floorWindow { recentLevels.removeFirst() }
        let threshold = max(Self.minimumThreshold, (noiseFloor ?? rms) * 4)
        if rms < threshold {
            quietSeconds += seconds
            // A pause opens a turn; pauses inside a turn that is still gathering speech do not
            // restart it — people pause between phrases, and restarting on each one kept a turn
            // from ever reaching 3 s (a he → en switch caught 13 s late in replay).
            if quietSeconds >= Self.pauseSeconds, !armed {
                armed = true
                turnSpeechSeconds = 0
            }
            return false
        }
        quietSeconds = 0
        guard armed else { return false }
        turnSpeechSeconds += seconds
        guard turnSpeechSeconds >= Self.probeAfterSeconds else { return false }
        armed = false
        return true
    }
}

/// Identity for the Apple source, which has no bridge object of its own.
nonisolated final class AppleLanguageIDToken: Sendable {
    static let shared = AppleLanguageIDToken()
}

actor LanguageProbe {

    /// The engine the probe runs on, resolved per call: the main engine can load, unload or be
    /// switched between sessions.
    enum Source: Sendable {
        case qwen3(Qwen3ASRBridge)
        case whisper(WhisperBridge)
        /// Apple's dictation models, one pass per candidate locale (`AppleLanguageID`).
        case apple

        var name: String {
            switch self {
            case .qwen3: return "Qwen3"
            case .whisper: return "V3"
            case .apple: return "Apple"
            }
        }

        /// Silence-calibration strength chosen per engine (see the header).
        var calibration: Float {
            switch self {
            case .qwen3: return 1.0
            case .whisper: return 0.5
            case .apple: return 0
            }
        }

        /// Shortest window this engine's answer can be trusted on. Qwen3 on 1.0–1.5 s flips
        /// between he and ru at p 1.00 depending on where the window starts (the user's 3.1 s
        /// Russian: he 1.00 from 0.28 s, ru 1.00 from 0.06 s); from 2.0 s all 18 windows of the
        /// user's 9 dictations were right at 1.00. Whisper V3 was stable from 1.0 s.
        var earliestSeconds: Double {
            switch self {
            case .qwen3: return 2.0
            case .whisper: return 1.0
            // Apple's word confidences need a few words; at 1 s there are often none.
            case .apple: return 2.0
            }
        }

        nonisolated var identity: ObjectIdentifier {
            switch self {
            case .qwen3(let bridge): return ObjectIdentifier(bridge)
            case .whisper(let bridge): return ObjectIdentifier(bridge)
            case .apple: return ObjectIdentifier(AppleLanguageIDToken.shared)
            }
        }
    }

    private let resolve: @MainActor @Sendable () -> Source?
    /// Log-scores on 1 s of silence, per language code, for the engine they were measured on.
    private var silence: [String: Float] = [:]
    private var calibratedFor: ObjectIdentifier?

    init(resolve: @escaping @MainActor @Sendable () -> Source?) {
        self.resolve = resolve
    }

    /// The engine a probe would run on now, nil when no main engine is loaded.
    func currentSourceName() async -> String? {
        await resolve()?.name
    }

    /// The first checkpoint a session should probe at, for the engine loaded now.
    func earliestSeconds() async -> Double? {
        await resolve()?.earliestSeconds
    }

    /// Measure the silence calibration for `languages` ahead of the first session.
    func prepare(for languages: [TranscriptionLanguage]) async {
        let codes = languages.filter { $0 != .auto }.map(\.rawValue)
        guard codes.count > 1, let source = await resolve() else { return }
        if case .apple = source { return }
        _ = await calibrate(source, codes: codes)
        // MLX compiles per input length: the first 2 s probe of a session cost 835–1029 ms cold
        // against ~150 ms warm. Run each checkpoint length once here instead.
        if case .qwen3 = source {
            for seconds in [source.earliestSeconds, SystemLivePreviewBridge.lateProbeSeconds] {
                _ = await Self.logScores(source, samples: [Float](repeating: 0, count: Int(seconds * 16_000)), codes: codes)
            }
        }
    }

    /// The most likely of `allowed` for `samples` (16 kHz mono), with probabilities renormalized
    /// over `allowed`. Nil when fewer than two languages are allowed or no main engine is loaded.
    func identify(
        samples: [Float],
        allowed: [TranscriptionLanguage]
    ) async -> (language: TranscriptionLanguage, probability: Float, probabilities: [TranscriptionLanguage: Float])? {
        let candidates = allowed.filter { $0 != .auto }
        guard candidates.count > 1, !samples.isEmpty, let source = await resolve() else { return nil }
        let codes = candidates.map(\.rawValue)
        if case .apple = source {
            let started = ContinuousClock.now
            let confidences = await AppleLanguageID.confidences(samples: samples, languages: candidates)
            ComputeLedger.add(.languageID, seconds: started.duration(to: .now).seconds)
            let all = AppleLanguageID.probabilities(from: confidences)
            guard let best = all.max(by: { $0.value < $1.value }) else { return nil }
            return (best.key, best.value, all)
        }
        guard await calibrate(source, codes: codes),
              let scores = await Self.logScores(source, samples: samples, codes: codes) else { return nil }

        let lambda = source.calibration
        let values = codes.map { (scores[$0] ?? -100) - lambda * (silence[$0] ?? 0) }
        let peak = values.max() ?? 0
        let exps = values.map { expf($0 - peak) }
        let sum = exps.reduce(0, +)
        guard sum > 0, let best = exps.indices.max(by: { exps[$0] < exps[$1] }) else { return nil }
        var all: [TranscriptionLanguage: Float] = [:]
        for (index, language) in candidates.enumerated() { all[language] = exps[index] / sum }
        return (candidates[best], exps[best] / sum, all)
    }

    /// Silence scores for `codes` on `source`, measured once per engine instance.
    private func calibrate(_ source: Source, codes: [String]) async -> Bool {
        if calibratedFor == source.identity, codes.allSatisfy({ silence[$0] != nil }) { return true }
        guard let scores = await Self.logScores(source, samples: [Float](repeating: 0, count: 16_000), codes: codes) else {
            return false
        }
        if calibratedFor != source.identity { silence = [:] }
        silence.merge(scores) { _, new in new }
        calibratedFor = source.identity
        return true
    }

    /// Per-code log-scores: Qwen3 name-token logits, or log of whisper's language probabilities.
    private static func logScores(_ source: Source, samples: [Float], codes: [String]) async -> [String: Float]? {
        switch source {
        case .qwen3(let bridge):
            let available = codes.filter { Qwen3ASREngine.forcedLanguageTokens[$0] != nil }
            guard available.count == codes.count else { return nil }
            let started = ContinuousClock.now
            defer { ComputeLedger.add(.languageID, seconds: started.duration(to: .now).seconds) }
            return await bridge.languageLogits(samples: samples, codes: codes)
        case .whisper(let bridge):
            guard let probabilities = await Task.detached(priority: .userInitiated, operation: {
                bridge.detectLanguage(samples: samples, minProbability: 0)
            }).value else { return nil }
            var result: [String: Float] = [:]
            for code in codes { result[code] = logf(max(probabilities[code] ?? 0, 1e-9)) }
            return result
        case .apple:
            return nil   // `identify` handles Apple itself; it has no log-scores to calibrate
        }
    }
}
