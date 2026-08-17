//
//  M6PromptGateTests.swift
//  WhispererTests
//
//  The measurement gate for Milestone 6 — replacing the Hebrew mishearing example in
//  `AIMode.correct`. `docs/knowledge/llm/rules.md` closes with *"Never edit
//  `AIMode.correct.prompt` and eyeball the result"*, and until this ran, M6 was exactly that:
//  `Tools/llm-eval/m6-hebrew-example.md` records the change as **edited, NOT gated**.
//
//  **Both arms are generated here, in one process, by one model.** The obvious cheaper design —
//  score the new prompt against `ZAIENHANCEDTEXT` from production history — is invalid: those
//  outputs came from a different model on a different build, so the delta would carry the model
//  change, the decode-parameter change and the prompt change together, and attribute all of it
//  to the pair of Hebrew words. The pre-M6 prompt is therefore reconstructed by substituting the
//  two sites back and run under the *same* loaded weights, same greedy decode, same corpus, in
//  the same thermal state.
//
//  Both arms are written back into `Tools/llm-eval/corpus.json` under `cases[].outputs`, which
//  is where `score.py` reads an arm from — the schema's own stated purpose, *"a re-run of any
//  prompt or model drops in without a schema change"*. Scoring is then
//  `python3 Tools/llm-eval/score.py --arm C_m6`, and nothing is judged here by eye. This test
//  asserts only that both arms actually generated; the three gate conditions (holdout does not
//  drop, Hebrew within ~0.15 of en/ru, drift 0) are decided by the scorer.
//

import XCTest
@testable import whisperer

@MainActor
final class M6PromptGateTests: XCTestCase {

    // MARK: - The two prompts

    /// The pair as it stands after M6, and as it stood before. Substituted rather than kept as a
    /// second full prompt string so the two arms cannot drift apart in any other respect — if a
    /// substitution does not apply, the test fails instead of silently benchmarking one prompt
    /// against itself.
    private static let substitutions: [(m6: String, preM6: String)] = [
        ("הטקס → הטקסט", "טורף → טוב"),
        ("""
        before: בואו נדבר בעברית, אני רוצה לראות איך התוכנה מציגה את הטקס שלנו
        after: בואו נדבר בעברית, אני רוצה לראות איך התוכנה מציגה את הטקסט שלנו.
        """,
         """
         before: בוא ננסה לדבר בעברית, אני רוצה לראות עד כמה טורף זה יכול לעבוד?
         after: בוא ננסה לדבר בעברית, אני רוצה לראות עד כמה טוב זה יכול לעבוד?
         """),
    ]

    private static func preM6Prompt(from current: String) throws -> String {
        var prompt = current
        for (m6, preM6) in substitutions {
            guard prompt.contains(m6) else {
                throw XCTSkip("AIMode.correct no longer contains the M6 text — this gate is "
                              + "written against a specific edit and would otherwise compare a "
                              + "prompt to itself")
            }
            prompt = prompt.replacingOccurrences(of: m6, with: preM6)
        }
        return prompt
    }

    // MARK: - Corpus

    private struct Corpus: Decodable {
        struct Case: Decodable {
            let id: String
            let language: String
            let split: String
            let input: String
        }
        let cases: [Case]
    }

    private static var harnessDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhispererTests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Tools/llm-eval")
    }

    private func loadCorpus() throws -> [Corpus.Case] {
        let url = Self.harnessDirectory.appendingPathComponent("corpus.json")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("Tools/llm-eval/corpus.json absent — run build_corpus.py")
        }
        return try JSONDecoder().decode(Corpus.self, from: data).cases
    }

    // MARK: - The run

    func testM6PromptArmsAgainstPreM6() async throws {
        let cases = try loadCorpus()
        try XCTSkipIf(cases.isEmpty, "corpus.json holds no cases")

        let mode = TestPrompts.mode(named: "Correct")
        let arms: [(name: String, prompt: String)] = [
            ("C_m6", mode.prompt),
            ("B_pre_m6", try Self.preM6Prompt(from: mode.prompt)),
        ]
        XCTAssertNotEqual(arms[0].prompt, arms[1].prompt,
                          "the two arms are the same prompt; the gate would be vacuous")

        // One load for both arms. Two loads would put the second arm in a different thermal and
        // page-cache state than the first, and the whole point of reconstructing the old prompt
        // is that nothing but the prompt differs.
        let processor = LLMPostProcessor()
        do {
            try await processor.loadModel(.qwen3_5_4B_mtp)
        } catch {
            throw XCTSkip("Qwen3.5-4B MTP not on disk: \(error.localizedDescription)")
        }
        defer { Task { await processor.unloadModel() } }

        for arm in arms {
            var outputs: [String: [String: Any]] = [:]
            var failures = 0
            let started = CFAbsoluteTimeGetCurrent()

            for (index, testCase) in cases.enumerated() {
                var mutated = mode
                mutated.prompt = arm.prompt
                let (system, user) = TestPrompts.split(mutated, text: testCase.input)
                let caseStarted = CFAbsoluteTimeGetCurrent()
                do {
                    let text = try await processor.process(
                        text:              testCase.input,
                        systemPrompt:      system,
                        userMessage:       user,
                        temperature:       mode.temperature,
                        topP:              mode.topP,
                        topK:              mode.topK,
                        repetitionPenalty: mode.repetitionPenalty,
                        maxTokensCap:      mode.maxTokensCap,
                        throwOnFallback:   true)
                    outputs[testCase.id] = [
                        "text": text,
                        "source": "\(arm.name), qwen3_5_4B_mtp, greedy, in-process",
                        "capabilityTier": "full",
                        "latencySec": CFAbsoluteTimeGetCurrent() - caseStarted,
                    ]
                } catch {
                    // Recorded, not skipped. A timeout or a refusal is a quality result and the
                    // scorer's timeout gate is written to consume it; dropping the row would
                    // shrink one arm's corpus relative to the other's and flatter whichever arm
                    // failed more.
                    failures += 1
                    outputs[testCase.id] = [
                        "text": "",
                        "source": "\(arm.name), qwen3_5_4B_mtp, greedy, in-process",
                        "capabilityTier": "full",
                        "error": error.localizedDescription,
                        "latencySec": CFAbsoluteTimeGetCurrent() - caseStarted,
                    ]
                }
                if (index + 1) % 20 == 0 {
                    print("[\(arm.name)] \(index + 1)/\(cases.count)")
                }
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - started
            print(String(format: "[%@] %d cases, %d failed, %.1f s total, %.2f s/case",
                         arm.name, cases.count, failures, elapsed,
                         elapsed / Double(cases.count)))
            try merge(outputs, arm: arm.name, prompt: arm.prompt)
            XCTAssertLessThan(failures, cases.count / 4,
                              "\(arm.name) failed to generate on \(failures)/\(cases.count) "
                                + "cases; the arm is not scoreable")
        }

        print("""

        Both arms written. The gate itself is the scorer, not this test:
          python3 Tools/llm-eval/score.py --arm B_pre_m6
          python3 Tools/llm-eval/score.py --arm C_m6
          python3 Tools/llm-eval/report.py
        Ships only if holdout does not drop, Hebrew stays within ~0.15 of en/ru, and drift is 0.
        Otherwise delete the pair from both sites — do not restore טורף → טוב.

        """)
    }

    // MARK: - Output

    private enum CorpusError: Error { case unreadable }

    /// Writes an arm into `corpus.json` under `cases[].outputs[arm]`, the shape `score.py` reads.
    ///
    /// Read-modify-write of the whole file through `JSONSerialization` rather than through the
    /// `Decodable` above: the corpus carries `provenance`, `composition` and `dropped` sections
    /// this test has no model for, and re-encoding it from a partial type would silently delete
    /// the record of why 308 rows were dropped.
    private func merge(_ outputs: [String: [String: Any]], arm: String, prompt: String) throws {
        let url = Self.harnessDirectory.appendingPathComponent("corpus.json")
        guard var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any],
              var cases = root["cases"] as? [[String: Any]] else {
            throw CorpusError.unreadable
        }

        for index in cases.indices {
            guard let id = cases[index]["id"] as? String, let produced = outputs[id] else { continue }
            var armOutputs = cases[index]["outputs"] as? [String: Any] ?? [:]
            armOutputs[arm] = produced
            cases[index]["outputs"] = armOutputs
        }
        root["cases"] = cases

        // Beside the corpus, not inside it: the prompt is ~2 KB and repeating it per case would
        // quadruple the file for no gain, but an arm whose prompt is not recorded cannot be
        // re-scored or reproduced later.
        var prompts = root["armPrompts"] as? [String: Any] ?? [:]
        prompts[arm] = ["model": "qwen3_5_4B_mtp", "decode": "greedy", "prompt": prompt]
        root["armPrompts"] = prompts

        try JSONSerialization.data(withJSONObject: root,
                                   options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: url)
        print("[\(arm)] merged \(outputs.count) outputs into \(url.lastPathComponent)")
    }
}
