//
//  M6HebrewPairRemovalTests.swift
//  WhispererTests
//
//  Arm D for Milestone 6: `AIMode.correct` with the Hebrew mishearing pair DELETED from both
//  sites, measured against the two arms `M6PromptGateTests` already produced.
//
//  Why a third arm exists at all. M6's own written contingency is *"If nothing clears it, delete
//  the pair from both sites rather than ship a wrong example. Do not restore טורף → טוב."*
//  Deleting is not free: `AIMode.swift` records that removing the worked examples costs 0.11
//  balanced and 0.14 holdout, so the contingency is a change that must be measured, not assumed.
//  All three prompts are derived from the one currently in `AIMode.correct` by substitution, so
//  nothing but the Hebrew pair differs between them, and all three run under one loaded model.
//
//  Why this test also carries a gate probe that has no gold. `Tools/llm-eval/README.md` §4(c) is
//  blunt: the joinable corpus is 89 en / 2 he / 1 ru, both Hebrew cases are in train, and
//  `rules.md` rule 10 says *"Non-Latin cases need to be counted in the dozens before 'it
//  preserves language' means anything."* Two cases cannot answer M6's second gate condition —
//  Hebrew within ~0.15 of en/ru — nor its third, drift 0. But README §4 also records what the
//  harness CAN do without gold: *"Drift, echo and degeneration are computed from the output text
//  alone and need no gold."* M6 is a change to a Hebrew example, and the failure it is suspected
//  of causing (a 4B degeneration on `Correct-he-82ch`) is a gate failure. So the probe runs all
//  three prompts over dozens of real Hebrew and Russian transcripts from the same history
//  database and scores gates only. It answers the gate conditions; it deliberately does not
//  pretend to answer recovery, because there is no gold for these rows.
//
//  Nothing is judged here by eye. This test generates and writes; the verdict is
//  `python3 Tools/llm-eval/score.py --arm D_no_he_pair` and `probe_gates.py`.
//

import XCTest
@testable import whisperer

@MainActor
final class M6HebrewPairRemovalTests: XCTestCase {

    // MARK: - The three prompts

    /// Rule 7's inline mishearing list, and the worked pair, as they stand after M6.
    private static let m6Inline = "הטקס → הטקסט"
    private static let m6Pair = """
        before: בואו נדבר בעברית, אני רוצה לראות איך התוכנה מציגה את הטקס שלנו
        after: בואו נדבר בעברית, אני רוצה לראות איך התוכנה מציגה את הטקסט שלנו.
        """

    /// The same two sites before M6. Reconstructed identically to `M6PromptGateTests` so arm B
    /// here is the same arm B there — if the two ever diverge, the three-arm comparison is void.
    private static let preM6Inline = "טורף → טוב"
    private static let preM6Pair = """
        before: בוא ננסה לדבר בעברית, אני רוצה לראות עד כמה טורף זה יכול לעבוד?
        after: בוא ננסה לדבר בעברית, אני רוצה לראות עד כמה טוב זה יכול לעבוד?
        """

    private enum PromptError: Error, CustomStringConvertible {
        case siteMissing(String)
        var description: String {
            switch self {
            case .siteMissing(let site): return "AIMode.correct no longer contains \(site)"
            }
        }
    }

    private static func preM6Prompt(from current: String) throws -> String {
        try require(current, contains: m6Inline)
        try require(current, contains: m6Pair)
        return current
            .replacingOccurrences(of: m6Inline, with: preM6Inline)
            .replacingOccurrences(of: m6Pair, with: preM6Pair)
    }

    /// M6's contingency, applied.
    ///
    /// Site 1 — rule 7's list `(Plower → planner, rounds → routes, הטקס → הטקסט)` loses its last
    /// item and the comma that introduces it; the two English mishearings stay, so the rule keeps
    /// its illustration and only the Hebrew instance goes.
    ///
    /// Site 2 — the worked pair and the blank line that separates it from the next one are
    /// removed together. `AIMode.swift` note 2 records that the bare `before:`/`after:` shape is
    /// load-bearing (delimiter-shaped examples were imitated and echoed on 3 Russian cases), so
    /// the remaining examples must stay blank-line separated with no other edit. Example count
    /// goes 7 → 6; two Hebrew examples remain, the `Dicitation` repetition case and the
    /// digits/24-7 case, so Hebrew is still demonstrated.
    private static func noHebrewPairPrompt(from current: String) throws -> String {
        try require(current, contains: ", " + m6Inline)
        try require(current, contains: m6Pair + "\n\n")
        return current
            .replacingOccurrences(of: ", " + m6Inline, with: "")
            .replacingOccurrences(of: m6Pair + "\n\n", with: "")
    }

    private static func require(_ prompt: String, contains site: String) throws {
        guard prompt.contains(site) else { throw PromptError.siteMissing(site) }
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

    // MARK: - Arm D over the scored corpus

    func testArmDOverCorpus() async throws {
        let url = Self.harnessDirectory.appendingPathComponent("corpus.json")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("Tools/llm-eval/corpus.json absent — run build_corpus.py")
        }
        let cases = try JSONDecoder().decode(Corpus.self, from: data).cases
        try XCTSkipIf(cases.isEmpty, "corpus.json holds no cases")

        let mode = TestPrompts.mode(named: "Correct")
        let prompt = try Self.noHebrewPairPrompt(from: mode.prompt)
        XCTAssertNotEqual(prompt, mode.prompt, "the deletion did not apply; arm D is arm C")
        XCTAssertFalse(prompt.contains("הטקס →"), "site 1 survived the deletion")
        XCTAssertFalse(prompt.contains("מציגה את הטקס"), "site 2 survived the deletion")
        XCTAssertEqual(prompt.components(separatedBy: "\nbefore: ").count - 1, 6,
                       "expected 6 worked examples after deleting one of 7")

        let processor = LLMPostProcessor()
        try await Self.load(processor)
        defer { Task { await processor.unloadModel() } }

        var outputs: [String: [String: Any]] = [:]
        var failures = 0
        for (index, testCase) in cases.enumerated() {
            let (text, latency, error) = await Self.run(processor, mode: mode, prompt: prompt,
                                                        input: testCase.input)
            if error != nil { failures += 1 }
            outputs[testCase.id] = Self.record(text: text, latency: latency, error: error,
                                               arm: "D_no_he_pair")
            if (index + 1) % 20 == 0 { print("[D_no_he_pair] \(index + 1)/\(cases.count)") }
        }
        try Self.mergeIntoCorpus(outputs, arm: "D_no_he_pair", prompt: prompt)
        XCTAssertLessThan(failures, cases.count / 4,
                          "arm D failed to generate on \(failures)/\(cases.count) cases")
        print("""

        Arm D written. Score it against the other two:
          python3 Tools/llm-eval/score.py --arm D_no_he_pair
          python3 Tools/llm-eval/report.py

        """)
    }

    // MARK: - Gold-free multilingual gate probe, all three arms

    func testHebrewAndRussianGateProbe() async throws {
        let fixtures = try Self.probeFixtures()
        try XCTSkipIf(fixtures.isEmpty, "no non-Latin transcripts in the history database")
        print("probe: " + Dictionary(grouping: fixtures, by: \.script)
            .map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " "))

        let mode = TestPrompts.mode(named: "Correct")
        let arms: [(name: String, prompt: String)] = [
            ("B_pre_m6", try Self.preM6Prompt(from: mode.prompt)),
            ("C_m6", mode.prompt),
            ("D_no_he_pair", try Self.noHebrewPairPrompt(from: mode.prompt)),
        ]
        XCTAssertEqual(Set(arms.map(\.prompt)).count, 3, "two arms are the same prompt")

        // One load for all three arms — same weights, same thermal state, same page cache. The
        // whole value of deriving the arms by substitution is lost if they run under different
        // conditions.
        let processor = LLMPostProcessor()
        try await Self.load(processor)
        defer { Task { await processor.unloadModel() } }

        var rows: [[String: Any]] = []
        for arm in arms {
            for (index, fixture) in fixtures.enumerated() {
                let (text, latency, error) = await Self.run(processor, mode: mode,
                                                            prompt: arm.prompt,
                                                            input: fixture.transcript)
                var row: [String: Any] = [
                    "arm": arm.name,
                    "id": fixture.id,
                    "script": fixture.script,
                    "input": fixture.transcript,
                    "output": text,
                    "latencySec": latency,
                ]
                if let error { row["error"] = error }
                rows.append(row)
                if (index + 1) % 20 == 0 { print("[\(arm.name)/probe] \(index + 1)/\(fixtures.count)") }
            }
        }

        let url = Self.harnessDirectory.appendingPathComponent("probe-nonlatin.json")
        try JSONSerialization.data(
            withJSONObject: ["model": "qwen3_5_4B_mtp", "decode": "greedy", "rows": rows],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: url)
        print("""

        Wrote \(rows.count) probe rows to \(url.lastPathComponent). Gates:
          python3 Tools/llm-eval/probe_gates.py

        """)
    }

    // MARK: - Fixtures

    private struct ProbeFixture { let id: String; let script: String; let transcript: String }

    /// Hebrew and Russian dictation transcripts straight from the history database.
    ///
    /// Selected by the SCRIPT OF THE TRANSCRIPT, never by `ZLANGUAGE`: that column is the
    /// router's decision, and across the Correct-mode rows it declares 151 `he` while only 10
    /// transcripts actually contain Hebrew. `LLMModelComparisonTests` records the same trap.
    /// Sorted by id and capped so the set is deterministic across runs and the three arms see
    /// exactly the same inputs.
    private static func probeFixtures(perScript: Int = 40) throws -> [ProbeFixture] {
        let all = HistoryTestLoader.loadFixtures(maxCount: 4000)
        var byScript: [String: [ProbeFixture]] = [:]
        for fixture in all where fixture.transcript.count > 60 {
            guard let script = script(of: fixture.transcript), script != "en" else { continue }
            byScript[script, default: []].append(
                ProbeFixture(id: fixture.id, script: script, transcript: fixture.transcript))
        }
        return ["he", "ru"].flatMap { byScript[$0, default: []].sorted { $0.id < $1.id }.prefix(perScript) }
    }

    /// Dominant script by character count. Presence alone will not do here: a Hebrew sentence
    /// quoting `docker run --rm -it` is majority-Latin by token but Hebrew by character mass,
    /// and an English sentence naming one Hebrew word is not a Hebrew fixture.
    private static func script(of text: String) -> String? {
        var counts = ["he": 0, "ru": 0, "en": 0]
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x05FF, 0xFB1D...0xFB4F: counts["he"]! += 1
            case 0x0400...0x04FF, 0x0500...0x052F: counts["ru"]! += 1
            case 0x41...0x5A, 0x61...0x7A:         counts["en"]! += 1
            default: break
            }
        }
        guard let best = counts.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        return best.key
    }

    // MARK: - Generation plumbing

    private static func load(_ processor: LLMPostProcessor) async throws {
        do {
            try await processor.loadModel(.qwen3_5_4B_mtp)
        } catch {
            throw XCTSkip("Qwen3.5-4B MTP not on disk: \(error.localizedDescription)")
        }
    }

    private static func run(_ processor: LLMPostProcessor, mode: AIMode, prompt: String,
                            input: String) async -> (String, Double, String?) {
        var mutated = mode
        mutated.prompt = prompt
        let (system, user) = TestPrompts.split(mutated, text: input)
        let started = CFAbsoluteTimeGetCurrent()
        do {
            let text = try await processor.process(
                text:              input,
                systemPrompt:      system,
                userMessage:       user,
                temperature:       mode.temperature,
                topP:              mode.topP,
                topK:              mode.topK,
                repetitionPenalty: mode.repetitionPenalty,
                maxTokensCap:      mode.maxTokensCap,
                throwOnFallback:   true)
            return (text, CFAbsoluteTimeGetCurrent() - started, nil)
        } catch {
            // Recorded as an empty output, never dropped: a refusal or a timeout is a quality
            // result, and removing the row would shrink one arm relative to the others and
            // flatter whichever arm failed most.
            return ("", CFAbsoluteTimeGetCurrent() - started, error.localizedDescription)
        }
    }

    private static func record(text: String, latency: Double, error: String?,
                               arm: String) -> [String: Any] {
        var payload: [String: Any] = [
            "text": text,
            "source": "\(arm), qwen3_5_4B_mtp, greedy, in-process",
            "capabilityTier": "full",
            "latencySec": latency,
        ]
        if let error { payload["error"] = error }
        return payload
    }

    private enum CorpusError: Error { case unreadable }

    /// Read-modify-write of the whole corpus through `JSONSerialization`, matching
    /// `M6PromptGateTests.merge` — decoding into a partial type and re-encoding would silently
    /// delete the `provenance`, `composition` and `dropped` sections and the other arms' outputs.
    private static func mergeIntoCorpus(_ outputs: [String: [String: Any]], arm: String,
                                        prompt: String) throws {
        let url = harnessDirectory.appendingPathComponent("corpus.json")
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
        var prompts = root["armPrompts"] as? [String: Any] ?? [:]
        prompts[arm] = ["model": "qwen3_5_4B_mtp", "decode": "greedy", "prompt": prompt]
        root["armPrompts"] = prompts
        try JSONSerialization.data(withJSONObject: root,
                                   options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: url)
        print("[\(arm)] merged \(outputs.count) outputs into \(url.lastPathComponent)")
    }
}
