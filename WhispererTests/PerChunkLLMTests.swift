//
//  PerChunkLLMTests.swift
//  WhispererTests
//
//  Verifies the per-chunk LLM correction pipeline:
//  - AIMode.supportsChunkProcessing gating
//  - ChunkLLMCoordinator serial ordering
//  - Context tail propagation between chunks
//  - Coordinator reset between recordings
//  - Timing comparison: per-chunk vs batch (requires LLM model, auto-skipped otherwise)
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

/// Build the user message the same way AppState does — with optional context injection.
private func buildUserMessage(text: String, contextTail: String? = nil) -> String {
    let baseUserMessage = "[INPUT]\n\(text)\n[/INPUT]"
    if let ctx = contextTail, !ctx.isEmpty {
        return "[CONTEXT=previous]\n\(ctx)\n[/CONTEXT]\n\(baseUserMessage)"
    }
    return baseUserMessage
}

/// Split a mode prompt into (systemPrompt, userMessage) the same way AppState.splitPrompt does.
private func splitPrompt(_ mode: AIMode, text: String, contextTail: String? = nil) -> (system: String, user: String) {
    let parts = mode.prompt.components(separatedBy: "{transcript}")
    var sys = parts[0]
    if let r = sys.range(of: "[INPUT]", options: .backwards) { sys = String(sys[..<r.lowerBound]) }
    sys = sys.trimmingCharacters(in: .whitespacesAndNewlines)
    return (sys, buildUserMessage(text: text, contextTail: contextTail))
}

// MARK: - Tests

final class PerChunkLLMTests: XCTestCase {

    // MARK: 1 — Mode gating (no model needed)

    func testSupportsChunkProcessing() {
        // Corrective modes — should support per-chunk
        XCTAssertTrue(
            AIMode.builtInModes.first { $0.id == AIMode.correctModeId }!.supportsChunkProcessing,
            "Correct mode should support chunk processing"
        )
        XCTAssertTrue(
            AIMode.builtInModes.first { $0.id == AIMode.grammarModeId }!.supportsChunkProcessing,
            "Grammar mode should support chunk processing"
        )
        XCTAssertTrue(
            AIMode.builtInModes.first { $0.id == AIMode.translateModeId }!.supportsChunkProcessing,
            "Translate mode should support chunk processing"
        )

        // Transformative modes — must NOT support per-chunk (need full-transcript context)
        XCTAssertFalse(
            AIMode.builtInModes.first { $0.id == AIMode.summarizeModeId }!.supportsChunkProcessing,
            "Summarize mode must NOT support chunk processing — needs full text"
        )
        XCTAssertFalse(
            AIMode.builtInModes.first { $0.id == AIMode.rewriteModeId }!.supportsChunkProcessing,
            "Rewrite mode must NOT support chunk processing — needs full text"
        )
        XCTAssertFalse(
            AIMode.builtInModes.first { $0.id == AIMode.listFormatModeId }!.supportsChunkProcessing,
            "List Format mode must NOT support chunk processing — needs full text"
        )
        XCTAssertFalse(
            AIMode.builtInModes.first { $0.id == AIMode.formatModeId }!.supportsChunkProcessing,
            "Format mode must NOT support chunk processing — needs full text"
        )
    }

    // MARK: 2 — Serial ordering under concurrency (no model needed)

    func testCoordinatorSerialOrdering() async throws {
        let coordinator = ChunkLLMCoordinator()
        // Each corrector waits a random short delay to stress ordering
        coordinator.corrector = { text, _ in
            let ns = UInt64.random(in: 10_000_000...60_000_000)
            try? await Task.sleep(nanoseconds: ns)
            return "corrected(\(text))"
        }
        coordinator.enqueue(chunkText: "chunk1")
        coordinator.enqueue(chunkText: "chunk2")
        coordinator.enqueue(chunkText: "chunk3")

        let result = await coordinator.drain()
        XCTAssertEqual(
            result,
            "corrected(chunk1) corrected(chunk2) corrected(chunk3)",
            "Chunks must be joined in enqueue order regardless of async timing"
        )
    }

    // MARK: 3 — Context tail propagates from chunk N to chunk N+1 (no model needed)

    func testCoordinatorContextPassing() async throws {
        var receivedContexts: [String?] = []
        let coordinator = ChunkLLMCoordinator()
        coordinator.corrector = { text, ctx in
            receivedContexts.append(ctx)
            return text + "_done"   // corrected = original + "_done" (predictable suffix(100))
        }
        coordinator.enqueue(chunkText: "hello world")
        coordinator.enqueue(chunkText: "how are you")
        coordinator.enqueue(chunkText: "doing today")

        _ = await coordinator.drain()

        XCTAssertEqual(receivedContexts.count, 3)
        XCTAssertNil(receivedContexts[0], "First chunk has no previous context")
        XCTAssertEqual(receivedContexts[1], "hello world_done",
                       "Second chunk receives tail of first corrected chunk")
        XCTAssertEqual(receivedContexts[2], "how are you_done",
                       "Third chunk receives tail of second corrected chunk")
    }

    // MARK: 4 — Reset clears state for next recording (no model needed)

    func testCoordinatorReset() async throws {
        let coordinator = ChunkLLMCoordinator()
        coordinator.corrector = { text, _ in text }

        coordinator.enqueue(chunkText: "from old recording")
        _ = await coordinator.drain()
        XCTAssertEqual(coordinator.correctedChunks.count, 1)

        coordinator.reset()
        XCTAssertTrue(coordinator.correctedChunks.isEmpty, "reset() must clear correctedChunks")

        // Enqueue from a new recording
        coordinator.enqueue(chunkText: "from new recording")
        let result = await coordinator.drain()
        XCTAssertEqual(result, "from new recording", "After reset, only new-recording chunks appear")
        XCTAssertEqual(coordinator.correctedChunks.count, 1, "Only one chunk from new recording")
    }

    // MARK: 5 — Empty chunks are filtered from the joined result (no model needed)

    func testCoordinatorFiltersEmptyChunks() async throws {
        let coordinator = ChunkLLMCoordinator()
        coordinator.corrector = { text, _ in
            // Simulate hallucination filter returning empty for the middle chunk
            return text.contains("noise") ? "" : text
        }
        coordinator.enqueue(chunkText: "first chunk")
        coordinator.enqueue(chunkText: "noise only")
        coordinator.enqueue(chunkText: "last chunk")

        let result = await coordinator.drain()
        XCTAssertEqual(result, "first chunk last chunk",
                       "Empty corrected chunks must be filtered from the join")
    }

    // MARK: 6 — Real history recordings: per-chunk vs batch timing
    // Texts sourced directly from ~/Library/Application Support/Whisperer/history.sqlite
    // (ZCHUNKTEXTSJSON is unpopulated so chunks are simulated by splitting on word boundaries,
    //  ~20 words per chunk, matching whisper's ~2s audio collection window at ~10 wps)

    struct HistoryFixture {
        let label: String
        let durationSec: Double
        let wordCount: Int
        let transcript: String
    }

    private func simulateChunks(_ text: String, wordsPerChunk: Int = 20) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var chunks: [String] = []
        var i = 0
        while i < words.count {
            let slice = words[i..<min(i + wordsPerChunk, words.count)]
            chunks.append(slice.joined(separator: " "))
            i += wordsPerChunk
        }
        return chunks
    }

    @MainActor
    func testRealHistoryRecordings() async throws {
        let processor = try await makeProcessor(for: .qwen3_5_4B_mtp)
        let mode = correctMode()

        let fixtures: [HistoryFixture] = [
            // Short — 12 words, ~3.4s (1 chunk)
            HistoryFixture(
                label: "short",
                durationSec: 3.4,
                wordCount: 12,
                transcript: "Have you deployed everything that is needed in order it to work?"
            ),
            // Medium — 42 words, ~18.6s (2-3 chunks)
            HistoryFixture(
                label: "medium",
                durationSec: 18.6,
                wordCount: 42,
                transcript: "Let's think together what is the best way to represent those changes in basically current tab. So we basically have a categories tab and using categories tab we want to also represent the whole flow for the application. So basically..."
            ),
            // Long — 98 words, ~43s (4-5 chunks)
            HistoryFixture(
                label: "long",
                durationSec: 43.1,
                wordCount: 98,
                transcript: "Let's try to create extensive plan how to add metrics based on the research below and also check our app logic. We want to detect bad user experience, slow requests. We want to detect errors when things fail and user expecting some issue, something that we detect that requires our attention as developer, something that is not reliable, any failure that can occur, any loss, anything that is broken. For the user, we need to be able to basically expose metrics about this. So we need extensively to understand the app logic and create like winning plan here."
            ),
            // Very long — 174 words, ~67s (8-9 chunks)
            HistoryFixture(
                label: "very-long",
                durationSec: 67.0,
                wordCount: 174,
                transcript: "I want you to redesign the activity bar. So currently the activity is pretty basic and based that is pretty basic it's difficult for the user to see the operations. We grouping it by day but sometimes in the same day there can be a lot of activity. I want you on the right to introduce activity minimap like VS Code minimap that we can quickly scroll through the dates and a lot of changes and we should have a lot on scroll component. So basically when we have thousands of activity we want better grouping. We want minimap to quickly pick the date and changes on the right. So create right beautiful minimap sidebar that we can scroll through and also make this premium polishing. So it will be easy to scroll through a lot of activities that will be very clear to the user. We have grouping on folder based on the user. We have a lot of different operations and based on the same sequence of operations that really executed here."
            ),
        ]

        // Quality helpers — word-level overlap between two corrected texts
        func normalizedWords(_ text: String) -> [String] {
            text.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .map { $0.filter { $0.isLetter || $0.isNumber } }
                .filter { !$0.isEmpty }
        }

        // F1-like word overlap: how many words appear in both outputs (order-independent bag)
        func wordOverlapF1(_ a: String, _ b: String) -> Double {
            var bagA: [String: Int] = [:]
            var bagB: [String: Int] = [:]
            for w in normalizedWords(a) { bagA[w, default: 0] += 1 }
            for w in normalizedWords(b) { bagB[w, default: 0] += 1 }
            let shared = bagA.keys.reduce(0) { $0 + min(bagA[$1]!, bagB[$1, default: 0]) }
            let precision = bagA.values.reduce(0, +) > 0 ? Double(shared) / Double(bagA.values.reduce(0, +)) : 0
            let recall    = bagB.values.reduce(0, +) > 0 ? Double(shared) / Double(bagB.values.reduce(0, +)) : 0
            guard precision + recall > 0 else { return 0 }
            return 2 * precision * recall / (precision + recall)
        }

        // Count mid-join capitalization artifacts: does a chunk-corrected text start with
        // an uppercase word that looks like it was incorrectly sentence-terminated?
        // We check each corrected chunk (after the first) for spurious capitalization.
        func boundaryArtifacts(correctedChunks: [String], rawChunks: [String]) -> Int {
            var count = 0
            for i in 1..<correctedChunks.count {
                let corrected = correctedChunks[i].trimmingCharacters(in: .whitespaces)
                let raw = rawChunks[i].trimmingCharacters(in: .whitespaces)
                // Raw chunk starts with lowercase continuation → LLM should NOT capitalize it
                // (unless first word is a proper noun, which is indistinguishable here)
                if let firstRawChar = raw.first, firstRawChar.isLowercase,
                   let firstCorrectedChar = corrected.first, firstCorrectedChar.isUppercase {
                    count += 1
                }
            }
            return count
        }

        struct Result {
            let label: String
            let durationSec: Double
            let wordCount: Int
            let chunkCount: Int
            let batchTime: Double
            let perChunkSeqTime: Double
            let batchResult: String
            let perChunkResult: String
            let wordF1: Double              // word-bag overlap between batch and per-chunk outputs
            let boundaryArtifactCount: Int  // chunks where LLM wrongly capitalized mid-sentence start
            let correctedChunks: [String]   // individual corrected chunks for inspection
        }

        var results: [Result] = []

        for fixture in fixtures {
            let chunks = simulateChunks(fixture.transcript)

            // --- Batch: single LLM call on full transcript ---
            let (batchSys, batchUser) = splitPrompt(mode, text: fixture.transcript)
            let batchStart = CFAbsoluteTimeGetCurrent()
            let batchResult = try await processor.process(
                text: fixture.transcript,
                systemPrompt: batchSys,
                userMessage: batchUser,
                temperature: mode.temperature,
                topP: mode.topP,
                topK: mode.topK,
                repetitionPenalty: mode.repetitionPenalty,
                maxTokensCap: mode.maxTokensCap
            )
            let batchTime = CFAbsoluteTimeGetCurrent() - batchStart

            // --- Per-chunk: route through ChunkLLMCoordinator (the production path) ---
            // The coordinator applies: 200-char context tail, fragment-mode system prompt
            // injection, and seam repair after all chunks are corrected.
            let coordinator = ChunkLLMCoordinator()
            coordinator.corrector = { [mode] text, contextTail in
                // Mirror AppState.applyLLMPostProcessing:
                // contextTail non-nil → fragment-mode instruction in system prompt only.
                // Context content is NOT injected into user message (causes model to echo it).
                var (sys, userMsg) = splitPrompt(mode, text: text, contextTail: nil)
                if contextTail != nil {
                    sys += "\n\nThis is a speech fragment from a continuous dictation stream — it may begin or end mid-sentence. Do NOT capitalize the first word unless the source already capitalizes it or it is a proper noun/acronym. Do NOT add terminal punctuation (.!?) at the end unless the source already contains it."
                }
                let raw = (try? await processor.process(
                    text: text,
                    systemPrompt: sys,
                    userMessage: userMsg,
                    temperature: mode.temperature,
                    topP: mode.topP,
                    topK: mode.topK,
                    repetitionPenalty: mode.repetitionPenalty,
                    maxTokensCap: mode.maxTokensCap
                )) ?? text
                return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let chunkStart = CFAbsoluteTimeGetCurrent()
            for chunk in chunks {
                coordinator.enqueue(chunkText: chunk)
            }
            let perChunkResult = await coordinator.drain()
            let perChunkSeqTime = CFAbsoluteTimeGetCurrent() - chunkStart
            let correctedChunks = coordinator.correctedChunks  // pre-seam-repair chunks (for boundary artifact analysis)

            let f1 = wordOverlapF1(batchResult, perChunkResult)
            let artifacts = boundaryArtifacts(correctedChunks: correctedChunks, rawChunks: chunks)

            results.append(Result(
                label: fixture.label,
                durationSec: fixture.durationSec,
                wordCount: fixture.wordCount,
                chunkCount: chunks.count,
                batchTime: batchTime,
                perChunkSeqTime: perChunkSeqTime,
                batchResult: batchResult,
                perChunkResult: perChunkResult,
                wordF1: f1,
                boundaryArtifactCount: artifacts,
                correctedChunks: correctedChunks
            ))

            XCTAssertFalse(batchResult.isEmpty, "\(fixture.label): batch result empty")
            XCTAssertFalse(perChunkResult.isEmpty, "\(fixture.label): per-chunk result empty")
            XCTAssertFalse(batchResult.contains("<think>"), "\(fixture.label): batch result leaks think tags")
            XCTAssertFalse(perChunkResult.contains("<think>"), "\(fixture.label): per-chunk result leaks think tags")
            // Quality gate: per-chunk must preserve ≥ 75% of batch word vocabulary
            XCTAssertGreaterThan(f1, 0.75, "\(fixture.label): word overlap F1=\(String(format: "%.2f", f1)) too low — per-chunk output diverged too much from batch")
        }

        // ── Timing + quality table ──────────────────────────────────────────────────────
        print("\n╔══════════╦═════╦══════╦══════════╦══════════╦════════════╦═══════╦══════════╗")
        print(  "║ Label    ║ Wds ║ Chnk ║ Batch(s) ║ Seq/c(s) ║ ProdGain%  ║ F1    ║ BdryArt ║")
        print(  "╠══════════╬═════╬══════╬══════════╬══════════╬════════════╬═══════╬══════════╣")
        for r in results {
            let avgChunkTime = r.perChunkSeqTime / Double(r.chunkCount)
            let gainPct = r.batchTime > 0 ? max(0, (r.batchTime - avgChunkTime) / r.batchTime * 100) : 0
            let lbl = r.label.padding(toLength: 8, withPad: " ", startingAt: 0)
            print(String(format: "║ %@ ║ %3d ║  %2d  ║   %5.2f  ║   %5.2f  ║  ~%4.0f%%    ║ %.2f  ║   %d      ║",
                         lbl, r.wordCount, r.chunkCount,
                         r.batchTime, r.perChunkSeqTime, gainPct,
                         r.wordF1, r.boundaryArtifactCount))
        }
        print("╚══════════╩═════╩══════╩══════════╩══════════╩════════════╩═══════╩══════════╝")
        print("  ProdGain% = (batch − avg_chunk_time) / batch   [earlier chunks overlap audio collection]")
        print("  F1        = word-bag overlap between batch and per-chunk outputs  [1.0 = identical vocabulary]")
        print("  BdryArt   = chunks where LLM wrongly capitalized a mid-sentence continuation")

        // ── Full text comparison ────────────────────────────────────────────────────────
        print("\n── Full output comparison ──")
        for r in results {
            print("\n[\(r.label)] BATCH (\(r.batchResult.split(separator: " ").count) words):")
            print("  \(r.batchResult)")
            print("[\(r.label)] PER-CHUNK (\(r.perChunkResult.split(separator: " ").count) words, F1=\(String(format: "%.2f", r.wordF1))):")
            print("  \(r.perChunkResult)")
            if r.chunkCount > 1 {
                print("  Chunk boundaries:")
                for (i, chunk) in r.correctedChunks.enumerated() {
                    print("    chunk[\(i)]: \(chunk.prefix(80))")
                }
            }
        }
    }

    // MARK: 7 — Structural tag stripping (no model needed)
    // Guards against the regression where [CONTEXT=previous] / [INPUT] tags leaked into output.

    func testStripStructuralTagsFromOutput() {
        // Access the static method via the test-accessible type
        // (AppState is @MainActor but stripStructuralTags is static — test on MainActor)
        // Inline the same logic as AppState.stripStructuralTags so the test is model-free
        func strip(_ text: String) -> String {
            var out = text
            if let regex = try? NSRegularExpression(pattern: #"\[CONTEXT=previous\][\s\S]*?\[/CONTEXT\]"#) {
                let range = NSRange(out.startIndex..., in: out)
                out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "")
            }
            for tag in ["[CONTEXT=previous]", "[/CONTEXT]", "[INPUT]", "[/INPUT]"] {
                out = out.replacingOccurrences(of: tag, with: "")
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Verify no structural tags survive stripping — exact whitespace not asserted
        let leakyInputs = [
            // Full block leakage (the real-world bug)
            "some text [CONTEXT=previous]\nion \"see the link\"\n[/CONTEXT] [CONTEXT=previous]\ne link\n[/CONTEXT]\n[INPUT]\nwant it like we want",
            // Only [INPUT] tag leaked
            "[INPUT]\nThis is the real output",
            // Bare [/CONTEXT] leftover
            "output text [/CONTEXT] more text",
        ]
        let forbidden = ["[CONTEXT=previous]", "[/CONTEXT]", "[INPUT]", "[/INPUT]"]

        for input in leakyInputs {
            let result = strip(input)
            for tag in forbidden {
                XCTAssertFalse(result.contains(tag), "Tag '\(tag)' survived stripping in: \(result.prefix(80))")
            }
        }

        // Clean output must not be modified
        let clean = "Everything is fine here."
        XCTAssertEqual(strip(clean), clean, "Clean output must not be changed by stripping")
    }

    // MARK: 9 — Per-chunk vs batch timing (real LLM — auto-skips if model not downloaded)

    @MainActor
    func testPerChunkVsBatchLatency() async throws {
        let processor = try await makeProcessor(for: .qwen3_5_4B_mtp)
        let mode = correctMode()

        let chunks = [
            "so the thing about the live transcription is that we want to improve it further",
            "like the buttons on the hud we need to tell the user what functionality they expect",
            "basically when hovering on the buttons display really minimal tooltip text"
        ]
        let joined = chunks.joined(separator: " ")

        // --- Batch timing (current behaviour: single LLM call on full text) ---
        let (batchSys, batchUser) = splitPrompt(mode, text: joined)
        let batchStart = CFAbsoluteTimeGetCurrent()
        let batchResult = try await processor.process(
            text: joined,
            systemPrompt: batchSys,
            userMessage: batchUser,
            temperature: mode.temperature,
            topP: mode.topP,
            topK: mode.topK,
            repetitionPenalty: mode.repetitionPenalty,
            maxTokensCap: mode.maxTokensCap
        )
        let batchTime = CFAbsoluteTimeGetCurrent() - batchStart

        // --- Per-chunk timing (sequential — represents worst-case drain time at stop) ---
        // In production these run during audio collection windows; drain ≈ last chunk only.
        let chunkStart = CFAbsoluteTimeGetCurrent()
        var corrected: [String] = []
        var prevTail: String? = nil
        for chunk in chunks {
            let (cs, cu) = splitPrompt(mode, text: chunk, contextTail: prevTail)
            let result = try await processor.process(
                text: chunk,
                systemPrompt: cs,
                userMessage: cu,
                temperature: mode.temperature,
                topP: mode.topP,
                topK: mode.topK,
                repetitionPenalty: mode.repetitionPenalty,
                maxTokensCap: mode.maxTokensCap
            )
            corrected.append(result)
            prevTail = String(result.suffix(100))
        }
        let perChunkSequentialTime = CFAbsoluteTimeGetCurrent() - chunkStart

        print(String(format: "\n=== Per-chunk vs batch ==="))
        print(String(format: "Batch (full text):       %.2fs → %@", batchTime, String(batchResult.prefix(80))))
        print(String(format: "Per-chunk (sequential):  %.2fs → %@", perChunkSequentialTime,
                     String(corrected.joined(separator: " ").prefix(80))))
        print(String(format: "Ratio (seq/batch):       %.2fx", perChunkSequentialTime / batchTime))
        print("Note: real drain time ≈ last-chunk LLM time (~\(String(format: "%.2f", perChunkSequentialTime / Double(chunks.count)))s)")
        print("      because earlier chunks correct during audio collection windows.")

        XCTAssertFalse(batchResult.isEmpty, "Batch result must not be empty")
        XCTAssertFalse(corrected.joined().isEmpty, "Per-chunk result must not be empty")
        XCTAssertFalse(batchResult.contains("<think>"), "Batch: think tags must not leak")
        XCTAssertFalse(corrected.joined().contains("<think>"), "Per-chunk: think tags must not leak")
    }
}
