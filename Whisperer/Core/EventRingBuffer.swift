//
//  EventRingBuffer.swift
//  Whisperer
//
//  Thread-safe circular buffer of diagnostic events. Never writes to disk.
//  Captured at stall time and embedded in dump files.
//
//  OSAllocatedUnfairLock is Sendable by design — no @unchecked needed.
//  record() uses withLockIfAvailable (non-blocking try-lock) so the real-time
//  audio callback drops an event rather than blocking.
//

import Foundation
import os

enum EventKind: String {
    case state
    case progress
    case error
    case recovery
    case performance
}

enum MetadataValue: CustomStringConvertible {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    var description: String {
        switch self {
        case .string(let v): return v
        case .int(let v):    return "\(v)"
        case .double(let v): return String(format: "%.3f", v)
        case .bool(let v):   return v ? "true" : "false"
        }
    }
}

struct HealthEvent {
    let offset: Double       // seconds from recordingStart (negative = before recording)
    let component: String
    let operation: String
    let kind: EventKind
    let metadata: [String: MetadataValue]

    var formatted: String {
        let sign = offset >= 0 ? "+" : ""
        var parts = "\(sign)\(String(format: "%.2f", offset))s  \(component)  \(operation)  [\(kind.rawValue)]"
        if !metadata.isEmpty {
            let meta = metadata.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            parts += "  \(meta)"
        }
        return parts
    }
}

// Internal state bundled to minimize lock-region footprint
private struct RingState {
    var events: [HealthEvent?]
    var head: Int = 0
    var count: Int = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.events = [HealthEvent?](repeating: nil, count: capacity)
    }

    mutating func append(_ event: HealthEvent) {
        events[head] = event
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    func takeLast(_ n: Int) -> [HealthEvent] {
        let take = min(n, count)
        guard take > 0 else { return [] }
        var result: [HealthEvent] = []
        result.reserveCapacity(take)
        let oldest = (head - count + capacity) % capacity
        for i in 0..<take {
            let index = (oldest + (count - take) + i) % capacity
            if let event = events[index] { result.append(event) }
        }
        return result
    }
}

final class EventRingBuffer: Sendable {

    static let shared = EventRingBuffer(capacity: 4096)

    // OSAllocatedUnfairLock is itself Sendable — no @unchecked needed
    private let state: OSAllocatedUnfairLock<RingState>

    // Set to .now when recording begins, nil when idle.
    // Protected by state lock since record() reads it.
    private let startLock = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

    var recordingStart: ContinuousClock.Instant? {
        get { startLock.withLock { $0 } }
        set { startLock.withLock { $0 = newValue } }
    }

    init(capacity: Int) {
        state = OSAllocatedUnfairLock(initialState: RingState(capacity: capacity))
    }

    func record(
        component: String,
        operation: String,
        kind: EventKind,
        metadata: [String: MetadataValue] = [:]
    ) {
        let now = ContinuousClock.now
        let start = startLock.withLockIfAvailable { $0 } ?? nil
        let offset: Double
        if let s = start {
            let d = now - s
            offset = Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
        } else {
            offset = 0.0
        }

        let event = HealthEvent(offset: offset, component: component, operation: operation, kind: kind, metadata: metadata)

        // Non-blocking try-lock — real-time audio callback drops event rather than blocking
        state.withLockIfAvailable { ring in ring.append(event) }
    }

    /// Returns up to `n` most recent events in chronological order.
    func snapshot(last n: Int = 200) -> [HealthEvent] {
        state.withLock { $0.takeLast(n) }
    }

    func formattedSnapshot(last n: Int = 200) -> String {
        let events = snapshot(last: n)
        guard !events.isEmpty else { return "_no events_" }
        return events.map(\.formatted).joined(separator: "\n")
    }
}
