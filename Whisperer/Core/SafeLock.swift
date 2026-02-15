//
//  SafeLock.swift
//  Whisperer
//
//  Thread-safe lock wrapper with timeout to prevent deadlocks
//

import Foundation

/// Error thrown when lock acquisition times out
enum SafeLockError: Error, LocalizedError {
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
final class SafeLock {
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

    /// Execute an async block with the lock held
    /// - Parameters:
    ///   - timeout: Maximum time to wait for lock
    ///   - block: Async block to execute
    /// - Returns: Result of the block
    func withLockAsync<T>(timeout: TimeInterval? = nil, _ block: @Sendable () async throws -> T) async throws -> T {
        let actualTimeout = timeout ?? defaultTimeout
        let deadline = Date().addingTimeInterval(actualTimeout)

        // Try to acquire lock with timeout using async-safe approach
        while true {
            // Check if we can acquire the lock
            if lock.try() {
                // Lock acquired
                break
            }

            if Date() > deadline {
                Logger.error("Lock acquisition timeout after \(actualTimeout)s", subsystem: .app)
                throw SafeLockError.timeout(duration: actualTimeout)
            }

            // Small sleep to avoid busy-waiting
            try await Task.sleep(nanoseconds: 1_000_000)  // 1ms
        }

        // Ensure unlock happens even if task is cancelled
        defer { lock.unlock() }

        do {
            return try await block()
        } catch {
            Logger.error("Error in async locked block: \(error)", subsystem: .app)
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
