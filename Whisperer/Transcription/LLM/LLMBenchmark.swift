//
//  LLMBenchmark.swift
//  Whisperer
//
//  Spec-decode benchmark: baseline vs spec-decode generation time.
//  Triggered from the AI Post-Processing settings card (debug builds only).
//  Uses hardcoded transcription strings to isolate LLM timing from whisper inference.
//

import Foundation
import Combine

@MainActor
class LLMBenchmark: ObservableObject {

    @Published var isRunning = false
    @Published var lastSummary: String? = nil

    private struct TestInput {
        let label: String
        let text: String
    }

    private struct RunResult {
        let label: String
        let inputChars: Int
        let baselineMs: [Double]
        let specDecodeMs: [Double]

        var baselineAvg: Double { baselineMs.reduce(0, +) / Double(baselineMs.count) }
        var specDecodeAvg: Double { specDecodeMs.reduce(0, +) / Double(specDecodeMs.count) }
        var baselineMed: Double { sorted(baselineMs)[baselineMs.count / 2] }
        var specDecodeMed: Double { sorted(specDecodeMs)[specDecodeMs.count / 2] }
        var speedupAvg: Double { baselineAvg / max(specDecodeAvg, 1) }
        var speedupMed: Double { baselineMed / max(specDecodeMed, 1) }
        private func sorted(_ v: [Double]) -> [Double] { v.sorted() }
    }

    private let runsPerInput = 3

    // Representative inputs spanning the range of real transcription lengths.
    private let testInputs: [TestInput] = [
        TestInput(
            label: "Tiny",
            text: "you"
        ),
        TestInput(
            label: "Short",
            text: "Hello, how are you doing today?"
        ),
        TestInput(
            label: "Medium",
            text: "Also please instruct me how to properly format the markdown output so it renders correctly in the application without any extra spacing or indentation issues."
        ),
        TestInput(
            label: "Long",
            text: "Okay but let's respond to this email first. The project is on track and we expect to deliver the first milestone by end of next week. The main blocker right now is the authentication integration with the third-party service, but we have a workaround in place and the team is confident we can resolve it without impacting the timeline. I'll send a detailed status update later today with the specific tickets and their current state."
        ),
    ]

    // Realistic system prompt matching typical LLM mode usage.
    private let systemPrompt = "Fix any transcription errors in the text. Correct spelling, grammar, and punctuation. Output only the corrected text, no explanations."

    func run(processor: LLMPostProcessor) async {
        guard !isRunning else { return }
        guard processor.isModelLoaded else {
            Logger.warning("LLMBenchmark: model not loaded, aborting", subsystem: .model)
            return
        }

        isRunning = true
        defer { isRunning = false }

        let hasSpecDecode = processor.hasDraftModel
        Logger.info("LLMBenchmark ─── START ────────────────────────────────────────", subsystem: .model)
        Logger.info("LLMBenchmark: \(testInputs.count) inputs × \(runsPerInput) runs (+ 1 warmup) each", subsystem: .model)
        Logger.info("LLMBenchmark: spec-decode available = \(hasSpecDecode)", subsystem: .model)
        if !hasSpecDecode {
            Logger.warning("LLMBenchmark: draft model not loaded — baseline-only run (no speedup comparison)", subsystem: .model)
        }

        var results: [RunResult] = []

        for input in testInputs {
            Logger.info("LLMBenchmark: [\(input.label)] \(input.text.count) chars — warming up...", subsystem: .model)

            // Baseline warmup (discarded)
            _ = try? await processor.process(
                text: input.text, systemPrompt: systemPrompt, userMessage: input.text,
                useSpecDecoding: false
            )

            // Baseline timed runs
            var baselineMs: [Double] = []
            for i in 1...runsPerInput {
                let t0 = Date()
                _ = try? await processor.process(
                    text: input.text, systemPrompt: systemPrompt, userMessage: input.text,
                    useSpecDecoding: false
                )
                let ms = -t0.timeIntervalSinceNow * 1000
                baselineMs.append(ms)
                Logger.info("LLMBenchmark: [\(input.label)] baseline run \(i)/\(runsPerInput) = \(Int(ms))ms", subsystem: .model)
            }

            var specDecodeMs: [Double] = baselineMs  // default: same as baseline if no draft model

            if hasSpecDecode {
                // Spec-decode warmup (discarded)
                _ = try? await processor.process(
                    text: input.text, systemPrompt: systemPrompt, userMessage: input.text,
                    useSpecDecoding: true
                )

                specDecodeMs = []
                for i in 1...runsPerInput {
                    let t0 = Date()
                    _ = try? await processor.process(
                        text: input.text, systemPrompt: systemPrompt, userMessage: input.text,
                        useSpecDecoding: true
                    )
                    let ms = -t0.timeIntervalSinceNow * 1000
                    specDecodeMs.append(ms)
                    Logger.info("LLMBenchmark: [\(input.label)] spec-decode run \(i)/\(runsPerInput) = \(Int(ms))ms", subsystem: .model)
                }
            }

            let result = RunResult(
                label: input.label,
                inputChars: input.text.count,
                baselineMs: baselineMs,
                specDecodeMs: specDecodeMs
            )
            results.append(result)

            Logger.info("LLMBenchmark: [\(input.label)] baseline avg=\(Int(result.baselineAvg))ms  spec-decode avg=\(Int(result.specDecodeAvg))ms  speedup=\(String(format: "%.2fx", result.speedupAvg))", subsystem: .model)
        }

        // Aggregate verdict
        let medianSpeedups = results.map { $0.speedupMed }.sorted()
        let overallMedianSpeedup = medianSpeedups[medianSpeedups.count / 2]

        let verdict: String
        if !hasSpecDecode {
            verdict = "N/A (draft model not loaded)"
        } else if overallMedianSpeedup >= 1.3 {
            verdict = "PASS ✓ — ship spec-decode"
        } else if overallMedianSpeedup >= 1.1 {
            verdict = "MARGINAL — consider numDraftTokens=2"
        } else {
            verdict = "FAIL ✗ — revert fork, stay baseline"
        }

        Logger.info("LLMBenchmark ─── RESULTS ────────────────────────────────────────", subsystem: .model)
        Logger.info("LLMBenchmark: Label       | Chars | Baseline | SpecDec | Speedup", subsystem: .model)
        for r in results {
            let lbl = r.label.padding(toLength: 10, withPad: " ", startingAt: 0)
            Logger.info("LLMBenchmark: \(lbl) | \(String(r.inputChars).padding(toLength: 5, withPad: " ", startingAt: 0)) | \(String(Int(r.baselineAvg)).padding(toLength: 8, withPad: " ", startingAt: 0)) | \(String(Int(r.specDecodeAvg)).padding(toLength: 7, withPad: " ", startingAt: 0)) | \(String(format: "%.2fx", r.speedupAvg))", subsystem: .model)
        }
        Logger.info("LLMBenchmark: Median speedup: \(String(format: "%.2fx", overallMedianSpeedup))", subsystem: .model)
        Logger.info("LLMBenchmark: VERDICT = \(verdict)", subsystem: .model)
        Logger.info("LLMBenchmark: Criteria: PASS≥1.3x AND acceptance≥35% | FAIL<1.1x OR acceptance<25%", subsystem: .model)
        Logger.info("LLMBenchmark: Check console for [spec-decode] acceptance rate logs", subsystem: .model)
        Logger.info("LLMBenchmark ─── END ────────────────────────────────────────────", subsystem: .model)

        let summary: String
        if hasSpecDecode {
            summary = "Speedup: \(String(format: "%.2fx", overallMedianSpeedup)) — \(verdict)"
        } else {
            summary = "Draft model not loaded. Load Qwen3.5-4B or 9B and wait for draft to finish."
        }
        lastSummary = summary
    }
}
