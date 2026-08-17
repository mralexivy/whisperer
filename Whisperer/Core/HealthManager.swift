//
//  HealthManager.swift
//  Whisperer
//
//  Progress-based silent monitoring. Logs nothing during healthy operation.
//  On SLA breach: one structured alert, exponential backoff, diagnostic dump.
//

import Foundation
import AppKit

// MARK: - Shared Types

/// Component decides its own status — HealthManager only aggregates.
enum ComponentStatus: String {
    case healthy
    case busy     // late but still making progress — not yet alarming
    case stalled  // late AND no recent progress
}

/// Richer progress: monotonic sequence counter + fractional completeness + last update.
struct ProgressInfo {
    var sequence: UInt64 = 0
    var completedWork: Double = 0.0   // 0.0–1.0
    var lastUpdate: ContinuousClock.Instant = .now
}

/// Per-operation identity and timing. `deadline` is mutable — component extends it as work proceeds.
struct OperationInfo {
    let id: UInt64                              // monotonic, e.g. 184
    let name: String
    let started: ContinuousClock.Instant
    var deadline: ContinuousClock.Instant       // component updates this as it learns more
    let queueBacklog: Int
}

/// Full health snapshot from one component, read on every polling tick.
struct ComponentHealth {
    var status: ComponentStatus = .healthy
    var operation: OperationInfo?               // nil when idle
    var progress: ProgressInfo = ProgressInfo()
    var dependencies: [String] = []            // names of components this one waits on
    var metadata: [String: MetadataValue] = [:]
}

/// Any component that wants HealthManager to monitor it implements this.
protocol HealthReportable: AnyObject {
    var componentName: String { get }
    var healthState: ComponentHealth { get }
}

// MARK: - HealthManager

final class HealthManager {

    static let shared = HealthManager()

    // MARK: - State

    private let monitorQueue = DispatchQueue(label: "health.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// Weak, and deliberately so. This registry used to hold components strongly with no
    /// `unregister` call anywhere in the app, so **every `StreamingTranscriber` ever created
    /// stayed here for the life of the process** — leaked along with its ring buffer and eager
    /// engine, and still polled once a second. That is where the duplicate name came from: not
    /// two concurrent recordings, but twenty finished ones, all still named
    /// "StreamingTranscriber". A torn-down instance also keeps whatever operation it was in the
    /// middle of when it was released, so it eventually reports `.stalled` and drags the stall
    /// reporter in after it.
    ///
    /// Weak references make correctness independent of call-site discipline: an owner that
    /// forgets to unregister still drops out of the registry when it is deallocated. Dead entries
    /// are pruned in `poll()`.
    private struct WeakComponent {
        weak var value: HealthReportable?
    }
    private var components: [ObjectIdentifier: WeakComponent] = [:]

    // Stall tracking per component
    private struct StallState {
        var alertedAt: ContinuousClock.Instant?
        var nextAlertDelay: Duration = .seconds(5)
        var criticalDumpFired: Bool = false
        var lastSequence: UInt64 = 0
        var lastStatus: ComponentStatus = .healthy
    }

    /// Keyed by instance identity — the same key `components` uses — **not** by
    /// `componentName`.
    ///
    /// Name-keying made two live instances of one class share a single stall state, which is
    /// routine here: a recording starts before the previous `StreamingTranscriber` has been
    /// released, and the old one is the instance most likely to be stalled. Within a single
    /// `poll()` the stalled instance wrote `alertedAt`/`nextAlertDelay`/`criticalDumpFired` and
    /// the healthy one immediately replaced the whole struct with a fresh `StallState()` (its
    /// `alertedAt != nil && seq != lastSequence` branch is satisfied by the sibling's write).
    /// The 5s→80s backoff therefore never engaged: the ⚠️ Stall warning fired *every tick* —
    /// 0.25s in `.watchful`, which a stall itself forces — and `criticalDumpFired` was cleared
    /// each time, so `triggerDump` re-ran `/usr/bin/sample` repeatedly, suspending every thread
    /// in the process. The same shared key also flipped `lastStatus` back and forth, appending a
    /// spurious `stalled → healthy` pair to the timeline every tick until it hit its 500-entry
    /// cap and evicted the history the dump exists to show.
    ///
    /// Identity keying makes all of that structurally impossible rather than patching one site.
    /// `buildDependencyChain` stays name-based because `ComponentHealth.dependencies` is
    /// `[String]` — declared by name, so the ambiguity there is inherent and handled separately.
    ///
    /// **Confined to `monitorQueue`.** Every access is on the poll queue, so the
    /// read-modify-writes in the two handlers are atomic by construction. They used to read
    /// unlocked and write under `lock` while `register()`/`recordingStarted()` wrote from the
    /// main actor — a genuine `Dictionary` data race, and a lost update even when it did not
    /// tear. Taking `lock` in the handlers instead is not an option: `handleStalledComponent`
    /// calls `snapshot()`, which takes the same non-recursive `NSLock`.
    private var stallStates: [ObjectIdentifier: StallState] = [:]

    // Health timeline — status-change events only
    private var timeline: [(offset: Double, component: String, from: ComponentStatus, to: ComponentStatus)] = []
    private var timelineStart: ContinuousClock.Instant?
    private var timelineLock = NSLock()

    // Main thread monitor — protected by mainThreadLock (accessed from monitorQueue and DispatchQueue.main)
    private let mainThreadLock = NSLock()
    private var mainThreadPendingSince: ContinuousClock.Instant?
    private var lastMainThreadResponse: ContinuousClock.Instant = .now
    private var mainThreadAlertFired: Bool = false
    // Startup suppression: model loading causes expected GPU-queue stalls that are not real hangs.
    private var suppressStallUntil: ContinuousClock.Instant?

    func suppressForStartup(seconds: Double) {
        suppressStallUntil = .now + .seconds(seconds)
    }

    // Lock protecting components dict and stall states
    private let lock = NSLock()

    private static let warnThreshold: Duration   = .seconds(2)
    private static let criticalThreshold: Duration = .seconds(10)
    private static let maxBackoffDelay: Duration = .seconds(80)
    /// Log a main-thread warning at 1.5s. A Debug-build whisper.cpp decode blocks main for ~1s
    /// routinely, so the old 500ms bar fired on healthy recordings several times a minute.
    private static let mainThreadWarnThreshold: Duration = .milliseconds(1500)
    /// Write a full dump only past 3s — see the comment at the call site.
    private static let mainThreadDumpThreshold: Duration = .seconds(3)

    private init() {}

    // MARK: - Registration

    /// No `stallStates` seeding here any more — the poll handlers default a missing entry, so
    /// registration never touches state that lives on `monitorQueue`.
    func register(_ component: HealthReportable) {
        let key = ObjectIdentifier(component)
        lock.lock()
        components[key] = WeakComponent(value: component)
        lock.unlock()
    }

    func unregister(_ component: HealthReportable) {
        let key = ObjectIdentifier(component)
        lock.lock()
        components.removeValue(forKey: key)
        lock.unlock()
        monitorQueue.async { [weak self] in self?.stallStates.removeValue(forKey: key) }
    }

    // MARK: - Lifecycle

    func startMonitoring() {
        guard timer == nil else { return }
        Logger.info("HealthManager started", subsystem: .app)

        let t = DispatchSource.makeTimerSource(queue: monitorQueue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t

        // ContinuousClock advances during Mac sleep, so a pending main-thread check
        // that spans sleep reports a huge stale elapsed time. Reset on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.monitorQueue.async { [weak self] in
                guard let self else { return }
                self.mainThreadLock.lock()
                self.mainThreadPendingSince = nil
                self.mainThreadAlertFired = false
                self.mainThreadLock.unlock()
            }
        }

        timelineStart = .now
    }

    func stopMonitoring() {
        timer?.cancel()
        timer = nil
        Logger.info("HealthManager stopped", subsystem: .app)
    }

    // MARK: - Recording lifecycle hooks

    func recordingStarted() {
        EventRingBuffer.shared.recordingStart = .now
        timelineLock.lock()
        timelineStart = .now
        timeline.removeAll()
        timelineLock.unlock()
        // Reset stall states on the queue that owns them. Dropping the entries is the reset —
        // the handlers default a missing key to a fresh `StallState()`.
        monitorQueue.async { [weak self] in self?.stallStates.removeAll() }
        adjustPollingRate(.watchful)  // fast polling immediately when recording starts
    }

    func recordingStopped() {
        EventRingBuffer.shared.recordingStart = nil
    }

    // MARK: - Diagnostic snapshot (callable on demand)

    func snapshot() -> String {
        lock.lock()
        let snapshot = components.values.compactMap { box in
            box.value.map { ($0.componentName, $0.healthState) }
        }
        lock.unlock()

        var lines = ["## Component Health"]
        for (name, health) in snapshot.sorted(by: { $0.0 < $1.0 }) {
            let icon = health.status == .healthy ? "✓" : health.status == .busy ? "⚠" : "✗"
            var line = "  \(icon) \(name)  status=\(health.status.rawValue)"
            if let op = health.operation {
                line += "  op=#\(op.id).\(op.name)  backlog=\(op.queueBacklog)"
                let elapsed = ContinuousClock.now - op.started
                line += "  elapsed=\(String(format: "%.1f", elapsedSeconds(elapsed)))s"
            }
            line += "  seq=\(health.progress.sequence)"
            if !health.dependencies.isEmpty {
                line += "  waitingOn=\(health.dependencies.joined(separator: ","))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    func formattedTimeline() -> String {
        timelineLock.lock()
        let entries = timeline
        timelineLock.unlock()

        guard !entries.isEmpty else { return "_no status changes recorded_" }
        return entries.map { e in
            let sign = e.offset >= 0 ? "+" : ""
            return "\(sign)\(String(format: "%.1f", e.offset))s  \(e.component)  \(e.from.rawValue) → \(e.to.rawValue)"
        }.joined(separator: "\n")
    }

    // MARK: - Private polling

    private func poll() {
        checkMainThread()

        lock.lock()
        // Prune deallocated components before reading. Without this a released component's slot
        // lingers until the next `register`.
        var deadKeys: [ObjectIdentifier] = []
        for (key, box) in components where box.value == nil {
            components.removeValue(forKey: key)
            deadKeys.append(key)
        }
        let entries = components.compactMap { key, box in
            box.value.map { (key: key, name: $0.componentName, health: $0.healthState) }
        }
        lock.unlock()

        // Retire the dead instances' stall state too. It used to survive, so the next instance
        // registered under the same name inherited a stranger's `alertedAt` and
        // `criticalDumpFired`.
        for key in deadKeys { stallStates.removeValue(forKey: key) }

        var anyStalled = false
        var anyBusy = false

        // `buildDependencyChain` still wants (name, health) pairs.
        let snapshot = entries.map { ($0.name, $0.health) }

        for entry in entries {
            let prev = stallStates[entry.key]?.lastStatus ?? .healthy
            let current = entry.health.status

            // Record timeline transitions
            if current != prev {
                recordTimelineTransition(component: entry.name, from: prev, to: current)
                stallStates[entry.key, default: StallState()].lastStatus = current
            }

            switch current {
            case .healthy:
                handleHealthyComponent(key: entry.key, name: entry.name, health: entry.health)
            case .busy:
                anyBusy = true
                // Busy = working, just late — don't alarm
            case .stalled:
                anyStalled = true
                handleStalledComponent(key: entry.key, name: entry.name, health: entry.health,
                                       allComponents: snapshot)
            }
        }

        // Adapt polling rate
        if anyStalled || anyBusy {
            adjustPollingRate(.watchful)
        } else if EventRingBuffer.shared.recordingStart != nil {
            adjustPollingRate(.healthy)
        } else {
            adjustPollingRate(.idle)
        }
    }

    private func handleHealthyComponent(key: ObjectIdentifier, name: String, health: ComponentHealth) {
        var stall = stallStates[key] ?? StallState()
        let seq = health.progress.sequence

        if stall.alertedAt != nil && seq != stall.lastSequence {
            // Was stalled, now progressing again
            if let alertedAt = stall.alertedAt {
                let elapsed = ContinuousClock.now - alertedAt
                let elapsedStr = String(format: "%.1f", elapsedSeconds(elapsed))
                let completedStr = String(format: "%.0f%%", health.progress.completedWork * 100)
                Logger.info("✓ \(name) recovered  elapsed=\(elapsedStr)s  completedWork=\(completedStr)  auto_recovery=YES", subsystem: .app)
            }
            stall = StallState()
            stall.lastStatus = .healthy
            stallStates[key] = stall
        } else {
            stallStates[key, default: StallState()].lastSequence = seq
        }
    }

    private func handleStalledComponent(
        key: ObjectIdentifier,
        name: String,
        health: ComponentHealth,
        allComponents: [(String, ComponentHealth)]
    ) {
        var stall = stallStates[key] ?? StallState()
        let now = ContinuousClock.now

        if let alertedAt = stall.alertedAt {
            let sinceAlert = now - alertedAt
            if sinceAlert < stall.nextAlertDelay { return }  // still in backoff window

            // Backoff: 5s → 10s → 20s → 40s → 80s cap
            stall.nextAlertDelay = Swift.min(stall.nextAlertDelay * 2, Self.maxBackoffDelay)
        } else {
            stall.alertedAt = now
        }

        // Build stall message
        let opStr: String
        if let op = health.operation {
            let elapsed = now - op.started
            let deadline = op.deadline
            opStr = "#\(op.id).\(op.name)  started=\(String(format: "%.1f", elapsedSeconds(now - op.started)))s ago  deadline=+\(String(format: "%.1f", elapsedSeconds(deadline - op.started)))s  pct=\(String(format: "%.0f%%", health.progress.completedWork * 100))  backlog=\(op.queueBacklog)"
            _ = elapsed  // suppress unused warning
        } else {
            opStr = "no operation info"
        }

        let rootChain = buildDependencyChain(stalled: name, allComponents: allComponents)

        Logger.warning("""
            ⚠️ Stall: \(name)  \(opStr)
            \(snapshot())
              Dependencies: \(rootChain)
            """, subsystem: .app)

        // Critical threshold — write dump
        if let op = health.operation {
            let elapsed = ContinuousClock.now - op.started
            if !stall.criticalDumpFired && elapsed > Self.criticalThreshold {
                stall.criticalDumpFired = true
                triggerDump(reason: "\(name) stalled >\(Int(Self.criticalThreshold.components.seconds))s  op=\(opStr)")
            }
        }

        stallStates[key] = stall
    }

    private func buildDependencyChain(stalled: String, allComponents: [(String, ComponentHealth)]) -> String {
        // `uniquingKeysWith`, not `uniqueKeysWithValues`. The registry is keyed by
        // `ObjectIdentifier`, so two live components may share a `componentName` — which is
        // exactly what happens when a recording starts before the previous `StreamingTranscriber`
        // has been released, and the old one is precisely the instance most likely to be stalled.
        // `uniqueKeysWithValues` traps on that duplicate, so the diagnostic that exists to report
        // a stall was instead crashing the app during one:
        // `Fatal error: Duplicate values for key: 'StreamingTranscriber'`.
        // Keep the stalled one when names collide — it is the subject of the report.
        let nameToHealth = Dictionary(allComponents) { lhs, rhs in
            rhs.status == .stalled ? rhs : lhs
        }
        var chain: [String] = []
        var visited = Set<String>()

        func walk(_ name: String) {
            guard !visited.contains(name) else { return }
            visited.insert(name)
            chain.append(name)
            guard let health = nameToHealth[name] else { return }
            for dep in health.dependencies {
                walk(dep)
            }
        }
        walk(stalled)
        return chain.joined(separator: " → ")
    }

    // MARK: - Main thread monitor (non-blocking)

    private func checkMainThread() {
        let now = ContinuousClock.now

        // Read state under lock — mainThreadPendingSince is written from DispatchQueue.main
        mainThreadLock.lock()
        let pendingSince = mainThreadPendingSince
        let alreadyAlerted = mainThreadAlertFired
        mainThreadLock.unlock()

        if pendingSince == nil {
            mainThreadLock.lock()
            mainThreadPendingSince = now
            mainThreadLock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Piggy-backs on the liveness ping: this is a block that is, by construction,
                // running on the main thread, which is the only place its mach port can be read.
                MainThreadBacktrace.registerMainThread()
                self.mainThreadLock.lock()
                self.lastMainThreadResponse = .now
                self.mainThreadPendingSince = nil
                self.mainThreadAlertFired = false
                self.mainThreadLock.unlock()
            }
            // Elapsed on this tick would be ~0 — skip the check until next poll.
            return
        }

        if let pending = pendingSince {
            let elapsed = now - pending
            // ContinuousClock advances through Mac sleep. If the pending timestamp was captured
            // before a sleep period, elapsed will be enormous after wake — a false positive.
            // Any elapsed > 30s cannot be a real main-thread hang; reset and re-probe instead.
            if elapsed > .seconds(30) {
                mainThreadLock.lock()
                mainThreadPendingSince = nil
                mainThreadAlertFired = false
                mainThreadLock.unlock()
                return
            }
            if elapsed > Self.mainThreadWarnThreshold && !alreadyAlerted {
                if let suppress = suppressStallUntil, now < suppress { return }
                mainThreadLock.lock()
                mainThreadAlertFired = true
                mainThreadLock.unlock()
                let elapsedStr = String(format: "%.1f", elapsedSeconds(elapsed))
                // Captured here, not in triggerDump: the dump hops to @MainActor, so by the time
                // it runs the hang is over and the stack that caused it is gone. This poll runs
                // on `monitorQueue` while the main thread is still wedged — the only moment the
                // blocking frame can be read.
                MainThreadBacktrace.capture(reason: "Main thread unresponsive for \(elapsedStr)s")
                Logger.error("Main thread unresponsive for \(elapsedStr)s — possible AppKit/AX hang", subsystem: .app)
                EventRingBuffer.shared.record(
                    component: "MainThread",
                    operation: "hung",
                    kind: .error,
                    metadata: ["elapsed": .double(elapsedSeconds(elapsed))]
                )
                // Only a *sustained* block is worth a dump. A sub-3s block is almost always a
                // synchronous whisper.cpp decode or a Metal command-buffer wait — expected work,
                // not a hang. Dumping on those was self-defeating: each dump runs `/usr/bin/sample`
                // against a live task, which suspends every thread in the process to walk their
                // stacks, so the "diagnostic" froze the app mid-transcription. The in-process
                // `MainThreadBacktrace.capture` above already records the blocking frame for free
                // and always runs.
                if elapsed > Self.mainThreadDumpThreshold {
                    triggerDump(reason: "Main thread unresponsive for \(elapsedStr)s")
                }
            }
        }
    }

    // MARK: - Dump trigger

    private nonisolated func triggerDump(reason: String) {
        Task { @MainActor in
            StuckStateDumper.dump(reason: reason)
        }
    }

    // MARK: - Polling rate

    private enum PollingRate {
        case idle       // 2.0s
        case healthy    // 1.0s
        case watchful   // 0.25s
    }

    private var currentRate: PollingRate = .idle

    private func adjustPollingRate(_ rate: PollingRate) {
        guard rate != currentRate else { return }
        currentRate = rate

        let interval: Double
        switch rate {
        case .idle:     interval = 2.0
        case .healthy:  interval = 1.0
        case .watchful: interval = 0.25
        }
        timer?.schedule(deadline: .now() + interval, repeating: interval)
    }

    // MARK: - Timeline

    private func recordTimelineTransition(component: String, from: ComponentStatus, to: ComponentStatus) {
        timelineLock.lock()
        defer { timelineLock.unlock() }
        let offset: Double
        if let start = timelineStart {
            offset = elapsedSeconds(ContinuousClock.now - start)
        } else {
            offset = 0.0
        }
        timeline.append((offset: offset, component: component, from: from, to: to))
        // Cap timeline to 500 entries
        if timeline.count > 500 { timeline.removeFirst(timeline.count - 500) }
    }

    // MARK: - Helpers

    private func elapsedSeconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}

// Expose elapsedSeconds publicly for StuckStateDumper
extension HealthManager {
    static func durationSeconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}
