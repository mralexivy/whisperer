# Concurrency — Knowledge

Facts about where code in this app actually runs, as opposed to where its surrounding syntax
suggests it runs.

## An `async` closure parameter runs on the caller's executor

`ModelWorkQueue.run` was declared:

```swift
func run<T>(_ label: String, _ body: @Sendable () async throws -> T) async throws -> T {
    …
    return try await body()
}
```

`body` carries no isolation annotation, so it inherits the isolation of whoever calls `run`. The
demangler prints the resulting type as `nonisolated(nonsending) @Sendable () async throws -> ()` —
that phrase in a stack frame is the tell.

Every meeting-engine call site is a method on a `@MainActor` class, so the body ran on the main
thread. In `MeetingEngines.runCleanup()` the body was:

```swift
try await ModelWorkQueue.shared.run("meeting-engine-warm-cleanup") {
    let bridge = try WhisperBridge(modelPath: modelPath, useGPU: false)   // blocking C
    bridge.prepareForShutdown()
}
```

`WhisperBridge.init` is synchronous, and on first run for a model it triggers a CoreML/ANE encoder
compile — a synchronous XPC round trip to `_ANEDaemonConnection compileModel:`. Opening Meeting
Notes froze the whole app for **40.7 seconds** (`stall-2026-08-14T07-13-33Z.dump`:
`10:12:52.378 Initializing WhisperBridge` → `10:13:33.104 WhisperBridge initialized`, with thread 0
sitting in `mach_msg2_trap` the entire time).

The fix is at the API, not the call sites: `run` now hands the body to a `Task.detached` itself, so
the contract the type already advertised — heavy model work happens in a slot, *off your thread* —
holds by construction. Fixing the three offending call sites individually would have left the trap
armed for the fourth.

## Two things that look like they move work off the main actor, and don't

| Construct | Why it doesn't help |
|---|---|
| `Task.detached { await self?.method() }` where the class is `@MainActor` | The detached task starts nonisolated, then the very first `await` hops onto the main actor and stays there. `MeetingEngines.startEngine` did exactly this, and a comment even documented the hop ("After each `await`, execution resumes on the main actor") as a convenience — it was written without noticing it was also a hazard. |
| `actor ModelWorkQueue` | An actor serializes *scheduling*. It does not relocate a closure that was handed to it with caller-inherited isolation. |

## Isolation inheritance only bites on *synchronous* work

All 12 `ModelWorkQueue.run` call sites inherited main-actor isolation the same way, but only three
froze anything. The distinction is what is inside the closure:

- **`await` into an actor or `@MainActor` method** — that call runs on *its* executor regardless of
  the closure's. Inheriting main isolation changes nothing. (`meeting-engine-download-cleanup`,
  `sortformer-warmup`, `nemotron-meeting-release`.)
- **Synchronous blocking work** — runs wherever the closure runs. This is the failure mode.
  (`WhisperBridge.init` ×2, `bridge.transcribeTimestamped` once per 30s refine window.)

So an audit of "which call sites are on the main actor" is the wrong question; "which closures
contain a synchronous blocking call" is the right one.

## Why the AppState call sites were already safe

`nemotron-load`, `nemotron-hebrew-load` and `llm-load` submit from inside
`Task.detached(priority: .userInitiated) { [weak self] in … }` and call `ModelWorkQueue.run`
*before* touching anything main-isolated. The caller's executor is the global one, so the body
landed there too. This was accidental rather than designed — the same file's `llm-load` comment
shows the hazard was understood locally ("ChatSession inference must not run on the main thread")
and simply not generalized.

`SWIFT_VERSION = 5.0` in this project, so none of this is caught by the compiler. Strict
concurrency checking would not have flagged it either — the isolation is legal, just wrong.

## A detached task inherits no priority

`Task.detached` starts at the default priority unless one is passed. `run` forwards
`Task.currentPriority` so the dictation loads, which deliberately submit at `.userInitiated`, are
not silently demoted to background while the meeting warm-ups (`.utility`) keep their intent.
Priority and executor are independent: moving work off the main thread does not require making it
slower.

## The in-process backtrace is what found this

Nothing in the dump's state sections implicated concurrency: `AppState.state = idle`, every
component `healthy`, the Health Timeline empty, all audio devices alive. Read alone, the dump says
"nothing is wrong", because from the components' point of view nothing was — the main thread simply
could not run the run loop. Only `## Thread Sample`, produced by `MainThreadBacktrace`'s in-process
unwind, named `MeetingEngines.runCleanup` and the ANE compile beneath it. See
[../diagnostics/knowledge.md](../diagnostics/knowledge.md).
