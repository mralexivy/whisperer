//
//  PolishAuthoredGoldBoundaryTests.swift
//  WhispererTests
//
//  Verdict rule 3b — sentence-boundary F1 — measured against the **authored** gold rather than
//  against `goldenTranscript`.
//
//  `PolishBenchmarkTests` already reports 3b, and stays the primary source for it: its reference
//  is a same-model whole-file decode of the same audio, so model error is held constant across
//  the two arms. What it cannot do is report Hebrew or Russian above the n=20 floor — real he/ru
//  are a handful of rows in a 400-recording corpus that is overwhelmingly English.
//
//  `Tools/llm-eval/authoring/gold-corpus-punctuation.json` is the corpus that can: 217 en, 55 he,
//  47 ru, every case carrying at least one terminator, gated on script identity and content-word
//  similarity but deliberately *not* on headroom — a gold whose only difference from its input is
//  punctuation is the ideal boundary reference rather than a defective one.
//
//  Two things this measurement is not:
//
//  - **Not human truth.** The gold is LLM-authored from the raw transcripts and reviewed by an
//    independent model, not by a person. It detects damage between arms scored against one
//    reference. No absolute claim may be made from a figure computed on it.
//  - **Not paired outside English.** Arm A's side is `ZAIENHANCEDTEXT`, what the shipped 4B
//    actually returned, and it exists only for the ids in `corpus.json`. That intersection is
//    78 en / 1 he / 1 ru. So the A-vs-B comparison is English-only here, and the he/ru columns
//    report arm B and the raw input alone — which still answers the question that matters for
//    default-on: does the deterministic arm segment non-English speech at all, or does it leave a
//    run-on. The raw-input column is what makes that readable: it is the floor the arm has to
//    beat, since whisper.cpp already emits some punctuation of its own.
//

import XCTest
@testable import whisperer

final class PolishAuthoredGoldBoundaryTests: XCTestCase {

    private struct GoldCorpus: Decodable {
        struct Case: Decodable {
            let id: String
            let language: String
            let input: String
            let gold: String
        }
        let cases: [Case]
    }

    private struct ArmACorpus: Decodable {
        struct Case: Decodable {
            struct Outputs: Decodable {
                struct Arm: Decodable { let text: String }
                let armA: Arm?

                private enum CodingKeys: String, CodingKey { case armA = "A_shipped_correct" }
            }
            let id: String
            let outputs: Outputs
        }
        let cases: [Case]
    }

    /// `#filePath` rather than the bundle: `Tools/` is not a test resource and is never copied in.
    private var evalDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()         // .../WhispererTests
            .deletingLastPathComponent()         // repo root
            .appendingPathComponent("Tools/llm-eval")
    }

    /// The reporting floor from `assemble_gold.py`. Below it a language is `unmeasured`, never a
    /// point estimate — the same rule the Python side applies, restated rather than imported
    /// because there is no shared constant across the two languages.
    private let minimumN = 20

    func testBoundaryF1AgainstAuthoredGold() throws {
        let goldURL = evalDirectory.appendingPathComponent(
            "authoring/gold-corpus-punctuation.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: goldURL.path),
                          "gold-corpus-punctuation.json not present — run assemble_gold.py")

        let corpus = try JSONDecoder().decode(GoldCorpus.self, from: Data(contentsOf: goldURL))
        XCTAssertFalse(corpus.cases.isEmpty, "punctuation gold parsed to zero cases")

        let armA = try loadArmA()
        // Shipping dictation's configuration, not the initialiser's defaults — see the note in
        // `PolishVerdictTests`. The bare initialiser turns list reflow and paragraph splitting on;
        // `AppState.swift:2000` turns the first off and the second follows an off-by-default flag.
        let polisher = DeterministicPolisher.forTranscript(dictionaryEntries: [],
                                                           formatsLists: false,
                                                           splitsParagraphs: false)

        // Accumulated per language, then divided once — micro-averaging, for the same reason
        // `PolishBenchmarkTests` does it: a per-row F1 over the two sentences in a 20-second
        // utterance takes the values 0, 0.5 and 1, and the mean of that is noise.
        var totals: [String: (b: PolishBenchmarkTests.BoundaryCounts,
                              raw: PolishBenchmarkTests.BoundaryCounts,
                              n: Int)] = [:]
        var paired: [String: (a: PolishBenchmarkTests.BoundaryCounts,
                              b: PolishBenchmarkTests.BoundaryCounts,
                              n: Int)] = [:]

        for entry in corpus.cases {
            let polished = polisher.polish(text: entry.input).text
            let armB = PolishBenchmarkTests.boundaryCounts(reference: entry.gold,
                                                           hypothesis: polished)
            let raw = PolishBenchmarkTests.boundaryCounts(reference: entry.gold,
                                                          hypothesis: entry.input)
            let running = totals[entry.language] ?? (.init(), .init(), 0)
            totals[entry.language] = (running.b + armB, running.raw + raw, running.n + 1)

            guard let shipped = armA[entry.id] else { continue }
            let counts = PolishBenchmarkTests.boundaryCounts(reference: entry.gold,
                                                             hypothesis: shipped)
            let pair = paired[entry.language] ?? (.init(), .init(), 0)
            paired[entry.language] = (pair.a + counts, pair.b + armB, pair.n + 1)
        }

        report(totals: totals, paired: paired, total: corpus.cases.count, armACount: armA.count)

        // The one assertion. Every figure above is reported rather than asserted — the verdict is
        // the user's, on the numbers — but an arm that emitted no terminator at all in some
        // language is not a number to weigh, it is the regression this column was added to catch.
        for (language, group) in totals where group.n >= minimumN {
            XCTAssertGreaterThan(group.b.hypothesis, 0,
                                 "arm B produced zero sentence boundaries across \(group.n) "
                                  + "\(language) cases — the output is one run-on")
        }
    }

    /// Arm A's shipped output, keyed by id. Empty when `corpus.json` is absent, which downgrades
    /// the paired table to nothing rather than failing: the unpaired columns still stand.
    private func loadArmA() throws -> [String: String] {
        let url = evalDirectory.appendingPathComponent("corpus.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let corpus = try JSONDecoder().decode(ArmACorpus.self, from: Data(contentsOf: url))
        return corpus.cases.reduce(into: [:]) { table, entry in
            table[entry.id] = entry.outputs.armA?.text
        }
    }

    private func report(totals: [String: (b: PolishBenchmarkTests.BoundaryCounts,
                                          raw: PolishBenchmarkTests.BoundaryCounts,
                                          n: Int)],
                        paired: [String: (a: PolishBenchmarkTests.BoundaryCounts,
                                          b: PolishBenchmarkTests.BoundaryCounts,
                                          n: Int)],
                        total: Int,
                        armACount: Int) {
        print("""

        ── Boundary F1 vs authored gold ──────────────────────────────────────────
        corpus: \(total) authored pairs; \(armACount) ids carry a shipped arm-A output
        reference: LLM-authored gold, independently reviewed. Detects damage between arms
        scored against one reference. NOT human truth — no absolute claim from these figures.
        `unmeasured` below means n < \(minimumN), not a score of zero.

        unpaired — every case, arm B against the raw input it started from
        lang  n     rawF1      bF1B       B ref/hyp/matched   B P/R
        """)
        for language in ["en", "he", "ru"] {
            guard let group = totals[language] else { continue }
            let label = group.n >= minimumN ? "" : "   ← unmeasured (n<\(minimumN))"
            let counts = "\(group.b.reference)/\(group.b.hypothesis)/\(group.b.matched)"
            print(Self.pad(language, 5) + Self.pad("\(group.n)", 6)
                  + Self.pad(Self.formatted(group.raw.f1), 11)
                  + Self.pad(Self.formatted(group.b.f1), 11)
                  + Self.pad(counts, 20)
                  + "\(Self.formatted(group.b.precision))/\(Self.formatted(group.b.recall))"
                  + label)
        }

        print("""

        paired — only the ids with a shipped arm-A output (rule 3b: F1_B ≥ F1_A − 0.05)
        lang  n     bF1A       bF1B       delta      A P/R                 B P/R
        """)
        for language in ["en", "he", "ru"] {
            guard let group = paired[language] else { continue }
            let delta: String
            if let a = group.a.f1, let b = group.b.f1 {
                delta = String(format: "%+.4f", b - a)
            } else {
                delta = "—"
            }
            let label = group.n >= minimumN ? "" : "   ← unmeasured (n<\(minimumN))"
            print(Self.pad(language, 5) + Self.pad("\(group.n)", 6)
                  + Self.pad(Self.formatted(group.a.f1), 11)
                  + Self.pad(Self.formatted(group.b.f1), 11)
                  + Self.pad(delta, 11)
                  + Self.pad("\(Self.formatted(group.a.precision))"
                             + "/\(Self.formatted(group.a.recall))", 22)
                  + "\(Self.formatted(group.b.precision))/\(Self.formatted(group.b.recall))"
                  + label)
        }
        print("──────────────────────────────────────────────────────────────────────────\n")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text + String(repeating: " ", count: max(1, width - text.count))
    }

    private static func formatted(_ value: Double?) -> String {
        value.map { String(format: "%.4f", $0) } ?? "unmeasured"
    }
}
