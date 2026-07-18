//
//  EventRingBuffer.swift
//  Whisperer
//
//  Thread-safe circular buffer of diagnostic events. Never writes to disk.
//  Captured at stall time and embedded in dump files.
//

import Foundation

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
        case .int(let v): return "\(v)"
        case .double(let v): return String(format: "%.3f", v)
        case .bool(let v): return v ? "true" : "false"
        }
    }
}

struct HealthEvent {
    // Offset from recordingStart (or absolute time when idle) in seconds
    let offset: Double
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

final class EventRingBuffer: @unchecked Sendable {

    static let shared = EventRingBuffer(capacity: 4096)

    private let lock = NSLock()
    private var events: [HealthEvent?]
    private var head: Int = 0
    private var count: Int = 0
    private let capacity: Int

    // Set to .now when recording begins, nil when idle.
    // Events recorded while nil use a negative offset from "now".
    var recordingStart: ContinuousClock.Instant?

    init(capacity: Int) {
        self.capacity = capacity
        self.events = [HealthEvent?](repeating: nil, count: capacity)
    }

    func record(
        component: String,
        operation: String,
        kind: EventKind,
        metadata: [String: MetadataValue] = [:]
    ) {
        let now = ContinuousClock.now
        let offset: Double
        if let start = recordingStart {
            offset = Double((now - start).components.seconds) +
                     Double((now - start).components.attoseconds) * 1e-18
        } else {
            offset = 0.0
        }

        let event = HealthEvent(
            offset: offset,
            component: component,
            operation: operation,
            kind: kind,
            metadata: metadata
        )

        lock.lock()
        defer { lock.unlock() }
        events[head] = event
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    /// Returns up to `n` most recent events in chronological order.
    func snapshot(last n: Int = 200) -> [HealthEvent] {
        lock.lock()
        defer { lock.unlock() }

        let take = min(n, count)
        guard take > 0 else { return [] }

        var result: [HealthEvent] = []
        result.reserveCapacity(take)

        // head points to the next write position; oldest is at (head - count + capacity) % capacity
        let oldest = (head - count + capacity) % capacity
        for i in 0..<take {
            let index = (oldest + (count - take) + i) % capacity
            if let event = events[index] {
                result.append(event)
            }
        }
        return result
    }

    func formattedSnapshot(last n: Int = 200) -> String {
        let events = snapshot(last: n)
        guard !events.isEmpty else { return "_no events_" }
        return events.map(\.formatted).joined(separator: "\n")
    }
}
