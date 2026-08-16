//
//  BatchedLLMSchedulerTests.swift
//  WhispererTests
//
//  The scheduler is the one piece of this feature that needs no model to test, so it is tested
//  exhaustively rather than sampled: fake runners, deterministic, sub-second. Everything asserted
//  here is a way the scheduler could strand a continuation, and a stranded continuation does not
//  fail loudly — it hangs the drain at key release and the user's text never arrives.
//

import XCTest
@testable import whisperer

@MainActor
final class BatchedLLMSchedulerTests: XCTestCase {

    /// Records what the runners were asked to do, so the tests can assert on batch shape rather
    /// than only on results.
    private final class RunnerLog {
        var batchWidths: [Int] = []
        var singleCalls = 0
    }

    private func request(_ text: String) -> LLMBatchRequest {
        LLMBatchRequest.make(text: text, userMessage: "[INPUT]\n\(text)\n[/INPUT]")
    }

    /// A scheduler whose runners simply uppercase, with an optional delay to hold the batch open.
    private func makeScheduler(
        log: RunnerLog, maxBatch: Int = 16, delay: Duration = .zero
    ) -> BatchedLLMScheduler {
        BatchedLLMScheduler(
            maxBatch: maxBatch,
            single: { request, _ in
                log.singleCalls += 1
                if delay > .zero { try? await Task.sleep(for: delay) }
                return request.text.uppercased()
            },
            batch: { requests, _ in
                log.batchWidths.append(requests.count)
                if delay > .zero { try? await Task.sleep(for: delay) }
                return requests.map { $0.text.uppercased() }
            })
    }

    // MARK: - Coalescing

    /// A synchronous burst — which is what `ChunkLLMCoordinator` produces when several chunks are
    /// outstanding at key release — must land in one batch. This is the whole reason the flush is
    /// deferred by a `Task.yield()` rather than run inline.
    func testSynchronousBurstCoalescesIntoOneBatch() async throws {
        let log = RunnerLog()
        let scheduler = makeScheduler(log: log)
        let texts = (0 ..< 8).map { "chunk \($0)" }

        let results = await withTaskGroup(of: (Int, String).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask { @MainActor in
                    (index, await scheduler.submit(self.request(text), instructions: "sys"))
                }
            }
            var collected = [String](repeating: "", count: texts.count)
            for await (index, result) in group { collected[index] = result }
            return collected
        }

        XCTAssertEqual(results, texts.map { $0.uppercased() }, "results are not on their own rows")
        XCTAssertEqual(log.batchWidths, [8], "burst did not coalesce")
        XCTAssertEqual(log.singleCalls, 0)
    }

    /// A lone request must not wait for anything. It goes to the single-stream runner, because at
    /// B=1 the MTP path beats batched greedy by ~1.5× and paying a deadline to discover that would
    /// be the worst of both.
    func testLoneRequestUsesSingleRunnerImmediately() async throws {
        let log = RunnerLog()
        let scheduler = makeScheduler(log: log)

        let started = ContinuousClock.now
        let result = await scheduler.submit(request("alone"), instructions: "sys")
        let elapsed = ContinuousClock.now - started

        XCTAssertEqual(result, "ALONE")
        XCTAssertEqual(log.singleCalls, 1)
        XCTAssertTrue(log.batchWidths.isEmpty, "a batch of one should not use the batch runner")
        XCTAssertLessThan(elapsed, .milliseconds(200), "lone request was held by a deadline")
    }

    /// Requests arriving *while a batch runs* form the next batch. This is where the streaming path
    /// gets whatever batching it gets: mid-stream arrivals are sparse, but they are not sparse
    /// relative to a generation that is already in flight.
    func testArrivalsDuringAFlightJoinTheNextBatch() async throws {
        let log = RunnerLog()
        let scheduler = makeScheduler(log: log, delay: .milliseconds(120))

        async let first: [String] = withTaskGroup(of: String.self) { group in
            for index in 0 ..< 2 {
                group.addTask { @MainActor in
                    await scheduler.submit(self.request("a\(index)"), instructions: "sys")
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        // Land in the middle of the first batch's generation.
        try await Task.sleep(for: .milliseconds(40))
        async let second: [String] = withTaskGroup(of: String.self) { group in
            for index in 0 ..< 3 {
                group.addTask { @MainActor in
                    await scheduler.submit(self.request("b\(index)"), instructions: "sys")
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        let (one, two) = await (first, second)
        XCTAssertEqual(Set(one), ["A0", "A1"])
        XCTAssertEqual(Set(two), ["B0", "B1", "B2"])
        XCTAssertEqual(log.batchWidths, [2, 3], "second wave did not form its own batch")
    }

    // MARK: - Grouping and bounds

    /// Rows in one batch share the warm system prefix, so two prompts cannot mix. They must both
    /// still complete, and in arrival order — a majority prompt must not starve a minority one.
    func testDifferentInstructionsDoNotMix() async throws {
        let log = RunnerLog()
        let scheduler = makeScheduler(log: log)

        let results = await withTaskGroup(of: (Int, String).self) { group in
            for index in 0 ..< 6 {
                let instructions = index == 4 ? "other" : "sys"
                group.addTask { @MainActor in
                    (index, await scheduler.submit(
                        self.request("t\(index)"), instructions: instructions))
                }
            }
            var collected = [String](repeating: "", count: 6)
            for await (index, result) in group { collected[index] = result }
            return collected
        }

        XCTAssertEqual(results, (0 ..< 6).map { "T\($0)".uppercased() })
        // Five "sys" rows batched; the single "other" row is a batch of one and goes single-stream.
        XCTAssertEqual(log.batchWidths, [5])
        XCTAssertEqual(log.singleCalls, 1)
    }

    /// `maxBatch` bounds one call to the runner, not the total. The overflow must run immediately
    /// afterwards rather than wait for another submission to wake the flush.
    func testMaxBatchSplitsWithoutStranding() async throws {
        let log = RunnerLog()
        let scheduler = makeScheduler(log: log, maxBatch: 4)

        let results = await withTaskGroup(of: String.self) { group in
            for index in 0 ..< 10 {
                group.addTask { @MainActor in
                    await scheduler.submit(self.request("x\(index)"), instructions: "sys")
                }
            }
            return await group.reduce(into: [String]()) { $0.append($1) }
        }

        XCTAssertEqual(results.count, 10)
        XCTAssertEqual(Set(results).count, 10, "results collided")
        XCTAssertEqual(log.batchWidths.reduce(0, +) + log.singleCalls, 10)
        XCTAssertTrue(log.batchWidths.allSatisfy { $0 <= 4 },
                      "a batch exceeded maxBatch: \(log.batchWidths)")
    }

    // MARK: - Failure modes

    /// A runner that returns the wrong number of results is a programming error, but it must
    /// degrade to "uncorrected text" rather than to a permanent hang.
    func testMismatchedResultCountFallsBackToInputs() async throws {
        let scheduler = BatchedLLMScheduler(
            single: { request, _ in request.text.uppercased() },
            batch: { _, _ in [] })

        let results = await withTaskGroup(of: String.self) { group in
            for index in 0 ..< 3 {
                group.addTask { @MainActor in
                    await scheduler.submit(self.request("keep \(index)"), instructions: "sys")
                }
            }
            return await group.reduce(into: [String]()) { $0.append($1) }
        }

        XCTAssertEqual(Set(results), ["keep 0", "keep 1", "keep 2"],
                       "callers did not get their own text back")
    }

    /// `cancelAll` is what a watchdog force-idle calls. Every queued caller must be resumed — with
    /// its input, never with nothing — and the scheduler must be usable again afterwards.
    func testCancelAllResumesQueuedCallersWithTheirInput() async throws {
        let log = RunnerLog()
        let scheduler = makeScheduler(log: log, delay: .milliseconds(150))

        async let inFlight = scheduler.submit(request("first"), instructions: "sys")
        try await Task.sleep(for: .milliseconds(30))

        async let queued: [String] = withTaskGroup(of: String.self) { group in
            for index in 0 ..< 3 {
                group.addTask { @MainActor in
                    await scheduler.submit(self.request("q\(index)"), instructions: "sys")
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(scheduler.queueDepth, 3, "nothing was queued to cancel")
        scheduler.cancelAll()

        let cancelled = await queued
        XCTAssertEqual(Set(cancelled), ["q0", "q1", "q2"], "cancelled callers lost their text")
        // The generation already in flight is left to finish; it was never the thing being
        // abandoned, and killing it mid-batch would need a stop flag in the token callback.
        let survived = await inFlight
        XCTAssertEqual(survived, "FIRST")

        // Still usable.
        let after = await scheduler.submit(request("again"), instructions: "sys")
        XCTAssertEqual(after, "AGAIN")
    }
}
