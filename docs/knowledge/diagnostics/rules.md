# Diagnostics — Rules (apply by default)

1. **A diagnostic that only works in Debug is not a diagnostic.** Every stall report comes from a
   sandboxed Release build. Before adding a section to the dump, check it can be produced there:
   no `Process`, no `task_for_pid`, no entitlement the shipped app does not have. `#if DEBUG` around
   a diagnostic means it is absent exactly when it is needed — keep such a path only as a *fallback*
   behind one that works everywhere.

2. **Capture evidence on the thread that noticed, not after a hop.** A `@MainActor` dump cannot run
   until the main thread is free, so anything it captures describes the aftermath. State that only
   exists during the fault — a wedged stack, a lock holder, an in-flight buffer — must be read at
   detection time, on the detecting queue, and stashed for the dump to render.

3. **Stamp captured evidence and expire it.** A stashed report rendered into an unrelated later dump
   is worse than an empty section: it is confidently wrong. Print its age, and return nil past a
   ceiling (120s).

4. **Nothing but register reads and memory reads inside a `thread_suspend` window.** The suspended
   thread may hold the malloc or dyld lock; allocating, symbolicating, or logging there deadlocks the
   watchdog against the thread it is inspecting. Pre-allocate the scratch buffer at file scope,
   resume, and only then call `dladdr` and build strings.

5. **Strip PAC before symbolicating an arm64 code pointer** (`& 0x0000_FFFF_FFFF_FFFF`). The high
   bits are a signature, not address. Skipping this makes every frame render as `???` and reads as
   "the unwind failed" rather than "the addresses were never valid".

6. **Read memory during an unwind with `mach_vm_read_overwrite`, never a raw dereference,** and
   bound the walk: stop when the frame pointer stops increasing, when it is unaligned, and at a
   fixed frame cap. A corrupt chain must end the capture, not fault or spin inside the watchdog.

7. **Repeated identical watchdog alerts are one incident until proven otherwise.** The alert latch
   plus the 30s sleep/wake reset in `HealthManager.checkMainThread()` turn a single continuous block
   into alerts ~32s apart. Size a stall from the queue/job durations that bracket it
   (`ModelWorkQueue` logs `waited=` / `ran=`), not from how many times it was reported.
