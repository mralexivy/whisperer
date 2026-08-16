//
//  BatchedLLMGuardrailTests.swift
//  WhispererTests
//
//  The memory half of the batched-decode validation. Throughput is measured elsewhere; this file
//  answers the other three questions that have to be answered before any of it ships:
//
//  1. **Can it blow up the machine again?** The first wide-batch run allocated 19.5 GB on a 32 GB
//     Mac and took the system down. `BatchMemoryPlanner` is the fix, and a guardrail that is not
//     tested is a comment.
//  2. **Is it one model instance, or several?** Batching is only cheap because 2.34 GB of weights
//     are paid for once and shared by every row. A second `ModelContainer` would silently double
//     the floor.
//  3. **Does memory come back?** A leak of a few MB per batch does not show up in a single
//     measurement and does show up after an hour of dictation.
//
//  The arithmetic tests need no model and run in milliseconds. The measured tests load the real
//  4B model and skip when it is absent, like every other model test here.
//
//  Must not run concurrently with any other model test — several GB of weights co-resident
//  thrashes unified memory and corrupts the very numbers being collected.
//

import Darwin
import MLX
import MLXLLM
import XCTest
@testable import whisperer

@MainActor
final class BatchedLLMGuardrailTests: XCTestCase {

    private let variant: LLMModelVariant = .qwen3_5_4B_mtp
    private let planner = BatchMemoryPlanner.forQwen35_4B

    // MARK: - 1. The arithmetic, with no model in the way

    /// A ceiling that cannot hold the requested width must produce a narrower batch, not a bigger
    /// allocation and a promise. The three cases are the three regimes: comfortable, tight, and
    /// smaller than the model itself.
    func testPlannerClampsToCeiling() {
        // Comfortable: 16 rows of a typical chunk against 12 GB. Nothing should be clamped.
        let roomy = planner.plan(requestedRows: 16, systemPrefixTokens: 800, suffixTokens: 64,
                                 maxOutputTokens: 256, ceilingMB: 12_000)
        XCTAssertEqual(roomy.rows, 16)
        XCTAssertNil(roomy.clampReason, "16 rows fit in 12 GB and should not have been clamped")
        XCTAssertLessThanOrEqual(roomy.projectedPeakMB, 12_000)

        // Tight: the same request against a ceiling that can hold the fixed costs and a handful of
        // rows, but nowhere near 64.
        let tight = planner.plan(requestedRows: 64, systemPrefixTokens: 800, suffixTokens: 64,
                                 maxOutputTokens: 256, ceilingMB: 6_000)
        XCTAssertLessThan(tight.rows, 64, "a 6 GB ceiling cannot hold 64 rows")
        XCTAssertNotNil(tight.clampReason)
        XCTAssertFalse(tight.exceedsCeiling)
        XCTAssertLessThanOrEqual(tight.projectedPeakMB, 6_000,
                                 "clamped plan still projects over its own ceiling")

        // Impossible: a ceiling below the fixed costs. The fixed costs do not shrink with width,
        // so the honest answer is one row *and* `exceedsCeiling` — the caller's fallback is a
        // serial pass on a smaller model, and it cannot make that decision from a zero or from a
        // one-row plan that quietly will not fit either.
        let impossible = planner.plan(requestedRows: 32, systemPrefixTokens: 800, suffixTokens: 64,
                                      maxOutputTokens: 256, ceilingMB: 1_000)
        XCTAssertEqual(impossible.rows, 1, "the planner must never return a zero-row batch")
        XCTAssertTrue(impossible.exceedsCeiling,
                      "a 1 GB ceiling cannot hold 2.3 GB of weights and the planner said nothing")
    }

    /// The allocation that actually caused the crash. At B=64 with a 256-token prompt the naive
    /// prefill is `64 × 256 × 248320 × 2 B` = 8.1 GB in one tensor. The budget exists to stop
    /// exactly that, and this asserts the number rather than the intent.
    func testPrefillBudgetBoundsTheLogitsTensor() {
        let plan = planner.plan(requestedRows: 64, systemPrefixTokens: 800, suffixTokens: 256,
                                maxOutputTokens: 256, ceilingMB: 12_000)
        let groupRows = plan.prefillGroupRows
        let logitsGB = Double(groupRows) * 256 * 248_320 * 2 / 1_073_741_824
        let naiveGB = Double(plan.rows) * 256 * 248_320 * 2 / 1_073_741_824

        XCTAssertLessThan(logitsGB, 2.5,
                          String(format: "grouped prefill still allocates %.1f GB at once", logitsGB))
        XCTAssertGreaterThan(naiveGB, logitsGB,
                             "the budget did not actually split anything — the test is not testing")
        print(String(format: "prefill logits: naive %.1f GB → grouped %.1f GB "
                     + "(%d rows in groups of %d)", naiveGB, logitsGB, plan.rows, groupRows))
    }

    /// A long prompt must narrow the group by itself. This is why the knob counts *positions* and
    /// not rows: at a fixed 8-row group, a 4× longer prompt is a 4× larger allocation and the
    /// guardrail quietly stops guarding.
    func testLongPromptNarrowsTheGroupAutomatically() {
        let short = planner.plan(requestedRows: 32, systemPrefixTokens: 800, suffixTokens: 64,
                                 maxOutputTokens: 256, ceilingMB: 12_000)
        let long = planner.plan(requestedRows: 32, systemPrefixTokens: 800, suffixTokens: 1024,
                                maxOutputTokens: 256, ceilingMB: 12_000)
        let shortGroup = short.prefillGroupRows
        let longGroup = long.prefillGroupRows

        XCTAssertLessThan(longGroup, shortGroup,
                          "a 16× longer prompt did not narrow the prefill group")
        // The product is what is bounded, so the two allocations should be within a small factor
        // of each other even though the shapes are nothing alike.
        let shortPositions = Double(shortGroup * 64)
        let longPositions = Double(longGroup * 1024)
        XCTAssertLessThan(max(shortPositions, longPositions) / min(shortPositions, longPositions), 2.5,
                          "the position budget is not holding the allocation roughly constant")
    }

    /// The default ceiling has to be a number this machine can actually honour. Both terms are
    /// checked: it must leave most of RAM alone, and it must be big enough to run a batch at all.
    func testDefaultCeilingIsSaneOnThisMachine() {
        let physicalMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        let ceiling = planner.currentCeilingMB()
        let available = BatchMemoryPlanner.availableMemoryMB()

        XCTAssertGreaterThan(ceiling, planner.modelBaseMB,
                             "the ceiling is below the model's own weights — nothing could run")
        XCTAssertLessThan(ceiling, physicalMB * 0.5,
                          "the ceiling would let one batch claim half the machine")
        print(String(format: "ceiling %.0f MB of %.0f MB physical (%.0f MB reported available)",
                     ceiling, physicalMB, available ?? -1))
    }

    // MARK: - 2. The model matches reality

    /// The constants are measurements, and a measurement that is never re-checked becomes folklore.
    /// This runs real batches at four widths and compares MLX's own peak against the projection.
    ///
    /// The assertion is deliberately one-sided plus a loose upper bound. Under-projecting is the
    /// dangerous direction — that is what lets a batch exceed the ceiling — so it fails hard.
    /// Over-projecting only costs throughput, so it is allowed a wide band before it is called a
    /// regression; the number is printed either way.
    func testMemoryModelMatchesMeasuredPeak() async throws {
        let corpus = try loadCorpus()
        let pool = realChunkTexts(count: 64, corpus: corpus)
        try XCTSkipIf(pool.count < 16, "corpus has only \(pool.count) usable chunks")

        try await withModel { processor in
            var lines = ["\n=== Memory model vs measured ===", machineConditions()]
            lines.append("   B   projected_MB   measured_peak_MB   ratio   active_after_MB")

            for width in [1, 4, 16, 32] {
                let texts = (0 ..< width).map { pool[$0 % pool.count] }
                let group = rows(for: texts)
                let shape = try await measurePromptShape(processor, rows: group)
                let plan = planner.plan(
                    requestedRows: width, systemPrefixTokens: shape.systemPrefixTokens,
                    suffixTokens: shape.maxSuffixTokens, maxOutputTokens: 128)
                XCTAssertEqual(plan.rows, width,
                               "the planner refused a width this test needs: \(plan.clampReason ?? "")")

                // Reset the high-water mark so the number belongs to this batch and not to
                // whatever the previous width did.
                Memory.clearCache()
                Memory.peakMemory = 0
                _ = try await runBatchedGeneration(
                    processor, rows: group, maxTokens: 128, warmPrefix: true,
                    prefillPositionBudget: plan.prefillPositionBudget)
                let measuredPeak = Double(Memory.peakMemory) / 1_048_576
                let activeAfter = Double(Memory.activeMemory) / 1_048_576

                lines.append(String(format: "%4d  %13.0f  %17.0f  %6.2f  %16.0f",
                                    width, plan.projectedPeakMB, measuredPeak,
                                    measuredPeak / max(plan.projectedPeakMB, 1), activeAfter))

                XCTAssertLessThanOrEqual(
                    measuredPeak, plan.projectedPeakMB * 1.15,
                    "B=\(width) used more than the planner projected — the guardrail under-counts, "
                    + "which is the failure mode that took the machine down")
            }
            print(lines.joined(separator: "\n") + "\n")
        }
    }

    /// Where the peak actually goes, stage by stage.
    ///
    /// The first version of `BatchMemoryPlanner` under-projected by a near-constant ~1.4 GB at
    /// every width, which is the signature of a missing fixed term rather than a wrong per-row
    /// coefficient. Fitting a constant to close that gap would have produced a number that happened
    /// to work on this machine; this test attributes it instead, so the term that gets added is one
    /// that scales with something real.
    ///
    /// Reports. The assertions in `testMemoryModelMatchesMeasuredPeak` are the gate.
    func testMemoryStageBreakdown() async throws {
        let corpus = try loadCorpus()
        let pool = realChunkTexts(count: 32, corpus: corpus)
        try XCTSkipIf(pool.count < 8, "corpus has only \(pool.count) usable chunks")

        try await withModel { processor in
            var lines = ["\n=== Where the peak goes ===", machineConditions()]
            for width in [1, 8, 32] {
                let texts = (0 ..< width).map { pool[$0 % pool.count] }
                let probe = try await probeMemoryStages(processor, texts: texts, steps: 16)
                let logitsMB = Double(planner.vocabularySize) * 4 / 1_048_576
                lines.append(String(
                    format: "\n-- B=%d, prefix %d tok, suffix %d tok (one row of logits at fp32 "
                    + "= %.0f MB, whole prefix = %.0f MB) --",
                    width, probe.prefixTokens, probe.maxSuffixTokens, logitsMB,
                    logitsMB * Double(probe.prefixTokens)))
                lines.append("  stage           peak_MB   active_MB")
                for stage in probe.stages {
                    lines.append(String(format: "  %-14@  %8.0f  %10.0f",
                                        stage.name as NSString, stage.peakMB, stage.activeMB))
                }
            }
            print(lines.joined(separator: "\n") + "\n")
        }
    }

    /// The whole point of the guardrail: ask for a width the machine cannot hold and get a narrower
    /// batch that completes, rather than a spike.
    ///
    /// The ceiling is injected rather than real, because the honest version of this test — request
    /// enough rows to actually exhaust 32 GB — is the crash it is meant to prevent.
    func testAnUnaffordableRequestIsClampedAndStillRuns() async throws {
        let corpus = try loadCorpus()
        let pool = realChunkTexts(count: 16, corpus: corpus)
        try XCTSkipIf(pool.count < 4, "corpus has only \(pool.count) usable chunks")

        try await withModel { processor in
            let group = rows(for: Array(pool.prefix(8)))
            let shape = try await measurePromptShape(processor, rows: group)
            // Just above the weights: enough for a couple of rows, nowhere near eight.
            let plan = planner.plan(
                requestedRows: 128, systemPrefixTokens: shape.systemPrefixTokens,
                suffixTokens: shape.maxSuffixTokens, maxOutputTokens: 128,
                ceilingMB: planner.modelBaseMB + 200)

            XCTAssertLessThan(plan.rows, 128)
            XCTAssertNotNil(plan.clampReason)
            print("clamped: \(plan.clampReason ?? "")")

            Memory.clearCache()
            Memory.peakMemory = 0
            let run = try await runBatchedGeneration(
                processor, rows: Array(group.prefix(plan.rows)), maxTokens: 64, warmPrefix: true,
                prefillPositionBudget: plan.prefillPositionBudget)
            let peak = Double(Memory.peakMemory) / 1_048_576

            XCTAssertEqual(run.texts.count, plan.rows, "the clamped batch did not complete")
            XCTAssertFalse(run.texts.contains { $0.isEmpty }, "a clamped row produced no text")
            print(String(format: "clamped batch of %d ran to completion, peak %.0f MB",
                         plan.rows, peak))
        }
    }

    // MARK: - 3. One instance, and it comes back

    /// Batching's economics rest on the weights being paid for once. Two containers would double a
    /// 2.34 GB floor and nobody would notice until an 18 GB machine started swapping.
    func testModelIsASingleReusedInstance() async throws {
        let corpus = try loadCorpus()
        let pool = realChunkTexts(count: 16, corpus: corpus)
        try XCTSkipIf(pool.count < 4, "corpus has only \(pool.count) usable chunks")

        try await withModel { processor in
            guard let first = processor.modelContainer else {
                return XCTFail("no container after load")
            }
            let afterLoad = Double(Memory.activeMemory) / 1_048_576

            // A redundant load is a real code path: `AppState` calls `loadModel` on settings
            // changes, and the early-return on `loadedVariant == variant` is what keeps it from
            // allocating a second copy.
            try await processor.loadModel(variant)
            XCTAssertTrue(processor.modelContainer === first,
                          "loading the same variant twice replaced the container")

            let group = rows(for: Array(pool.prefix(8)))
            for _ in 0 ..< 3 {
                _ = try await runBatchedGeneration(
                    processor, rows: group, maxTokens: 48, warmPrefix: true)
                XCTAssertTrue(processor.modelContainer === first,
                              "a batch swapped the container out from under the app")
            }

            Memory.clearCache()
            let afterBatches = Double(Memory.activeMemory) / 1_048_576
            XCTAssertLessThan(afterBatches, afterLoad + 500,
                              String(format: "resident grew %.0f → %.0f MB across three batches "
                                     + "— a second copy of the weights would look like this",
                                     afterLoad, afterBatches))
            print(String(format: "single instance: %.0f MB after load, %.0f MB after 3 batches",
                         afterLoad, afterBatches))
        }
    }

    /// A per-batch leak is invisible in one measurement and fatal over an hour of dictation. Twelve
    /// batches is enough for a linear leak to clear the noise floor, and the trend is checked
    /// rather than just the endpoints — one high sample near the end would otherwise pass.
    func testMemoryReturnsToBaselineAcrossManyBatches() async throws {
        let corpus = try loadCorpus()
        let pool = realChunkTexts(count: 64, corpus: corpus)
        try XCTSkipIf(pool.count < 16, "corpus has only \(pool.count) usable chunks")

        try await withModel { processor in
            let batches = 12
            let width = 8
            var actives: [Double] = []

            // One warm-up batch first: the first run of any width allocates its Metal graph and
            // its cache blocks, and counting that as growth would fail every clean run.
            _ = try await runBatchedGeneration(
                processor, rows: rows(for: Array(pool.prefix(width))),
                maxTokens: 48, warmPrefix: true)
            Memory.clearCache()
            let baseline = Double(Memory.activeMemory) / 1_048_576
            Memory.peakMemory = 0

            for index in 0 ..< batches {
                let start = (index * width) % max(pool.count - width, 1)
                let texts = (0 ..< width).map { pool[(start + $0) % pool.count] }
                _ = try await runBatchedGeneration(
                    processor, rows: rows(for: texts), maxTokens: 64, warmPrefix: true)
                Memory.clearCache()
                actives.append(Double(Memory.activeMemory) / 1_048_576)
            }

            let peak = Double(Memory.peakMemory) / 1_048_576
            let firstHalf = actives.prefix(batches / 2).reduce(0, +) / Double(batches / 2)
            let secondHalf = actives.suffix(batches / 2).reduce(0, +) / Double(batches / 2)
            let drift = actives.last! - baseline

            print(String(format: "%d batches of %d: baseline %.0f MB, final %.0f MB, "
                         + "drift %+.0f MB, halves %.0f → %.0f MB, peak %.0f MB",
                         batches, width, baseline, actives.last!, drift,
                         firstHalf, secondHalf, peak))

            // 150 MB over twelve batches is roughly one row's recurrent state — well inside
            // allocator noise, and far below the ~30 MB/batch a real per-batch leak would show.
            XCTAssertLessThan(drift, 150,
                              String(format: "resident drifted %+.0f MB across %d batches",
                                     drift, batches))
            XCTAssertLessThan(secondHalf - firstHalf, 100,
                              "resident memory is trending upward batch over batch")
            XCTAssertLessThan(peak, planner.currentCeilingMB(),
                              String(format: "peak %.0f MB exceeded the planner's own ceiling",
                                     peak))
        }
    }

    /// `installLimits` is the backstop under the projection. This checks it is actually installed,
    /// is above the projection rather than at it, and is fully restored afterwards — a leaked
    /// `Memory.memoryLimit` would throttle every later generation in the process.
    func testInstalledLimitsBoundAndRestore() {
        let before = (memory: Memory.memoryLimit, cache: Memory.cacheLimit)
        let plan = planner.plan(requestedRows: 16, systemPrefixTokens: 800, suffixTokens: 128,
                                maxOutputTokens: 256, ceilingMB: 12_000)

        let restore = BatchMemoryPlanner.installLimits(for: plan)
        let installed = Double(Memory.memoryLimit) / 1_048_576
        XCTAssertGreaterThan(installed, plan.projectedPeakMB,
                             "the limit sits at or below the projection — one bad estimate hangs")
        XCTAssertLessThan(installed, plan.projectedPeakMB + 2_048,
                          "the limit is so far above the projection it bounds nothing")

        restore()
        XCTAssertEqual(Memory.memoryLimit, before.memory, "memoryLimit was not restored")
        XCTAssertEqual(Memory.cacheLimit, before.cache, "cacheLimit was not restored")
    }

    // MARK: - Fixtures

    private func withModel(_ body: (LLMPostProcessor) async throws -> Void) async throws {
        let processor = LLMPostProcessor()
        do {
            try await processor.loadModel(variant)
        } catch {
            throw XCTSkip("cannot load \(variant.rawValue): \(error.localizedDescription)")
        }
        do { try await body(processor) } catch {
            await processor.unloadModel()
            throw error
        }
        await processor.unloadModel()
    }

    private func rows(for texts: [String]) -> [(system: String, user: String)] {
        texts.map { correctPrompt(for: $0, fragment: true) }
    }

    private func loadCorpus() throws -> ChunkStreamCorpus {
        guard let corpus = ChunkStreamCorpus.loadPersisted(), !corpus.streams.isEmpty else {
            throw XCTSkip("No frozen chunk corpus — run testChunkArrivalCharacterisation first")
        }
        return corpus
    }

    private func machineConditions() -> String {
        var loads = [Double](repeating: 0, count: 3)
        let load = getloadavg(&loads, 3) == 3
            ? String(format: "load %.2f %.2f %.2f", loads[0], loads[1], loads[2])
            : "load unavailable"
        return String(format: "conditions: %@, active %.0f MB, cache %.0f MB, available %.0f MB",
                      load,
                      Double(Memory.activeMemory) / 1_048_576,
                      Double(Memory.cacheMemory) / 1_048_576,
                      BatchMemoryPlanner.availableMemoryMB() ?? -1)
    }
}
