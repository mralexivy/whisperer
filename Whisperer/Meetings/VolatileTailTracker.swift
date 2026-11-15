//
//  VolatileTailTracker.swift
//  Whisperer
//
//  Finds the words of an ever-growing transcript that come after its first `settled` words, without splitting the
//  whole transcript into words on every update.
//
//  Apple dictation reports the whole accumulated text on every result (about three a second). The meeting needs only
//  what follows the words it has already settled. Splitting a 20-minute transcript (3,000 words, 3,000 String
//  allocations) for that, three times a second, for as long as the meeting runs, was pure waste; the settled words
//  never change, so the position just past them only ever moves forward. This remembers it and scans only the words
//  that settled since.
//

import Foundation

nonisolated struct VolatileTailTracker {
    /// Byte offset just past the `settledCount`-th word of the last text, and the last bytes before it — a cheap check
    /// that the text still starts the way it did (a restart, carried text or a shrink invalidates the position).
    private var offset = 0
    private var settledCount = 0
    private var guardBytes: [UInt8] = []
    private static let guardLength = 24

    init() {}

    mutating func reset() { offset = 0; settledCount = 0; guardBytes = [] }

    /// Same result as `words(text).dropFirst(settled).joined(" ")` with words split on single spaces, in time
    /// proportional to the words that settled since the last call plus the tail itself.
    mutating func tail(of text: String, settled: Int) -> String {
        var text = text
        return text.withUTF8 { bytes in tail(in: bytes, settled: settled) }
    }

    private mutating func tail(in bytes: UnsafeBufferPointer<UInt8>, settled: Int) -> String {
        guard settled > 0 else { reset(); return Self.join(bytes, from: 0) }

        if settled < settledCount || offset > bytes.count || !guardMatches(bytes) { reset() }

        var position = offset
        var count = settledCount
        while count < settled {
            while position < bytes.count, bytes[position] == 0x20 { position += 1 }
            guard position < bytes.count else { return "" } // fewer words than settled: nothing follows them
            while position < bytes.count, bytes[position] != 0x20 { position += 1 }
            count += 1
        }
        offset = position
        settledCount = count
        let from = max(0, position - Self.guardLength)
        guardBytes = Array(bytes[from..<position])
        return Self.join(bytes, from: position)
    }

    private func guardMatches(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard settledCount > 0 else { return true }
        let from = offset - guardBytes.count
        guard from >= 0, offset <= bytes.count else { return false }
        return guardBytes.elementsEqual(bytes[from..<offset])
    }

    /// The remaining bytes with runs of spaces collapsed to one and the ends trimmed — what splitting on spaces and
    /// joining with one space gives.
    private static func join(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> String {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count - start)
        var pendingSpace = false
        for i in start..<bytes.count {
            if bytes[i] == 0x20 { pendingSpace = !out.isEmpty; continue }
            if pendingSpace { out.append(0x20); pendingSpace = false }
            out.append(bytes[i])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
