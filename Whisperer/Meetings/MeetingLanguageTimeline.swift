//
//  MeetingLanguageTimeline.swift
//  Whisperer
//
//  Which language is being spoken, when, across a whole meeting.
//
//  ### Why this exists
//  Whisper handed a *wrong* forced language code does not fail — it emits fluent text in the
//  language it was told, i.e. it translates. So a single bad language decision does not degrade
//  a transcript, it destroys it, and no downstream length or plausibility check can catch it.
//  The old rule (pin the whole meeting to whatever the first decoded window auto-detected) had
//  exactly one chance to be wrong, and every later window inherited the mistake.
//
//  This file replaces that with a decision fused over *many* windows spread across the meeting,
//  smoothed so that a single mis-detected window cannot move it, and expressed as a timeline of
//  spans rather than one verdict — because people code-switch, and a five-minute English stretch
//  inside a Hebrew meeting has to be decodable as English.
//
//  ### Split
//  Everything here is **pure**: it takes probe distributions plus text and returns a timeline.
//  No audio, no model, no clock — so the scoring and the smoothing are unit-testable without a
//  decoder. The I/O half (reading windows off disk and running the encoder-only detector) lives
//  in `MeetingLanguageScanner`.
//

import Foundation
import NaturalLanguage

// MARK: - Probe

/// One encoder-only language detection over a slice of meeting audio.
///
/// `probabilities` is exactly what `WhisperBridge.detectLanguage(samples:)` returns: whisper
/// language codes to probabilities over *all* languages, unfiltered and unnormalized by our
/// shortlist. Kept in that raw form so the fusion, not the caller, owns the filtering.
struct MeetingLanguageProbe: Equatable {
    /// Seconds from meeting start.
    let start: Double
    let end: Double
    let probabilities: [String: Float]

    var midpoint: Double { (start + end) / 2 }
}

// MARK: - Span

/// A contiguous stretch of the meeting decided to be one language.
///
/// `language == .auto` means the fusion **abstained** — the evidence was too close to call, so
/// the decoder should be left to its own per-window detection there. Abstaining is the correct
/// outcome when confidence is low: it degrades to today's behaviour instead of translating.
struct MeetingLanguageSpan: Equatable {
    var start: Double
    var end: Double
    var language: TranscriptionLanguage
    /// Posterior share of `language` over this span's probes, 0…1.
    var confidence: Float

    var duration: Double { max(0, end - start) }
    func contains(_ time: Double) -> Bool { time >= start && time < end }
}

// MARK: - Timeline

struct MeetingLanguageTimeline: Equatable {
    /// Ordered, contiguous, non-overlapping. Empty only when there was no usable evidence.
    var spans: [MeetingLanguageSpan]
    /// Language covering the most seconds, or `.auto` when every span abstained.
    var dominant: TranscriptionLanguage
    var dominantConfidence: Float
    /// How many detections went into this — asserted on by the efficiency tests.
    var probeCount: Int

    static let empty = MeetingLanguageTimeline(spans: [], dominant: .auto, dominantConfidence: 0, probeCount: 0)

    var isEmpty: Bool { spans.isEmpty }

    /// True when the meeting genuinely contains more than one decided language.
    var isMultilingual: Bool {
        Set(spans.map(\.language).filter { $0 != .auto }).count > 1
    }

    /// Language to force when decoding audio at `time`. `.auto` where the timeline abstained or
    /// has no coverage — callers pass that straight through to the decoder.
    func language(at time: Double) -> TranscriptionLanguage {
        spans.first { $0.contains(time) }?.language
            ?? spans.last.map { time >= $0.end ? $0.language : .auto }
            ?? .auto
    }

    /// One-line summary for the log, e.g. `he 0.97 [0–612 he, 612–780 en]`.
    var logDescription: String {
        let detail = spans
            .map { "\(Int($0.start))–\(Int($0.end)) \($0.language.rawValue) \(String(format: "%.2f", $0.confidence))" }
            .joined(separator: ", ")
        return "\(dominant.rawValue) \(String(format: "%.2f", dominantConfidence)) [\(detail)] over \(probeCount) probe(s)"
    }
}

// MARK: - Configuration

struct MeetingLanguageTimelineConfig {
    /// Log-likelihood price of changing language between two adjacent probes.
    ///
    /// This single number is what makes borrowing safe. A probe that is confidently wrong
    /// (p ≈ 0.9 against p ≈ 0.05) contributes a log-ratio near 2.9, so one such probe cannot pay
    /// the 2× `switchCost` round trip of flipping out and back — it takes two or more consecutive
    /// probes, i.e. sustained speech in the other language. Tuned against the real-history
    /// integration corpus; the false-switch metric there is the signal for changing it.
    var switchCost: Float = 3.0

    /// Minimum posterior lead the winner needs over the runner-up before a span is trusted.
    /// Below this the span abstains to `.auto` rather than risk a translated decode.
    var abstainMargin: Float = 0.25

    /// A decided span shorter than this is merged into a neighbour. Set to the dwell time a
    /// genuine code-switch has to survive; anything briefer is a borrowed word or a phrase.
    var minSpanDuration: Double = 15.0

    /// How far the two text-derived signals (script and `NLLanguageRecognizer`) can move the
    /// result relative to the audio evidence. Both are computed from text that may itself be
    /// corrupt — the very failure this file exists to fix — so they inform, they don't decide.
    var textPriorWeight: Float = 0.6

    /// Weight of the live Nemotron per-chunk tally. Free (already computed during the meeting)
    /// but from a model that had no language pinned, so it is the weakest signal here.
    var nemotronPriorWeight: Float = 0.4

    /// Posterior a *minority* language needs before it is allowed to own a span of its own.
    ///
    /// The dwell threshold and the switch cost both reason locally — they ask whether this run of
    /// probes is long enough and consistent enough. Neither asks the question the whole meeting can
    /// answer: is this language plausible *here at all*. On a 48-minute Hebrew meeting in the real
    /// history corpus the tiny detector produced a 73-second run of Polish at 0.48 — long enough to
    /// clear the dwell bar, consistent enough to clear the switch cost, and obviously wrong beside
    /// 45 minutes of Hebrew. A genuine code-switch does not look like that; a real English stretch
    /// inside a Hebrew meeting comes back at 0.9 and up.
    ///
    /// So a run in anything other than the meeting's leading language must be *confident*, not
    /// merely sustained. Below this it is re-labelled as the leader rather than abstained: the
    /// alternative, `.auto`, hands those windows back to per-window detection — which is the
    /// mechanism that produced the Polish in the first place.
    var minSwitchConfidence: Float = 0.6

    /// Languages carried through fusion. More candidates means more chances for a spurious
    /// switch, and beyond the top handful the tail is noise.
    var candidateLimit: Int = 6

    /// Probability floor, so one probe assigning a language exactly 0 cannot veto it outright
    /// through a `log(0)` of negative infinity.
    var probabilityFloor: Float = 1e-4

    /// A probe this certain about a language makes that language immune to the script veto. Set
    /// where only the accurate detector reaches it: Whisperer V3 returns 0.97–0.99 on clear speech,
    /// the tiny coarse probe wavers around 0.6 and is the signal the veto is meant to correct.
    var vetoImmunityConfidence: Float = 0.9

    static let `default` = MeetingLanguageTimelineConfig()
}

// MARK: - Builder

/// The pure half: probe distributions + transcript text in, timeline out.
enum MeetingLanguageTimelineBuilder {

    /// Fuse the evidence and smooth it into spans.
    ///
    /// - Parameters:
    ///   - probes: encoder-only detections, in time order. May be sparse.
    ///   - transcript: the meeting's text as it currently stands. Used only for the two text
    ///     signals, and treated as untrustworthy — it is the output of the broken path.
    ///   - nemotronTally: language code → chunk count from the live pass, or empty.
    ///   - allowedLanguages: the routing shortlist. Empty or single-element means no filtering.
    ///   - duration: meeting length, so the last span can be extended to the end.
    static func build(
        probes: [MeetingLanguageProbe],
        transcript: String = "",
        nemotronTally: [String: Int] = [:],
        allowedLanguages: [TranscriptionLanguage] = [],
        duration: Double? = nil,
        config: MeetingLanguageTimelineConfig = .default
    ) -> MeetingLanguageTimeline {
        let ordered = probes.sorted { $0.start < $1.start }
        guard !ordered.isEmpty else { return .empty }

        let allowed = allowedLanguages.count > 1 ? Set(allowedLanguages).subtracting([.auto]) : []
        let mapped = ordered.map { normalize($0.probabilities, allowed: allowed) }

        var candidates = topCandidates(in: mapped, limit: config.candidateLimit)
        candidates = applyScriptVeto(candidates, transcript: transcript,
                                     distributions: mapped, config: config)
        guard !candidates.isEmpty else { return .empty }
        guard candidates.count > 1 else {
            // Unanimous: one candidate survived, so there is nothing to smooth or compare.
            let only = candidates[0]
            let end = duration ?? ordered.last!.end
            let span = MeetingLanguageSpan(start: 0, end: max(end, ordered.last!.end),
                                           language: only,
                                           confidence: meanShare(of: only, in: mapped, over: 0..<mapped.count))
            return MeetingLanguageTimeline(spans: [span], dominant: only,
                                           dominantConfidence: span.confidence, probeCount: ordered.count)
        }

        let prior = combinedPrior(transcript: transcript, nemotronTally: nemotronTally,
                                  candidates: candidates, config: config)
        let emissions = mapped.map { emission(from: $0, candidates: candidates, config: config) }
        let path = viterbi(emissions: emissions, prior: prior, switchCost: config.switchCost)

        var spans = spans(from: path, probes: ordered, candidates: candidates, distributions: mapped,
                          leader: leadingLanguage(in: mapped, candidates: candidates,
                                                  margin: config.abstainMargin),
                          duration: duration, config: config)
        spans = absorbShortSpans(spans, minimum: config.minSpanDuration)
        spans = mergeAdjacent(spans)

        let (dominant, dominantConfidence) = dominantLanguage(in: spans)
        return MeetingLanguageTimeline(spans: spans, dominant: dominant,
                                       dominantConfidence: dominantConfidence, probeCount: ordered.count)
    }

    // MARK: - Normalization

    /// Whisper codes to languages, shortlist applied, renormalized to sum to 1.
    ///
    /// Renormalizing *after* filtering matters: with a two-language shortlist, a window where
    /// whisper spread 0.4/0.35 over the two allowed languages and 0.25 over forty others should
    /// read as 0.53/0.47, not as two weak signals.
    static func normalize(_ raw: [String: Float], allowed: Set<TranscriptionLanguage>) -> [TranscriptionLanguage: Float] {
        var kept: [TranscriptionLanguage: Float] = [:]
        for (code, probability) in raw {
            guard probability > 0, let language = TranscriptionLanguage(rawValue: code), language != .auto else { continue }
            if !allowed.isEmpty && !allowed.contains(language) { continue }
            kept[language, default: 0] += probability
        }
        let total = kept.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return kept.mapValues { $0 / total }
    }

    /// The languages worth carrying, ranked by **summed** probability across every probe.
    ///
    /// Summed, never per-probe argmax: argmax throws away confidence, and one 0.98 probe should
    /// outweigh four 0.3 probes rather than losing 1-vote-to-4.
    static func topCandidates(in distributions: [[TranscriptionLanguage: Float]], limit: Int) -> [TranscriptionLanguage] {
        var totals: [TranscriptionLanguage: Float] = [:]
        for distribution in distributions {
            for (language, probability) in distribution { totals[language, default: 0] += probability }
        }
        return totals
            .sorted { ($0.value, $0.key.rawValue) > ($1.value, $1.key.rawValue) }
            .prefix(limit)
            .map(\.key)
    }

    // MARK: - Script veto

    /// Drop candidates whose script does not appear in the transcript at all.
    ///
    /// A hard veto rather than a weight, because script is near-perfect at the distinctions that
    /// matter most here — Hebrew, Cyrillic and CJK against Latin are exactly the pairs where a
    /// wrong pin produces a full translation. It cannot separate Latin-script languages from each
    /// other, and it does not try; that is `NLLanguageRecognizer`'s job below.
    ///
    /// Deliberately permissive when the text is mixed: a transcript already corrupted into two
    /// scripts contains both families, so nothing is vetoed and the audio decides. The veto only
    /// fires against a candidate with *no* presence in the text at all.
    ///
    /// **A candidate the audio is near-certain about is immune.** The veto's input is the
    /// transcript, which is the output of the path being judged, so it cannot be allowed to
    /// confirm itself. On 2026-08-23 a live session locked English at 46 s on one noisy probe; the
    /// eager decoder then wrote all-Latin text, which vetoed Hebrew out of the candidate set
    /// entirely — so four subsequent V3 probes at he 0.97–0.99 could not win, and with a single
    /// candidate left `build` took the unanimous branch and re-affirmed the lock that had written
    /// the text. Immunity is keyed on peak confidence rather than on rank because rank alone would
    /// also protect a 0.6/0.4 coin flip, which is precisely the case the veto exists for: the
    /// coarse detector wavers around 0.6 on Hebrew and Hebrew script in the text settles it. Only
    /// the accurate detector reaches `vetoImmunityConfidence`, and when it does, it is not a
    /// hypothesis the script hint gets to overrule.
    static func applyScriptVeto(
        _ candidates: [TranscriptionLanguage],
        transcript: String,
        distributions: [[TranscriptionLanguage: Float]] = [],
        config: MeetingLanguageTimelineConfig = .default
    ) -> [TranscriptionLanguage] {
        guard !candidates.isEmpty, transcript.contains(where: { $0.isLetter }) else { return candidates }
        let permitted = ScriptAnalyzer.dominantScript(in: transcript, allowedLanguages: candidates)
        guard !permitted.isEmpty else { return candidates }

        var immune: Set<TranscriptionLanguage> = []
        for distribution in distributions {
            for (language, probability) in distribution where probability >= config.vetoImmunityConfidence {
                immune.insert(language)
            }
        }
        let survivors = candidates.filter { permitted[$0] != nil || immune.contains($0) }
        return survivors.isEmpty ? candidates : survivors
    }

    // MARK: - Priors

    /// Text and Nemotron evidence folded into one distribution over the candidates.
    /// Uniform when neither signal has an opinion.
    static func combinedPrior(
        transcript: String,
        nemotronTally: [String: Int],
        candidates: [TranscriptionLanguage],
        config: MeetingLanguageTimelineConfig
    ) -> [Float] {
        let uniform = 1 / Float(candidates.count)
        let text = textHypotheses(for: transcript, candidates: candidates)
        let nemotron = nemotronDistribution(tally: nemotronTally, candidates: candidates)

        return candidates.enumerated().map { index, _ in
            var score = uniform
            if let text { score += config.textPriorWeight * (text[index] - uniform) }
            if let nemotron { score += config.nemotronPriorWeight * (nemotron[index] - uniform) }
            return max(score, config.probabilityFloor)
        }
    }

    /// Apple's offline text language ID, restricted to the candidates. Independent of the audio
    /// detector and much stronger on same-script pairs (en/nl/de) where the audio detector is
    /// weakest. Returns nil when the recognizer has nothing to say.
    static func textHypotheses(for transcript: String, candidates: [TranscriptionLanguage]) -> [Float]? {
        let sample = String(transcript.prefix(4000))
        guard sample.contains(where: { $0.isLetter }) else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 10)
        guard !hypotheses.isEmpty else { return nil }

        var scores = [Float](repeating: 0, count: candidates.count)
        for (language, confidence) in hypotheses {
            // NLLanguage codes are BCP-47 (`zh-Hans`), whisper's are ISO 639-1 (`zh`).
            let base = language.rawValue.split(separator: "-").first.map(String.init) ?? language.rawValue
            guard let mapped = TranscriptionLanguage(rawValue: base),
                  let index = candidates.firstIndex(of: mapped) else { continue }
            scores[index] += Float(confidence)
        }
        let total = scores.reduce(0, +)
        guard total > 0 else { return nil }
        return scores.map { $0 / total }
    }

    static func nemotronDistribution(tally: [String: Int], candidates: [TranscriptionLanguage]) -> [Float]? {
        var scores = [Float](repeating: 0, count: candidates.count)
        for (code, count) in tally where count > 0 {
            // Nemotron's tally keys are BCP-47 (`"it-IT"`, `"he-IL"`), so `init(rawValue:)`
            // rejected every one of them and this prior contributed nothing at all.
            guard let language = TranscriptionLanguage.from(languageTag: code),
                  let index = candidates.firstIndex(of: language) else { continue }
            scores[index] += Float(count)
        }
        let total = scores.reduce(0, +)
        guard total > 0 else { return nil }
        return scores.map { $0 / total }
    }

    // MARK: - Emission

    /// Per-probe log-probabilities over the candidate set, renormalized to the candidates.
    static func emission(
        from distribution: [TranscriptionLanguage: Float],
        candidates: [TranscriptionLanguage],
        config: MeetingLanguageTimelineConfig
    ) -> [Float] {
        let raw = candidates.map { max(distribution[$0] ?? 0, config.probabilityFloor) }
        let total = raw.reduce(0, +)
        return raw.map { log($0 / total) }
    }

    // MARK: - Viterbi

    /// Maximum-likelihood language path over the probe sequence, with a flat `switchCost` charged
    /// on every change. Self-transitions are free, so the path stays put unless the emissions pay
    /// for a move — which is the whole mechanism for ignoring borrowed words.
    ///
    /// The prior is spread across the probes (`weight / n`) rather than applied once per probe:
    /// applied per probe it would be counted n times and a long meeting would let a text signal
    /// overpower all of the audio.
    static func viterbi(emissions: [[Float]], prior: [Float], switchCost: Float) -> [Int] {
        guard let first = emissions.first, !first.isEmpty else { return [] }
        let states = first.count
        let priorPerProbe = prior.map { log(max($0, 1e-7)) / Float(emissions.count) }

        var scores = (0..<states).map { emissions[0][$0] + priorPerProbe[$0] }
        var backpointers: [[Int]] = []
        backpointers.reserveCapacity(emissions.count)

        for step in 1..<emissions.count {
            var next = [Float](repeating: -.greatestFiniteMagnitude, count: states)
            var previous = [Int](repeating: 0, count: states)
            for state in 0..<states {
                var best = -Float.greatestFiniteMagnitude
                var bestPrevious = 0
                for candidate in 0..<states {
                    let score = scores[candidate] + (candidate == state ? 0 : -switchCost)
                    if score > best { best = score; bestPrevious = candidate }
                }
                next[state] = best + emissions[step][state] + priorPerProbe[state]
                previous[state] = bestPrevious
            }
            scores = next
            backpointers.append(previous)
        }

        var path = [Int](repeating: 0, count: emissions.count)
        path[emissions.count - 1] = scores.enumerated().max { $0.element < $1.element }?.offset ?? 0
        for step in stride(from: emissions.count - 1, to: 0, by: -1) {
            path[step - 1] = backpointers[step - 1][path[step]]
        }
        return path
    }

    // MARK: - Spans

    private static func spans(
        from path: [Int],
        probes: [MeetingLanguageProbe],
        candidates: [TranscriptionLanguage],
        distributions: [[TranscriptionLanguage: Float]],
        leader: TranscriptionLanguage?,
        duration: Double?,
        config: MeetingLanguageTimelineConfig
    ) -> [MeetingLanguageSpan] {
        guard !path.isEmpty else { return [] }

        var result: [MeetingLanguageSpan] = []
        var runStart = 0
        for index in 1...path.count {
            if index < path.count && path[index] == path[runStart] { continue }
            let range = runStart..<index
            var language = candidates[path[runStart]]
            // Whole-meeting veto on a weakly-held minority run. See `minSwitchConfidence`.
            if let leader, language != leader,
               meanShare(of: language, in: distributions, over: range) < config.minSwitchConfidence {
                language = leader
            }
            // Span edges sit midway between the last probe of one run and the first of the next:
            // the probes are samples, so the true boundary is somewhere in the gap and the middle
            // is the lowest-error guess available without extra decoding.
            let start = runStart == 0 ? 0 : (probes[runStart - 1].end + probes[runStart].start) / 2
            let end = index == path.count
                ? max(duration ?? probes[index - 1].end, probes[index - 1].end)
                : (probes[index - 1].end + probes[index].start) / 2
            let demoted = language != candidates[path[runStart]]
            let share = meanShare(of: language, in: distributions, over: range)
            let runnerUp = bestRival(of: language, in: distributions, over: range, candidates: candidates)
            // A demoted run is decided by the meeting, not by its own probes, so the local margin
            // does not apply to it — it will usually be *below* the margin, that being why the
            // detector wandered there. Abstaining would return exactly those windows to the
            // per-window detection that wandered.
            let decided = demoted || (share - runnerUp) >= config.abstainMargin
            result.append(MeetingLanguageSpan(start: start, end: end,
                                              language: decided ? language : .auto,
                                              confidence: share))
            runStart = index
        }
        return result
    }

    /// Mean posterior of `language` over a run of probes — the span's confidence, and half of the
    /// abstention test.
    static func meanShare(
        of language: TranscriptionLanguage,
        in distributions: [[TranscriptionLanguage: Float]],
        over range: Range<Int>
    ) -> Float {
        guard !range.isEmpty else { return 0 }
        let total = range.reduce(Float(0)) { $0 + (distributions[$1][language] ?? 0) }
        return total / Float(range.count)
    }

    /// The language with the highest mean posterior across *every* probe — the meeting's own
    /// opinion of itself, before any smoothing. Used only as the reference for
    /// `minSwitchConfidence`; the Viterbi path, not this, decides the spans.
    ///
    /// nil when the meeting does not clearly lead by `margin`. A meeting that cannot decide what
    /// language it is in has no authority to overrule a span, and letting it try would convert an
    /// honest abstention into a coin-flip pin — the one outcome this design treats as worse than
    /// no decision at all.
    static func leadingLanguage(
        in distributions: [[TranscriptionLanguage: Float]],
        candidates: [TranscriptionLanguage],
        margin: Float
    ) -> TranscriptionLanguage? {
        let range = 0..<distributions.count
        guard !range.isEmpty else { return nil }
        // Ties break on the code so the result never depends on candidate ordering.
        var best: TranscriptionLanguage?
        var bestShare: Float = -1
        for candidate in candidates {
            let share = meanShare(of: candidate, in: distributions, over: range)
            if share > bestShare || (share == bestShare && candidate.rawValue < (best?.rawValue ?? "")) {
                best = candidate
                bestShare = share
            }
        }
        guard let best else { return nil }
        let rival = bestRival(of: best, in: distributions, over: range, candidates: candidates)
        return (bestShare - rival) >= margin ? best : nil
    }

    private static func bestRival(
        of language: TranscriptionLanguage,
        in distributions: [[TranscriptionLanguage: Float]],
        over range: Range<Int>,
        candidates: [TranscriptionLanguage]
    ) -> Float {
        candidates
            .filter { $0 != language }
            .map { meanShare(of: $0, in: distributions, over: range) }
            .max() ?? 0
    }

    /// Merge any span below the dwell threshold into whichever neighbour is longer.
    ///
    /// This is the second half of the borrowing defence, and it is the one with a time unit:
    /// `switchCost` limits how *easily* the path moves, this limits how *briefly* it may stay.
    /// Runs to a fixed point, since merging can leave a new short span behind.
    static func absorbShortSpans(_ spans: [MeetingLanguageSpan], minimum: Double) -> [MeetingLanguageSpan] {
        guard spans.count > 1 else { return spans }
        var working = spans

        while working.count > 1, let index = working.firstIndex(where: { $0.duration < minimum }) {
            let previous = index > 0 ? working[index - 1] : nil
            let next = index + 1 < working.count ? working[index + 1] : nil
            let absorbInto: Int
            switch (previous, next) {
            case (nil, _): absorbInto = index + 1
            case (_, nil): absorbInto = index - 1
            case let (p?, n?): absorbInto = p.duration >= n.duration ? index - 1 : index + 1
            }
            let victim = working.remove(at: index)
            let target = absorbInto > index ? index : index - 1
            working[target].start = min(working[target].start, victim.start)
            working[target].end = max(working[target].end, victim.end)
        }
        return working
    }

    static func mergeAdjacent(_ spans: [MeetingLanguageSpan]) -> [MeetingLanguageSpan] {
        var result: [MeetingLanguageSpan] = []
        for span in spans {
            if var last = result.last, last.language == span.language {
                last.end = span.end
                last.confidence = max(last.confidence, span.confidence)
                result[result.count - 1] = last
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// Language covering the most seconds. Abstained spans never win — the point of abstaining is
    /// to have no opinion, and letting `.auto` become the meeting's answer would hide the fact
    /// that some spans *were* decided.
    static func dominantLanguage(in spans: [MeetingLanguageSpan]) -> (TranscriptionLanguage, Float) {
        var coverage: [TranscriptionLanguage: Double] = [:]
        var weighted: [TranscriptionLanguage: Double] = [:]
        for span in spans where span.language != .auto {
            coverage[span.language, default: 0] += span.duration
            weighted[span.language, default: 0] += span.duration * Double(span.confidence)
        }
        guard let winner = coverage.max(by: { ($0.value, $0.key.rawValue) < ($1.value, $1.key.rawValue) }),
              winner.value > 0 else {
            return (.auto, 0)
        }
        return (winner.key, Float((weighted[winner.key] ?? 0) / winner.value))
    }
}
