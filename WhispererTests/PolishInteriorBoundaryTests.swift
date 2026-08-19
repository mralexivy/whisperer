//
//  PolishInteriorBoundaryTests.swift
//  WhispererTests
//
//  Scores `DeterministicPolisher.polish(chunks:)` — the entry point that actually ships — on real
//  chunk spans from `Tools/llm-eval/chunk-corpus.json`.
//
//  **What this measures that nothing else could.** `SentenceTerminator` has two rules. The
//  end-of-utterance rule puts a period on the last word; the interior rule puts one at a chunk
//  join where the speaker fell silent long enough. Verdict rule 5 has only ever scored the first,
//  because every benchmark reached the pipeline through `polish(text:)`, whose pause map is empty
//  by construction — so the interior rule fired zero times under measurement while firing on every
//  multi-chunk dictation in production. All 96 insertions rule 5 scored were end-of-utterance.
//
//  This is the other rule, and it is a genuinely better-posed measurement than the one it joins.
//  The end-of-utterance position turned out to be unscoreable on the references available: the
//  authored gold terminates 98% of utterances because its author was asked to punctuate, the
//  whole-file decode terminates 82% because whisper often just omits a final period, and on the
//  311 recordings both cover they disagree 56 times, 51 of them in the same direction (see
//  `Tools/llm-eval/calibrate_danglers.py`). An **interior** boundary has no such problem: it sits
//  in the middle of the text where both references have a real opinion, and the two agree there —
//  which is why rule 3b's boundary F1 has been a usable number all along.
//
//  Reported per script, never pooled: en supplies most of the corpus and pooling would let it set
//  a bar Hebrew and Russian are then assumed to clear.
//

import XCTest
@testable import whisperer

final class PolishInteriorBoundaryTests: XCTestCase {

    /// Events per script before a cell is a number rather than an anecdote. Matches the floor
    /// verdict rule 5 already applies; below it a cell reports `unmeasured`, never a point estimate.
    private static let floor = 30

    /// The whole measurement, so verdict rule 5i and this test score the same thing. Two copies of
    /// this arithmetic would be two chances to disagree about what an interior boundary is, which
    /// is the exact failure `BoundaryScorer` was extracted to prevent one level down.
    struct Measurement {
        fileprivate var cells: [String: Cell] = [:]
        var records = 0
        var singleChunk = 0
        /// Joins in total, and the subset carrying a gap at all. The second number is the finding:
        /// see `interiorClassOccurs`.
        var joins = 0
        var positiveGapJoins = 0
        /// Records where `polish(chunks:)` and `polish(text:)` produced different text. Expected to
        /// be zero while every gap is zero, and checked rather than assumed — a divergence would
        /// mean the two entry points disagree for some reason other than the pause map, which is
        /// the one thing every benchmark taken through `polish(text:)` has been assuming they do not.
        var chunkTextDivergences: [String] = []

        /// Whether the class this file exists to measure happens at all on the decoded path.
        ///
        /// `polish(chunks:)` records a pause only when `nextStart > chunk.end`
        /// (`DeterministicPolisher.swift:201`). The eager soft-commit path partitions the audio, so
        /// the next chunk starts exactly where the previous ended and the condition is never true.
        var interiorClassOccurs: Bool { positiveGapJoins > 0 }

        /// Cells that are scoreable — a cell below the floor is not evidence either way.
        fileprivate var scored: [(String, Cell)] {
            cells.filter { !$0.key.hasSuffix("· pauses") && $0.value.insertions.total >= floor }
                .sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }

        /// Cells below the bar. `PolishVerdictTests` maps this and `isUnmeasured` onto its own
        /// private `Status` rather than importing one, so the two files do not have to share a
        /// vocabulary to share a measurement.
        var failures: [(String, Double)] {
            scored.compactMap { key, cell in
                guard let precision = cell.insertions.precision, precision < 0.99 else { return nil }
                return (key, precision)
            }
        }

        /// True when nothing can be concluded — no corpus, or no cell reached the floor. Never
        /// collapsed into "pass": an unscored class is the thing this whole file exists to stop
        /// being mistaken for a working one.
        var isUnmeasured: Bool { records == 0 || scored.isEmpty }

        var summary: String {
            guard records > 0 else {
                return "no chunk corpus — run PolishChunkCorpusDumpTests. Until it exists the "
                     + "interior rule, which fires on every multi-chunk dictation, is unscored."
            }
            guard interiorClassOccurs else {
                return "the interior class does not occur on the decoded path: \(joins) chunk "
                     + "joins across \(records) recordings, 0 with any gap. The eager soft-commit "
                     + "stamps next.start == prev.end, and polish(chunks:) records a pause only "
                     + "when nextStart > chunk.end, so the pause map is empty in production too — "
                     + "not only in benches. polish(chunks:) and polish(text:) agreed on "
                     + "\(records - chunkTextDivergences.count)/\(records) recordings."
            }
            guard !scored.isEmpty else {
                return "\(records) recordings, \(positiveGapJoins)/\(joins) joins with a gap, but "
                     + "no cell reached n=\(floor) insertions."
            }
            let cells = scored.map { key, cell in
                "\(key) \(cell.insertions.precision.map { String(format: "%.4f", $0) } ?? "-") "
                + "(\(cell.insertions.truePositives)/\(cell.insertions.total))"
            }.joined(separator: "; ")
            let unmeasured = self.cells.keys.filter { !$0.hasSuffix("· pauses") }
                .filter { key in !scored.contains { $0.0 == key } }.sorted()
            return cells
                 + (unmeasured.isEmpty ? "" :
                    ". unmeasured (n < \(floor)): " + unmeasured.joined(separator: ", "))
        }

        func print() { PolishInteriorBoundaryTests.report(self) }
    }

    fileprivate struct Cell {
        var insertions = BoundaryScorer.EditCounts()
        var boundaries = BoundaryScorer.Counts()
        var recordings = 0
        var joins = 0
        var generativePasses = 0
        /// Pause lengths at joins the pass terminated, and at joins it declined. Reported as a
        /// distribution because any future argument about `minimumPause` (0.7s) or `confidentPause`
        /// (1.2s) has to be made from these two, and neither a mean nor a count can carry it.
        var acceptedPauses: [Double] = []
        var refusedPauses: [Double] = []
    }

    func testInteriorBoundaryPrecision() throws {
        let measurement = Self.measure()
        try XCTSkipIf(measurement.records == 0,
                      "no Tools/llm-eval/chunk-corpus.json — see PolishChunkCorpusDumpTests")
        measurement.print()

        // Fails only on a cell that is both measured and below the bar. An unmeasured cell is not
        // a pass — it is reported as unmeasured and the verdict treats it as blocking there.
        for (key, precision) in measurement.failures {
            XCTFail("\(key): interior period precision \(String(format: "%.4f", precision))")
        }

        // With no pauses the two entry points must agree. This is an invariant, not a measurement:
        // a divergence means `polish(chunks:)` differs from `polish(text:)` for some reason other
        // than pause evidence, which would retroactively invalidate every benchmark taken through
        // `polish(text:)`. Asserted even though the interior class is empty — especially then.
        XCTAssertEqual(measurement.chunkTextDivergences, [],
                       "polish(chunks:) diverged from polish(text:) with an empty pause map")
    }

    /// Score `polish(chunks:)` over the whole chunk corpus. Returns an empty measurement when the
    /// corpus is absent, so a caller reports `unmeasured` rather than failing.
    static func measure() -> Measurement {
        var measurement = Measurement()
        let records = ChunkCorpus.records()
        measurement.records = records.count
        guard !records.isEmpty else { return measurement }

        // `formatsLists: false` matches the dictation call site (`AppState.swift:2000`); this is
        // the strict-mode configuration users actually get.
        //
        // `terminatesUtteranceEnd: false` is the one deliberate departure, and it is what makes
        // this an interior measurement rather than a second copy of rule 5. Leaving it on would
        // fold the final period into every cell — and that period is the one edit neither
        // reference can judge, so it would import the same unscoreable disagreement into a class
        // that does not suffer from it. What ships still terminates the utterance end; this
        // measures the other rule in isolation, which is the only way to get a number for it.
        let polisher = DeterministicPolisher.forTranscript(dictionaryEntries: [],
                                                           formatsLists: false,
                                                           terminatesUtteranceEnd: false)

        // Keyed by script × reference. Both dimensions matter and collapsing either hides a
        // failure: a script can fail while the pooled figure passes, and a cell can pass against
        // the reference that shares the polisher's edit policy while failing the independent one.
        var cells: [String: Cell] = [:]

        for record in records {
            guard record.joins > 0 else { measurement.singleChunk += 1; continue }

            measurement.joins += record.joins
            measurement.positiveGapJoins += record.pauses.filter { $0 > 0 }.count

            let input = record.chunks.map(\.text).joined(separator: " ")
            let result = polisher.polish(chunks: record.polisherChunks)

            // The two entry points, on the same text. `polish(chunks:)` adds exactly one thing —
            // the pause map — so with no pauses it must reduce to `polish(text:)`. Every polish
            // benchmark before this corpus existed reached the pipeline through `polish(text:)`
            // and carried a caveat saying it therefore measured less than what ships. This is the
            // check that says whether that caveat was ever true.
            if polisher.polish(text: input).text != result.text {
                measurement.chunkTextDivergences.append(record.id)
            }

            var references: [(name: String, text: String)] = []
            if !record.goldenTranscript.isEmpty {
                references.append(("decode", record.goldenTranscript))
            }
            if let authored = Self.authoredGold[record.id] {
                references.append(("authored", authored))
            }

            for reference in references {
                // A reference in a different script from the input is not a reference for it —
                // the aligner would pair almost nothing and the counts would be noise.
                guard PolishBenchmarkTests.detectedLanguage(of: reference.text)
                        == PolishBenchmarkTests.detectedLanguage(of: input) else { continue }

                let key = "\(record.script) · \(reference.name)"
                var cell = cells[key] ?? Cell()
                cell.recordings += 1
                cell.joins += record.joins
                if result.needsGenerativePass { cell.generativePasses += 1 }
                cell.insertions = cell.insertions + BoundaryScorer.insertionCounts(
                    reference: reference.text, input: input, hypothesis: result.text)
                cell.boundaries = cell.boundaries + BoundaryScorer.counts(
                    reference: reference.text, hypothesis: result.text)
                cells[key] = cell
            }

            // Pause distribution is a property of the run, not of a reference, so it is recorded
            // once per record under the script alone.
            var cell = cells["\(record.script) · pauses"] ?? Cell()
            let terminated = Self.terminatedJoins(input: input, polished: result.text,
                                                  chunks: record.chunks)
            for (index, pause) in record.pauses.enumerated() {
                if terminated.contains(index) { cell.acceptedPauses.append(pause) }
                else { cell.refusedPauses.append(pause) }
            }
            cells["\(record.script) · pauses"] = cell
        }

        measurement.cells = cells
        return measurement
    }

    // MARK: - Helpers

    private static let authoredGold: [String: String] = {
        Dictionary(AuthoredGold.punctuationCases().map { ($0.id, $0.gold) },
                   uniquingKeysWith: { first, _ in first })
    }()

    /// Which join indices the polisher put a sentence end at.
    ///
    /// Found by position rather than by asking the polisher, because `Result` reports the edits it
    /// applied but not which join each belongs to, and matching an edit back to a join by text is
    /// the bug `polish(chunks:)`'s own doc comment warns about — two chunks reading "yeah" resolve
    /// to the same one. The join's position in the *input* is known exactly (it is the running
    /// word count of the chunks before it), so projecting the polished boundaries onto the input
    /// answers it without guessing.
    private static func terminatedJoins(input: String, polished: String,
                                        chunks: [ChunkCorpus.Span]) -> Set<Int> {
        let inputWords = BoundaryScorer.words(input)
        let polishedBoundaries = BoundaryScorer.projectedBoundaries(
            of: BoundaryScorer.words(polished), onto: inputWords)

        var terminated: Set<Int> = []
        var cursor = 0
        for (index, chunk) in chunks.enumerated().dropLast() {
            cursor += BoundaryScorer.words(chunk.text).count
            if polishedBoundaries.contains(cursor) { terminated.insert(index) }
        }
        return terminated
    }

    fileprivate static func report(_ measurement: Measurement) {
        let cells = measurement.cells
        print("\n=== interior boundaries — polish(chunks:) on real chunk spans ===")
        print("\(measurement.records) recordings, \(measurement.singleChunk) of them single-chunk "
              + "and so contributing no")
        print("joins. Precision is of the terminators the pass ADDED, by position, against each")
        print("reference separately. A cell below n=\(floor) is unmeasured, never a point estimate.")
        print("\(measurement.positiveGapJoins)/\(measurement.joins) joins carry a gap; "
              + "polish(chunks:) == polish(text:) on "
              + "\(measurement.records - measurement.chunkTextDivergences.count)/"
              + "\(measurement.records) recordings.")
        if !measurement.interiorClassOccurs {
            print("")
            print("THE INTERIOR CLASS DOES NOT OCCUR. Not a corpus shortfall — every join has")
            print("next.start == prev.end, because the eager soft-commit path partitions the audio")
            print("(StreamingTranscriber :1494/:1830) and polish(chunks:) records a pause only when")
            print("nextStart > chunk.end (DeterministicPolisher :201). The VAD chunker at :1035 is")
            print("the path whose spans are voiced-only, and usesEagerStream skips it (:860).")
            print("SentenceTerminator's interior rule and ParagraphSplitter are therefore inert for")
            print("dictation as shipped, and the cells below are empty for that reason.")
        }
        print("")
        print("script · reference    rec  joins  inserted  P        boundary F1  R       llm_rate")

        for (key, cell) in cells.sorted(by: { $0.key < $1.key }) where !key.hasSuffix("· pauses") {
            let measured = cell.insertions.total >= floor
            let precision = measured
                ? cell.insertions.precision.map { String(format: "%.4f", $0) } ?? "-"
                : "unmeas"
            print(String(format: "%-20@ %4d %6d %9d  %-7@  %-11@  %-6@  %.3f",
                         key as NSString, cell.recordings, cell.joins, cell.insertions.total,
                         precision as NSString,
                         (cell.boundaries.f1.map { String(format: "%.4f", $0) } ?? "-") as NSString,
                         (cell.boundaries.recall.map { String(format: "%.4f", $0) } ?? "-") as NSString,
                         cell.recordings > 0
                            ? Double(cell.generativePasses) / Double(cell.recordings) : 0))
        }

        print("\npause at joins the pass terminated vs declined (seconds)")
        print("minimumPause is 0.7 and confidentPause 1.2 — an accepted distribution that")
        print("starts below the floor would mean the pause is not what decided it.")
        print("script    n_accept  p10   p50   p90    n_refuse  p10   p50   p90")
        for (key, cell) in cells.sorted(by: { $0.key < $1.key }) where key.hasSuffix("· pauses") {
            let script = key.replacingOccurrences(of: " · pauses", with: "")
            let accepted = cell.acceptedPauses.sorted()
            let refused = cell.refusedPauses.sorted()
            print(String(format: "%-9@ %8d  %-5@ %-5@ %-6@ %8d  %-5@ %-5@ %-5@",
                         script as NSString,
                         accepted.count, pct(accepted, 0.1), pct(accepted, 0.5), pct(accepted, 0.9),
                         refused.count, pct(refused, 0.1), pct(refused, 0.5), pct(refused, 0.9)))
        }
        print("")
    }

    private static func pct(_ sorted: [Double], _ q: Double) -> NSString {
        guard !sorted.isEmpty else { return "-" }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * q).rounded())))
        return String(format: "%.2f", sorted[index]) as NSString
    }
}
