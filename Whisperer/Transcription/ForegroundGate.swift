//
//  ForegroundGate.swift
//  Whisperer
//
//  Lets a long background job pause *in place* — mid-generation, mid-meeting-cleanup — while the
//  user dictates, and pick up exactly where it stopped when the dictation is done.
//
//  `ModelWorkQueue` already holds back jobs that have not started yet (its dictation gate) and
//  offers `waitWhileDictationActive` at step boundaries. Neither reaches inside a single long step:
//  a local overview generation is one 30 s+ call, and on 2026-10-01 one of those stretched a
//  dictation's tail decode from ~800 ms to 10.9 s. This gate is the piece that does:
//
//  - **Synchronous and lock-based**, so it can be polled from a token callback on a generation
//    thread and raised in the same main-actor turn as the key press. The queue's gate is an actor
//    and is raised through `Task { await … }`, which left a window where background work kept the
//    GPU after the user had started speaking.
//  - **Pause, never cancel.** A paused job keeps its KV cache, its partial output and its place;
//    resuming costs nothing. Timeouts measure *active* time (`activeSeconds(since:)`), so a long
//    dictation never makes a paused summary time out and fall down to a worse rung.
//  - **Opt-in per caller.** Dictation's own LLM cleanup runs through the same `LLMPostProcessor`
//    functions; only callers that pass `.background` pause. A dictation must never wait on itself.
//  - **Bounded.** A pause gives up after `maxPause`, so a gate stranded up by a missed `end` can
//    slow background work but never deadlock it.
//

import Foundation

/// Who a piece of model work is for. Background work yields to the user; interactive work is
/// the user.
nonisolated enum ModelWorkPriority: Sendable {
    case interactive
    case background
}

nonisolated final class ForegroundGate: @unchecked Sendable {
    static let shared = ForegroundGate()

    /// Longest a background job will sit paused before resuming regardless. A dictation is
    /// seconds; hands-free mode caps at the five-minute recording limit.
    static let maxPause: TimeInterval = 330

    private let condition = NSCondition()
    /// Reasons currently holding the gate — a dictation, a meeting's paused capture — so two
    /// overlapping holders cannot release each other's.
    private var holders: Set<String> = []
    /// Total seconds the gate has been raised, for active-time accounting.
    private var accumulatedRaised: TimeInterval = 0
    private var raisedAt: Date?
    private var waiters = 0

    init() {}

    var isRaised: Bool {
        condition.lock()
        defer { condition.unlock() }
        return !holders.isEmpty
    }

    /// Raises the gate for `holder`. Idempotent per holder.
    func begin(_ holder: String) {
        condition.lock()
        let wasRaised = !holders.isEmpty
        holders.insert(holder)
        if !wasRaised { raisedAt = Date() }
        condition.unlock()
        if !wasRaised {
            Logger.debug("ForegroundGate: raised by \(holder) — background model work pauses", subsystem: .model)
        }
    }

    /// Releases `holder`'s hold. The gate drops when the last holder leaves.
    func end(_ holder: String) {
        condition.lock()
        guard holders.remove(holder) != nil else { condition.unlock(); return }
        let lowered = holders.isEmpty
        if lowered, let since = raisedAt {
            accumulatedRaised += Date().timeIntervalSince(since)
            raisedAt = nil
        }
        let resumed = waiters
        if lowered { condition.broadcast() }
        condition.unlock()
        if lowered {
            Logger.debug("ForegroundGate: lowered by \(holder) — resuming \(resumed) paused job(s)", subsystem: .model)
        }
    }

    /// Drops every holder. For the stranded-gate recovery paths only.
    func clearAll(reason: String) {
        condition.lock()
        let had = holders
        holders.removeAll()
        if let since = raisedAt {
            accumulatedRaised += Date().timeIntervalSince(since)
            raisedAt = nil
        }
        condition.broadcast()
        condition.unlock()
        if !had.isEmpty {
            Logger.warning("ForegroundGate: cleared stranded holders \(had.sorted()) (\(reason))", subsystem: .model)
        }
    }

    /// Total seconds the gate has been raised since launch, including a raise in progress.
    /// Subtract two readings to get how long a job was paused-for over an interval.
    var raisedSecondsTotal: TimeInterval {
        condition.lock()
        defer { condition.unlock() }
        return accumulatedRaised + (raisedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    /// Wall time since `start` minus the time the gate was raised over the same interval, given
    /// `raisedAtStart = raisedSecondsTotal` read at `start`. This is what timeouts should count.
    func activeSeconds(since start: Date, raisedAtStart: TimeInterval) -> TimeInterval {
        Date().timeIntervalSince(start) - (raisedSecondsTotal - raisedAtStart)
    }

    /// Blocks the calling thread while the gate is raised. For synchronous code on a background
    /// thread — a token callback, a C decode loop. Never call on the main thread.
    /// Returns how long it waited.
    @discardableResult
    func waitWhileRaised(_ label: String, priority: ModelWorkPriority = .background) -> TimeInterval {
        guard priority == .background else { return 0 }
        condition.lock()
        guard !holders.isEmpty else { condition.unlock(); return 0 }
        if Thread.isMainThread {
            condition.unlock()
            Logger.error("ForegroundGate: \(label) tried to pause on the main thread — not pausing", subsystem: .model)
            return 0
        }
        let started = Date()
        let deadline = started.addingTimeInterval(Self.maxPause)
        waiters += 1
        Logger.debug("ForegroundGate: \(label) paused", subsystem: .model)
        while !holders.isEmpty {
            if !condition.wait(until: deadline) { break }
        }
        waiters -= 1
        let stillRaised = !holders.isEmpty
        condition.unlock()
        let waited = Date().timeIntervalSince(started)
        if stillRaised {
            Logger.warning("ForegroundGate: \(label) resumed after the \(Int(Self.maxPause))s ceiling with the gate still up", subsystem: .model)
        } else {
            Logger.debug("ForegroundGate: \(label) resumed after \(Int(waited * 1000))ms", subsystem: .model)
        }
        return waited
    }

    /// Async form: suspends (does not block a thread) while the gate is raised.
    @discardableResult
    func waitWhileRaisedAsync(_ label: String, priority: ModelWorkPriority = .background) async -> TimeInterval {
        guard priority == .background, isRaised else { return 0 }
        let started = Date()
        Logger.debug("ForegroundGate: \(label) paused", subsystem: .model)
        while isRaised, Date().timeIntervalSince(started) < Self.maxPause, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let waited = Date().timeIntervalSince(started)
        Logger.debug("ForegroundGate: \(label) resumed after \(Int(waited * 1000))ms", subsystem: .model)
        return waited
    }
}
