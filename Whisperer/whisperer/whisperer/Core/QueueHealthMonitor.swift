//
//  QueueHealthMonitor.swift
//  Whisperer
//
//  Monitors the health of critical DispatchQueues to detect hangs
//

import Foundation

/// Represents the health status of a monitored queue
enum QueueHealthStatus: Equatable {
    case healthy
    case degraded(latency: TimeInterval)
    case unresponsive
}

/// Monitors a single queue's health
class MonitoredQueue {
    let name: String
    let queue: DispatchQueue
    private var lastPingTime: Date?
    private var lastResponseTime: Date?
    private var consecutiveFailures: Int = 0

    // Health thresholds
    var warningLatency: TimeInterval = 1.0  // Warn if ping takes > 1s
    var failureLatency: TimeInterval = 3.0  // Mark unhealthy if ping takes > 3s
    var maxConsecutiveFailures: Int = 3

    var currentStatus: QueueHealthStatus {
        guard let lastResponse = lastResponseTime else {
            return .unresponsive
        }

        // Check if we're waiting for a response
        if let pingTime = lastPingTime, lastResponse < pingTime {
            let waitTime = Date().timeIntervalSince(pingTime)
            if waitTime > failureLatency {
                return .unresponsive
            } else if waitTime > warningLatency {
                return .degraded(latency: waitTime)
            }
        }

        if consecutiveFailures >= maxConsecutiveFailures {
            return .unresponsive
        }

        return .healthy
    }

    init(name: String, queue: DispatchQueue) {
        self.name = name
        self.queue = queue
    }

    /// Send a ping to the queue and measure response time
    func ping(timeout: TimeInterval = 2.0) {
        lastPingTime = Date()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lastResponseTime = Date()
            self.consecutiveFailures = 0

            if let pingTime = self.lastPingTime {
                let latency = Date().timeIntervalSince(pingTime)
                if latency > self.warningLatency {
                    Logger.warning("Queue '\(self.name)' responded slowly: \(String(format: "%.2f", latency))s", subsystem: .app)
                } else {
                    Logger.debug("Queue '\(self.name)' ping: \(String(format: "%.3f", latency))s", subsystem: .app)
                }
            }
        }

        queue.async(execute: workItem)

        // Check if it responded within timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self else { return }

            // If we sent a ping but haven't received response yet
            if let pingTime = self.lastPingTime,
               (self.lastResponseTime == nil || self.lastResponseTime! < pingTime) {
                let waitTime = Date().timeIntervalSince(pingTime)
                if waitTime >= timeout {
                    self.consecutiveFailures += 1
                    Logger.error("Queue '\(self.name)' did not respond within \(timeout)s (failure #\(self.consecutiveFailures))", subsystem: .app)
                }
            }
        }
    }
}

/// Monitors the health of critical DispatchQueues
class QueueHealthMonitor {
    static let shared = QueueHealthMonitor()

    private var monitoredQueues: [MonitoredQueue] = []
    private var monitorTimer: Timer?
    private let lock = NSLock()

    // Check health every 5 seconds
    private let checkInterval: TimeInterval = 5.0

    private init() {
        Logger.debug("QueueHealthMonitor initialized", subsystem: .app)
    }

    /// Register a queue to monitor
    func monitor(queue: DispatchQueue, name: String) {
        lock.lock()
        defer { lock.unlock() }

        let monitored = MonitoredQueue(name: name, queue: queue)
        monitoredQueues.append(monitored)

        Logger.debug("Monitoring queue: '\(name)'", subsystem: .app)
    }

    /// Start monitoring all registered queues
    func startMonitoring() {
        guard monitorTimer == nil else {
            Logger.warning("QueueHealthMonitor already running", subsystem: .app)
            return
        }

        Logger.debug("Starting queue health monitoring (interval: \(checkInterval)s)", subsystem: .app)

        // Initial ping
        pingAllQueues()

        // Schedule periodic pings
        monitorTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.pingAllQueues()
        }
    }

    /// Stop monitoring
    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        Logger.debug("Stopped queue health monitoring", subsystem: .app)
    }

    /// Ping all monitored queues
    private func pingAllQueues() {
        lock.lock()
        let queues = monitoredQueues
        lock.unlock()

        for queue in queues {
            queue.ping()
        }
    }

    /// Get health status of all queues
    func getHealthStatus() -> [(name: String, status: QueueHealthStatus)] {
        lock.lock()
        defer { lock.unlock() }

        return monitoredQueues.map { ($0.name, $0.currentStatus) }
    }

    /// Check if all queues are healthy
    var allQueuesHealthy: Bool {
        let statuses = getHealthStatus()
        return statuses.allSatisfy { $0.status == .healthy }
    }

    /// Get unhealthy queues
    func getUnhealthyQueues() -> [String] {
        let statuses = getHealthStatus()
        return statuses.filter { $0.status != .healthy }.map { $0.name }
    }

    /// Log current health status
    func logHealthStatus() {
        let statuses = getHealthStatus()

        if allQueuesHealthy {
            Logger.debug("All queues healthy (\(statuses.count) monitored)", subsystem: .app)
        } else {
            Logger.warning("Queue health issues detected:", subsystem: .app)
            for (name, status) in statuses where status != .healthy {
                switch status {
                case .healthy:
                    break
                case .degraded(let latency):
                    Logger.warning("  - \(name): DEGRADED (latency: \(String(format: "%.2f", latency))s)", subsystem: .app)
                case .unresponsive:
                    Logger.error("  - \(name): UNRESPONSIVE", subsystem: .app)
                }
            }
        }
    }
}
