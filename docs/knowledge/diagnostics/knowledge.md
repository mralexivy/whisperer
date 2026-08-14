# Diagnostics — Knowledge

Facts about observing this app while it is misbehaving: what the dump can and cannot see, and
which of its sections are trustworthy in which build.

## `## Thread Sample` was empty in every dump that mattered

`StuckStateDumper.renderThreadSample()` shelled out to `/usr/bin/sample` under `#if DEBUG`. That
section is the single most valuable part of a hang dump — it is the only thing that names the frame
the main thread is actually sitting in — and it was blank in every dump written by a real user.

Two independent reasons, either one sufficient:

| Barrier | Effect |
|---|---|
| `#if DEBUG` | The App Store and Release configurations never even attempted it. |
| Sandbox | `Process` cannot spawn a helper out of the container at all. |
| `task_for_pid` | Even unsandboxed, sampling *another* process needs the debugger entitlement or an admin authorization prompt. Neither is available to a shipped menu bar app. |

So the section was structurally dead: present in the template, never populated where it was needed.
A dump that reports "the main thread was unresponsive for 2.0s" and then cannot say *where* only
proves the symptom the user already reported.

**A task always has the right to inspect its own threads.** `thread_suspend` /
`thread_get_state` / `mach_vm_read_overwrite` on a thread of the calling task need no entitlement
and no subprocess. `MainThreadBacktrace` does the unwind in-process, which is why it works in the
sandboxed build — the only build user reports come from.

## The suspend window is the whole design

Between `thread_suspend(mainThread)` and `thread_resume(mainThread)` the main thread may be holding
the malloc lock or the dyld lock. Anything in that window that allocates, symbolicates, or logs can
block on a lock whose owner is the thread we just froze — a deadlock with no recovery path, in the
watchdog whose entire job is to survive a hang.

The window therefore contains exactly three operations:

1. `thread_get_state` — read pc/fp out of the register set.
2. Frame-pointer walk into a buffer **allocated once at file scope**.
3. `thread_resume`.

`dladdr`, demangling, `String` formatting and `Report` construction all happen strictly after the
resume. This is the standard crash-reporter shape applied to a live hang instead of a signal.

Two details the walk depends on:

- **Both ABIs agree on the frame layout** — caller's frame pointer at `[fp]`, return address at
  `[fp+8]` — so one loop covers arm64 and x86_64 once the initial pc/fp come from the right
  register flavor (`ARM_THREAD_STATE64` / `x86_THREAD_STATE64`).
- **PAC must be stripped on arm64** (`& 0x0000_FFFF_FFFF_FFFF`). The high bits of a signed pointer
  are a signature, not address. Without stripping, `dladdr` resolves nothing and every frame renders
  as `???`.

Reads go through `mach_vm_read_overwrite`, not a raw dereference: a corrupt frame pointer must
produce a failed read, not a fault inside the watchdog while the main thread is suspended. The loop
also bails when the chain stops climbing (`nextFP <= fp`) and caps at 64 frames, so a corrupt chain
cannot spin.

## Capture time is not dump time

`HealthManager.triggerDump` does `Task { @MainActor in StuckStateDumper.dump(...) }`. By definition
that Task cannot run until the main thread is free again — which is to say, until the hang is over
and the stack that caused it has unwound. Any stack capture placed inside `dump()` would reliably
photograph the aftermath.

The capture therefore lives in `checkMainThread()`, on `monitorQueue`, at the moment the 500ms
threshold trips. That poll runs while the main thread is still wedged. The report is stashed and
`renderThreadSample()` picks it up later, printing its age so a stale one is obvious:

```
_main thread, captured 3s ago while wedged: Main thread unresponsive for 2.0s_
```

`latestReport(maxAge:)` returns nil past 120s so a dump written for an unrelated reason cannot
present an old hang's stack as its own.

## Registering the main thread has exactly one legal place

`mach_thread_self()` names *the calling thread*, so the main thread's port can only be obtained by
running on it. There is already a block that is on the main thread by construction: the liveness
ping `checkMainThread()` posts every poll. `registerMainThread()` piggy-backs on it — no new
dispatch, and registration is complete within one poll of `startMonitoring()`.

The port right is deliberately never deallocated. The main thread lives for the whole process, and
dropping the right would leave the watchdog holding a dangling name.

## Two alerts 32.0s apart were one 40-second block

`HealthManager` logged `Main thread unresponsive for 2.0s` twice, exactly 32.0s apart, and that
reads as two separate short hangs. It is one continuous block, shaped by three constants in
`checkMainThread()`:

- `mainThreadAlertFired` latches, so a continuing hang logs once, not once per poll.
- `elapsed > .seconds(30)` resets the probe — a guard against `ContinuousClock` advancing through
  Mac sleep, which cannot distinguish sleep from a very long hang.
- The re-probe then takes another 2s to breach the threshold again.

2s alert → 30s reset → 2s re-detect = 34s of wall clock covered by two log lines with a silent gap
between them. When reading a log, treat repeated main-thread alerts ~32s apart as **one** stall, and
size it from the queue/job timings around it, not from the alert count.
