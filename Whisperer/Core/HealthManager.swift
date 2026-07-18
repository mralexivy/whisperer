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

    private var components: [ObjectIdentifier: HealthReportable] = [:]
    private var componentNames: [ObjectIdentifier: String] = [:]

    // Stall tracking per component
    private struct StallState {
        var alertedAt: ContinuousClock.Instant?
        var nextAlertDelay: Duration = .seconds(5)
        var criticalDumpFired: Bool = false
        var lastSequence: UInt64 = 0
        var lastStatus: ComponentStatus = .healthy
    }
    private var stallStates: [String: StallState] = [:]

    // Health timeline — status-change events only
    private var timeline: [(offset: Double, component: String, from: ComponentStatus, to: ComponentStatus)] = []
    private var timelineStart: ContinuousClock.Instant?
    private var timelineLock = NSLock()

    // Main thread monitor
    private var mainThreadPendingSince: ContinuousClock.Instant?
    private var lastMainThreadResponse: ContinuousClock.Instant = .now
    private var mainThreadAlertFired: Bool = false

    // Lock protecting components dict and stall states
    private let lock = NSLock()

    private static let warnThreshold: Duration   = .seconds(2)
    private static let criticalThreshold: Duration = .seconds(10)
    private static let maxBackoffDelay: Duration = .seconds(80)

    private init() {}

    // MARK: - Registration

    func register(_ component: HealthReportable) {
        let key = ObjectIdentifier(component)
        lock.lock()
        components[key] = component
        componentNames[key] = component.componentName
        if stallStates[component.componentName] == nil {
            stallStates[component.componentName] = StallState()
        }
        lock.unlock()
    }

    func unregister(_ component: HealthReportable) {
        let key = ObjectIdentifier(component)
        lock.lock()
        components.removeValue(forKey: key)
        componentNames.removeValue(forKey: key)
        lock.unlock()
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
        lock.lock()
        // Reset stall states for all components
        for name in stallStates.keys {
            stallStates[name] = StallState()
        }
        lock.unlock()
        adjustPollingRate(.watchful)  // fast polling immediately when recording starts
    }

    func recordingStopped() {
        EventRingBuffer.shared.recordingStart = nil
    }

    // MARK: - Diagnostic snapshot (callable on demand)

    func snapshot() -> String {
        lock.lock()
        let snapshot = components.values.map { ($0.componentName, $0.healthState) }
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
        let snapshot = components.values.map { c in (c.componentName, c.healthState) }
        lock.unlock()

        var anyStalled = false
        var anyBusy = false

        for (name, health) in snapshot {
            let prev = stallStates[name]?.lastStatus ?? .healthy
            let current = health.status

            // Record timeline transitions
            if current != prev {
                recordTimelineTransition(component: name, from: prev, to: current)
                lock.lock()
                stallStates[name]?.lastStatus = current
                lock.unlock()
            }

            switch current {
            case .healthy:
                handleHealthyComponent(name: name, health: health)
            case .busy:
                anyBusy = true
                // Busy = working, just late — don't alarm
            case .stalled:
                anyStalled = true
                handleStalledComponent(name: name, health: health, allComponents: snapshot)
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

    private func handleHealthyComponent(name: String, health: ComponentHealth) {
        guard var stall = stallStates[name] else { return }
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
            lock.lock()
            stallStates[name] = stall
            lock.unlock()
        } else {
            lock.lock()
            stallStates[name]?.lastSequence = seq
            lock.unlock()
        }
    }

    private func handleStalledComponent(
        name: String,
        health: ComponentHealth,
        allComponents: [(String, ComponentHealth)]
    ) {
        guard var stall = stallStates[name] else { return }
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

        lock.lock()
        stallStates[name] = stall
        lock.unlock()
    }

    private func buildDependencyChain(stalled: String, allComponents: [(String, ComponentHealth)]) -> String {
        let nameToHealth = Dictionary(uniqueKeysWithValues: allComponents)
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

        if mainThreadPendingSince == nil {
            mainThreadPendingSince = now
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastMainThreadResponse = .now
                self.mainThreadPendingSince = nil
                self.mainThreadAlertFired = false
            }
        }

        if let pending = mainThreadPendingSince {
            let elapsed = now - pending
            if elapsed > .milliseconds(500) && !mainThreadAlertFired {
                mainThreadAlertFired = true
                let elapsedStr = String(format: "%.1f", elapsedSeconds(elapsed))
                Logger.error("Main thread unresponsive for \(elapsedStr)s — possible AppKit/AX hang", subsystem: .app)
                EventRingBuffer.shared.record(
                    component: "MainThread",
                    operation: "hung",
                    kind: .error,
                    metadata: ["elapsed": .double(elapsedSeconds(elapsed))]
                )
                triggerDump(reason: "Main thread unresponsive for \(elapsedStr)s")
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
