//
//  LogSession.swift
//  Whisperer
//
//  One `>ses … <ses` block per recording, closed with a verdict.
//
//  A verdict is what makes the file skimmable: an agent reads the `<ses` lines,
//  sees which sessions failed, and opens only those. On failure the block is
//  followed by the EventRingBuffer timeline, so every step that `Logger.step`
//  kept out of the file comes back — and only then.
//

import Foundation

@MainActor
final class LogSession {

    /// Session numbers restart at 1 each launch. They identify a block within one
    /// file region, not across days — `#t` anchors give absolute time.
    private static var nextID = 1

    let id: Int
    let kind: String

    private let started: ContinuousClock.Instant
    private var closed = false

    // Counters folded into the verdict rather than logged per occurrence.
    private var partials = 0
    private var chunks = 0
    private var chars = 0

    private init(id: Int, kind: String) {
        self.id = id
        self.kind = kind
        self.started = .now
    }

    // MARK: - Lifecycle

    /// Open a block. `fields` describe the *configuration* of the recording —
    /// the things that decide which code path runs and therefore which failures
    /// are possible (backend, route, language, model).
    @discardableResult
    static func begin(_ kind: String, _ fields: [String: MetadataValue] = [:]) -> LogSession {
        let session = LogSession(id: nextID, kind: kind)
        nextID += 1

        var header = ">ses \(session.id) \(kind)"
        let packed = Logger.packMetadata(fields)
        if !packed.isEmpty { header += " " + packed }
        Logger.beginBlock(header)
        return session
    }

    /// Close with a success verdict.
    func end(_ fields: [String: MetadataValue] = [:]) {
        close(verdict: "ok", extra: fields, dumpTimeline: false)
    }

    /// Close with a failure verdict. `at` defaults to the last event written in the
    /// block, which is where things got to before they stopped.
    func fail(_ error: String, at: LogEvent? = nil, _ fields: [String: MetadataValue] = [:]) {
        var extra = fields
        extra["at"] = .string(at?.code ?? Logger.blockState.lastEvent)
        extra["err"] = .string(error)
        close(verdict: "FAIL", extra: extra, dumpTimeline: true)
    }

    /// Close with no outcome — the recording was cancelled before it could produce one.
    func cancel(_ reason: String) {
        close(verdict: "cancel", extra: ["why": .string(reason)], dumpTimeline: false)
    }

    // MARK: - Counters

    func countPartial() { partials += 1 }
    func countChunk() { chunks += 1 }
    func setChars(_ n: Int) { chars = n }

    // MARK: - Private

    private func close(verdict: String, extra: [String: MetadataValue], dumpTimeline: Bool) {
        guard !closed else { return }
        closed = true

        let tally = Logger.blockState
        var fields: [String: MetadataValue] = [
            "dur": .double(Logger.seconds(ContinuousClock.now - started))
        ]
        if chars > 0 { fields["chars"] = .int(chars) }
        if partials > 0 { fields["partials"] = .int(partials) }
        if chunks > 0 { fields["chunks"] = .int(chunks) }
        if tally.warn > 0 { fields["warn"] = .int(tally.warn) }
        if tally.err > 0 { fields["err#"] = .int(tally.err) }
        for (k, v) in extra { fields[k] = v }

        var footer = "<ses \(id) \(verdict)"
        let packed = Logger.packMetadata(fields)
        if !packed.isEmpty { footer += " " + packed }

        // Order matters: the timeline explains the verdict, so it is written between
        // the last record and the verdict line rather than after it.
        if dumpTimeline {
            let timeline = EventRingBuffer.shared.packedSnapshot(last: 60)
            if !timeline.isEmpty {
                Logger.writeRaw("|tl " + timeline.replacingOccurrences(of: "\n", with: "\n|tl "))
            }
        }
        Logger.endBlock(footer)
    }
}
