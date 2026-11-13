//
//  SyncLedger.swift
//  Whisperer
//
//  Per-row sync metadata in a sidecar file (Application Support/Whisperer/Cloud/ledger.json), keyed by the row's
//  sync key. Nothing here touches the Core Data store: enabling Cloud adds no attribute, no index and no
//  history-tracking option to the existing history, so there is no migration that could lose or alter a row.
//
//  The ledger also holds the device-level sync state (sequence counter, per-device cursors, server version,
//  snapshot bookkeeping, initial-upload phase). Every write is atomic (temp file + rename).
//

import Foundation

nonisolated struct LedgerRow: Codable, Equatable, Sendable {
    var hlc: HLC
    var dev: String
    /// SHA-256 of the row as this Mac last saw it (written or merged). A difference from the store means a local edit.
    var hash: String
    /// A local change not yet acknowledged by a 200 commit.
    var dirty: Bool
    /// Wall time (corrected ms) of the commit that acknowledged this row, or the merge that received it.
    var syncedAt: Int64?
    var deleted: Bool
    var tombstoneAt: Int64?
    var audioId: String?
    var audioKind: String?
    var audioSize: Int64?
    var audioName: String?
    /// Our audio object is in the cloud (uploaded, maybe not yet announced).
    var audioUploaded: Bool
    /// The audio object was announced by a committed batch (or arrived that way from another Mac).
    var audioAcked: Bool
    /// Dictionary entries: the local Core Data id the sync key currently maps to.
    var localId: String?

    var stamp: SyncStamp { SyncStamp(hlc: hlc, device: dev) }

    init(stamp: SyncStamp, hash: String, dirty: Bool, syncedAt: Int64? = nil, deleted: Bool = false, tombstoneAt: Int64? = nil) {
        self.hlc = stamp.hlc; self.dev = stamp.device; self.hash = hash; self.dirty = dirty
        self.syncedAt = syncedAt; self.deleted = deleted; self.tombstoneAt = tombstoneAt
        self.audioUploaded = false; self.audioAcked = false
    }
}

nonisolated enum InitialUploadPhase: String, Codable, Sendable { case notStarted, text, audio, done }

nonisolated struct LedgerState: Codable, Sendable {
    var version = 1
    var deviceId: String
    var epoch: Int
    var committedSeq: Int64 = 0
    var cursors: [String: Int64] = [:]
    var serverVersion: Int64 = 0
    var lastHLC: HLC = .zero
    var clockOffsetMs: Int64 = 0
    var lastFullSyncAt: Int64?
    var keyEverWorked = false
    var paused = false
    var snapshotVersion: Int64 = 0
    var snapshotId: String?
    var snapshotCovers: [String: Int64] = [:]
    var batchesSinceSnapshot = 0
    var lastSnapshotAt: Int64?
    /// Highest seq per device whose batch object was deleted by compaction.
    var compactedUpTo: [String: Int64] = [:]
    var initialPhase: InitialUploadPhase = .notStarted
    var initialTotal = 0
    var initialDone = 0
    var pendingApplyKeys: [String] = []
    /// Journal of the merge in flight: the ledger row each key will have, and the store hash that proves the merge landed.
    var pendingStaged: [String: LedgerRow] = [:]
    var pendingExpect: [String: String] = [:]
    var pendingLanded = false
    /// Files the in-flight merge deletes once its store save has landed (a crash must not leave them behind).
    var pendingRemove: [String] = []
    var firstDirtyAt: Int64?
    var massDeleteApproved = false
    var uploadedChanges = 0
    var downloadedChanges = 0
    var lastSyncAt: Int64?
    var rows: [String: LedgerRow] = [:]
}

nonisolated final class SyncLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var state: LedgerState
    let url: URL?

    /// `url == nil` keeps the ledger in memory only (tests).
    init(url: URL?, deviceId: String, epoch: Int) throws {
        self.url = url
        if let url, FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let loaded = try JSONDecoder().decode(LedgerState.self, from: data)
            self.state = loaded
        } else {
            self.state = LedgerState(deviceId: deviceId, epoch: epoch)
        }
    }

    // MARK: Access

    func read<T>(_ body: (LedgerState) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(state)
    }

    @discardableResult
    func mutate<T>(_ body: (inout LedgerState) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&state)
    }

    var deviceId: String { read { $0.deviceId } }
    var epoch: Int { read { $0.epoch } }
    func row(_ key: String) -> LedgerRow? { read { $0.rows[key] } }
    var snapshot: LedgerState { read { $0 } }

    var dirtyCount: Int { read { s in s.rows.values.reduce(0) { $0 + ($1.dirty ? 1 : 0) } } }
    var liveRowCount: Int { read { s in s.rows.values.reduce(0) { $0 + ($1.deleted ? 0 : 1) } } }

    // MARK: Persistence

    func save() throws {
        guard let url else { return }
        let data: Data = try read { try JSONEncoder().encode($0) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Drop in-memory edits and re-read the file (after a failed merge).
    func reload() {
        guard let url, let data = try? Data(contentsOf: url), let loaded = try? JSONDecoder().decode(LedgerState.self, from: data) else { return }
        lock.lock(); state = loaded; lock.unlock()
    }

    static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whisperer/Cloud/ledger.json")
    }
}
