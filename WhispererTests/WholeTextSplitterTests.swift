//
//  WholeTextSplitterTests.swift
//  WhispererTests
//
//  Two halves, deliberately separated.
//
//  The first half is model-free and asserts the property the whole feature rests on: splitting a
//  transcript loses nothing. Every word of the input appears in the output, in order, exactly once.
//  A splitter that drops a clause would be almost invisible in a wall-clock benchmark and very
//  visible to a user who dictated a paragraph and got most of it back.
//
//  The second half loads the model and compares the segmented path against the single whole-text
//  call it replaces, on real long transcripts from the app's own history. It measures two things,
//  and the second one turned out to matter more than the first: `AIMode.correct` caps output at
//  256 tokens (`AIMode.swift`), so a single pass over a 5,000-character transcript stops
//  mid-sentence and returns the truncated text. The segmented path has that cap applied per
//  segment instead, so the cap stops binding at all.
//
//  Must not run concurrently with any other model test.
//

import XCTest
@testable import whisperer

@MainActor
final class WholeTextSplitterTests: XCTestCase {

    private let variant: LLMModelVariant = .qwen3_5_4B_mtp

    // MARK: - Helpers

    /// Words, lowercased and stripped of punctuation. Comparing on this rather than on characters
    /// is the point: the correction pass is *supposed* to change punctuation and capitalisation, so
    /// a character-level assertion would fail on success.
    private func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private func withModel(_ body: (LLMPostProcessor) async throws -> Void) async throws {
        let processor = LLMPostProcessor()
        do {
            try await processor.loadModel(variant)
        } catch {
            throw XCTSkip("cannot load \(variant.rawValue): \(error.localizedDescription)")
        }
        do {
            try await body(processor)
        } catch {
            await processor.unloadModel()
            throw error
        }
        await processor.unloadModel()
    }

    /// The production segmented path, at processor level: split, correct every segment in one
    /// batch, repair the seams, join. `AppState.applyLLMPostProcessingSegmented` is the same
    /// sequence with the scheduler in the middle; running it here keeps the test off `AppState`'s
    /// singleton and its recording state machine.
    private func segmentedCorrect(_ text: String,
                                  processor: LLMPostProcessor) async -> (String, [String]) {
        let segments = WholeTextSplitter.split(text)
        let prompts = segments.map { correctPrompt(for: $0, fragment: true) }
        let instructions = prompts[0].system
        let requests = zip(segments, prompts).map { segment, prompt in
            LLMBatchRequest.make(text: segment, userMessage: prompt.user)
        }
        let corrected = await processor.processBatch(requests: requests, instructions: instructions)
        guard corrected.count == segments.count else { return (text, segments) }
        let repaired = ChunkLLMCoordinator.repairSeams(corrected: corrected, raw: segments)
        return (repaired.filter { !$0.isEmpty }.joined(separator: " "), segments)
    }

    // MARK: - 1. Splitting loses nothing (model-free)

    /// The load-bearing property. Run over every real transcript in the history DB rather than over
    /// hand-written strings, because the inputs that break a splitter are the ones nobody would
    /// think to write: no terminal punctuation at all, a 900-character run-on, Hebrew, a single
    /// word repeated by a stuck VAD.
    func testSplitPreservesEveryWord() throws {
        // Both orderings: the near-20 s sample is the representative population, and the
        // longest-first sample is where splitting actually happens.
        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 300)
            + HistoryTestLoader.loadLongestFixtures(maxCount: 60)
        try XCTSkipIf(fixtures.isEmpty, "no history.sqlite")

        var split = 0
        var singles = 0
        for fixture in fixtures {
            let text = fixture.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let segments = WholeTextSplitter.split(text)
            if segments.count > 1 { split += 1 } else { singles += 1 }

            XCTAssertEqual(words(segments.joined(separator: " ")), words(text),
                           "words changed for \(fixture.id) (\(fixture.durationBucket), "
                           + "\(text.count) chars, \(segments.count) segments)")
            for segment in segments {
                XCTAssertFalse(segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "empty segment for \(fixture.id)")
            }
        }
        print("split \(split) transcripts, left \(singles) whole, of \(fixtures.count)")
    }

    /// The gate itself. Short dictations must keep the single-pass behaviour that the measured
    /// quality corpus in `docs/knowledge/llm/criteria.md` was scored against — a seam in a
    /// one-sentence dictation is all cost and no benefit.
    func testShortTextIsNotSplit() {
        let short = String(repeating: "hello there. ", count: 4)
        XCTAssertLessThan(short.count, WholeTextSplitter.minimumSplitLength)
        XCTAssertEqual(WholeTextSplitter.split(short).count, 1)
    }

    /// Dictation frequently arrives as one unpunctuated run-on. If that came back as a single
    /// segment, the longest inputs — the ones with the most to gain — would never batch.
    func testRunOnWithoutPunctuationStillSplits() {
        let runOn = (0 ..< 120).map { "word\($0)" }.joined(separator: " ")
        XCTAssertGreaterThan(runOn.count, WholeTextSplitter.maximumSegmentLength)

        let segments = WholeTextSplitter.split(runOn)
        XCTAssertGreaterThan(segments.count, 1, "run-on did not split")
        XCTAssertEqual(words(segments.joined(separator: " ")), words(runOn))
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.count, WholeTextSplitter.maximumSegmentLength)
            // A cut inside a word is a spelling error the model will confidently "correct" into
            // a different word, so it must never happen — checked by round-tripping the tokens.
            for word in segment.split(separator: " ") {
                XCTAssertTrue(word.hasPrefix("word"), "split mid-word: \(word)")
            }
        }
    }

    /// Hebrew and Russian are 17% of the corpus and are the population a naive `.!?` regex mangles.
    /// `enumerateSubstrings(.bySentences)` is used precisely for this; the test pins that choice.
    func testNonLatinSplitsWithoutLoss() throws {
        let fixtures = (HistoryTestLoader.loadFixtures(maxCount: 300)
                        + HistoryTestLoader.loadLongestFixtures(maxCount: 60))
            .filter { $0.language == "he" || $0.language == "ru" }
            .filter { $0.transcript.count >= WholeTextSplitter.minimumSplitLength }
        try XCTSkipIf(fixtures.isEmpty, "no long he/ru transcripts in history")

        for fixture in fixtures {
            let segments = WholeTextSplitter.split(fixture.transcript)
            XCTAssertEqual(words(segments.joined(separator: " ")), words(fixture.transcript),
                           "words changed for \(fixture.language) \(fixture.id)")
        }
        print("checked \(fixtures.count) non-Latin transcripts")
    }

    // MARK: - 2. Segmented correction on long transcripts (model)

    /// The production gate for Phase 5b, measured against **serial correction of the same
    /// segments** rather than against the single whole-text call.
    ///
    /// The single call was the obvious baseline and it is the wrong one. `AIMode.correct` caps
    /// output at 256 tokens, so on a 12,000-character transcript the model stops a fifth of the way
    /// through; the app then either returns that fragment or falls back to the raw text. Both
    /// outcomes make the baseline *fast* — it is fast because it does almost nothing — so timing
    /// against it would reward truncation. It is still measured and printed, because "the path this
    /// replaces does not actually correct long dictation" is the finding that justifies the change.
    ///
    /// The gate is therefore: same segments, same prompts, same per-row budgets, batched versus one
    /// at a time. That isolates the batching win with output quality held fixed.
    func testSegmentedCorrectionBeatsSerialOnLongTranscripts() async throws {
        // Longest first: `loadFixtures` orders by distance from 20 s and never reaches the long
        // bucket, which is the only bucket this path changes anything for.
        let candidates = HistoryTestLoader.loadLongestFixtures(maxCount: 20)
            .filter { $0.durationBucket == "long" || $0.durationBucket == "very-long" }
            .filter { $0.transcript.count >= WholeTextSplitter.minimumSplitLength }
        // Transcripts whose *input* already loops are excluded, and this is not tidying up an
        // inconvenient result. The longest recording in the DB is 22,196 characters of which a
        // large tail is whisper hallucinating "it's okay, it's okay, …" ~40 times; the degeneration
        // guard collapses that to one clause, which is correct and which a word-retention metric
        // scores as 98% of the words lost. Correcting a hallucination loop is not the workload this
        // path is for, and leaving those rows in measures the guard rather than the batching.
        let looping = candidates.filter { TestLoopDetector.firstRepeat(in: $0.transcript) != nil }
        let fixtures = candidates
            .filter { TestLoopDetector.firstRepeat(in: $0.transcript) == nil }
            .prefix(5)
        print("\(candidates.count) long transcripts, \(looping.count) excluded for input loops")
        try XCTSkipIf(fixtures.isEmpty, "no long transcripts without input loops")

        try await withModel { processor in
            var rows: [String] = []
            var batchedTotal = 0.0
            var serialTotal = 0.0
            var singleTotal = 0.0
            var batchedRetentionSum = 0.0
            var serialRetentionSum = 0.0
            var singleRetentionSum = 0.0

            for fixture in fixtures {
                let text = fixture.transcript
                let inputWords = words(text).count
                let segments = WholeTextSplitter.split(text)
                let prompts = segments.map { correctPrompt(for: $0, fragment: true) }
                let instructions = prompts[0].system
                await processor.ensureWarmPrefix(for: instructions)

                let batchedStart = Date()
                let (batchedText, _) = await segmentedCorrect(text, processor: processor)
                let batchedSeconds = -batchedStart.timeIntervalSince(Date())

                let serialStart = Date()
                var serialSegments: [String] = []
                for (segment, prompt) in zip(segments, prompts) {
                    serialSegments.append((try? await processor.process(
                        text: segment, systemPrompt: prompt.system, userMessage: prompt.user,
                        repetitionPenalty: correctAIMode.repetitionPenalty,
                        maxTokensCap: correctAIMode.maxTokensCap)) ?? segment)
                }
                let serialText = ChunkLLMCoordinator
                    .repairSeams(corrected: serialSegments, raw: segments)
                    .filter { !$0.isEmpty }.joined(separator: " ")
                let serialSeconds = -serialStart.timeIntervalSince(Date())

                // The path being replaced, for reference only.
                let whole = correctPrompt(for: text, fragment: false)
                let singleStart = Date()
                let singleText = (try? await processor.process(
                    text: text, systemPrompt: whole.system, userMessage: whole.user,
                    repetitionPenalty: correctAIMode.repetitionPenalty,
                    maxTokensCap: correctAIMode.maxTokensCap)) ?? text
                let singleSeconds = -singleStart.timeIntervalSince(Date())

                let batchedRetention = Double(words(batchedText).count) / Double(inputWords)
                let serialRetention = Double(words(serialText).count) / Double(inputWords)
                let singleRetention = Double(words(singleText).count) / Double(inputWords)
                batchedTotal += batchedSeconds
                serialTotal += serialSeconds
                singleTotal += singleSeconds
                batchedRetentionSum += batchedRetention
                serialRetentionSum += serialRetention
                singleRetentionSum += singleRetention

                rows.append(String(format:
                    "  %5d chars %3d seg   batched %6.2fs/%3.0f%%   serial %6.2fs/%3.0f%%"
                    + "   single-pass %6.2fs/%3.0f%%",
                    text.count, segments.count,
                    batchedSeconds, batchedRetention * 100,
                    serialSeconds, serialRetention * 100,
                    singleSeconds, singleRetention * 100))

                XCTAssertFalse(batchedText.isEmpty, "segmented path returned nothing")
                // Held against the serial run of the *same* segments, so this is a claim about
                // batching alone: padding and per-row budgets must not eat the user's words.
                XCTAssertGreaterThan(batchedRetention, serialRetention - 0.05,
                                     "batching lost words the serial segmented path kept "
                                     + "for \(fixture.id)")
                // An absolute floor as well: a correction pass drops filler, but not a third of it.
                // Only meaningful because looping inputs are excluded above — with them in, this
                // number measures the degeneration guard.
                XCTAssertGreaterThan(batchedRetention, 0.85,
                                     "segmented path returned "
                                     + "\(Int(batchedRetention * 100))% of the words "
                                     + "in \(fixture.id)")
                // The input is loop-free by construction here, so a loop in the output is the
                // model's, and is a real defect.
                XCTAssertNil(TestLoopDetector.firstRepeat(in: batchedText),
                             "segmented output degenerated for \(fixture.id)")
            }

            let count = Double(fixtures.count)
            let speedup = serialTotal / max(batchedTotal, .ulpOfOne)
            print("""
                  whole-text segmented correction — \(fixtures.count) longest real recordings
                  \(rows.joined(separator: "\n"))
                  \(String(format: "  totals: batched %.1fs (%.0f%% words) · serial %.1fs "
                           + "(%.0f%% words) · single-pass %.1fs (%.0f%% words)",
                           batchedTotal, batchedRetentionSum / count * 100,
                           serialTotal, serialRetentionSum / count * 100,
                           singleTotal, singleRetentionSum / count * 100))
                  \(String(format: "  batching speedup over serial segments: %.2fx", speedup))
                  """)

            // The headline for this path. Below ~1.3× the seams are not worth it and the single
            // pass should keep the text; above it, segmenting is a straight win.
            XCTAssertGreaterThan(speedup, 1.3,
                                 "batched segments did not beat serial segments")
        }
    }
}
