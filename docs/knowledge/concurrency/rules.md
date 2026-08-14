# Concurrency — Rules (apply by default)

1. **An `async` closure parameter with no isolation annotation runs on the caller's executor.**
   Declaring it `@Sendable` does not change that. If a utility takes a closure and promises to run
   it "in the background", the utility must detach it — do not leave the guarantee to each caller.
   `ModelWorkQueue.run` is the reference implementation.

2. **`Task.detached { await self.method() }` is not an off-main guarantee when the type is
   `@MainActor`.** The first `await` hops onto the main actor and everything after it stays there.
   To keep work off main, the work itself must be nonisolated — not merely reached from a detached
   task.

3. **An `actor` serializes scheduling, not execution.** Wrapping heavy work in an actor's method
   says nothing about which thread the work runs on.

4. **Before putting a synchronous blocking call inside a closure, ask where the closure runs — not
   where it is written.** Isolation inheritance is harmless around `await`s into other actors and
   fatal around blocking C, model loads, and `whisper_*` calls. Model loads in this app can block
   for 40s on a first-run CoreML/ANE compile.

5. **Forward `Task.currentPriority` when detaching on a caller's behalf.** A detached task inherits
   no priority, so relocating work off the main thread must not also demote a `.userInitiated`
   dictation load to the default queue.

6. **A stall dump where every component is `healthy` and the timeline is empty means the main
   thread was blocked, not that nothing was wrong.** Go straight to `## Thread Sample`; the state
   sections describe a process that was, from each component's own point of view, fine.
