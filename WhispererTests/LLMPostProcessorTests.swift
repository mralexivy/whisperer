//
//  LLMPostProcessorTests.swift
//  WhispererTests
//
//  MTP correctness + speedup tests using real app history examples.
//

import XCTest
@testable import whisperer

// MARK: - Helpers

@MainActor
private func makeProcessor(for variant: LLMModelVariant) async throws -> LLMPostProcessor {
    let p = LLMPostProcessor()
    do {
        try await p.loadModel(variant)
        return p
    } catch {
        throw XCTSkip("Cannot load \(variant.rawValue): \(error.localizedDescription)")
    }
}

private func correctMode() -> AIMode {
    AIMode.builtInModes.first { $0.name == "Correct" } ?? AIMode.defaultMode()
}

private func splitPrompt(_ mode: AIMode, text: String) -> (system: String, user: String) {
    let parts = mode.prompt.components(separatedBy: "{transcript}")
    var sys = parts[0]
    if let r = sys.range(of: "[INPUT]", options: .backwards) { sys = String(sys[..<r.lowerBound]) }
    sys = sys.trimmingCharacters(in: .whitespacesAndNewlines)
    return (sys, "[INPUT]\n\(text)\n[/INPUT]")
}

// MARK: - Tests

final class LLMPostProcessorTests: XCTestCase {

    // Shared processor — load once per test class run (model load is slow).
    @MainActor private static var sharedMTP: LLMPostProcessor?
    @MainActor private static var sharedBase: LLMPostProcessor?

    @MainActor
    private func mtpProcessor() async throws -> LLMPostProcessor {
        if let p = Self.sharedMTP, p.isModelLoaded { return p }
        let p = try await makeProcessor(for: .qwen3_5_4B_mtp)
        Self.sharedMTP = p
        return p
    }

    @MainActor
    private func baseProcessor() async throws -> LLMPostProcessor {
        if let p = Self.sharedBase, p.isModelLoaded { return p }
        // Unload MTP first to free memory before loading base model
        if let mtp = Self.sharedMTP { await mtp.unloadModel() }
        Self.sharedMTP = nil
        let p = try await makeProcessor(for: .qwen3_5_4B)
        Self.sharedBase = p
        return p
    }

    // MARK: MTP correctness — English history examples

    func testMTPEnglish() async throws {
        let p = try await mtpProcessor()
        let mode = correctMode()
        let cases: [(input: String, tag: String)] = [
            (
                "fix until a scaled row is fully rendered like a reference design that i gave you everything should work we should preview it",
                "ui-task"
            ),
            (
                "check the reference design its working perfectly on reference design its the same react why are you guessing",
                "frustration"
            ),
            (
                "im telling you again my expectation that thumbnail pass is constant whenever you need to update just like replace and nothing else should move",
                "product-req"
            ),
            (
                "we want to improve it further like the buttons on the hud we need to tell user what is the functionality they expect so basically when hovering on the buttons display really minimal tooltip text",
                "ui-hover"
            ),
            (
                "the model stays pre loaded in memory after first load whisper bridge is created once and reused why instant recording start loading large v3 turbo takes two to five seconds",
                "arch"
            ),
        ]

        print("\n=== MTP English (\(mode.name) mode) ===")
        var total = 0.0
        for c in cases {
            let (sys, user) = splitPrompt(mode, text: c.input)
            let t0 = CFAbsoluteTimeGetCurrent()
            let result = try await p.process(
                text: c.input,
                systemPrompt: sys,
                userMessage: user,
                temperature: mode.temperature,
                topP: mode.topP,
                topK: mode.topK,
                repetitionPenalty: mode.repetitionPenalty,
                maxTokensCap: mode.maxTokensCap
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            total += elapsed
            print(String(format: "[\(c.tag)] %.2fs\n  IN:  %@\n  OUT: %@", elapsed, c.input, result))

            XCTAssertFalse(result.isEmpty,            "[\(c.tag)] empty result")
            XCTAssertFalse(result.contains("<think>"), "[\(c.tag)] think tags leaked")

            let hasCyrillic = result.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
            let hasHebrew   = result.unicodeScalars.contains { $0.value >= 0x0590 && $0.value <= 0x05FF }
            XCTAssertFalse(hasCyrillic, "[\(c.tag)] Cyrillic in English output — garbled")
            XCTAssertFalse(hasHebrew,   "[\(c.tag)] Hebrew in English output — garbled")
        }
        print(String(format: "=== English total %.2fs, avg %.2fs ===", total, total / Double(cases.count)))
    }

    // MARK: MTP correctness — Hebrew history examples

    func testMTPHebrew() async throws {
        let p = try await mtpProcessor()
        let mode = correctMode()
        let cases: [(input: String, tag: String)] = [
            (
                "אנחנו נסתכל כאילו איך להצליח את זה ואני מקווה שם מאוד נתקן את זה",
                "he-1"
            ),
            (
                "כן אני חושב שהוא יתפוס את הרעיון הוא יבין איך עושים את זה ואז אנחנו נבין כאילו איך אני מתכנן את זה",
                "he-2"
            ),
            (
                "די-בי-אמס פיק פורט לא אמור להיות בחלוקה במשם בכלל לא נותן לאיזה פריאוריטים מהצד שלה",
                "he-3"
            ),
        ]

        print("\n=== MTP Hebrew (\(mode.name) mode) ===")
        for c in cases {
            let (sys, user) = splitPrompt(mode, text: c.input)
            let t0 = CFAbsoluteTimeGetCurrent()
            let result = try await p.process(
                text: c.input,
                systemPrompt: sys,
                userMessage: user,
                temperature: mode.temperature,
                topP: mode.topP,
                topK: mode.topK,
                repetitionPenalty: mode.repetitionPenalty,
                maxTokensCap: mode.maxTokensCap
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            print(String(format: "[\(c.tag)] %.2fs\n  IN:  %@\n  OUT: %@", elapsed, c.input, result))

            XCTAssertFalse(result.isEmpty, "[\(c.tag)] empty result")
            XCTAssertFalse(result.contains("<think>"), "[\(c.tag)] think tags leaked")

            let hasHebrew   = result.unicodeScalars.contains { $0.value >= 0x0590 && $0.value <= 0x05FF }
            XCTAssertTrue(hasHebrew, "[\(c.tag)] no Hebrew in output — garbled or translated")

            let hasCyrillic = result.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
            let hasCJK      = result.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
            XCTAssertFalse(hasCyrillic, "[\(c.tag)] Cyrillic in Hebrew output — garbled")
            XCTAssertFalse(hasCJK,      "[\(c.tag)] CJK in Hebrew output — garbled")
        }
    }

    // MARK: MTP vs baseline speedup

    func testMTPSpeedupVsBaseline() async throws {
        let input = """
        now we want to improve it further like the buttons on the hud we need to tell the user what is the functionality they expect so basically we should when hovering on the buttons display really minimal and informative tooltip text like what this button means so we need to display like a little overlay beautiful like what is this button functionality to hint the user so he will know how to use it and we should do the same for not only the hud but also the live transcription maximize and minimize button like a beautiful overlay minimal premium ui ux matching our overall design
        """
        let mode = correctMode()
        let (sys, user) = splitPrompt(mode, text: input)

        // MTP first (model already warm from English/Hebrew tests)
        let mtp = try await mtpProcessor()
        let t1 = CFAbsoluteTimeGetCurrent()
        let mtpResult = try await mtp.process(
            text: input, systemPrompt: sys, userMessage: user,
            temperature: mode.temperature, topP: mode.topP, topK: mode.topK,
            repetitionPenalty: mode.repetitionPenalty, maxTokensCap: mode.maxTokensCap
        )
        let mtpTime = CFAbsoluteTimeGetCurrent() - t1

        // Baseline — loads base model (unloads MTP to save memory)
        let base = try await baseProcessor()
        let t0 = CFAbsoluteTimeGetCurrent()
        let baseResult = try await base.process(
            text: input, systemPrompt: sys, userMessage: user,
            temperature: mode.temperature, topP: mode.topP, topK: mode.topK,
            repetitionPenalty: mode.repetitionPenalty, maxTokensCap: mode.maxTokensCap
        )
        let baseTime = CFAbsoluteTimeGetCurrent() - t0

        let speedup = baseTime / mtpTime
        print(String(format: "\n=== Speedup test ==="))
        print(String(format: "Baseline 4B:  %.2fs → %@", baseTime, String(baseResult.prefix(100))))
        print(String(format: "MTP 4B:       %.2fs → %@", mtpTime, String(mtpResult.prefix(100))))
        print(String(format: "Speedup:      %.2fx", speedup))

        XCTAssertFalse(baseResult.isEmpty, "baseline empty")
        XCTAssertFalse(mtpResult.isEmpty,  "mtp empty")
        XCTAssertFalse(mtpResult.contains("<think>"), "mtp think tags leaked")
        // MTP must not be more than 20% slower (allows for cold-start variance)
        XCTAssertGreaterThan(speedup, 0.80, "MTP is significantly slower than baseline — speedup regression (speedup=\(String(format: "%.2f", speedup))x)")
    }

    // MARK: MTP throughput benchmark

    func testMTPBenchmark() async throws {
        let p = try await mtpProcessor()
        let mode = correctMode()
        let input = "The user interface needs to be redesigned to improve the overall user experience and make it more intuitive for new users who are unfamiliar with the system."
        let (sys, user) = splitPrompt(mode, text: input)
        let call: () async throws -> Void = {
            _ = try await p.process(
                text: input, systemPrompt: sys, userMessage: user,
                temperature: mode.temperature, topP: mode.topP, topK: mode.topK,
                repetitionPenalty: mode.repetitionPenalty, maxTokensCap: mode.maxTokensCap
            )
        }
        // Warmup — not measured
        try await call()
        // 8 measured rounds
        var times: [Double] = []
        for _ in 0..<8 {
            let t0 = CFAbsoluteTimeGetCurrent()
            try await call()
            times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        let mean = times.reduce(0, +) / Double(times.count)
        let variance = times.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(times.count)
        let stddev = sqrt(variance)
        Logger.debug(
            "BENCHMARK: mean=\(Int(mean))ms stddev=\(Int(stddev))ms " +
            "min=\(Int(times.min()!))ms max=\(Int(times.max()!))ms",
            subsystem: .transcription
        )
        print(String(format: "\n=== BENCHMARK: mean=%.0fms stddev=%.0fms min=%.0fms max=%.0fms ===",
                     mean, stddev, times.min()!, times.max()!))
    }

    // MARK: MTP short-input smoke

    func testMTPShortInput() async throws {
        let p = try await mtpProcessor()
        let mode = correctMode()
        let inputs = ["hello world", "yes", "ok got it thanks"]
        for input in inputs {
            let (sys, user) = splitPrompt(mode, text: input)
            let result = try await p.process(
                text: input, systemPrompt: sys, userMessage: user,
                temperature: mode.temperature, topP: mode.topP, topK: mode.topK,
                repetitionPenalty: mode.repetitionPenalty, maxTokensCap: mode.maxTokensCap
            )
            print("[\(input)] → [\(result)]")
            XCTAssertFalse(result.contains("<think>"), "think tags leaked")
        }
    }
}
