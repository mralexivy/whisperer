//
//  PolishCorpusDumpTests.swift
//  WhispererTests
//
//  Emits the deterministic arm's output over `Tools/llm-eval/corpus.json` so `score.py` can
//  measure verdict rule 4 (recovery toward the authored gold) on it.
//
//  Why this exists rather than a Python reimplementation: recovery is a *paired* metric. It
//  compares an arm's output and the raw input against one reference, so both arms have to be
//  the genuine article. Arm A's side already is — `corpus.json` carries `ZAIENHANCEDTEXT`,
//  what the shipped Qwen3.5-4B actually returned. The deterministic arm's side can only come
//  from `DeterministicPolisher` itself; a Python approximation of protect → alias → numbers →
//  normalize → terminate → case → paragraph → render → lists would be a second implementation
//  to keep in sync, and every divergence would land in the verdict as if it were a result.
//
//  This is a dump, not an assertion. It writes a file and checks only that it wrote something
//  coherent; the actual rule-4 comparison happens in `score.py --gold`, which is where every
//  other recovery figure in this project is computed.
//

import XCTest
@testable import whisperer

final class PolishCorpusDumpTests: XCTestCase {

    private struct Corpus: Decodable {
        struct Case: Decodable {
            let id: String
            let input: String
        }
        let cases: [Case]
    }

    /// `#filePath` rather than the bundle: `Tools/` is not a test resource and is never copied
    /// into the bundle, and these tests are source-tree-local regardless.
    private var evalDirectory: URL {
        URL(fileURLWithPath: #filePath)          // .../WhispererTests/PolishCorpusDumpTests.swift
            .deletingLastPathComponent()         // .../WhispererTests
            .deletingLastPathComponent()         // repo root
            .appendingPathComponent("Tools/llm-eval")
    }

    func testDumpDeterministicArmForLLMEval() throws {
        let corpusURL = evalDirectory.appendingPathComponent("corpus.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: corpusURL.path),
                          "Tools/llm-eval/corpus.json not present")

        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpusURL))
        XCTAssertFalse(corpus.cases.isEmpty, "corpus.json parsed to zero cases")

        // The same configuration `AppState.applyLLMPostProcessing` uses for Correct-mode
        // dictation, and the same one `PolishBenchmarkTests` measures. A dump produced by a
        // differently-configured polisher would score a pipeline that does not ship.
        let polisher = DeterministicPolisher()

        // Latency is dumped alongside the text, and not as a nicety. `score.py` treats an
        // unchanged output as a timeout when no latency was recorded — a proxy that is right for
        // the 4B, whose ladder really does fall back to the input on expiry, and wrong for this
        // arm, which returns the input in microseconds when it finds nothing to fix. Recording
        // the measurement removes the need for the proxy.
        var outputs: [String: [String: Any]] = [:]
        for entry in corpus.cases {
            let started = CFAbsoluteTimeGetCurrent()
            let text = polisher.polish(text: entry.input).text
            outputs[entry.id] = [
                "text": text,
                "latencySec": CFAbsoluteTimeGetCurrent() - started,
            ]
        }

        let payload: [String: Any] = [
            "arm": "D_deterministic",
            "source": "DeterministicPolisher.polish(text:) over corpus.json inputs",
            "note": "polish(text:) — NOT polish(chunks:). The history persists chunk texts "
                  + "without sample spans, so no acoustic pause evidence exists for these ids "
                  + "and SentenceTerminator sees none. Boundary recall here is a lower bound "
                  + "on what ships.",
            "outputs": outputs,
        ]

        let url = evalDirectory.appendingPathComponent("arm-D_deterministic.json")
        try JSONSerialization.data(withJSONObject: payload,
                                   options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: url)

        XCTAssertEqual(outputs.count, corpus.cases.count,
                       "a duplicate id collapsed two cases into one output")
        XCTAssertTrue(outputs.values.allSatisfy { !(($0["text"] as? String) ?? "").isEmpty },
                      "the polisher returned empty text for at least one input")
        print("wrote \(outputs.count) deterministic outputs to \(url.path)")
    }
}
