//
//  SyncHLC.swift
//  Whisperer
//
//  Hybrid logical clock (plan 9.4). Every row carries `(wall, counter)` + the writing device; the greater
//  `(wall, counter, device)` wins. The wall part is corrected by server time (a Mac whose clock is a day, or a
//  year, off still stamps in server time) and is never allowed to run more than 24 h ahead of it (poisoning guard).
//

import Foundation

nonisolated struct HLC: Codable, Hashable, Comparable, Sendable {
    var wall: Int64      // milliseconds since 1970
    var counter: UInt32

    static let zero = HLC(wall: 0, counter: 0)
    static func < (a: HLC, b: HLC) -> Bool { (a.wall, a.counter) < (b.wall, b.counter) }
}

/// A stamp: HLC plus the device that wrote it. The device id only breaks exact ties, deterministically.
nonisolated struct SyncStamp: Codable, Hashable, Comparable, Sendable {
    var hlc: HLC
    var device: String

    static func < (a: SyncStamp, b: SyncStamp) -> Bool {
        if a.hlc != b.hlc { return a.hlc < b.hlc }
        return a.device < b.device
    }
}

nonisolated final class HybridLogicalClock: @unchecked Sendable {
    /// A remote stamp more than this far ahead of server time is not believed.
    static let maxAheadMs: Int64 = 24 * 3600 * 1000

    private let lock = NSLock()
    private let nowMs: @Sendable () -> Int64
    private var _last: HLC
    private var offsetMs: Int64 = 0
    private var haveServerTime = false

    init(nowMs: @escaping @Sendable () -> Int64, last: HLC = .zero) {
        self.nowMs = nowMs
        self._last = last
    }

    var last: HLC { lock.lock(); defer { lock.unlock() }; return _last }
    var hasServerTime: Bool { lock.lock(); defer { lock.unlock() }; return haveServerTime }

    /// Local clock plus what the last heads response said it is off by.
    /// The offset learned from the last heads response, persisted by the engine so a restart keeps stamping in server time.
    var serverOffsetMs: Int64 { lock.lock(); defer { lock.unlock() }; return offsetMs }

    func restoreOffset(_ ms: Int64) { lock.lock(); offsetMs = ms; lock.unlock() }

    func correctedNowMs() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return nowMs() + offsetMs
    }

    /// `server` is the `serverTime` of a heads response received just now.
    func observeServerTime(_ server: Date) {
        lock.lock(); defer { lock.unlock() }
        let local = nowMs()
        let serverMs = Int64((server.timeIntervalSince1970 * 1000).rounded())
        offsetMs = serverMs - local
        haveServerTime = true
        // A clock that was wrong before the first contact may have stamped far in the future; do not let that
        // poison every later edit.
        if _last.wall > serverMs + Self.maxAheadMs { _last = HLC(wall: serverMs, counter: 0) }
    }

    /// Stamp for a local event.
    func tick() -> HLC {
        lock.lock(); defer { lock.unlock() }
        let now = nowMs() + offsetMs
        if now > _last.wall { _last = HLC(wall: now, counter: 0) }
        else { _last = HLC(wall: _last.wall, counter: _last.counter &+ 1) }
        return _last
    }

    /// Advance past a stamp seen on a remote row — never past the poisoning limit.
    func receive(_ remote: HLC) {
        lock.lock(); defer { lock.unlock() }
        let ceiling = nowMs() + offsetMs + Self.maxAheadMs
        let bounded = remote.wall > ceiling ? HLC(wall: ceiling, counter: 0) : remote
        if bounded > _last { _last = bounded }
    }

    /// A stamp this device is about to publish must not be ahead of server time by more than the limit:
    /// anything beyond is brought back to "now" (the author-side half of the poisoning guard).
    func clampedForPublishing(_ stamp: HLC) -> HLC {
        let ceiling = correctedNowMs() + Self.maxAheadMs
        guard stamp.wall > ceiling else { return stamp }
        return tick()
    }
}
