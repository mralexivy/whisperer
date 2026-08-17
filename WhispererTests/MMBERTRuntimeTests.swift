//
//  MMBERTRuntimeTests.swift
//  WhispererTests
//
//  Proves `MMBERTCoreMLRuntime` reproduces the training-time pipeline, and measures what it
//  costs.
//
//  The runtime reimplements in Swift three things Python does at training time: word→sub-word
//  tokenisation, first-sub-word alignment, and padding to a fixed shape. All three fail
//  *plausibly* rather than loudly — a one-position alignment shift returns the previous word's
//  punctuation, which reads as a mediocre model and not as a bug, and would be found only after
//  the numbers had already been quoted. So the check is numeric and end to end: Python ran the
//  exported `.mlpackage` and recorded per-word head logits; Swift starts from the raw word
//  strings and must arrive at the same numbers.
//
//  Skipped when the artifacts are absent — they are 142 MB per shape and are not committed.
//

import CoreML
import XCTest
@testable import whisperer

final class MMBERTRuntimeTests: XCTestCase {

    /// Python's own read of the same `.mlpackage`, from `Tools/mmbert/build_swift_reference.py`.
    private struct Reference: Decodable {
        struct Word: Decodable {
            let word: String
            let ids: [Int]
            let logits: [String: [Float]]
        }
        struct Case: Decodable {
            let words: [String]
            let shape: Int
            let subwordCount: Int
            let words_out: [Word]
        }
        let bos: Int
        let eos: Int
        let pad: Int
        let cases: [Case]
    }

    private func makeRuntime(
        _ units: MLComputeUnits = .cpuAndGPU) throws -> MMBERTCoreMLRuntime {
        guard let runtime = MMBERTCoreMLRuntime.makeIfAvailable(computeUnits: units) else {
            throw XCTSkip("mmBERT artifacts absent — run Tools/mmbert/export_coreml.py")
        }
        return runtime
    }

    private func loadReference() throws -> Reference {
        guard let url = Bundle(for: Self.self)
            .url(forResource: "mmbert-runtime-reference", withExtension: "json")
            ?? Self.developmentFixture("mmbert-runtime-reference.json") else {
            throw XCTSkip("mmbert-runtime-reference.json absent — run build_swift_reference.py")
        }
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    private static func developmentFixture(_ name: String) -> URL? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("TestData")
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Which backend, and what it costs numerically

    /// Reports the worst logit delta against Python for each compute unit, and asserts only that
    /// *some* backend reproduces the reference.
    ///
    /// This exists because the first parity run failed on the ANE by up to ~3 logits — far beyond
    /// any rounding story — while `hello world` matched to ~0.03. A three-logit error is a
    /// different prediction, not a noisy one, and the thresholds in `thresholds.json` sit at
    /// 0.983–0.996 where that is decisive. Which backend the runtime asks for is therefore a
    /// correctness setting, not a speed setting, and it has to be measured rather than assumed.
    func testComputeUnitFidelityAgainstPython() async throws {
        let reference = try loadReference()
        var worstByUnit: [(name: String, worst: Float)] = []

        for (name, units) in [("cpuOnly", MLComputeUnits.cpuOnly),
                              ("cpuAndGPU", .cpuAndGPU),
                              ("cpuAndNeuralEngine", .cpuAndNeuralEngine),
                              ("all", .all)] {
            let runtime = try makeRuntime(units)
            try await runtime.load()
            var worst: Float = 0
            var worstWhere = "—"
            for testCase in reference.cases {
                let heads = try await runtime.rawHeads(for: testCase.words)
                for (swift, python) in zip(heads, testCase.words_out) {
                    let pairs: [(String, [Float])] = [
                        ("error", swift.heads.error), ("punct", swift.heads.punctuation),
                        ("case", swift.heads.casing), ("disf", swift.heads.disfluency),
                    ]
                    for (head, values) in pairs {
                        for (got, want) in zip(values, python.logits[head] ?? []) where
                            abs(got - want) > worst {
                            worst = abs(got - want)
                            worstWhere = "\(head)/'\(swift.word)'"
                        }
                    }
                }
            }
            await runtime.unload()
            worstByUnit.append((name, worst))
            print(String(format: "[fidelity] %-20s worst |Δlogit| %.4f at %@",
                         (name as NSString).utf8String!, worst, worstWhere))
        }

        let best = worstByUnit.min { $0.worst < $1.worst }
        XCTAssertNotNil(best)
        XCTAssertLessThan(best?.worst ?? .greatestFiniteMagnitude, 0.02,
                          "no compute unit reproduces the Python reference; the Swift "
                            + "pre/post-processing is wrong, not the backend")
    }

    // MARK: - Numeric parity

    /// The load-bearing test. Every logit, every word, every case, against Python.
    ///
    /// Tolerance is 2e-2 absolute, and on `.cpuAndGPU` the measured worst case is 0.0000: both
    /// sides run the same int8-quantised package on the same backend, so the quantisation delta
    /// cancels exactly. The tolerance is headroom for a future OS scheduling change, not slack
    /// the current numbers need — and it is far too tight to absorb a misalignment, since
    /// adjacent words differ by whole logits rather than hundredths.
    func testHeadLogitsMatchPythonReference() async throws {
        let runtime = try makeRuntime()
        let reference = try loadReference()
        try await runtime.load()
        defer { Task { await runtime.unload() } }

        var compared = 0
        var worst: (delta: Float, where: String) = (0, "—")

        for testCase in reference.cases {
            let heads = try await runtime.rawHeads(for: testCase.words)
            XCTAssertEqual(heads.count, testCase.words_out.count,
                           "word count diverged for \(testCase.words.prefix(4))…")

            for (swift, python) in zip(heads, testCase.words_out) {
                XCTAssertEqual(swift.word, python.word, "word alignment diverged")
                // Checked before the logits: a tokenisation difference changes every logit in the
                // sequence, so without this the failure reads as "the model is wrong everywhere".
                XCTAssertEqual(swift.ids, python.ids, "sub-word ids for '\(swift.word)'")
                let pairs: [(String, [Float])] = [
                    ("error", swift.heads.error),
                    ("punct", swift.heads.punctuation),
                    ("case", swift.heads.casing),
                    ("disf", swift.heads.disfluency),
                ]
                for (name, values) in pairs {
                    guard let expected = python.logits[name] else {
                        return XCTFail("reference is missing the \(name) head")
                    }
                    XCTAssertEqual(values.count, expected.count, "\(name) width for '\(swift.word)'")
                    for (got, want) in zip(values, expected) {
                        let delta = abs(got - want)
                        if delta > worst.delta { worst = (delta, "\(name)/'\(swift.word)'") }
                        XCTAssertEqual(got, want, accuracy: 2e-2,
                                       "\(name) logit for '\(swift.word)'")
                        compared += 1
                    }
                }
            }
        }

        print("[parity] \(compared) logits compared, worst delta \(worst.delta) at \(worst.where)")
        XCTAssertGreaterThan(compared, 500, "reference too small to prove anything")
    }

    /// Sub-word count and chosen shape must agree with Python too. If Swift tokenised `כאילו`
    /// into a different number of pieces, the logits above could still match by luck on the
    /// first word and diverge silently later; this pins the whole sequence.
    func testSequenceShapeMatchesPythonReference() async throws {
        let runtime = try makeRuntime()
        let reference = try loadReference()
        try await runtime.load()
        defer { Task { await runtime.unload() } }

        for testCase in reference.cases {
            let output = try await runtime.encode(testCase.words)
            XCTAssertEqual(output.shape.rawValue, testCase.shape,
                           "shape for \(testCase.words.prefix(3))…")
            XCTAssertEqual(output.tokens.count, testCase.words.count,
                           "one entry per input piece is the contract")
        }
    }

    // MARK: - The gate

    /// Every edit that survives the gate must belong to a class the calibration file certifies,
    /// at a confidence that clears that class's floor.
    ///
    /// This used to assert "zero edits survive", which was true only because
    /// `Calibration.uncalibrated` capped every confidence below a single flat 0.99 floor. The
    /// floor is now tiered — 0.99 for a word substitution, 0.97 for a filler deletion, 0.95 for a
    /// mark or a case transform — and a class becomes reachable the moment its cell in
    /// `MMBERTCalibrationTable` flips to `enabled`. "Nothing survives" would then be a test of
    /// today's data rather than of the invariant, and it would have to be deleted exactly when it
    /// started to matter.
    ///
    /// So the invariant is stated directly, and it still fails loudly: if an *uncertified* class
    /// ever applies — a cell that is disabled or absent, or a confidence below its own tier —
    /// this reports which edit and which class. With today's all-disabled table it is also still
    /// the case that nothing survives, which is printed rather than asserted.
    func testOnlyCertifiedEditClassesSurviveTheConfidenceGate() async throws {
        let runtime = try makeRuntime()
        try await runtime.load()
        defer { Task { await runtime.unload() } }

        let table = MMBERTEditingModel.Calibration.uncalibrated.table
        let model = MMBERTEditingModel(runtime: runtime)
        var graph = TokenGraph.from(text: Self.workedExample, capabilities: [])

        // English is the only language with any certified cell to be found, so it is the language
        // that can actually fail this test. Naming it also exercises the per-language lookup.
        let language = TranscriptionLanguage.english
        let edits = await model.propose(graph.tokens,
                                        context: EditContext(language: language,
                                                             capabilities: [],
                                                             pass: .authoritative))

        // Captured before application: an accepted delete removes the token the class is
        // computed from, and classifying a survivor afterwards would classify nothing.
        let textByTarget = Dictionary(uniqueKeysWithValues:
            graph.tokens.map { ($0.id, $0.effectiveText) })

        let applied = ConfidenceGate(language: language).apply(edits, to: &graph)

        for edit in applied {
            let original = textByTarget[edit.target] ?? ""
            let editClass = ConfidenceGate.editClass(of: edit.operation, originalText: original)
            let floor = ConfidenceGate.floor(for: .editorModel,
                                             operation: edit.operation,
                                             originalText: original,
                                             language: language)
            XCTAssertGreaterThanOrEqual(edit.confidence, floor,
                                        "'\(original)' applied at \(edit.confidence) below the "
                                          + "\(floor) floor for \(editClass)")

            guard let verdict = Self.verdict(for: edit.operation,
                                             original: original,
                                             language: language.rawValue,
                                             in: table) else {
                XCTFail("'\(original)': \(edit.operation) has no calibration cell and applied")
                continue
            }
            if case .certified = verdict { continue }
            XCTFail("'\(original)': \(editClass) applied from an uncertified cell (\(verdict))")
        }

        print("[gate] \(edits.count) proposals, \(applied.count) survived the gate")
    }

    /// The cell an applied operation must have come from. `nil` when the operation is not one the
    /// tagger can emit, which is itself a failure at this point.
    private static func verdict(for operation: EditOperation,
                                original: String,
                                language: String,
                                in table: MMBERTCalibrationTable) -> MMBERTCalibrationTable.Verdict? {
        switch operation {
        case .insertAfter(let mark):
            return table.verdict(language: language, head: .punct, action: mark)
        case .delete:
            return table.verdict(language: language, head: .disf, action: "DISF")
        case .replace(let text):
            guard original.lowercased() == text.lowercased() else { return nil }
            let action = text == text.uppercased() && text.count > 1 ? "UPPER"
                : (text == text.lowercased() ? "LOWER" : "CAP")
            return table.verdict(language: language, head: .casing, action: action)
        case .keep:
            return nil
        }
    }

    // MARK: - Latency

    /// The plan budgets p95 < 100 ms for the editor at ≤128 tokens. Measured on the shipping
    /// path — tokenise, predict, synthesise — not on `MLModel.prediction` alone, because the
    /// tokeniser is Swift and is part of the cost.
    func testEditorLatencyIsWithinBudget() async throws {
        let runtime = try makeRuntime()
        try await runtime.load()
        defer { Task { await runtime.unload() } }

        let words = Self.workedExample.split(separator: " ").map(String.init)
        _ = try await runtime.encode(words)   // warm: first prediction pays ANE program load

        var samples: [Double] = []
        for _ in 0..<40 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await runtime.encode(words)
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p95 = samples[Int(Double(samples.count) * 0.95)]
        print(String(format: "[latency] %d words, p50 %.2f ms, p95 %.2f ms", words.count, p50, p95))
        XCTAssertLessThan(p95, 100, "editor p95 exceeds the plan's 100 ms budget")
    }

    /// The plan's worked example, verbatim. Note `сегодня` stays Russian: the source document's
    /// own `сегодня → היום` violates its no-translation rule.
    private static let workedExample =
        "okay um first send the deployment to chat gpt second update postgress "
        + "and then כאילו restart the service сегодня"
}
