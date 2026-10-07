//
//  EngineComparisonHarness.swift
//  WhispererTests
//
//  Scoring utilities for comparing ASR engines against each other when no human ground
//  truth exists.
//
//  ### Why not score against `GoldenSet`
//  `GoldenSet` is a full-file decode by whisper.cpp `.largeTurboQ5`. Its own documentation is
//  explicit that it is not ground truth: "where the model mishears a word it will mishear it
//  here too, identically". That property is exactly right for measuring what *windowing* costs a
//  single engine, and exactly wrong for comparing two engines — whisper.cpp scores ~0 against it
//  by construction, so any rival engine can only look worse. Using it to pick a default would be
//  a rigged comparison.
//
//  ### What this does instead
//  Medoid consensus. Every engine decodes the same audio; the hypothesis with the lowest mean
//  word error rate to all the others is taken as that clip's reference, and each engine is scored
//  against it. An engine that is consistently the outlier is the one disagreeing with everybody
//  else. This cannot prove an engine is *correct* — three engines can share a mistake — but it
//  does identify which engine is the odd one out, and it is symmetric, which the `GoldenSet`
//  comparison is not.
//
//  Pair that with `disagreements`, which dumps the clips where the engines diverge most, so the
//  numbers can be adjudicated by reading rather than trusted blindly.
//

import Foundation

// MARK: - Hypothesis

/// One engine's decode of one clip.
struct EngineHypothesis {
    let engine: String
    let text: String
    /// Wall-clock seconds the decode took.
    let elapsed: TimeInterval
    /// Language the engine reported, when it detects one.
    let detectedLanguage: String?
}

// MARK: - Per-clip comparison

struct ClipComparison {
    let fixtureID: String
    let durationSec: Double
    /// Language recorded in the app's history for this clip.
    let language: String
    let hypotheses: [EngineHypothesis]
    /// Engine whose text is the medoid — the per-clip reference.
    let referenceEngine: String
    /// Engine name → word error rate against the medoid.
    let errorRates: [String: Double]

    /// Highest WER on this clip. High values mean the engines genuinely disagree, so the clip is
    /// worth reading rather than averaging.
    var spread: Double { errorRates.values.max() ?? 0 }
}

// MARK: - Harness

enum EngineComparisonHarness {

    /// Scores one clip by medoid consensus. Returns nil when fewer than two engines produced text:
    /// a single hypothesis is its own medoid and contributes nothing but a spurious 0.0.
    static func compare(
        fixtureID: String,
        durationSec: Double,
        language: String,
        hypotheses: [EngineHypothesis]
    ) -> ClipComparison? {
        let usable = hypotheses.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard usable.count >= 2 else { return nil }

        // Mean WER from each candidate to every other. The minimum is the medoid.
        var meanToOthers: [String: Double] = [:]
        for candidate in usable {
            let others = usable.filter { $0.engine != candidate.engine }
            guard !others.isEmpty else { continue }
            let total = others.reduce(0.0) {
                $0 + wordErrorRate($1.text, reference: candidate.text)
            }
            meanToOthers[candidate.engine] = total / Double(others.count)
        }
        guard let reference = meanToOthers.min(by: { $0.value < $1.value })?.key,
              let referenceText = usable.first(where: { $0.engine == reference })?.text else {
            return nil
        }

        var errorRates: [String: Double] = [:]
        for hypothesis in usable {
            errorRates[hypothesis.engine] = hypothesis.engine == reference
                ? 0.0
                : wordErrorRate(hypothesis.text, reference: referenceText)
        }

        return ClipComparison(
            fixtureID: fixtureID,
            durationSec: durationSec,
            language: language,
            hypotheses: usable,
            referenceEngine: reference,
            errorRates: errorRates
        )
    }

    // MARK: - Aggregation

    struct EngineScore {
        let engine: String
        /// Clips this engine produced text for.
        let clips: Int
        /// Mean WER against the per-clip medoid. Lower is more central, not provably more correct.
        let meanErrorRate: Double
        /// How often this engine *was* the medoid. A high share means the others agree with it.
        let medoidShare: Double
        /// Clips where the engine returned nothing but at least one other engine did.
        let emptyDecodes: Int
        /// Mean realtime factor: audio seconds decoded per wall-clock second. Higher is faster.
        let realtimeFactor: Double
    }

    /// Per-engine scores over a set of clips. `engines` is passed explicitly so an engine that
    /// returned empty text on every clip still appears in the table as a failure rather than
    /// vanishing from the report.
    static func score(_ comparisons: [ClipComparison], engines: [String]) -> [EngineScore] {
        engines.map { engine in
            let present = comparisons.filter { $0.errorRates[engine] != nil }
            let rates = present.compactMap { $0.errorRates[engine] }
            let medoidCount = comparisons.filter { $0.referenceEngine == engine }.count
            let empty = comparisons.filter { comparison in
                comparison.errorRates[engine] == nil
            }.count
            let audio = present.reduce(0.0) { $0 + $1.durationSec }
            let wall = present.reduce(0.0) { accumulated, comparison in
                accumulated + (comparison.hypotheses.first { $0.engine == engine }?.elapsed ?? 0)
            }
            return EngineScore(
                engine: engine,
                clips: present.count,
                meanErrorRate: rates.isEmpty ? .nan : rates.reduce(0, +) / Double(rates.count),
                medoidShare: comparisons.isEmpty ? 0 : Double(medoidCount) / Double(comparisons.count),
                emptyDecodes: empty,
                realtimeFactor: wall > 0 ? audio / wall : .nan
            )
        }
    }

    /// Groups comparisons by the language recorded in history. A per-language table is the only
    /// useful shape: an engine can lead overall and still lose badly on one language, which is
    /// precisely the case the specialist-model table exists to catch.
    static func byLanguage(_ comparisons: [ClipComparison]) -> [String: [ClipComparison]] {
        Dictionary(grouping: comparisons, by: \.language)
    }

    /// The clips the engines disagree about most, worst first. Read these; do not average them.
    static func disagreements(_ comparisons: [ClipComparison], limit: Int = 15) -> [ClipComparison] {
        comparisons.sorted { $0.spread > $1.spread }.prefix(limit).map { $0 }
    }

    // MARK: - Reporting

    /// Fixed-width table, printed to the test log. Deliberately plain text: these numbers get
    /// pasted into `docs/knowledge/transcription/knowledge.md` as the baseline for later runs.
    static func report(title: String, comparisons: [ClipComparison], engines: [String]) -> String {
        func pad(_ s: String, _ width: Int) -> String {
            s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
        }
        func lead(_ s: String, _ width: Int) -> String {
            s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
        }
        func num(_ value: Double, _ places: Int) -> String {
            value.isNaN ? "—" : String(format: "%.\(places)f", value)
        }

        var out = "\n=== \(title) ===\n"
        out += "clips=\(comparisons.count)\n"
        out += pad("engine", 16) + lead("clips", 7) + lead("meanWER", 10)
            + lead("medoid%", 9) + lead("empty", 7) + lead("RTF", 8) + "\n"
        let sorted = score(comparisons, engines: engines).sorted { lhs, rhs in
            let l = lhs.meanErrorRate.isNaN ? Double.infinity : lhs.meanErrorRate
            let r = rhs.meanErrorRate.isNaN ? Double.infinity : rhs.meanErrorRate
            return l < r
        }
        for s in sorted {
            out += pad(s.engine, 16)
                + lead("\(s.clips)", 7)
                + lead(num(s.meanErrorRate, 3), 10)
                + lead(num(s.medoidShare * 100, 1), 9)
                + lead("\(s.emptyDecodes)", 7)
                + lead(num(s.realtimeFactor, 1), 8) + "\n"
        }
        return out
    }

    /// Writes the full comparison, including every hypothesis, to a JSON file beside the other
    /// eval corpora. Adjudicating a disagreement means reading the competing texts side by side;
    /// a WER table cannot tell you which one is right.
    @discardableResult
    static func writeDump(_ comparisons: [ClipComparison], named name: String) -> URL? {
        let directory = AuthoredGold.evalDirectory.appendingPathComponent("asr-engine-comparison")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)

        let payload: [String: Any] = [
            "generated": ISO8601DateFormatter().string(from: Date()),
            "note": "Medoid-consensus comparison, NOT human ground truth. "
                + "referenceEngine is the clip's medoid; errorRates are against it.",
            "clips": comparisons.map { comparison in
                [
                    "id": comparison.fixtureID,
                    "durationSec": comparison.durationSec,
                    "language": comparison.language,
                    "referenceEngine": comparison.referenceEngine,
                    "errorRates": comparison.errorRates,
                    "hypotheses": comparison.hypotheses.map {
                        [
                            "engine": $0.engine,
                            "text": $0.text,
                            "elapsed": $0.elapsed,
                            "detectedLanguage": $0.detectedLanguage ?? "",
                        ]
                    },
                ]
            },
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        try? data.write(to: url)
        return url
    }
}
