//
//  ComputeLedger.swift
//  Whisperer
//
//  Where Whisperer's compute goes, by component: seconds of work and how many calls. Fed from the
//  few places heavy work happens — every whisper.cpp decode, every language-ID probe, every
//  diarizer step — and read as a delta over a meeting, so the log can say which part of a
//  meeting cost what. `EnergyMonitor` gives the watts; this says who spent them.
//
//  Cheap by construction: one lock and two additions per call, on calls that each take
//  milliseconds to seconds.
//

import Foundation
import os

nonisolated enum ComputeLedger {

    enum Component: String, CaseIterable, Sendable {
        /// whisper.cpp decodes: the eager stream, tails, refine windows, file transcription.
        /// Which one is told by the phase the log line belongs to (meeting vs processing).
        case whisper = "whisper"
        /// Spoken-language identification (one encoder pass per probe).
        case languageID = "language ID"
        /// Speaker diarization.
        case diarizer = "diarizer"
    }

    struct Entry: Sendable, Equatable {
        var seconds: Double = 0
        var calls = 0
    }

    typealias Snapshot = [Component: Entry]

    private static let totals = OSAllocatedUnfairLock(initialState: Snapshot())

    static func add(_ component: Component, seconds: Double) {
        totals.withLock {
            $0[component, default: Entry()].seconds += seconds
            $0[component, default: Entry()].calls += 1
        }
    }

    /// Runs `work`, charging its wall time to `component`.
    @discardableResult
    static func measure<T>(_ component: Component, _ work: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        defer { add(component, seconds: start.duration(to: .now).seconds) }
        return try work()
    }

    static func snapshot() -> Snapshot { totals.withLock { $0 } }

    /// What was spent since `earlier`, in seconds and calls per component.
    static func delta(since earlier: Snapshot) -> Snapshot {
        let now = snapshot()
        var out = Snapshot()
        for component in Component.allCases {
            let a = earlier[component] ?? Entry(), b = now[component] ?? Entry()
            let d = Entry(seconds: b.seconds - a.seconds, calls: b.calls - a.calls)
            if d.calls > 0 { out[component] = d }
        }
        return out
    }

    /// "language ID 9× 6.7 s (1.1%), diarizer 41× 4.6 s (0.8%)" over `wallSeconds`.
    static func describe(_ delta: Snapshot, wallSeconds: Double) -> String {
        let parts = Component.allCases.compactMap { component -> String? in
            guard let e = delta[component] else { return nil }
            let share = wallSeconds > 0 ? e.seconds / wallSeconds * 100 : 0
            return String(format: "%@ %d× %.1f s (%.1f%%)", component.rawValue, e.calls, e.seconds, share)
        }
        return parts.isEmpty ? "no model work" : parts.joined(separator: ", ")
    }
}

nonisolated extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
