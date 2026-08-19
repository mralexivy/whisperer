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

### Isolated deinit + `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` aborts the test host (2026-08-16)

**78 of the 79 crash reports** accumulated in `~/Library/Logs/Whisperer/crash.log` over three days
are one stack, and it is not a bug in any of the classes it names:

```
___BUG_IN_CLIENT_OF_LIBMALLOC_POINTER_BEING_FREED_WAS_NOT_ALLOCATED
swift::TaskLocal::StopLookupScope::~StopLookupScope()
swift_task_deinitOnExecutorImpl
<SomeClass>.__deallocating_deinit
<a synchronous XCTest method>
```

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY
= YES`, so every class is implicitly `@MainActor` and gets an **isolated deinit** — deallocation
routes through `swift_task_deinitOnExecutor` to hop to the main actor. In this toolchain that path
aborts when the object is released **outside any task**, which is precisely what a synchronous
XCTest method is. The app never hits it because it always releases these objects from a
main-actor context.

The named class is simply whichever one deallocated first, which is why it looked like three
different bugs: `EagerStreamEngine` (31 crashes, while it was still a class), `SafeLock` (6, and
the one that killed a 20-minute corpus sweep twice), `VADSegmenter` (2). The `SafeLock` case was
even written off in a source comment as "reads as a bug in the transcriber and is not one" — true,
but the actual cause was one level further down.

Fix: mark genuinely non-UI, non-actor-bound types `nonisolated` at the class declaration. Both
`VADSegmenter` and `SafeLock` are pure computation / synchronisation over background threads, so
main-actor isolation was never accurate in the first place — the crash just made the inaccuracy
fatal. `nonisolated class VADSegmenter` turned a deterministic abort into a passing test.

**Diagnostic value:** a `pointer being freed was not allocated` whose address is *identical across
separate processes* (here `0x2b2ecadc0`) is not heap corruption. Real corruption produces varying
addresses; a constant one points at the runtime freeing something it should not.

#### It also rules out recursively-owned reference structures (2026-08-17)

Same abort, reached without any XCTest peculiarity: `AliasEngine` was first written as a node
trie for longest-match-wins phrase lookup. A trie of reference types deallocates **recursively** —
releasing the root releases its children, and so on — so with `SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor` every node's `deinit` is an isolated deinit, and tearing the trie down ran the whole
cascade through `swift_task_deinitOnExecutorImpl` and aborted in malloc with `pointer being freed
was not allocated`.

`nonisolated` on the node class would have fixed it, but the data structure was not worth the
constraint: the fix taken was a **flat dictionary** keyed by the folded phrase
(`AliasEngine.table`). The lookup it trades away is bounded by `maxPhraseWords`, which is 2 for
the shipped lexicon.

Generalizes: in this target, "a plain `class`" is not a neutral choice — it is a `@MainActor`
class with an isolated deinit. Anything whose teardown is a cascade of releases (trie, linked
list, tree, parent/child graph) multiplies that hazard by its node count.
