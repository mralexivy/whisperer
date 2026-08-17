//
//  BatchMemoryPlanner.swift
//  Whisperer
//
//  Decides how wide a batch may be, and how much of a prefill may be in flight at once, from
//  measured memory constants rather than from a constant somebody liked the look of.
//
//  This exists because the first wide-batch benchmark took the machine down. At B=64 with a
//  256-token prompt the prefill materialises a `[64, 256, 248320]` logits tensor — 8.1 GB — of
//  which exactly 64 rows are ever read. MLX peak memory hit 19.5 GB on a 32 GB machine and the
//  load average hit 64. Nothing in the code was wrong; nothing in the code was bounded either.
//
//  Every constant below is measured on the shipping model (Qwen3.5-4B MTP, 4-bit affine,
//  group_size 64) on an M2 Pro / 32 GB / macOS 26.2, from `probeRawStepCost` and the throughput
//  sweep in `BatchedLLMRemeasureTests`. They are model-specific, which is why `forQwen35_4B` is a
//  named factory rather than the type's only possible state — a different model needs its own
//  measurement, not a fudge factor.
//
//  Three costs, and they scale differently. Getting the shapes right matters more than the
//  constants' precision:
//
//  1. **Model weights** — fixed, ~2340 MB. Paid once, shared by every row, and the whole point of
//     batching: one instance, reused.
//  2. **Per-row recurrent state** — ~33.5 MB per row, *independent of sequence length*. This is the
//     GatedDeltaNet conv + SSM state across the 24 linear-attention layers, not KV. It is the
//     dominant per-row term and the reason batch width is bounded at all.
//  3. **Per-row-per-token KV** — ~32 KB, for the 8 full-attention layers only
//     (2 × 4 kv-heads × 256 head_dim × 2 B bf16 × 8 layers = 32,768 B). Small until sequences get
//     long, and it grows *during* generation, so it must be budgeted against the output cap and
//     not just the prompt.
//  4. **Prefill activations** — ~0.85 MB per prefilled position, transient. This term used to be
//     twice as large and dominate everything, because a prefill projected *every* position to the
//     248320-wide vocabulary to read one of them: that is the allocation that killed the machine.
//     `SelectivePrefillModel` (Vendor/mlx-swift-lm/.../BatchGenerate.swift) removed it, which is
//     why the coefficient here is now the layer activations alone.
//
//  The planner's job is to keep (1)+(2)+(3)+(4) under a ceiling derived from what the machine
//  actually has free right now, and to say plainly when it had to clamp.
//

import Darwin
import Foundation
import MLX

/// What the planner decided, and why. `clampReason` is non-nil whenever the caller did not get
/// what it asked for — callers log it rather than silently running narrower than intended.
struct BatchMemoryPlan: Equatable {
    /// Rows to run concurrently. Always ≥ 1: a batch of one still has to be possible, because the
    /// alternative to a too-expensive batch is a serial pass, not a failure.
    let rows: Int
    /// Positions (`rows × promptTokens`) allowed in a single prefill pass. `generateBatchTokens`
    /// derives its row-group size from this, so a long prompt automatically gets narrower groups.
    let prefillPositionBudget: Int
    /// Steady-state resident cost of the batch: weights + per-row state + KV at full output length.
    let projectedResidentMB: Double
    /// `projectedResidentMB` plus the largest transient prefill allocation. The number that has to
    /// fit.
    let projectedPeakMB: Double
    /// Rows the prefill will run at once, derived from `prefillPositionBudget`. Reported rather
    /// than inferred because splitting the prefill is *normal operation*, not a clamp — conflating
    /// the two made every healthy wide batch look like a degraded one.
    let prefillGroupRows: Int
    /// The bound `projectedPeakMB` was fitted under.
    let ceilingMB: Double
    /// Nil when the requested width was granted in full. Set only when rows were taken away.
    let clampReason: String?
    /// True when even a single row cannot fit under the ceiling. The fixed costs — weights plus
    /// the one-off warm-prefix prefill — do not shrink with batch width, so on a machine this
    /// tight the answer is "not with this model", and the caller needs to hear that rather than
    /// receive a one-row plan that will also fail.
    let exceedsCeiling: Bool

    var wasClamped: Bool { clampReason != nil }
}

/// Memory model for one LLM variant, plus the arithmetic that turns it into a batch plan.
///
/// A value type with injectable constants so the tests can drive it with synthetic ceilings —
/// asserting a guardrail by allocating 30 GB to see whether it trips is not a test anyone can run.
struct BatchMemoryPlanner {

    // MARK: - Measured constants

    /// Resident cost of the loaded weights, before any batch. Measured: MLX active memory settles
    /// at 2341 MB after load and returns to it after every batch drains.
    let modelBaseMB: Double

    /// Resident cost that appears once the first generation has run and never goes away: the warm
    /// system-prefix cache, the specialised Metal graphs, and the allocator's own floor. Measured
    /// as the gap between post-load resident (2341 MB) and the settled resident before a batch
    /// starts (2728 MB) in `probeMemoryStages`.
    let fixedRuntimeMB: Double

    /// Per-row cost that does not depend on sequence length — the GatedDeltaNet conv and SSM state
    /// over the 24 linear-attention layers.
    ///
    /// Measured by differencing resident memory across widths on the real batched path with a
    /// warm 881-token prefix: 2790 MB at B=1, 3220 at B=8, 4696 at B=32 — a clean 61.5 MB per row,
    /// of which the KV term below accounts for ~30 MB at that sequence length, leaving ~32 MB of
    /// length-independent state.
    ///
    /// An earlier value of 33.5 MB came from the raw-kernel probe, which used a 16-token prompt
    /// and fresh caches; it was the same constant measured where the KV term was nearly zero, and
    /// using it here double-counted nothing but under-counted the whole per-row cost by half.
    let perRowStateMB: Double

    /// KV bytes per token per row, for the 8 full-attention layers.
    /// 2 (K+V) × 4 kv-heads × 256 head_dim × 2 B (bf16) × 8 layers = 32,768 B.
    let perRowTokenKVBytes: Double

    /// Transient memory per prefilled *position*, in MB, regardless of how those positions are
    /// distributed across rows.
    ///
    /// Measured at 1.72 MB when a prefill projected every position to vocabulary: one fp32 logits
    /// row (248320 × 4 B = 0.95 MB) plus ~0.77 MB of layer activations. `SelectivePrefillModel`
    /// removed the logits row — `lm_head` now runs at one position per row — and re-measuring gave
    /// 0.81 MB/position on the 881-token warm prefill and 0.76 at B=32, i.e. the activations alone,
    /// as predicted.
    ///
    /// 0.85 rather than the larger of the two: it over-projects every measured stage (B=1, B=8,
    /// B=32 and the warm prefill) once the safety factor is applied, and over-projection is the
    /// safe direction for a guardrail.
    ///
    /// Position count is the right unit — the same coefficient fits at every width.
    let prefillMBPerPosition: Double

    /// Vocabulary width. Retained for reporting the logits term explicitly; the projection uses
    /// `prefillMBPerPosition`, which already contains it.
    let vocabularySize: Int

    /// Multiplier on the whole projection, covering allocator granularity and the fact that two
    /// stages' allocations can briefly overlap. 1.15 is the smallest value that keeps every
    /// measured width under its projection in `testMemoryModelMatchesMeasuredPeak`; it is a
    /// stated margin, not a fudge that hides a wrong term.
    let safetyFactor: Double

    /// Fraction of the *remaining* headroom the transient prefill allocation may occupy.
    ///
    /// Held below 1 so a prefill spike cannot consume headroom the resident batch is about to
    /// need. 0.5 rather than something tighter because the measurements showed the cache merge,
    /// not the prefill, is what binds at wide batches; squeezing the prefill further shrinks
    /// groups — and slows prefill — without lowering the peak it was meant to lower.
    let prefillHeadroomFraction: Double

    /// Cap on the ceiling as a fraction of physical RAM, applied even when the machine reports
    /// plenty free. Free memory on macOS includes pages the OS will happily reclaim from other
    /// processes; spending all of it is how a benchmark becomes a system hang.
    let physicalMemoryFraction: Double

    /// The shipping configuration. Constants measured on Qwen3.5-4B MTP, M2 Pro / 32 GB /
    /// macOS 26.2, by `probeMemoryStages` — see the file header.
    static let forQwen35_4B = BatchMemoryPlanner(
        modelBaseMB: 2340,
        fixedRuntimeMB: 400,
        perRowStateMB: 32,
        perRowTokenKVBytes: 32_768,
        prefillMBPerPosition: 0.85,
        vocabularySize: 248_320,
        safetyFactor: 1.15,
        prefillHeadroomFraction: 0.5,
        physicalMemoryFraction: 0.45)

    // MARK: - Planning

    /// Largest safe plan not exceeding `requestedRows`.
    ///
    /// - Parameters:
    ///   - requestedRows: how many rows the caller would like. Never exceeded.
    ///   - systemPrefixTokens: the shared warm prefix. It is prefilled once at batch 1 and
    ///     broadcast, so it costs KV on every row but contributes *nothing* to the batched
    ///     prefill's logits — which is the whole reason the warm cache exists.
    ///   - suffixTokens: padded per-row suffix length, i.e. the *longest* user message in the
    ///     batch, since right-padding makes every row that long. This is what the batched prefill
    ///     actually runs, so it is the multiplier on the logits tensor.
    ///   - maxOutputTokens: per-row output cap, so KV growth during generation is budgeted up
    ///     front rather than discovered at token 200.
    ///   - ceilingMB: the bound to fit under. Defaults to `currentCeilingMB()`.
    func plan(
        requestedRows: Int,
        systemPrefixTokens: Int,
        suffixTokens: Int,
        maxOutputTokens: Int,
        ceilingMB: Double? = nil
    ) -> BatchMemoryPlan {
        let ceiling = ceilingMB ?? currentCeilingMB()
        let requested = max(1, requestedRows)
        let promptTokens = max(1, suffixTokens)
        // KV covers the whole sequence each row will ever hold: shared prefix, its own suffix, and
        // everything it is allowed to generate.
        let sequenceTokens = max(0, systemPrefixTokens) + promptTokens + max(0, maxOutputTokens)
        let perRowMB = perRowStateMB + Double(sequenceTokens) * perRowTokenKVBytes / 1_048_576
        let floorMB = modelBaseMB + fixedRuntimeMB

        // The warm prefix is prefilled once at batch 1 before any row exists. It is width-
        // independent, and at an 881-token `Correct` prompt it is the single largest peak in the
        // whole run — larger than the batched prefill at B=8. A planner that ignored it
        // under-projected by 1.4 GB at every width, which is exactly the direction that gets a
        // machine killed.
        let warmPeak = (floorMB + Double(max(0, systemPrefixTokens)) * prefillMBPerPosition)
            * safetyFactor

        // Rows the ceiling can hold once the fixed costs are paid. Floor of 1: a single row is not
        // optional, and if even that does not fit the caller is told through `exceedsCeiling`
        // rather than handed a zero.
        func affordableRows(perRowCostMB: Double) -> Int {
            max(1, Int((ceiling / safetyFactor - floorMB) / max(perRowCostMB, .ulpOfOne)))
        }
        func groupRows(for rows: Int) -> (rows: Int, budget: Int, resident: Double) {
            let resident = floorMB + Double(rows) * perRowMB
            // What is left for the transient prefill tensor, held to a fraction of the headroom.
            let headroomMB = max(0, ceiling / safetyFactor - resident) * prefillHeadroomFraction
            // At least one row's worth of positions, or a prompt longer than the headroom could
            // never be prefilled at all.
            let budget = max(promptTokens,
                             Int(headroomMB / max(prefillMBPerPosition, .ulpOfOne)))
            return (max(1, min(rows, budget / promptTokens)), budget, resident)
        }

        // Two passes, because the cost per row depends on whether the prefill ends up grouped: a
        // grouped prefill pays for the cache twice at merge time, an ungrouped one never merges.
        // Sizing against the cheaper figure and then discovering grouping was needed is how the
        // first version projected 6.0 GB for a batch that used 8.7 GB.
        var rows = min(requested, affordableRows(perRowCostMB: perRowMB))
        var group = groupRows(for: rows)
        if group.rows < rows {
            rows = min(rows, affordableRows(perRowCostMB: 2 * perRowMB))
            group = groupRows(for: rows)
        }
        let resident = group.resident
        let budget = group.budget
        let groupRows = group.rows
        let prefillPeak = (resident + Double(groupRows * promptTokens) * prefillMBPerPosition)
            * safetyFactor

        // Merging the per-group caches into one batch cache concatenates along the row axis, so
        // for the duration of the concatenation both the group caches and their combined copy are
        // resident. At B=32 that is ~2 GB held twice, and it is the single largest term at wide
        // batches — bigger than the prefill the position budget was written to bound. Splitting
        // the prefill into more groups does not reduce it, which is why it has to be modelled
        // separately rather than folded into `prefillPeak`.
        let mergePeak = groupRows < rows
            ? (floorMB + 2 * Double(rows) * perRowMB) * safetyFactor
            : 0

        // The stages do not coexist — the warm prefill is freed before the first group runs, and
        // the groups are merged after the last one — so the run's high-water mark is the largest
        // of the three, not their sum.
        let peak = max(warmPeak, max(prefillPeak, mergePeak))

        var reason: String?
        if rows < requested {
            reason = "batch clamped \(requested)→\(rows) rows: "
                + String(format: "%.0f MB/row against a %.0f MB ceiling", perRowMB, ceiling)
        }

        return BatchMemoryPlan(
            rows: rows,
            prefillPositionBudget: budget,
            projectedResidentMB: resident * safetyFactor,
            projectedPeakMB: peak,
            prefillGroupRows: groupRows,
            ceilingMB: ceiling,
            clampReason: reason,
            exceedsCeiling: peak > ceiling)
    }

    /// Projected peak for a plan that is *not* being clamped — used by the tests to check the model
    /// against what MLX actually reports, which is the only thing that keeps these constants honest.
    func projectedPeakMB(
        rows: Int, systemPrefixTokens: Int, suffixTokens: Int, maxOutputTokens: Int
    ) -> Double {
        plan(requestedRows: rows, systemPrefixTokens: systemPrefixTokens,
             suffixTokens: suffixTokens, maxOutputTokens: maxOutputTokens,
             ceilingMB: .greatestFiniteMagnitude).projectedPeakMB
    }

    // MARK: - Backstop

    /// Installs MLX's own allocator limits around a planned batch, and returns a closure that puts
    /// them back.
    ///
    /// The planner's arithmetic is a *prediction*, and a prediction that is wrong by 3× is exactly
    /// how the 19.5 GB spike happened. `Memory.memoryLimit` is the allocator's hard backstop: past
    /// it, `malloc` waits on scheduled work instead of taking the page. MLX defaults it to 1.5× the
    /// device's recommended working set — about 30 GB on a 32 GB Mac, which is to say no bound at
    /// all for this purpose.
    ///
    /// The limit is set above the projected peak rather than at it, deliberately. At exactly the
    /// peak, one underestimated intermediate makes every allocation wait on work that cannot
    /// complete without allocating; a headroom band turns "hang" into "slower than planned, and the
    /// projection was wrong" — which the tests can then catch and report.
    @discardableResult
    static func installLimits(for plan: BatchMemoryPlan, headroomMB: Double = 1024) -> () -> Void {
        let previousMemoryLimit = Memory.memoryLimit
        let previousCacheLimit = Memory.cacheLimit
        Memory.memoryLimit = Int((plan.projectedPeakMB + headroomMB) * 1_048_576)
        // The cache is reclaimable, but it counts toward the peak while it is held. Bounding it to
        // a slice of the batch's own headroom keeps a long run of batches from drifting upward.
        Memory.cacheLimit = Int(headroomMB / 2 * 1_048_576)
        return {
            Memory.memoryLimit = previousMemoryLimit
            Memory.cacheLimit = previousCacheLimit
        }
    }

    // MARK: - What the machine has

    /// The ceiling to plan under: the smaller of a fixed fraction of physical RAM and a fraction of
    /// what is free right now.
    ///
    /// Both terms are needed. The physical-RAM fraction stops a big batch on a machine that happens
    /// to be idle from squeezing every other app onto swap. The free-memory term stops the same
    /// batch when the machine is already loaded — which is exactly the state the failing run was in.
    func currentCeilingMB() -> Double {
        let physicalMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        let byPhysical = physicalMB * physicalMemoryFraction
        guard let freeMB = Self.availableMemoryMB() else { return byPhysical }
        // The weights are already resident, so they are not part of "free" and must be added back
        // before comparing against a ceiling that includes them.
        return min(byPhysical, freeMB * 0.7 + modelBaseMB)
    }

    /// Free + inactive + purgeable pages, in MB. Nil when the Mach call fails, in which case the
    /// caller falls back to the physical-RAM fraction alone.
    ///
    /// Inactive and purgeable count as available because the VM will reclaim them under pressure
    /// without swapping; counting only `free_count` would under-report by many GB on a machine that
    /// has been up for a while, and clamp every batch to 1.
    static func availableMemoryMB() -> Double? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = Double(vm_kernel_page_size)
        let pages = Double(stats.free_count) + Double(stats.inactive_count)
            + Double(stats.purgeable_count)
        return pages * pageSize / 1_048_576
    }
}
