//
//  LiveLanguageArbiter.swift
//  Whisperer
//
//  One language verdict for a live session, fused from every detector that is already resident.
//

import Foundation

/// Decides what language a live session is in, fusing Whisperer V3 probes and Nemotron's
/// per-chunk guesses via `MeetingLanguageTimelineBuilder`.
///
/// ### What this is not
/// Not a new fusion algorithm. `MeetingLanguageTimelineBuilder.build` already does exactly
/// this job offline — Viterbi smoothing, switch cost, abstention margin, script veto, an
/// `NLLanguageRecognizer` text prior and a Nemotron tally prior — and it is pure. This class is
/// the evidence accumulator; the verdict itself is that function's output.
///
/// ### Probe cadence
/// V3 is the live decoder, so asking it costs one encoder pass against its `ctxLock`. Cadence is
/// certainty-driven: probe every 15 s until locked, every 30 s below 0.99 confidence, every 60 s
/// thereafter. Below 10 s of voiced audio no probe fires. That gives ~75 probes in a 60-minute
/// meeting — 54 s of GPU, about 1.5 % of wall clock.
///
/// `nonisolated` for the same reason as `LanguageRouter` — see the note on its declaration. This
/// class is `NSLock`-guarded arithmetic driven from the transcriber's background detection path,
/// so the project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` was never accurate for it, and
/// the *isolated deinit* it implies aborts when a synchronous XCTest method releases one.
nonisolated final class LiveLanguageArbiter: @unchecked Sendable {

    struct Config {
        /// A probe whose mass lies mostly outside the routing shortlist is not evidence about the
        /// shortlist. `MeetingLanguageTimelineBuilder.normalize` filters then *renormalizes*, so a
        /// probe reading `ar 0.319 / fa 0.21 / ur 0.18 / … / en 0.05` — a detector with no opinion,
        /// and none of its opinion inside the shortlist — arrives at the fusion as `en 0.93`.
        /// On 2026-08-23 one such probe locked a forty-minute Hebrew meeting into English.
        var minRetainedMass: Float = 0.5
        /// Below this V3 did not confirm anything; recording it would give a shrug the weight
        /// of a verdict. Observed: `top=ja p=0.261`.
        var minAccurateConfidence: Float = 0.5
        /// One V3 probe over ≥10 s of voiced audio at ≥0.85 confidence is sufficient evidence —
        /// Viterbi over a single strong distribution is unambiguous. The old value of 2 was set
        /// when probes came from the tiny model, where one guess meant little.
        var minProbesForVerdict: Int = 1
        /// V3 at 30 s reaches 0.98–0.99 on measured data. Setting the floor to 0.85 keeps
        /// a near-certain verdict from being blocked by the old 0.70 threshold (set for tiny-grade
        /// evidence), while still rejecting the `en 0.443` shrug at the tail of a Hebrew meeting.
        var minVerdictConfidence: Float = 0.85

        static let `default` = Config()
    }

    /// The fused answer, or nil while the evidence is still inconclusive.
    struct Verdict: Equatable {
        let language: TranscriptionLanguage
        let confidence: Float
        let probeCount: Int
        /// True when at least one Whisperer V3 confirmation went into it.
        let usedAccurate: Bool
    }

    private let config: Config
    private let lock = NSLock()

    private var _probes: [MeetingLanguageProbe] = []
    private var _tally: [String: Int] = [:]
    private var _accurateCount = 0
    private var _verdict: Verdict?
    private var _allowed: Set<TranscriptionLanguage> = []

    init(config: Config = .default) {
        self.config = config
    }

    /// Tell the arbiter what session it is arbitrating, before any evidence arrives.
    ///
    /// - Parameters:
    ///   - allowedLanguages: the routing shortlist, used for the retained-mass guard. A shortlist
    ///     of one (or none) disables the guard, since there is nothing to renormalize away.
    func configure(allowedLanguages: [TranscriptionLanguage]) {
        lock.lock(); defer { lock.unlock() }
        _allowed = allowedLanguages.count > 1 ? Set(allowedLanguages).subtracting([.auto]) : []
    }

    // MARK: - Accumulated evidence

    var probes: [MeetingLanguageProbe] {
        lock.lock(); defer { lock.unlock() }
        return _probes
    }

    /// Nemotron's per-chunk guesses, in the BCP-47 form it reports them. Handed to the offline
    /// refine pass so it starts from what the live pass learned instead of re-probing from zero.
    var nemotronTally: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return _tally
    }

    var verdict: Verdict? {
        lock.lock(); defer { lock.unlock() }
        return _verdict
    }

    /// Accurate probes whose answer was confident enough to become evidence.
    var accurateProbeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _accurateCount
    }

    /// How many probes have been recorded, without copying them out — this is read once per VAD
    /// scan purely for a log field.
    var probeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _probes.count
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        _probes = []
        _tally = [:]
        _accurateCount = 0
        _verdict = nil
    }

    // MARK: - Recording evidence

    /// One free observation from Nemotron. `code` may be BCP-47 (`"he-IL"`); it is stored verbatim
    /// because that is the form `MeetingLanguageTimelineBuilder` now normalizes.
    func recordNemotron(code: String?) {
        guard let code, !code.isEmpty, code != "auto" else { return }
        lock.lock(); defer { lock.unlock() }
        _tally[code, default: 0] += 1
    }

    /// One Whisperer V3 detection. Consumes a probe slot whether or not it confirms anything.
    ///
    /// No extra weighting for the accurate tier: emissions are log-probabilities, so a 0.98 probe
    /// already outweighs a 0.66 one by the right amount. Up-weighting it on top of that would be
    /// double-counting.
    @discardableResult
    func recordAccurate(probabilities: [String: Float], start: Double, end: Double) -> Bool {
        let top = probabilities.values.max() ?? 0
        guard top >= config.minAccurateConfidence else { return false }
        guard append(MeetingLanguageProbe(start: start, end: end, probabilities: probabilities)) else {
            return false
        }
        lock.lock(); _accurateCount += 1; lock.unlock()
        return true
    }

    /// - Returns: whether the probe was kept as evidence.
    @discardableResult
    private func append(_ probe: MeetingLanguageProbe) -> Bool {
        guard !probe.probabilities.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard retainedMass(of: probe.probabilities) >= config.minRetainedMass else { return false }
        _probes.append(probe)
        return true
    }

    /// The share of a raw distribution's mass that falls inside the shortlist. Caller holds `lock`.
    ///
    /// The denominator is the mass the detector actually reported, not 1: `detectLanguage` may
    /// return a truncated distribution, and normalising against a total it never emitted would
    /// understate every probe equally.
    private func retainedMass(of probabilities: [String: Float]) -> Float {
        guard !_allowed.isEmpty else { return 1 }
        var total: Float = 0
        var inside: Float = 0
        for (code, probability) in probabilities where probability > 0 {
            total += probability
            if let language = TranscriptionLanguage.from(languageTag: code), _allowed.contains(language) {
                inside += probability
            }
        }
        guard total > 0 else { return 0 }
        return inside / total
    }

    // MARK: - Verdict

    /// Fuse everything recorded so far. Returns nil while the evidence abstains.
    ///
    /// - Parameters:
    ///   - transcript: the text so far, used only for the two text priors and treated as
    ///     untrustworthy — it is the output of the path being corrected.
    ///   - allowedLanguages: the routing shortlist.
    ///   - duration: audio heard so far.
    @discardableResult
    func fuse(transcript: String, allowedLanguages: [TranscriptionLanguage], duration: Double) -> Verdict? {
        lock.lock()
        let probes = _probes
        let tally = _tally
        let usedAccurate = _accurateCount > 0
        lock.unlock()

        guard probes.count >= config.minProbesForVerdict else { return nil }
        let timeline = MeetingLanguageTimelineBuilder.build(
            probes: probes,
            transcript: transcript,
            nemotronTally: tally,
            allowedLanguages: allowedLanguages,
            duration: duration
        )
        // The timeline's *dominant* language, not its per-span answer: a live session is being
        // decoded now, from one end, so there is no span structure to honour yet.
        guard timeline.dominant != .auto,
              timeline.dominantConfidence >= config.minVerdictConfidence else {
            lock.lock(); _verdict = nil; lock.unlock()
            return nil
        }
        let verdict = Verdict(language: timeline.dominant,
                              confidence: timeline.dominantConfidence,
                              probeCount: timeline.probeCount,
                              usedAccurate: usedAccurate)
        lock.lock(); _verdict = verdict; lock.unlock()
        return verdict
    }

    /// The best guess available right now, with no thresholds applied at all.
    ///
    /// Not a verdict and deliberately not treated as one: it locks nothing, pins nothing, and is
    /// recomputed from scratch every time it is read. Its only job is to be a better argument to
    /// the decoder than `.auto`.
    ///
    /// Whisper's per-window auto-detect re-rolls the language on *every* pass — on the 2026-08-23
    /// Hebrew recording consecutive passes came back `it`, `ru`, `he`, `fr` — and whatever each one
    /// picked was decoded, displayed, and committed. A stable provisional guess drawn from all
    /// probes so far is strictly better: it is wrong less often, it is wrong *consistently* (so
    /// LocalAgreement can still converge), and it is replaced the moment a verdict lands.
    var leadingCandidate: (language: TranscriptionLanguage, confidence: Float)? {
        lock.lock()
        let probes = _probes
        let allowed = _allowed
        lock.unlock()

        guard !probes.isEmpty else { return nil }
        var totals: [TranscriptionLanguage: Float] = [:]
        for probe in probes {
            for (language, share) in MeetingLanguageTimelineBuilder.normalize(probe.probabilities, allowed: allowed) {
                totals[language, default: 0] += share
            }
        }
        let mass = totals.values.reduce(0, +)
        guard mass > 0, let best = totals.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, best.value / mass)
    }

}
