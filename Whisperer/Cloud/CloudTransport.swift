//
//  CloudTransport.swift
//  Whisperer
//
//  The contract between the sync engine and the network. The engine speaks only this protocol, so it is
//  tested against an in-memory implementation that follows the server's rules, and runs in the app against
//  `CloudHTTPTransport` (the real /v1/sync/* routes plus signed Cloud Storage URLs). Types mirror
//  server/internal/syncplane JSON exactly — field names are the wire format.
//

import Foundation

/// A named object in the library. `kind` is one of: changes, snapshots, audio, meetings.
nonisolated struct CloudObjectRef: Codable, Hashable, Sendable {
    var kind: String
    var device: String?   // kind == "changes": the 32-hex device id
    var seq: Int64?       // kind == "changes": >= 1
    var id: String?       // other kinds: 32 lowercase hex

    static func change(device: String, seq: Int64) -> CloudObjectRef { .init(kind: "changes", device: device, seq: seq, id: nil) }
    static func snapshot(id: String) -> CloudObjectRef { .init(kind: "snapshots", device: nil, seq: nil, id: id) }
    static func audio(id: String) -> CloudObjectRef { .init(kind: "audio", device: nil, seq: nil, id: id) }
    static func meeting(id: String) -> CloudObjectRef { .init(kind: "meetings", device: nil, seq: nil, id: id) }
}

nonisolated struct CloudUploadRequest: Codable, Sendable {
    var ref: CloudObjectRef
    var size: Int64
}

/// A signed URL to PUT (upload) or GET (download) one object. `headers` must be sent exactly as given —
/// they are part of the signature. `resumable` means the URL starts a resumable session (POST with
/// `x-goog-resumable: start`); the session URI in the `Location` response header receives the bytes.
nonisolated struct CloudGrant: Codable, Sendable, Equatable {
    var name: String
    var url: String
    var expiresAt: Date
    var resumable: Bool?
    var headers: [String: String]?
}

nonisolated struct CloudHead: Codable, Sendable, Equatable {
    var seq: Int64
    var crc: UInt32
}

nonisolated struct CloudSnapshotInfo: Codable, Sendable, Equatable {
    var id: String
    var covers: [String: Int64]   // device id -> highest change seq the snapshot includes
    var version: Int64
}

/// Answer of GET /v1/sync/heads. When `unchanged` is true only `version` is meaningful.
nonisolated struct CloudHeads: Codable, Sendable, Equatable {
    var version: Int64
    var unchanged: Bool?
    var epoch: Int?
    var heads: [String: CloudHead]?
    var snapshot: CloudSnapshotInfo?
    var serverTime: Date?
    var readOnly: Bool?
}

nonisolated struct CloudCommitResult: Codable, Sendable, Equatable {
    var version: Int64
    var head: CloudHead
}

nonisolated enum CloudTransportError: Error, Equatable {
    /// 409 sequence_conflict: the device's counter is out of step; `head` is what the server has.
    case sequenceConflict(head: CloudHead)
    case readOnly            // 403 read_only
    case overQuota           // 402 over_quota / storage_full
    case downloadLimit       // 429 download_limit
    case rateLimited(retryAfter: TimeInterval?)
    case notUploaded         // 409 not_uploaded
    case checksumMismatch    // 409 checksum_mismatch
    case deviceRevoked       // 403 device_revoked / device_not_authorized
    case unauthorized        // 401: session expired — renew and retry
    case sealed              // 403 sealed (audio of a lapsed plan)
    case noAccess            // 403 no_access
    case server(status: Int) // anything else
    case offline             // no network / timeout: retry later, never a data problem
}

protocol CloudTransport: Sendable {
    func heads(since version: Int64?) async throws -> CloudHeads
    func requestUploads(_ items: [CloudUploadRequest]) async throws -> [CloudGrant]
    /// Upload bytes through a grant. A 412 (object exists) is success for the engine's purposes: the commit's
    /// checksum decides whether the existing object is ours.
    func upload(_ data: Data, with grant: CloudGrant) async throws
    func commit(device: String, seq: Int64, crc: UInt32, extra: [CloudObjectRef], snapshot: CloudSnapshotInfo?) async throws -> CloudCommitResult
    func requestDownloads(_ refs: [CloudObjectRef]) async throws -> [CloudGrant]
    func download(with grant: CloudGrant) async throws -> Data
    func delete(_ refs: [CloudObjectRef]) async throws -> Int
    /// File-based variants for large objects (audio); defaults below read/write through `Data`.
    func upload(fileAt url: URL, size: Int64, with grant: CloudGrant) async throws
    func download(with grant: CloudGrant, to url: URL) async throws
}

// MARK: - File-based transfers (additive, used by the sync engine for audio)

/// Large objects (meeting audio) must not be loaded into memory. The engine hands the transport a file; a
/// transport that streams (the HTTP one, with its resumable sessions for objects >= 8 MB) overrides these.
/// The defaults go through `Data`, which is correct for every transport and fine for the small objects the
/// in-memory simulator carries.
extension CloudTransport {
    func upload(fileAt url: URL, size: Int64, with grant: CloudGrant) async throws {
        try await upload(try Data(contentsOf: url), with: grant)
    }

    /// Downloads the object behind `grant` into `url` (replacing it). A partial file is never left behind on failure.
    func download(with grant: CloudGrant, to url: URL) async throws {
        let data = try await download(with: grant)
        try data.write(to: url, options: .atomic)
    }
}
