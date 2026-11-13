//
//  SyncOutbox.swift
//  Whisperer
//
//  Encrypted change batches (and audio / snapshot objects) kept on disk until the server has acknowledged them.
//  The ciphertext is produced ONCE; a crash at any point replays upload + commit with identical bytes (plan 9.2).
//  A batch is visible to the engine only when its metadata file exists, and the metadata is written last.
//

import Foundation

nonisolated struct OutboxKey: Codable, Equatable, Sendable {
    var key: String
    var stamp: SyncStamp
    var tombstone: Bool
}

nonisolated struct OutboxSnapshot: Codable, Equatable, Sendable {
    var id: String
    var covers: [String: Int64]
    var version: Int64
    var size: Int64
    var crc: UInt32
    var previousId: String?
    var previousCovers: [String: Int64]
}

nonisolated struct OutboxEntry: Codable, Equatable, Sendable {
    var seq: Int64
    var crc: UInt32
    var size: Int64
    var keys: [OutboxKey]
    var audioRefs: [SyncAudioRef]
    var snapshot: OutboxSnapshot?
    var createdAt: Int64
}

nonisolated final class SyncOutbox: @unchecked Sendable {
    let directory: URL
    private let fm = FileManager.default

    init(directory: URL) throws {
        self.directory = directory
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func metaURL(_ seq: Int64) -> URL { directory.appendingPathComponent(String(format: "batch-%012lld.json", seq)) }
    private func dataURL(_ seq: Int64) -> URL { directory.appendingPathComponent(String(format: "batch-%012lld.bin", seq)) }
    func audioURL(_ id: String) -> URL { directory.appendingPathComponent("audio-\(id).enc") }
    func snapshotURL(_ id: String) -> URL { directory.appendingPathComponent("snapshot-\(id).enc") }
    func scratchURL(_ name: String) -> URL { directory.appendingPathComponent("scratch-\(name)") }

    func entries() -> [OutboxEntry] {
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        var result: [OutboxEntry] = []
        for name in names where name.hasPrefix("batch-") && name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let entry = try? JSONDecoder().decode(OutboxEntry.self, from: data),
                  fm.fileExists(atPath: dataURL(entry.seq).path) else { continue }
            result.append(entry)
        }
        return result.sorted { $0.seq < $1.seq }
    }

    func write(_ entry: OutboxEntry, ciphertext: Data) throws {
        try ciphertext.write(to: dataURL(entry.seq), options: .atomic)
        try JSONEncoder().encode(entry).write(to: metaURL(entry.seq), options: .atomic)
    }

    func updateMeta(_ entry: OutboxEntry) throws {
        try JSONEncoder().encode(entry).write(to: metaURL(entry.seq), options: .atomic)
    }

    func ciphertext(seq: Int64) throws -> Data { try Data(contentsOf: dataURL(seq)) }

    func remove(seq: Int64) {
        try? fm.removeItem(at: metaURL(seq))
        try? fm.removeItem(at: dataURL(seq))
    }

    func removeFile(_ url: URL) { try? fm.removeItem(at: url) }

    /// Keys with a change already encrypted and waiting, with the stamp that was captured.
    func inFlight() -> [String: SyncStamp] {
        var result: [String: SyncStamp] = [:]
        for entry in entries() { for k in entry.keys { result[k.key] = k.stamp } }
        return result
    }
}
