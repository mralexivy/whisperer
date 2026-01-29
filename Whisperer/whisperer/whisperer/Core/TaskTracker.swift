//
//  TaskTracker.swift
//  Whisperer
//
//  Tracks async task lifecycle to detect orphaned/failed operations
//

import Foundation

/// Represents a tracked task
struct TrackedTask {
    let id: String
    let name: String
    let startTime: Date
    var endTime: Date?
    var success: Bool?
    var error: Error?
    var isCancelled: Bool = false

    var duration: TimeInterval? {
        guard let endTime = endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    var isOrphaned: Bool {
        // Task is orphaned if it started but never completed/cancelled
        return endTime == nil && !isCancelled
    }
}

/// Tracks lifecycle of async operations to detect failures
final class TaskTracker {
    static let shared = TaskTracker()

    private var tasks: [String: TrackedTask] = [:]
    private let lock = NSLock()
    private let cleanupInterval: TimeInterval = 60.0  // Clean up old tasks every minute
    private var lastCleanup = Date()

    private init() {
        Logger.debug("TaskTracker initialized", subsystem: .app)
    }

    /// Start tracking a task
    /// - Parameters:
    ///   - id: Unique identifier for the task
    ///   - name: Human-readable task name
    func trackTask(id: String, name: String) {
        lock.lock()
        defer { lock.unlock() }

        let task = TrackedTask(id: id, name: name, startTime: Date())
        tasks[id] = task

        Logger.debug("[TASK:\(id)] Started: \(name)", subsystem: .app)

        // Periodic cleanup
        maybeCleanup()
    }

    /// Mark a task as completed
    /// - Parameters:
    ///   - id: Task identifier
    ///   - success: Whether task completed successfully
    ///   - error: Optional error if task failed
    func taskCompleted(id: String, success: Bool, error: Error? = nil) {
        lock.lock()
        defer { lock.unlock() }

        guard var task = tasks[id] else {
            Logger.warning("[TASK:\(id)] Completed but not found in tracker", subsystem: .app)
            return
        }

        task.endTime = Date()
        task.success = success
        task.error = error
        tasks[id] = task

        if let duration = task.duration {
            if success {
                Logger.debug("[TASK:\(id)] Completed in \(String(format: "%.2f", duration))s", subsystem: .app)
            } else {
                Logger.error("[TASK:\(id)] FAILED in \(String(format: "%.2f", duration))s: \(error?.localizedDescription ?? "unknown error")", subsystem: .app)
            }
        }
    }

    /// Mark a task as cancelled
    /// - Parameters:
    ///   - id: Task identifier
    ///   - reason: Reason for cancellation
    func taskCancelled(id: String, reason: String) {
        lock.lock()
        defer { lock.unlock() }

        guard var task = tasks[id] else {
            Logger.warning("[TASK:\(id)] Cancelled but not found in tracker", subsystem: .app)
            return
        }

        task.endTime = Date()
        task.isCancelled = true
        tasks[id] = task

        if let duration = task.duration {
            Logger.debug("[TASK:\(id)] Cancelled after \(String(format: "%.2f", duration))s: \(reason)", subsystem: .app)
        }
    }

    /// Get all orphaned tasks (started but never completed/cancelled)
    /// - Returns: Array of orphaned tasks
    func getOrphanedTasks() -> [TrackedTask] {
        lock.lock()
        defer { lock.unlock() }

        return tasks.values.filter { $0.isOrphaned }
    }

    /// Check for orphaned tasks and log warnings
    func checkForOrphans() {
        let orphans = getOrphanedTasks()

        if !orphans.isEmpty {
            Logger.warning("Found \(orphans.count) orphaned task(s):", subsystem: .app)
            for orphan in orphans {
                let age = Date().timeIntervalSince(orphan.startTime)
                Logger.warning("  - [\(orphan.id)] \(orphan.name) (running for \(String(format: "%.1f", age))s)", subsystem: .app)
            }
        }
    }

    /// Get task statistics
    func getStatistics() -> (total: Int, completed: Int, failed: Int, cancelled: Int, orphaned: Int) {
        lock.lock()
        defer { lock.unlock() }

        let completed = tasks.values.filter { $0.success == true }.count
        let failed = tasks.values.filter { $0.success == false }.count
        let cancelled = tasks.values.filter { $0.isCancelled }.count
        let orphaned = tasks.values.filter { $0.isOrphaned }.count

        return (tasks.count, completed, failed, cancelled, orphaned)
    }

    // MARK: - Private

    private func maybeCleanup() {
        guard Date().timeIntervalSince(lastCleanup) > cleanupInterval else { return }

        // Remove completed/cancelled tasks older than 5 minutes
        let cutoff = Date().addingTimeInterval(-300)
        tasks = tasks.filter { _, task in
            if let endTime = task.endTime, endTime < cutoff {
                return false  // Remove old completed tasks
            }
            return true  // Keep active or recent tasks
        }

        lastCleanup = Date()
        Logger.debug("TaskTracker cleanup: \(tasks.count) tasks remaining", subsystem: .app)
    }
}

// MARK: - Convenience Extensions

extension TaskTracker {
    /// Track an async task with automatic completion tracking
    /// - Parameters:
    ///   - name: Task name
    ///   - operation: Async operation to track
    /// - Returns: Result of the operation
    func track<T>(_ name: String, operation: () async throws -> T) async throws -> T {
        let id = UUID().uuidString
        trackTask(id: id, name: name)

        do {
            let result = try await operation()
            taskCompleted(id: id, success: true)
            return result
        } catch {
            taskCompleted(id: id, success: false, error: error)
            throw error
        }
    }
}
