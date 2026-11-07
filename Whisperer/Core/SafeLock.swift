//
//  SafeLock.swift
//  Whisperer
//
//  Thread-safe lock wrapper with timeout to prevent deadlocks
//

import Foundation

/// Error thrown when lock acquisition times out
nonisolated enum SafeLockError: Error, LocalizedError {
    case timeout(duration: TimeInterval)
    case lockFailed

    var errorDescription: String? {
        switch self {
        case .timeout(let duration):
            return "Failed to acquire lock within \(duration) seconds"
        case .lockFailed:
            return "Failed to acquire lock"
        }
    }
}

/// Thread-safe lock wrapper with timeout protection
// `nonisolated` for the same reason as `VADSegmenter` — see the note there. A lock whose entire
// purpose is to be taken from whichever thread reaches it cannot meaningfully be main-actor
// isolated, and the isolated deinit that `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` gives it
// aborts the process when it is released off a task, which is how a corpus sweep died in
// `SafeLock.deinit`.
nonisolated final class SafeLock: @unchecked Sendable {  // all mutable state is the NSLock itself
    private let lock = NSLock()
    private let defaultTimeout: TimeInterval

    /// Create a new safe lock
    /// - Parameter defaultTimeout: Default timeout in seconds (default: 5.0)
    init(defaultTimeout: TimeInterval = 5.0) {
        self.defaultTimeout = defaultTimeout
    }

    /// Execute a block with the lock held, with timeout protection
    /// - Parameters:
    ///   - timeout: Maximum time to wait for lock (uses default if not specified)
    ///   - block: Block to execute while lock is held
    /// - Returns: Result of the block
    /// - Throws: SafeLockError.timeout if lock cannot be acquired, or any error thrown by block
    func withLock<T>(timeout: TimeInterval? = nil, _ block: () throws -> T) throws -> T {
        let actualTimeout = timeout ?? defaultTimeout
        let deadline = Date().addingTimeInterval(actualTimeout)

        // Try to acquire lock with timeout
        while !lock.try() {
            if Date() > deadline {
                Logger.error("Lock acquisition timeout after \(actualTimeout)s", subsystem: .app)
                throw SafeLockError.timeout(duration: actualTimeout)
            }
            // Small sleep to avoid busy-waiting
            Thread.sleep(forTimeInterval: 0.001)  // 1ms
        }

        // Lock acquired
        defer { lock.unlock() }

        do {
            return try block()
        } catch {
            Logger.error("Error in locked block: \(error)", subsystem: .app)
            throw error
        }
    }

    /// Try to acquire lock without blocking
    /// - Returns: True if lock was acquired, false otherwise
    func tryLock() -> Bool {
        return lock.try()
    }

    /// Manually unlock (use with caution - prefer withLock)
    func unlock() {
        lock.unlock()
    }
}
