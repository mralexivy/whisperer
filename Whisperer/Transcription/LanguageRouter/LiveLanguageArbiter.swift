//
//  LiveLanguageArbiter.swift
//  Whisperer
//
//  One language verdict for a live session, fused from every detector that is already resident.
//

import Foundation

/// Decides what language a live session is in, using all three detectors instead of whichever one
/// happened to be asked.
///
/// ### Why
/// During a meeting three detectors are running and the decision was made by one of them, alone.
/// On a real Hebrew recording they said, at the same moment:
///
/// | detector | cost | verdict |
/// |---|---|---|
/// | Nemotron, per 1120 ms chunk | free, already computed | `it-IT`, for forty minutes |
/// | tiny CPU probe (`ModelPool.detectLanguage`) | ~50 ms | `he` 0.66–0.90, but also `fr` 0.55 |
/// | Whisperer V3, the resident large bridge | one encoder pass | `he` 0.98–0.99, everywhere |
///
/// The live path consulted only the tiny model — which is why routing needed 0.75 and still came
/// back undecided — never cross-checked Nemotron against anything, and never asked V3, which was
/// loaded, warm and unambiguous. Every detector returns a full probability distribution, so none
/// of this evidence had to be invented; it was being discarded.
///
/// ### What this is not
/// It is not a new fusion algorithm. `MeetingLanguageTimelineBuilder.build` already does exactly
/// this job offline — Viterbi smoothing, switch cost, abstention margin, script veto, an
/// `NLLanguageRecognizer` text prior and a Nemotron tally prior — and it is pure. This class is the
/// evidence accumulator and the escalation policy around it; the verdict itself is that function's.
///
/// ### Escalation
/// V3 is the live decoder, so asking it costs one encoder pass against its `ctxLock`. It is
/// therefore asked only when the cheap evidence is genuinely unclear, at most once per
/// `minAccurateInterval` of audio, and never more than `maxAccurateProbes` times in a session.
/// The first escalation cannot happen before `minAccurateInterval` either, which is what keeps
/// ordinary short dictation entirely off this path.
/// `nonisolated` for the same reason as `LanguageRouter` — see the note on its declaration. This
/// class is `NSLock`-guarded arithmetic driven from the transcriber's background detection path,
/// so the project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` was never accurate for it, and
/// the *isolated deinit* it implies aborts when a synchronous XCTest method releases one.
nonisolated final class LiveLanguageArbiter: @unchecked Sendable {

    struct Config {
        /// Below this top probability the cheap probe is not trusted on its own. Same number and
        /// same rationale as `MeetingLanguageScanner.confirmBelowConfidence`.
        var confirmBelowConfidence: Float = 0.85
        /// Seconds of audio between two accurate confirmations, and before the first.
        var minAccurateInterval: Double = 30
        /// Seconds of audio before the *first* confirmation of a long-form session that is still
        /// unrouted. Being unrouted is itself expensive — every window decoded before the first
        /// verdict is decoded in the wrong language, or in none — so a meeting should not wait the
        /// full interval to ask the one detector that knows. Short dictation keeps the full
        /// interval and therefore never reaches this path at all.
        var firstAccurateInterval: Double = 10
        /// Hard ceiling per session, so a pathologically ambiguous recording cannot bleed latency
        /// for its whole length.
        var maxAccurateProbes: Int = 8
        /// Probes needed before an abstaining timeline is itself treated as a reason to escalate.
        var minProbesBeforeAbstentionCounts: Int = 3
        /// A probe whose mass lies mostly outside the routing shortlist is not evidence about the
        /// shortlist. `MeetingLanguageTimelineBuilder.normalize` filters then *renormalizes*, so a
        /// probe reading `ar 0.319 / fa 0.21 / ur 0.18 / … / en 0.05` — a detector with no opinion,
        /// and none of its opinion inside the shortlist — arrives at the fusion as `en 0.93`.
        /// On 2026-08-23 one such probe locked a forty-minute Hebrew meeting into English.
        var minRetainedMass: Float = 0.5
        /// Below this the accurate detector did not confirm anything, and recording it as an
        /// accurate probe would give a shrug the weight of a verdict. Observed: `top=ja p=0.261`.
        var minAccurateConfidence: Float = 0.5
        /// A verdict locks the session and pins Nemotron, so it may not rest on one probe. Viterbi
        /// over a single distribution degenerates to its argmax, which is strictly weaker than the
        /// `decide` threshold it replaced.
        var minProbesForVerdict: Int = 2
        /// Floor on the fused confidence. Below the router's 0.75 on purpose: `decide` scores one
        /// distribution from one detector, whereas a verdict at this point has at least two probes
        /// and often a V3 confirmation behind it.
        var minVerdictConfidence: Float = 0.70

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

    /// Why the arbiter wants an accurate confirmation — logged so the budget can be audited.
    enum EscalationReason: String {
        case lowConfidence = "low-confidence"
        case detectorDisagreement = "detector-disagreement"
        case abstained
        case challenger
    }

    private let config: Config
    private let lock = NSLock()

    private var _probes: [MeetingLanguageProbe] = []
    private var _tally: [String: Int] = [:]
    private var _accurateCount = 0
    private var _accurateSpend = 0
    private var _lastAccurateAt: Double = 0
    private var _verdict: Verdict?
    private var _allowed: Set<TranscriptionLanguage> = []
    private var _longForm = false

    init(config: Config = .default) {
        self.config = config
    }

    /// Tell the arbiter what session it is arbitrating, before any evidence arrives.
    ///
    /// - Parameters:
    ///   - allowedLanguages: the routing shortlist, used for the retained-mass guard. A shortlist
    ///     of one (or none) disables the guard, since there is nothing to renormalize away.
    ///   - longForm: true for a meeting. Only this unlocks the early first confirmation.
    func configure(allowedLanguages: [TranscriptionLanguage], longForm: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        _allowed = allowedLanguages.count > 1 ? Set(allowedLanguages).subtracting([.auto]) : []
        _longForm = longForm
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

    /// Accurate encoder passes actually run, confident or not. This is what the budget counts —
    /// an inconclusive pass costs exactly as much as a conclusive one.
    var accurateSpend: Int {
        lock.lock(); defer { lock.unlock() }
        return _accurateSpend
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
        _accurateSpend = 0
        _lastAccurateAt = 0
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

    /// One cheap (tiny CPU) detection. Dropped when the shortlist barely covers it.
    @discardableResult
    func recordCoarse(probabilities: [String: Float], start: Double, end: Double) -> Bool {
        append(MeetingLanguageProbe(start: start, end: end, probabilities: probabilities))
    }

    /// One accurate (Whisperer V3) detection. Consumes budget whether or not it confirms anything.
    ///
    /// No extra weighting for the accurate tier: emissions are log-probabilities, so a 0.98 probe
    /// already outweighs a 0.66 one by the right amount. Up-weighting it on top of that would be
    /// double-counting.
    @discardableResult
    func recordAccurate(probabilities: [String: Float], start: Double, end: Double) -> Bool {
        let top = probabilities.values.max() ?? 0
        lock.lock()
        _accurateSpend += 1
        _lastAccurateAt = end
        let floor = config.minAccurateConfidence
        lock.unlock()

        guard top >= floor else { return false }
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

    // MARK: - Escalation policy

    /// Whether Whisperer V3 should be asked to confirm, and why.
    ///
    /// - Parameters:
    ///   - coarse: the probe just taken, if this call follows one.
    ///   - nemotronCode: Nemotron's current guess, if it has one.
    ///   - currentLock: the language the router is already locked to, if any.
    ///   - audioSeconds: audio heard so far, which is also the budget clock.
    func escalationReason(
        coarse: [String: Float]?,
        nemotronCode: String?,
        currentLock: TranscriptionLanguage?,
        audioSeconds: Double
    ) -> EscalationReason? {
        lock.lock()
        let spend = _accurateSpend
        let lastAccurateAt = _lastAccurateAt
        let probeCount = _probes.count
        let verdict = _verdict
        let longForm = _longForm
        lock.unlock()

        guard spend < config.maxAccurateProbes else { return nil }
        // Gates the *first* confirmation as well, which is what keeps short dictation off this
        // path entirely — a 20 s recording never reaches the interval. A long-form session that is
        // still unrouted is the one exception: everything decoded until it routes is wasted, so
        // the first confirmation comes early.
        let interval = (longForm && spend == 0 && currentLock == nil)
            ? config.firstAccurateInterval
            : config.minAccurateInterval
        guard audioSeconds - lastAccurateAt >= interval else { return nil }

        let coarseTop = coarse?.max(by: { $0.value < $1.value })
        if let coarseTop, coarseTop.value < config.confirmBelowConfidence { return .lowConfidence }

        if let coarseTop, let nemotronCode,
           let nemotronLanguage = TranscriptionLanguage.from(languageTag: nemotronCode),
           let coarseLanguage = TranscriptionLanguage.from(languageTag: coarseTop.key),
           nemotronLanguage != coarseLanguage {
            return .detectorDisagreement
        }

        if verdict == nil, probeCount >= config.minProbesBeforeAbstentionCounts { return .abstained }

        // A settled verdict that disagrees with the lock the decoder is actually using is the one
        // case worth spending a pass on unprompted: everything decoded until it is resolved is
        // being written in the wrong language.
        if let currentLock, let verdict, verdict.language != currentLock { return .challenger }

        return nil
    }
}
