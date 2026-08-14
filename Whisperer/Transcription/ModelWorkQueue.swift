//
//  ModelWorkQueue.swift
//  Whisperer
//
//  Admission control for heavy model work: one job at a time, none while a meeting records.
//

import Foundation

/// Serializes the expensive, deferrable model jobs — ASR loads, LLM loads, Sortformer warm-up,
/// RAG indexing — so they never contend for the ANE/GPU with each other or with a live meeting.
///
/// Four model families are resident in this app (Nemotron ASR, Sortformer diarization and the
/// MiniLM RAG embedder on the ANE; Qwen MTP on Metal). Before this queue the only coordination
/// between them was a blind 15s `Task.sleep` in `MeetingDiarizerService`, and meeting stop fired
/// RAG indexing, title generation, overview generation and an ASR backend reload within the same
/// second — a pile-up that produced a 33.7s KV warmup and a 120s embedder timeout.
///
/// Two rules:
/// 1. **One at a time, FIFO.** A job runs only when the previous one has returned.
/// 2. **Nothing during a meeting.** A job submitted while a meeting is recording waits for it to
///    stop. Ordinary dictation does *not* block — it is short and bursty, and its own
///    post-processing runs on this same LLM.
///
/// ### The gate is waited on BEFORE the slot, never while holding it
/// The original ordering was `acquireSlot()` then `while meetingActive { … }`, which parks a gated
/// job on the single execution slot. Everything submitted afterwards queues behind a job that is,
/// by definition, not running. In one observed session `nemotron-meeting-release` took the slot
/// mid-meeting, and the transcript-polish batches submitted two seconds after the meeting ended
/// never got to run at all — the meeting was left un-polished, un-summarised and permanently
/// missing its Wax index, with the processing banner spinning. Waiting on the gate first is the
/// fix; the post-acquire re-check below closes the window where a meeting starts during hand-off.
///
/// ### Every wait is cancellable and every job is bounded
/// A stuck job used to wedge the queue for the rest of the app session with no log line at all —
/// `run` only logged on completion. It now logs on submission, warns about long queue waits, and
/// reclaims the slot from a job that overruns `stallCeiling`.
///
/// ### The body runs off the caller's executor — and `Task.detached` is not what achieves that
/// An `async` closure parameter with no isolation annotation runs on the *caller's* executor. Every
/// meeting-engine call site is a method on a `@MainActor` class, so `WhisperBridge(modelPath:)` —
/// blocking C plus a first-run CoreML/ANE encoder compile — executed on the main thread: 40.7s of
/// frozen UI the first time Meeting Notes was opened (`stall-2026-08-14T07-13-33Z.dump`), with the
/// whole stack from `mach_msg2_trap` down to `MeetingEngines.runCleanup` on thread 0.
///
/// Wrapping the call in `Task.detached` inside `run` was the first fix and it **did not work**. The
/// detach changes where the *task* starts, not where `body` runs: `body`'s type still carries the
/// caller's isolation, so `await body()` hops straight back. `stall-2026-08-14T12-17-13Z.dump`
/// caught the identical freeze on thread 0 with the detach in place, and named the mechanism in the
/// symbol itself —
/// `closure #1 nonisolated(nonsending) @Sendable () async throws -> WhisperBridge in
/// MeetingTranscriptRefiner.run(...)` under `swift::runJobInEstablishedExecutorContext`, 44.5s
/// inside `whisper_coreml_init` → `-[_ANEDaemonConnection compileModel:…]`. Under this target's
/// `SWIFT_APPROACHABLE_CONCURRENCY = YES` (SE-0461) an unannotated `async` function type is
/// `nonisolated(nonsending)`, and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes essentially
/// every caller in this module the main actor. `@Sendable` does not change either fact, and neither
/// does this type being an `actor` — an actor serializes *scheduling*, not execution.
///
/// Two entry points, so the guarantee is structural rather than attribute-dependent:
///
/// - `run` — async bodies. The hop is forced by `offCallerExecutor`, which is `@concurrent`
///   `nonisolated`: it is required to run on the global concurrent executor, so the `body()` call
///   nested inside it inherits *that*, not the caller. It also trips a `Logger.error` if it ever
///   finds itself on thread 0, because the whole cost of this bug was that it was silent.
/// - `runBlocking` — **synchronous** bodies (`WhisperBridge.init`, `transcribeTimestamped`, and
///   anything else that blocks a thread in C). A synchronous closure has no executor to inherit; it
///   runs wherever it is called, and it is called on a private serial `DispatchQueue`. Nothing about
///   the caller's isolation, the language mode, or a future upcoming-feature flag can move it back
///   onto the main thread. Blocking C also has no business on a cooperative-pool thread, where a
///   44s stall would consume one of a handful of workers.
///
/// Anything that blocks should use `runBlocking`. `run` is for genuinely async work.
///
/// What must NOT go through here: live ASR, live diarization `feed()`, and interactive dictation
/// post-processing. Those are the latency path, not background work.
actor ModelWorkQueue {
    static let shared = ModelWorkQueue()

    private init() {}

    /// Carries a job's result out of the detached task. `T` is unconstrained for the reason given
    /// on `run` — the model handles callers return predate `Sendable` — so the box is the same
    /// unchecked hand-off their existing load paths already perform, made explicit in one place.
    private struct Transferred<T>: @unchecked Sendable {
        let value: T
    }

    /// A job that overruns this is presumed wedged: the slot is reclaimed so the queue survives.
    /// Sized well above the slowest legitimate job ever measured (a cold `llm-load` at ~5s).
    private static let stallCeiling: TimeInterval = 120
    /// Queue waits longer than this are reported — a meeting can legitimately exceed it, so this
    /// is a warning and not a reclaim.
    private static let longWaitWarning: TimeInterval = 30

    /// One queued or running job. `id` is the identity every release and reclaim is checked
    /// against, so a reclaimed job's late completion cannot release someone else's slot.
    private struct Waiter {
        let id: Int
        let label: String
        let continuation: CheckedContinuation<Void, Never>
    }

    private var nextJobID = 0

    /// True while a job holds the single execution slot; `slotOwner` is which one.
    private var isRunning = false
    private var slotOwner: Int?
    /// Jobs waiting for the slot, in submission order. Released one at a time by direct hand-off.
    private var slotWaiters: [Waiter] = []

    private var meetingActive = false
    private var meetingWaiters: [Waiter] = []

    /// Jobs cancelled while waiting. Recorded by id because the cancellation handler can land
    /// before the continuation has been appended.
    private var cancelledJobIDs: Set<Int> = []

    // MARK: - Meeting gate

    /// Called by `AppState` when a meeting recording starts and stops.
    func setMeetingActive(_ active: Bool) {
        guard meetingActive != active else { return }
        meetingActive = active
        guard !active else {
            Logger.info("ModelWorkQueue: meeting started — background model work suspended", subsystem: .model)
            return
        }
        let resumed = meetingWaiters
        meetingWaiters.removeAll()
        for waiter in resumed { waiter.continuation.resume() }
        if !resumed.isEmpty {
            Logger.info("ModelWorkQueue: meeting ended — releasing \(resumed.count) suspended job(s)", subsystem: .model)
        }
    }

    // MARK: - Submission

    /// Runs `body` once no meeting is recording and the queue is free.
    ///
    /// `label` appears in the timing log alongside the queue wait and the run duration — that log
    /// is the standing evidence for whether model loads still overlap.
    /// `T` is deliberately unconstrained: callers hand back model handles (`NemotronBridge`,
    /// `SortformerModels`) that predate `Sendable` and are already passed across isolation
    /// domains by their existing load paths.
    ///
    /// Throws `CancellationError` if the calling task is cancelled before `body` starts. It is
    /// `throws` rather than `rethrows` for exactly that reason — a non-throwing body still has a
    /// cancellable wait in front of it.
    ///
    /// `body` is forced onto the global concurrent executor and never runs on the caller's — see
    /// the class note. If it blocks a thread rather than suspending, use `runBlocking` instead.
    func run<T>(_ label: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let ticket = try await acquire(label)
        defer { finish(ticket) }

        // Priority is carried across explicitly: a detached task inherits nothing, and the
        // dictation loads (`nemotron-load`, `llm-load`) submit at `.userInitiated` on purpose.
        let job = Task.detached(priority: Task.currentPriority) {
            try await Self.offCallerExecutor(label, body)
        }
        return try await withTaskCancellationHandler {
            try await job.value.value
        } onCancel: {
            job.cancel()
        }
    }

    /// Same admission control as `run`, for a **synchronous** body that blocks its thread —
    /// `WhisperBridge.init`, `transcribeTimestamped`, any other blocking whisper.cpp call.
    ///
    /// A synchronous closure carries no isolation to inherit, so running it on `blockingQueue` is a
    /// structural guarantee that it is off the main thread and off the cooperative pool. This is the
    /// entry point every blocking model call should use; `run` is for work that genuinely suspends.
    func runBlocking<T>(_ label: String, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        let ticket = try await acquire(label)
        defer { finish(ticket) }
        return try await Self.onBlockingQueue(body).value
    }

    // MARK: - Execution

    /// Forces `body` off whatever executor called `run`.
    ///
    /// `@concurrent` is the load-bearing part: it requires this function to run on the global
    /// concurrent executor, and `body` — being `nonisolated(nonsending)` — then inherits *this*
    /// isolation instead of the original caller's. Removing the attribute silently reintroduces the
    /// main-thread freeze, which is what the tripwire below exists to catch.
    @concurrent
    private nonisolated static func offCallerExecutor<T>(
        _ label: String,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> Transferred<T> {
        if Thread.isMainThread {
            Logger.error(
                "ModelWorkQueue: \(label) entered on the main thread — isolation inheritance is back, "
                + "the UI will freeze for the duration of this job",
                subsystem: .model
            )
        }
        return Transferred(value: try await body())
    }

    /// Where blocking C runs. Serial and `.userInitiated`: the queue already admits one job at a
    /// time, so a concurrent queue would buy nothing.
    private nonisolated static let blockingQueue = DispatchQueue(
        label: "com.ivy.whisperer.modelwork.blocking",
        qos: .userInitiated
    )

    private nonisolated static func onBlockingQueue<T>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> Transferred<T> {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Transferred<T>, Error>) in
            blockingQueue.async {
                do {
                    continuation.resume(returning: Transferred(value: try body()))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Admission

    /// Identifies one admitted job, for the timing log and the owner-checked slot release.
    private struct Ticket {
        let id: Int
        let label: String
        let waitedMs: Int
        let startedAt: Date
    }

    /// Waits out the meeting gate and the slot, then arms the stall watchdog.
    private func acquire(_ label: String) async throws -> Ticket {
        let submittedAt = Date()
        let id = nextJobID
        nextJobID += 1

        Logger.debug(
            "ModelWorkQueue: \(label) submitted (running=\(isRunning), queued=\(slotWaiters.count + meetingWaiters.count), meeting=\(meetingActive))",
            subsystem: .model
        )
        armLongWaitWarning(id: id, label: label)

        // Safe to drop the cancellation record once the slot is held — it is only read while
        // waiting, and every throwing path below leaves the queues via `cancelWait`.
        defer { cancelledJobIDs.remove(id) }

        // Gate first, slot second. Re-check after acquiring: a meeting can start while the slot
        // is being handed over, and holding it through that wait is what wedged the queue.
        while true {
            try await waitForMeetingGate(id: id, label: label)
            try await waitForSlot(id: id, label: label)
            if !meetingActive { break }
            releaseSlot(owner: id)
        }

        armStallWatchdog(id: id, label: label)
        return Ticket(
            id: id,
            label: label,
            waitedMs: Int(Date().timeIntervalSince(submittedAt) * 1000),
            startedAt: Date()
        )
    }

    private func finish(_ ticket: Ticket) {
        let ranMs = Int(Date().timeIntervalSince(ticket.startedAt) * 1000)
        Logger.info(
            "ModelWorkQueue: \(ticket.label) waited=\(ticket.waitedMs)ms ran=\(ranMs)ms",
            subsystem: .model
        )
        releaseSlot(owner: ticket.id)
    }

    // MARK: - Waiting

    private enum WaitQueue { case slot, meetingGate }

    private func waitForMeetingGate(id: Int, label: String) async throws {
        while meetingActive {
            try Task.checkCancellation()
            await suspend(id: id, label: label, in: .meetingGate)
            if cancelledJobIDs.contains(id) { throw CancellationError() }
            try Task.checkCancellation()
        }
    }

    private func waitForSlot(id: Int, label: String) async throws {
        if !isRunning {
            try Task.checkCancellation()
            isRunning = true
            slotOwner = id
            return
        }
        // The slot is handed to us directly on release, so no re-check loop is needed.
        await suspend(id: id, label: label, in: .slot)
        // A cancelled waiter may still have been granted the slot by a concurrent hand-off;
        // releaseSlot is owner-checked, so this gives it back only when we actually hold it.
        if cancelledJobIDs.contains(id) || Task.isCancelled {
            releaseSlot(owner: id)
            throw CancellationError()
        }
    }

    /// Parks the caller in `queue` until resumed by a hand-off, the meeting gate, or cancellation.
    private func suspend(id: Int, label: String, in queue: WaitQueue) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // The handler can fire before we get here, so re-check rather than parking a
                // continuation nothing will ever resume.
                guard !cancelledJobIDs.contains(id), !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                let waiter = Waiter(id: id, label: label, continuation: continuation)
                switch queue {
                case .slot: slotWaiters.append(waiter)
                case .meetingGate: meetingWaiters.append(waiter)
                }
            }
        } onCancel: {
            Task { await self.cancelWait(id: id) }
        }
    }

    /// Pulls a cancelled job out of whichever queue holds it and wakes it so it can throw.
    private func cancelWait(id: Int) {
        cancelledJobIDs.insert(id)
        if let index = slotWaiters.firstIndex(where: { $0.id == id }) {
            slotWaiters.remove(at: index).continuation.resume()
        }
        if let index = meetingWaiters.firstIndex(where: { $0.id == id }) {
            meetingWaiters.remove(at: index).continuation.resume()
        }
    }

    // MARK: - Slot

    /// Hands the slot to the next waiter. A no-op unless `owner` currently holds it, so a
    /// reclaimed job returning late cannot evict its successor.
    private func releaseSlot(owner: Int) {
        guard slotOwner == owner else { return }
        if let next = slotWaiters.first {
            slotWaiters.removeFirst()
            slotOwner = next.id
            next.continuation.resume()
        } else {
            isRunning = false
            slotOwner = nil
        }
    }

    // MARK: - Watchdogs

    private func armStallWatchdog(id: Int, label: String) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.stallCeiling * 1_000_000_000))
            await self.reclaimIfStalled(id: id, label: label)
        }
    }

    private func reclaimIfStalled(id: Int, label: String) {
        guard slotOwner == id else { return }
        Logger.error(
            "ModelWorkQueue: \(label) still running after \(Int(Self.stallCeiling))s — presumed stuck, reclaiming the slot for \(slotWaiters.count) queued job(s)",
            subsystem: .model
        )
        releaseSlot(owner: id)
    }

    private func armLongWaitWarning(id: Int, label: String) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.longWaitWarning * 1_000_000_000))
            await self.warnIfStillWaiting(id: id, label: label)
        }
    }

    private func warnIfStillWaiting(id: Int, label: String) {
        let waitingOnGate = meetingWaiters.contains { $0.id == id }
        let waitingOnSlot = slotWaiters.contains { $0.id == id }
        guard waitingOnGate || waitingOnSlot else { return }
        Logger.warning(
            "ModelWorkQueue: \(label) has waited \(Int(Self.longWaitWarning))s on \(waitingOnGate ? "the meeting gate" : "the queue") (meeting=\(meetingActive), running=\(isRunning))",
            subsystem: .model
        )
    }
}
