//
//  SyncTypes.swift
//  Whisperer
//
//  Wire and status types of the sync engine. A change batch is JSON (`SyncBatchPayload`) that is compressed and
//  encrypted once by CloudCrypto; the row inside each op is the same generic Core Data row encoding the history
//  export uses (`HistoryArchive.encodeRow`).
//

import Foundation
import CryptoKit

/// What kind of thing a ledger key names. The first letter of the key says which.
nonisolated enum SyncKind: String, Codable, Sendable, CaseIterable {
    case dictation = "d"
    case meeting = "m"
    case dictionary = "w"
    case stat = "s"
    case chat = "c"

    /// Rows with a unique id never come back once deleted: a tombstone beats every edit, whatever the stamps.
    /// Dictionary entries and chats can be recreated with the same sync key, so they merge by stamp.
    var deleteWins: Bool { self == .dictation || self == .meeting }

    var entityName: String? {
        switch self {
        case .dictation: return "TranscriptionEntity"
        case .meeting: return "MeetingEntity"
        case .dictionary: return "DictionaryEntryEntity"
        case .stat, .chat: return nil
        }
    }

    static func of(key: String) -> SyncKind? { key.first.flatMap { SyncKind(rawValue: String($0)) } }
    static func key(_ kind: SyncKind, _ id: String) -> String { "\(kind.rawValue):\(id)" }
    static func id(ofKey key: String) -> String { String(key.dropFirst(2)) }
}

nonisolated struct SyncAudioRef: Codable, Equatable, Sendable {
    var id: String          // random 128-bit hex: the object name
    var kind: String        // "audio" (dictation) or "meetings"
    var size: Int64         // ciphertext bytes
    var name: String        // file name on the Mac that recorded it
}

/// One change. Exactly one of `row` (upsert), `del` (tombstone) or `aud` (audio is now available) is set.
nonisolated struct SyncOp: Codable, Equatable, Sendable {
    var k: String
    var w: Int64
    var c: UInt32
    var dev: String
    var at: Int64
    var del: Bool?
    var row: JSONValue?
    var aud: SyncAudioRef?

    var stamp: SyncStamp { SyncStamp(hlc: HLC(wall: w, counter: c), device: dev) }
    var isTombstone: Bool { del == true }

    init(key: String, stamp: SyncStamp, at: Int64, row: JSONValue? = nil, tombstone: Bool = false, audio: SyncAudioRef? = nil) {
        self.k = key; self.w = stamp.hlc.wall; self.c = stamp.hlc.counter; self.dev = stamp.device; self.at = at
        self.row = row; self.del = tombstone ? true : nil; self.aud = audio
    }
}

nonisolated struct SyncBatchPayload: Codable, Sendable {
    var v: Int = 1
    var device: String
    var seq: Int64
    var ops: [SyncOp]
}

nonisolated struct SyncSnapshotPayload: Codable, Sendable {
    var v: Int = 1
    var device: String
    var covers: [String: Int64]
    var ops: [SyncOp]
}

/// Account-level identity the engine needs; the account layer supplies it.
nonisolated struct SyncIdentity: Equatable, Sendable {
    var accountId: String
    var epoch: Int
    var deviceId: String       // 32 lowercase hex
}

nonisolated extension CloudObjectRef {
    /// The name bound into the ciphertext's AAD. The server's real object name has a bucket prefix the client never
    /// sees; this relative form is the same on every Mac.
    var relativeName: String {
        switch kind {
        case "changes": return "changes/\(device ?? "")/\(String(format: "%012lld", seq ?? 0))"
        default: return "\(kind)/\(id ?? "")"
        }
    }
}

// MARK: - Status

nonisolated enum SyncPhase: Equatable, Sendable {
    case idle
    case syncing
    case offline
    case paused
    case readOnly
    case needsKey
    case overQuota
    case error(String)
}

nonisolated struct SyncStatus: Equatable, Sendable {
    var phase: SyncPhase = .idle
    /// Rows (and audio files) waiting to be uploaded.
    var pendingChanges = 0
    var pendingAudio = 0
    var uploadedChanges = 0
    var downloadedChanges = 0
    var lastSyncAt: Date?
    /// First enable: rows uploaded / rows to upload while the initial upload runs; nil otherwise.
    var initialUpload: (done: Int, total: Int)?

    static func == (a: SyncStatus, b: SyncStatus) -> Bool {
        a.phase == b.phase && a.pendingChanges == b.pendingChanges && a.pendingAudio == b.pendingAudio
            && a.uploadedChanges == b.uploadedChanges && a.downloadedChanges == b.downloadedChanges
            && a.lastSyncAt == b.lastSyncAt && a.initialUpload?.done == b.initialUpload?.done
            && a.initialUpload?.total == b.initialUpload?.total
    }
}

nonisolated enum SyncError: Error, Equatable, Sendable {
    case needsKey
    case tampered(String)          // a downloaded object failed authentication though the key is known good
    case malformed(String)
    case epochMismatch(server: Int, local: Int)
    case paused
    case readOnly
    case storeUnavailable
    case noAudio
    case simulatedCrash(String)    // test hook only
}

/// Where the engine checks in so a test can "crash" it at an exact point. Production passes nil.
nonisolated struct SyncHooks: Sendable {
    var checkpoint: @Sendable (String) throws -> Void
    static let none = SyncHooks { _ in }
}

nonisolated struct SyncPolicy: Sendable {
    var batchMaxChanges = 50
    var batchMaxBytes = 4 << 20
    var batchMaxAge: TimeInterval = 5 * 60
    /// First-enable upload packs bigger batches (still capped by bytes): 10,000 dictations is a handful of objects.
    var initialBatchMaxChanges = 2_000
    var snapshotAfterBatches = 300
    var snapshotAfterDays = 30
    var tombstoneHorizonDays = 90
    var snapshotChunk = 2_000
    var fullScanEvery: TimeInterval = 10 * 60
    var massDeleteMinimum = 20
}
