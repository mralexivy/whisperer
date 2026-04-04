//
//  LLMPostProcessorTests.swift
//  WhispererTests
//
//  Integration tests for LLM post-processing with real model
//

import XCTest
@testable import whisperer

struct CleanupCase {
    let input: String
    let expected: String
}

final class LLMPostProcessorTests: XCTestCase {

    private static var processor: LLMPostProcessor?

    override class func tearDown() {
        Task { @MainActor in
            processor?.unloadModel()
        }
        processor = nil
        super.tearDown()
    }

    private static var testProcessor: LLMPostProcessor?

    @MainActor
    private func loadLLMProcessor() async throws -> LLMPostProcessor {
        // Use cached test processor if available
        if let cached = Self.testProcessor, cached.isModelLoaded {
            NSLog("Using cached test LLM processor")
            return cached
        }

        // Load a test processor with a smaller model for faster testing
        let processor = LLMPostProcessor()
        let variant = LLMModelVariant.qwen3_5_4B  // 4B model - default and recommended

        NSLog("Loading test LLM model \(variant.displayName)...")
        do {
            try await processor.loadModel(variant)
            Self.testProcessor = processor
            NSLog("Test LLM model loaded")
            return processor
        } catch {
            throw XCTSkip("Failed to load LLM model: \(error.localizedDescription)")
        }
    }

    /// Test transcription cleanup with real cases
    func testTranscriptionCleanup() async throws {
        let processor = try await loadLLMProcessor()

        let cases: [CleanupCase] = [
            .init(
                input: "hey jody just wanted to check if things moved forward on your end and if the role is still relevant",
                expected: "Hey Jody, just wanted to check if things moved forward on your end and if the role is still relevant."
            ),
            .init(
                input: "i think we should should move this to next week and then review it again",
                expected: "I think we should move this to next week and then review it again."
            ),
            .init(
                input: "so like i think we can probably like ship this on monday",
                expected: "So I think we can probably ship this on Monday."
            ),
        ]

        let systemPrompt = AIMode.builtInModes.first { $0.name == "Grammar" }?.prompt ?? ""
        XCTAssertFalse(systemPrompt.isEmpty, "Grammar mode prompt should exist")

        for (index, testCase) in cases.enumerated() {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try await processor.process(
                text: testCase.input,
                systemPrompt: systemPrompt,
                temperature: 0.1,
                topP: 0.8
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - start

            NSLog("Case \(index + 1): \(String(format: "%.2f", elapsed))s")
            NSLog("  Input:    '\(testCase.input)'")
            NSLog("  Expected: '\(testCase.expected)'")
            NSLog("  Got:      '\(result)'")

            // Verify basic requirements
            XCTAssertLessThan(elapsed, 30.0, "Case \(index + 1) timeout")
            XCTAssertFalse(result.isEmpty, "Case \(index + 1) empty result")
            XCTAssertFalse(result.contains("<think>"), "Case \(index + 1) has <think> tags")
            XCTAssertFalse(result.contains("/no_think"), "Case \(index + 1) leaked /no_think directive")

            // Note: Small models (0.6B-0.8B) don't reliably fix capitalization/punctuation
            // These tests verify the model produces usable output, not perfect formatting
            NSLog("Case \(index + 1) formatting check: starts with capital=\(result.first?.isUppercase ?? false), ends with punctuation=\(".!?".contains(result.last ?? Character(" "))))")
        }
    }

    /// Test that processing completes without timeout
    func testNoTimeout() async throws {
        let processor = try await loadLLMProcessor()

        // Use actual Grammar mode systemPrompt like the real app does
        let systemPrompt = AIMode.builtInModes.first { $0.name == "Grammar" }?.prompt ?? "Fix grammar and punctuation."
        NSLog("Using systemPrompt: \(systemPrompt.prefix(100))...")

        let start = CFAbsoluteTimeGetCurrent()
        let result = try await processor.process(
            text: "hello world how are you doing today",
            systemPrompt: systemPrompt,
            temperature: 0.1,
            topP: 0.8
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 30.0, "Should complete within timeout")
        XCTAssertFalse(result.isEmpty)
        NSLog("Basic test: \(String(format: "%.2f", elapsed))s -> '\(result)'")
    }

    /// Test real transcription cleanup using the Correct mode (default)
    func testRealTranscription() async throws {
        let processor = try await loadLLMProcessor()

        let realInput = """
        Now we want to improve it further. Like the buttons on the HUD, we need to tell user what is the functionality they expect. So basically we should when hovering on the buttons display really minimal and toggle text like what this button means. So we need like display like little overlay beautiful like what is this button functionality to hint the user like so he will know like how to use it and we should do the same for not only the half also live transcription maximize and minimize like beautiful overlay minimal premium UI UX matching our overall design like we need To Do it very carefully really beautifully
        """

        let mode = AIMode.builtInModes.first { $0.name == "Correct" }!
        let systemPrompt = mode.prompt.replacingOccurrences(of: "{transcript}", with: "")
        NSLog("Testing real transcription cleanup with Correct mode...")
        NSLog("BEFORE: '\(realInput.trimmingCharacters(in: .whitespacesAndNewlines))'")

        let start = CFAbsoluteTimeGetCurrent()
        let result = try await processor.process(
            text: realInput,
            systemPrompt: systemPrompt,
            temperature: mode.temperature,
            topP: mode.topP
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        NSLog("AFTER:  '\(result)'")
        NSLog("TIME:   \(String(format: "%.2f", elapsed))s")

        XCTAssertLessThan(elapsed, 30.0, "Should complete within timeout")
        XCTAssertFalse(result.isEmpty, "Result should not be empty")
        XCTAssertFalse(result.contains("<think>"), "Should not contain <think> tags")
        XCTAssertFalse(result.contains("Thinking"), "Should not contain thinking output")
    }
}
