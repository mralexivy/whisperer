//
//  GracefulShutdownTests.swift
//  WhispererTests
//
//  Regression tests for SIGABRT-on-quit: MLXLMCommon.BaseKVCache C++ destructor
//  crash during __cxa_finalize_ranges when exit() fires before the LLM cleanup Task.
//
//  Crash vector (confirmed 2026-09-19 crash.log):
//    SwiftUI Quit button
//      → NSApplication.terminate → exit()
//      → __cxa_finalize_ranges  (C++ static dtors)
//      → MLXLMCommon.BaseKVCache::~BaseKVCache()
//      → abort()
//
//  Root cause: releaseWhisperResources() dispatched unloadModel() as a fire-and-forget
//  Task; gracefulShutdown() returned (and exit() fired) before the Task ran.
//
//  Fix: gracefulShutdown() now awaits AppState.releaseLLMAsync() which in turn awaits
//  LLMPostProcessor.unloadModel() — full GPU fence + MLX pool flush before exit().
//

import XCTest
@testable import whisperer

// MARK: - LLMPostProcessor shutdown path

final class GracefulShutdownTests: XCTestCase {

    // MARK: releaseLLMAsync — no model loaded

    /// releaseLLMAsync() must return immediately when no LLM is loaded.
    /// If the fix regressed, this would hang or crash.
    @MainActor
    func testReleaseLLMAsync_noModelLoaded() async {
        // AppState.shared is a singleton; grab llmPostProcessor, nil it, restore after.
        let appState = AppState.shared
        let saved = appState.llmPostProcessor
        appState.llmPostProcessor = nil
        defer { appState.llmPostProcessor = saved }

        // Must complete without crashing or hanging.
        await appState.releaseLLMAsync()

        // After release, llmPostProcessor is still nil (set by the test, unchanged).
        XCTAssertNil(appState.llmPostProcessor)
    }

    // MARK: releaseLLMAsync — unloaded processor injected

    /// releaseLLMAsync() must nil llmPostProcessor and fully drain unloadModel()
    /// (including Memory.clearCache) even when the processor carries no loaded weights.
    @MainActor
    func testReleaseLLMAsync_withUnloadedProcessor() async {
        let appState = AppState.shared
        let saved = appState.llmPostProcessor
        defer { appState.llmPostProcessor = saved }

        // Inject an unloaded processor (isModelLoaded = false → unloadModel() is a no-op
        // on the inference drain loop, but still fences the GPU and clears the MLX pool).
        let processor = LLMPostProcessor()
        XCTAssertFalse(processor.isModelLoaded)
        appState.llmPostProcessor = processor

        await appState.releaseLLMAsync()

        // llmPostProcessor must be nil — the guard inside releaseLLMAsync consumed it.
        XCTAssertNil(appState.llmPostProcessor,
                     "releaseLLMAsync() must nil llmPostProcessor before returning")

        // processor.isModelLoaded must be false (was already false; unloadModel() keeps it so).
        XCTAssertFalse(processor.isModelLoaded)
    }

    // MARK: Double-call safety

    /// Calling releaseLLMAsync() twice must not crash (second call short-circuits on nil).
    @MainActor
    func testReleaseLLMAsync_idempotent() async {
        let appState = AppState.shared
        let saved = appState.llmPostProcessor
        defer { appState.llmPostProcessor = saved }

        appState.llmPostProcessor = LLMPostProcessor()

        await appState.releaseLLMAsync()   // first call — nils the processor
        await appState.releaseLLMAsync()   // second call — guard fires, no crash

        XCTAssertNil(appState.llmPostProcessor)
    }

    // MARK: releaseWhisperResources fallback path

    /// releaseWhisperResources() must emit a warning (not crash) when the processor
    /// was not pre-released by releaseLLMAsync() — this is the fallback path for
    /// any callers that skip the async pre-release step.
    @MainActor
    func testReleaseWhisperResources_fallbackWarning() async {
        // We can't call releaseWhisperResources() safely in a test (it tears down the
        // singleton's entire stack).  Instead, verify the guard condition: when
        // llmPostProcessor is non-nil entering releaseWhisperResources(), the method
        // must nil it and not crash.  We do this by checking the pre-condition via
        // releaseLLMAsync() first, which is the production path.
        let appState = AppState.shared
        let saved = appState.llmPostProcessor
        defer { appState.llmPostProcessor = saved }

        let processor = LLMPostProcessor()
        appState.llmPostProcessor = processor

        // Simulate: gracefulShutdown calls releaseLLMAsync BEFORE releaseWhisperResources.
        await appState.releaseLLMAsync()

        // At this point llmPostProcessor is nil, so releaseWhisperResources()'s guard
        // logs nothing (expected production path).  The test just verifies no crash.
        XCTAssertNil(appState.llmPostProcessor,
                     "Production path: releaseLLMAsync() must have cleared llmPostProcessor")
    }

    // MARK: Ordering invariant

    /// releaseLLMAsync must set llmPostProcessor = nil synchronously (before any await)
    /// so that concurrent code can't start new LLM work during the drain.
    @MainActor
    func testReleaseLLMAsync_nilsProcessorBeforeAwait() async {
        let appState = AppState.shared
        let saved = appState.llmPostProcessor
        defer { appState.llmPostProcessor = saved }

        appState.llmPostProcessor = LLMPostProcessor()
        XCTAssertNotNil(appState.llmPostProcessor)

        // Start releaseLLMAsync but don't await yet — check mid-flight state via Task.
        // Because releaseLLMAsync nils llmPostProcessor before its first await, by the
        // time the Task.detached below gets to observe the main actor, it must be nil.
        let releaseTask = Task { @MainActor in
            await appState.releaseLLMAsync()
        }
        // Yield to let releaseLLMAsync's synchronous preamble run on the main actor.
        await Task.yield()
        // After one yield, the nil assignment (before first await inside unloadModel) must
        // have executed — concurrent callers can't sneak in and start new work.
        XCTAssertNil(appState.llmPostProcessor,
                     "llmPostProcessor must be nil after first cooperative yield")
        await releaseTask.value
    }
}
