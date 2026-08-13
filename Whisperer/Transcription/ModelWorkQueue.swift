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
/// What must NOT go through here: live ASR, live diarization `feed()`, and interactive dictation
/// post-processing. Those are the latency path, not background work.
actor ModelWorkQueue {
    static let shared = ModelWorkQueue()

    private init() {}

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
    func run<T>(_ label: String, _ body: @Sendable () async throws -> T) async throws -> T {
        let submittedAt = Date()
        let id = nextJobID
        nextJobID += 1

        Logger.debug(
            "ModelWorkQueue: \(label) submitted (running=\(isRunning), queued=\(slotWaiters.count + meetingWaiters.count), meeting=\(meetingActive))",
            subsystem: .model
        )
        armLongWaitWarning(id: id, label: label)

        defer { cancelledJobIDs.remove(id) }

        // Gate first, slot second. Re-check after acquiring: a meeting can start while the slot
        // is being handed over, and holding it through that wait is what wedged the queue.
        while true {
            try await waitForMeetingGate(id: id, label: label)
            try await waitForSlot(id: id, label: label)
            if !meetingActive { break }
            releaseSlot(owner: id)
        }

        let waitedMs = Int(Date().timeIntervalSince(submittedAt) * 1000)
        let startedAt = Date()
        armStallWatchdog(id: id, label: label)
        defer {
            let ranMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            Logger.info("ModelWorkQueue: \(label) waited=\(waitedMs)ms ran=\(ranMs)ms", subsystem: .model)
            releaseSlot(owner: id)
        }
        return try await body()
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
