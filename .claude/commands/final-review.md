# Final Review - Comprehensive PR Review & Testing for macOS Apps

## Step 0: Determine Review Pass

Before starting, check the git history to determine if this is a follow-up review:

```bash
git log --oneline -10 | grep -i "Co-Authored-By: Claude"
```

- **First pass**: No recent Claude co-authored commits on this branch, or the Claude commits are from a different feature.
- **Follow-up pass**: Recent Claude co-authored commits exist from a previous `/final-review` run on this same feature.

If this is a follow-up pass:
- Note this in the summary as "Review Pass #2" (or #3, etc.)
- Tell the review agents to check git history to understand WHY recent changes were made before suggesting reversals
- Be more conservative with changes — the previous pass already applied significant improvements
- Focus agents on catching issues introduced BY the previous review, not re-litigating decisions already made

## Step 1: Create or Update the PR

First, check which branch you're on:
- **If on `main`**: Create a new feature branch with a descriptive name based on the changes (e.g., `feature/live-transcription`, `fix/audio-buffer-leak`), then commit the changes to that branch.
- **If already on a feature branch**: Continue with existing branch.

Then handle the PR:
- If a PR doesn't exist for this branch, create one with a clear title and description summarizing the changes.
- If a PR already exists, push any uncommitted changes to it.

## Step 2: Launch Seven Review Agents in Parallel

Use the Task tool to launch these seven agents simultaneously.

**Important context for all agents**: If this is a follow-up pass, include in each agent's prompt:
- "Check git log to see recent commits and their messages before making recommendations"
- "If a pattern looks intentional based on recent commit messages, don't recommend reversing it without strong justification"
- "Focus on issues that may have been INTRODUCED by recent changes, not re-reviewing the entire file"

**Constraint priority for ALL agents**: Correctness first → Performance second → Developer velocity third. Every recommendation must include: (1) why it exists, (2) what can go wrong if ignored, (3) how to verify the fix.

---

### Agent 1: Memory & Lifecycle Auditor

Review the code changes with obsessive focus on memory correctness:

- **Retain cycles**: Flag ANY closure capturing `self` without `[weak self]` or `[unowned self]`. Verify every `[weak self]` has an appropriate `guard let self` or optional chaining pattern. Specifically check:
  - `Task { }` and `Task.detached { }` closures — these capture `self` strongly by default
  - `Combine` `.sink { }` and `.map { }` closures
  - `NotificationCenter` closure-based observers
  - Completion handlers stored as properties
- **Delegate patterns**: Confirm all delegate properties are declared `weak`. Flag any `strong` delegate references.
- **Observation cleanup**: Verify every `NotificationCenter.addObserver`, `KVO` observation, and `Combine` subscription (`AnyCancellable`) is properly removed/cancelled in `deinit`, `viewDidDisappear`, or the appropriate teardown point. Verify `AnyCancellable` sets are owned by the correct object (not a transient local).
- **Timer invalidation**: Every `Timer.scheduledTimer` or `DispatchSourceTimer` must have a corresponding `invalidate()` / `cancel()` in the teardown path. Verify the timer doesn't prevent `deinit` from being called (circular reference through target/action).
- **Large allocations**: Flag any large data buffers (`Data`, `[UInt8]`, audio buffers, image buffers) that are held longer than necessary. Look for opportunities to use `autoreleasepool` in tight loops processing many temporary objects.
- **C interop memory**: If using C libraries (e.g., `whisper.cpp`, `libav`), verify every `malloc`/`calloc` has a corresponding `free`, every `UnsafeMutablePointer.allocate` has a `.deallocate()`, and every bridging call properly manages ownership. Check `Unmanaged` usage for correct `retain`/`release` balance.
- **Circular references in data models**: Check for parent-child object graphs that create cycles. Recommend `weak` back-references where appropriate.
- **Long-lived service safety**: Services that live for the app's entire lifetime (singletons, app-scoped actors) must not accumulate references to short-lived objects (view controllers, windows, transient tasks). Verify closures registered with long-lived services use `[weak self]`. Check for growing collections (caches, observer lists) that are never pruned.
- **AppKit-specific lifecycle traps**:
  - `NSWindowController` retains its window — verify teardown on `close()`
  - `NSViewController` can outlive its view if referenced elsewhere — verify no stale VC references
  - `NSStatusItem` must be stored strongly or it gets deallocated
  - `NSMenu` items with `target` set to `self` can create retain cycles if the menu outlives the target
- **Instruments verification checklist**: For any flagged concern, specify:
  - **Leaks template**: Look for purple leak indicators, check the backtrace for the retain that created the cycle
  - **Allocations template**: Filter by `Persistent Bytes`, sort by `Growth`, look for unbounded growth over 5+ minutes of usage
  - **VM Tracker**: Check for dirty memory pages that indicate unreleased buffers

---

### Agent 2: Concurrency & Thread Safety Reviewer

Review all concurrent code for correctness and safety:

- **Actor isolation**: If using Swift Concurrency, verify `@MainActor` is applied to all UI-touching code. Flag any `nonisolated` methods that access actor-isolated state. Check for unnecessary main actor hops that could cause UI jank.
  - **Rule**: `@MainActor` goes on ViewModels, UI-bound services, and any type that touches AppKit. It does NOT go on data services, repositories, or background processors.
  - **Actor reentrancy**: Flag any actor method where state could change across an `await` suspension point. Verify state assumptions are re-checked after every `await` inside actor methods. Example: reading a count, awaiting a network call, then using that count — the count may have changed.
- **Data races**: Look for mutable shared state accessed from multiple threads/queues without synchronization. Flag any property accessed from both a background queue and the main thread without protection.
- **Sendable conformance**: Verify types crossing actor/concurrency boundaries conform to `Sendable` or are properly isolated. Flag `@unchecked Sendable` that may be hiding real issues — each usage needs a comment justifying why it's safe.
- **GCD correctness**: If using `DispatchQueue`, verify serial queues are used for state protection (not concurrent queues with bare reads/writes). Flag `DispatchQueue.main.sync` calls from the main thread (deadlock). Flag `sync` calls on any queue from within that same queue.
- **async/await pitfalls**: Check for missing `Task` cancellation handling. Verify `Task { }` captures don't create retain cycles. Flag detached tasks that outlive their scope. Look for `await` calls in hot paths that could be batched.
- **Cancellation propagation**: Verify long-running `Task` and `TaskGroup` operations check `Task.isCancelled` or call `try Task.checkCancellation()` at appropriate intervals. Flag any `Task` that ignores cancellation entirely. Verify parent task cancellation propagates to child tasks. Check that `for await` loops on `AsyncStream` terminate when the producer is cancelled.
- **Lock ordering**: If multiple locks/queues are used, verify consistent acquisition order to prevent deadlocks. Prefer `os_unfair_lock` or actors over `NSLock`/`NSRecursiveLock` for new code. Document lock ordering in a comment if more than two locks exist.
- **Thread explosion**: Flag patterns that dispatch many concurrent tasks without limiting concurrency (e.g., `DispatchQueue.global()` in a loop). Recommend `TaskGroup` with max concurrency or `OperationQueue.maxConcurrentOperationCount`.
- **Real-time audio thread safety**: If audio processing is involved, verify NO allocations, NO locks, NO Objective-C messaging, and NO Swift `async` on the audio render thread. Only lock-free ring buffers and atomic operations are acceptable.
- **Background work orchestration**: Verify long-running background work uses appropriate patterns:
  - `TaskGroup` for fan-out/fan-in parallel work with bounded concurrency
  - `AsyncStream` for producer-consumer pipelines
  - Dedicated actor for stateful background services
  - `ProcessInfo.performActivity(reason:using:)` or `NSBackgroundActivityScheduler` for energy-efficient deferred work

---

### Agent 3: Architecture & SOLID Reviewer

Review through the lens of production macOS app architecture:

- **Single Responsibility**: Are types doing one thing? ViewModels shouldn't contain networking logic. Services shouldn't know about UI. Models shouldn't contain business logic.
- **Dependency Injection & Composition Root**: Are dependencies injected via initializers (preferred) or property injection? Flag any use of singletons accessed directly — these should go through a composition root or DI container. The app entry point (`@main` / `AppDelegate`) should be the ONLY place where the full dependency graph is assembled. Verify `@Environment` / `@EnvironmentObject` usage is intentional, not a shortcut for proper DI.
- **Dependency direction rules**: Verify dependencies flow inward: UI → Domain → Data. NEVER the reverse. Domain layer must not import AppKit/SwiftUI. Data layer must not import domain types directly — use protocols defined in the domain layer. Flag any `import AppKit` or `import SwiftUI` in non-UI code.
- **Protocol-driven design**: Are abstractions defined by protocols? Can components be tested in isolation with mock implementations? Flag concrete type dependencies where a protocol boundary would improve testability. But also flag over-abstraction: a protocol with exactly one conformer and no test mock is premature. Protocols should live in the Domain layer; implementations in the Data or UI layer.
- **Layer separation**: Verify clear boundaries between:
  - **Presentation** (SwiftUI Views / AppKit / ViewModels): UI rendering and user interaction only
  - **Domain** (business logic, use cases, protocols): Pure Swift, no framework imports, fully testable
  - **Data** (persistence, networking, system APIs): Implements domain protocols, owns all I/O
  - **Integration** (system bridges, XPC, audio hardware): Isolated wrappers around OS APIs
  - Flag any layer violation, especially domain code that imports framework types.
- **Error propagation**: Are errors modeled as typed enums with meaningful cases? Flag `String`-based errors. Verify errors propagate to the appropriate layer for handling (UI shows user-facing messages, services log technical details). Check the error taxonomy:
  - **Recoverable** (network timeout, file busy): Retry with backoff, inform user
  - **User-actionable** (invalid input, permission denied): Clear message, suggest fix
  - **Fatal** (corrupted state, missing critical resource): Log, crash with context
  - **Silent** (optional feature unavailable): Degrade gracefully, log at `.debug` level
- **Crash safety discipline**: `fatalError()` and `preconditionFailure()` are only acceptable for programmer errors (broken invariants), never for runtime conditions. `assert()` is for debug-only invariant checks. `guard` with graceful degradation for everything else. Flag any `fatalError` reachable from user input or external data.
- **State management**: Is state ownership clear? Flag `@State` used for complex domain state that belongs in a ViewModel. Verify `@Published` properties update on the main thread. Check for redundant state that could be derived.
- **App lifecycle**: Verify proper handling of `applicationDidFinishLaunching`, `applicationWillTerminate`, `NSApplication.willBecomeActive`, sleep/wake notifications, and window lifecycle events.
- **Coordinator / Navigation**: For multi-window or complex navigation, verify a clear navigation architecture (Coordinator pattern or similar). Flag ad-hoc `NSWindow` creation scattered across the codebase.

---

### Agent 4: Codebase Consistency & DRY Reviewer

Review changes against the existing codebase:

- **Duplicate logic**: Search the entire codebase for similar patterns, helper methods, extensions, or utilities that already exist. Flag reinvented wheels.
- **Naming conventions**: Verify new code follows the project's established naming patterns for files, types, methods, and properties. Flag deviations.
- **Extension organization**: Check if new functionality belongs in an existing extension file rather than a new one. Verify extensions are organized by protocol conformance.
- **Shared utilities**: Look for string literals, magic numbers, or hardcoded values that should be constants or configuration. Check existing `Constants`, `Theme`, or `Configuration` types.
- **Consistency across features**: If this change implements a pattern (e.g., error handling, loading states, analytics), verify it matches how other features implement the same pattern. Flag inconsistencies.
- **Asset management**: Verify new assets (icons, colors, strings) use the project's asset catalog and localization patterns. Flag hardcoded strings that should be localized.
- **Project structure alignment**: Verify new files are placed in the correct folder/module according to the project's established layout. Check that:
  - Protocols live in the Domain layer, not next to their implementations
  - System dependencies are isolated behind wrapper types in the Integration layer
  - ViewModels live in the Presentation layer alongside their views
  - Flag files placed in root-level or catch-all folders

---

### Agent 5: macOS Platform & Performance Specialist

Review for macOS-specific correctness and performance:

- **AppKit / SwiftUI interop**: If mixing AppKit and SwiftUI, verify `NSHostingView` / `NSViewRepresentable` bridges are correct. Check for layout constraint conflicts. Verify responder chain isn't broken.
- **Menu bar & system integration**: Verify menu items, keyboard shortcuts, and toolbar items follow Apple HIG. Check `NSMenuItem` action/target patterns are correct. Verify Dock menu, status bar items, and system services integration.
- **Sandbox & entitlements**: Flag any API usage that requires specific entitlements (microphone, file access, network). Verify `Info.plist` declarations match actual capability usage. Apply minimal permissions approach — flag entitlements that are declared but no longer used by the code.
- **Performance on hot paths**: Profile-worthy code should be flagged:
  - String interpolation in logging hot paths — use `os_log` with `%{public}@` and format specifiers instead
  - Unnecessary `AnyView` type erasure in SwiftUI — use `@ViewBuilder` or conditional views
  - `body` recomputation triggers from unrelated state changes — verify `@ObservedObject` granularity
  - Computed properties that do expensive work without caching
- **Startup path minimization**: Review `applicationDidFinishLaunching` and the `@main` entry point. Flag anything that blocks the main thread during launch:
  - Database migrations should be deferred or async
  - Network calls must not block launch
  - Heavy object graph construction should use lazy initialization
  - Recommend `os_signpost` or `OSSignposter` for measuring launch phases
- **Energy efficiency**: Flag excessive polling (`Timer` for checking state). Recommend `Combine` publishers, `NotificationCenter`, or `AsyncStream` instead. Verify background work uses appropriate QoS classes. Flag `DispatchQueue.global()` without explicit QoS.
- **Process lifecycle**: For helper tools or XPC services, verify proper `launchd` integration, graceful termination handling, and crash recovery. Check that `NSRunningApplication` and process management APIs are used correctly.
- **File system correctness**: Verify use of `FileManager.default.urls(for:in:)` for standard directories. Flag hardcoded paths. Verify bookmark-based file access for sandboxed apps. Check for proper error handling on file operations.
- **Accessibility**: Verify custom views expose accessibility properties. Check `NSAccessibility` protocol conformance. Flag any UI that would be unusable with VoiceOver.

---

### Agent 6: State Management & Reliability Reviewer

Review state flow, resilience patterns, and data integrity:

- **State flow correctness**: Verify state flows unidirectionally from Domain → Presentation. Flag any UI that directly mutates domain state without going through a ViewModel or use case. Check for:
  - **Snapshot vs streaming**: Is the UI getting point-in-time snapshots (value types) or live-updating references (observable objects)? Verify the choice is intentional. Snapshots are safer for lists and detail views; streaming is appropriate for real-time displays.
  - **Race conditions in state updates**: If multiple async operations can update the same state, verify they're serialized through an actor or serial queue. Flag optimistic UI updates that don't handle rollback on failure.
  - **Derived state**: Flag any stored property that could be computed from other state. Redundant state is a consistency bug waiting to happen.
- **Retry & resilience patterns**: For operations that can fail transiently (file I/O, audio device access, IPC):
  - Verify retry logic uses exponential backoff, not immediate retry loops
  - Flag infinite retry patterns — all retries must have a max attempt count
  - For critical subsystems, check for circuit breaker pattern: after N failures, stop retrying and surface the error
  - Verify timeout values are explicitly set, not relying on system defaults
- **Persistence safety**: If the app persists state (UserDefaults, Core Data, files, SQLite):
  - Verify writes are atomic or use write-ahead logging
  - Flag direct `UserDefaults.standard.set()` for complex data — recommend `Codable` serialization with error handling
  - Verify data migration paths exist for schema changes
  - Check that file writes use `.atomicWrite` option or temporary-file-then-rename pattern
  - Flag any persistence operation on the main thread that could block UI
- **Graceful degradation**: Verify the app handles partial failures without crashing:
  - Missing optional features (audio device unavailable, network down) should degrade gracefully
  - Corrupted persisted state should trigger a reset path, not a crash
  - Missing resources (images, config files) should use sensible defaults

---

### Agent 7: Security, Privacy & Logging Reviewer

Review for security hygiene, privacy compliance, and observability:

- **Entitlements discipline**: Verify every entitlement in the `.entitlements` file is actually used by the code. Flag unused entitlements (they widen the attack surface for no benefit). Verify hardened runtime is enabled unless there's a documented reason.
- **Data protection**:
  - Sensitive user data at rest should use the Keychain (`SecItem` API) or encrypted containers, not plain `UserDefaults` or unprotected files
  - Flag any credentials, API keys, or tokens stored in plaintext
  - Verify temporary files containing sensitive data are cleaned up
  - If using `URLSession`, verify `httpShouldHandleCookies` and credential storage are configured intentionally
- **Minimal permissions**: Flag prompts for user permissions (microphone, location, screen recording) that happen at launch rather than at the moment of first use. Permissions should be requested just-in-time with clear context.
- **Input validation**: If processing external data (files, clipboard, network responses, IPC messages):
  - Verify size limits before allocating buffers
  - Validate structure before parsing (check magic bytes, headers)
  - Flag any `try! JSONDecoder().decode()` — external data must use `try` with error handling
  - Verify URL schemes and deep link handlers validate input
- **Logging & observability**:
  - Verify the project uses `os_log` / `Logger` (unified logging) instead of `print()` or `NSLog()`. Flag any `print()` statements — these are noise in production and don't support log levels.
  - Check log levels are appropriate: `.debug` for development-only detail, `.info` for operational events, `.error` for failures, `.fault` for unrecoverable states.
  - Flag any sensitive data (user content, file paths, credentials) logged at `.info` or above — sensitive data should only appear at `.debug` level with `%{private}@`.
  - Verify `os_signpost` or `OSSignposter` is used for performance-critical paths (startup, audio processing, file operations) to enable Instruments profiling.
  - Recommend `OSLogStore` for programmatic log retrieval in diagnostic/feedback features.

---

## Step 3: Reconcile and Apply Fixes

When the seven agents return their recommendations:

1. **Memory and concurrency fixes are mandatory** — If Agents 1 or 2 flag a retain cycle, data race, or thread safety issue, fix it. These are production crashes and silent corruption waiting to happen. No exceptions.

2. **Security fixes are mandatory** — If Agent 7 flags plaintext credential storage, unused entitlements, or sensitive data logging, fix it. These are ship-blockers.

3. **Architecture improvements: apply most** — If you're on the fence, do it. This is a single-developer repo so "out of scope" doesn't apply.

4. **Handle conflicts intelligently**:
   - If Agent 4 says "use existing utility X" and Agent 3 says "extract to new protocol Y", prefer using existing code (Agent 4) to keep the codebase DRY.
   - If Agent 2 says "use an actor" and Agent 5 says "this is an audio thread, no Swift Concurrency", Agent 5 wins for audio-specific code.
   - If Agent 3 says "add a protocol" and Agent 4 says "only one conformer exists", skip the protocol unless testability requires it.
   - If Agent 6 says "add retry logic" and Agent 3 says "keep it simple", Agent 6 wins for I/O operations — reliability trumps simplicity for system interactions.

5. **Track what you skip** — Only skip if you're genuinely confident it's wrong for this codebase. Note these for the summary.

6. **On follow-up passes, aim for convergence** — If agents are only finding minor issues or suggesting stylistic preferences, note this in the summary. The goal is to converge, not to endlessly refactor. If changes from this pass are minimal, recommend that the user proceed without another review pass.

## Step 4: Comprehensive Testing

Run ALL of these that apply to the changes:

### 4a. Build & Static Analysis
```bash
# Clean build to catch all warnings
xcodebuild clean build -scheme "YourScheme" -destination "platform=macOS" 2>&1 | tee ./tmp/build-results.log

# Check for warnings (treat as errors)
grep -c "warning:" ./tmp/build-results.log

# SwiftLint (if configured)
swiftlint lint --path Sources/ --reporter json > ./tmp/swiftlint-results.json

# Swift compiler strict concurrency checking
# Verify the project has SWIFT_STRICT_CONCURRENCY = complete in build settings

# Verify no print() statements in production code
grep -rn "print(" Sources/ --include="*.swift" | grep -v "// debug" | grep -v "Tests/"
```

### 4b. Unit & Integration Tests
```bash
# Run full test suite
xcodebuild test -scheme "YourScheme" -destination "platform=macOS" 2>&1 | tee ./tmp/test-results.log

# Run specific test targets related to changes
xcodebuild test -scheme "YourScheme" -destination "platform=macOS" -only-testing "YourTestTarget/SpecificTestClass" 2>&1

# Check for test failures
grep -E "(Test Suite .* failed|Executed .* with .* failure)" ./tmp/test-results.log
```

**Concurrency test verification**: For any new or modified concurrent code, verify tests exist that:
- Use `XCTestExpectation` with explicit timeouts for async operations
- Test cancellation paths (start a task, cancel it, verify cleanup)
- Use deterministic scheduling where possible (inject clock/scheduler dependencies)
- Don't rely on `sleep()` or `Task.sleep()` for synchronization — use expectations or continuations

### 4c. Memory Leak Detection
```bash
# Run tests with leak checking enabled via environment variable
xcodebuild test -scheme "YourScheme" -destination "platform=macOS" \
  OTHER_SWIFT_FLAGS="-Xfrontend -enable-actor-data-race-checks" 2>&1

# If MallocStackLogging is available for debug builds:
MallocStackLogging=1 xcodebuild test -scheme "YourScheme" -destination "platform=macOS" 2>&1
```

Manual verification (note in summary if not possible to automate):
- Run the app in Instruments with the **Leaks** template for 5 minutes of typical usage
- Run with **Allocations** template: filter by `Persistent Bytes`, sort by `Growth`, look for unbounded growth; use **Mark Generation** (heapshot) before and after exercising a feature to isolate leaks
- Run with **Thread Sanitizer** enabled (Edit Scheme → Diagnostics → Thread Sanitizer)
- Run with **Address Sanitizer** enabled for C interop code
- Run **VM Tracker** to check for large dirty memory regions from unreleased buffers

### 4d. Concurrency Verification
```bash
# Build with Thread Sanitizer (TSan)
xcodebuild test -scheme "YourScheme" -destination "platform=macOS" \
  -enableThreadSanitizer YES 2>&1 | tee ./tmp/tsan-results.log

# Check for data race reports
grep -i "ThreadSanitizer" ./tmp/tsan-results.log

# If using actors with strict concurrency, verify no warnings:
grep -i "concurrency" ./tmp/build-results.log
```

### 4e. Runtime Smoke Testing

Based on the code changes, identify which features/windows are affected. Then:

1. List out each manual smoke test based on what changed
2. Launch the app and exercise the affected features
3. Verify:
   - Window lifecycle: open, close, minimize, fullscreen, multiple windows
   - Menu items: all relevant menu actions trigger correctly
   - Keyboard shortcuts: affected shortcuts still work
   - System integration: status bar items, Dock menu, notifications
   - State persistence: quit and relaunch, verify state restores
   - Edge cases: rapid clicks, resizing during operations, sleep/wake
   - Accessibility: tab through UI with keyboard, verify VoiceOver reads elements
   - Permission flows: first-launch permission prompts appear at the right moment

### 4f. Performance Sanity Check

If changes touch hot paths (audio processing, rendering, data parsing):

```bash
# Run performance tests if they exist
xcodebuild test -scheme "YourScheme" -destination "platform=macOS" \
  -only-testing "PerfTests" 2>&1
```

Verify:
- CPU usage stays reasonable during steady-state operation
- Memory footprint doesn't grow unbounded over time (check with `footprint` CLI tool or Activity Monitor)
- App launch time hasn't regressed — measure with `os_signpost` or Time Profiler
- UI remains responsive (no main thread blocking > 16ms)
- Use **Time Profiler** in Instruments for CPU hotspot analysis
- Use **Points of Interest** instrument with `os_signpost` to verify custom performance markers

### 4g. Security Sanity Check

```bash
# Verify no hardcoded secrets
grep -rn "api_key\|secret\|password\|token" Sources/ --include="*.swift" | grep -v "// placeholder" | grep -v "Tests/"

# Verify hardened runtime (check entitlements)
codesign -d --entitlements - build/Build/Products/Debug/YourApp.app 2>&1

# Check for unused entitlements
diff <(grep -oP 'com\.apple\.\S+' YourApp/YourApp.entitlements | sort) \
     <(grep -rn "com\.apple\." Sources/ --include="*.swift" | grep -oP 'com\.apple\.\S+' | sort)
```

## Step 5: Push Final Changes

After all fixes and tests pass, commit and push the changes to the PR.

## Step 6: Final Summary

Provide a summary with these sections:

### Review Pass
- State which pass this is (e.g., "Review Pass #1" or "Review Pass #2")
- If follow-up pass, briefly note what the previous pass addressed

### Changes Applied
- List the recommendations you implemented from each agent
- **Memory fixes**: Specifically call out every retain cycle, leak, or ownership issue fixed
- **Concurrency fixes**: Specifically call out every race condition or threading issue fixed
- **Architecture improvements**: Note structural changes and dependency direction corrections
- **State & reliability fixes**: Note state flow corrections, retry logic, persistence safety
- **Consistency fixes**: Note alignment with existing patterns
- **Platform fixes**: Note macOS-specific corrections
- **Security & logging fixes**: Note entitlement cleanup, data protection, logging improvements

### Recommendations Skipped
- For each skipped item, explain WHY you decided not to do it
- Remember: "out of scope" is not a valid excuse in a single-developer repo
- Memory, concurrency, and security skips require extra justification

### Test Coverage
- Build status and warning count
- Unit/integration test results (including concurrency test coverage)
- Thread Sanitizer results
- Any Instruments profiling performed (Leaks, Allocations, Time Profiler)
- What was smoke tested manually
- Security check results

### Unable to Test
- List anything that couldn't be tested and why
- Specifically note if Instruments profiling was not performed
- Specifically note if security sanity checks were skipped
- Explain what you'd want to manually verify

### Another Pass Needed?
- If this pass fixed memory leaks, concurrency issues, or security problems, **always recommend another pass** to verify the fixes didn't introduce new issues
- If changes were minor (small tweaks, naming fixes), recommend proceeding to merge
- Be honest: "Fixed 3 retain cycles, a data race, and plaintext credential storage — I'd recommend one more review" or "Changes were cosmetic — ready to merge"