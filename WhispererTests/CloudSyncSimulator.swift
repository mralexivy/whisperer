//
//  CloudSyncSimulator.swift
//  WhispererTests
//
//  A deterministic stand-in for the cloud: `InMemoryCloudTransport` follows the SERVER's rules
//  (server/internal/syncplane): objects are immutable, a commit verifies the object and its crc32c, a device's
//  sequence advances by exactly one or is an identical retry, heads carry a version, uploads reserve quota,
//  read-only refuses writes, a snapshot claim is checked (covers <= heads, CAS on version).
//  On top of that it injects faults: dropped replies, failures at a byte, duplicate / reordered delivery,
//  tampering, and "crash" points that throw `SyncError.simulatedCrash`.
//

import Foundation
@testable import whisperer

nonisolated final class CloudSimServer: @unchecked Sendable {
    let lock = NSLock()
    let accountId = "0123456789abcdef0123456789abcdef"
    var epoch = 1
    var objects: [String: Data] = [:]          // full name -> ciphertext
    var heads: [String: CloudHead] = [:]
    var version: Int64 = 0
    var snapshot: CloudSnapshotInfo?
    var quotaLimit: Int64 = .max
    var committed: Int64 = 0
    var reserved: Int64 = 0
    var pending: [String: Int64] = [:]
    var readOnly = false
    var serverNow: @Sendable () -> Date = { Date() }
    var deletedNames: [String] = []
    var rejectedSnapshots = 0
    var ever: [String: Data] = [:]              // every object that was ever created, even after deletion (test oracle)
    var resumableGrants = 0
    var commitLog: [(device: String, seq: Int64, name: String)] = []
    var downloadCount = 0

    var prefix: String { "whisperer/users/\(accountId)/e\(epoch)/" }
    func name(_ ref: CloudObjectRef) -> String { prefix + ref.relativeName }

    func allObjects() -> [String: Data] { lock.lock(); defer { lock.unlock() }; return objects }
    func committedNames() -> [String] { lock.lock(); defer { lock.unlock() }; return commitLog.map(\.name) }
}

nonisolated final class InMemoryCloudTransport: CloudTransport, @unchecked Sendable {
    let server: CloudSimServer
    private let lock = NSLock()
    private var oneShots = Set<String>()
    var offline = false
    var duplicateUploads = false
    var reorderDownloads = false
    var tamperNames = Set<String>()     // substring of the object name whose downloads get a flipped byte
    var trace: [String] = []
    /// Called just before a commit reaches the server (lets a test make the world change underneath it).
    var beforeCommit: (() -> Void)?

    init(server: CloudSimServer) { self.server = server }

    /// Arms a one-shot fault: "before:commit", "drop:commit", "crash:before:commit", "crash:after:commit", ...
    func arm(_ token: String) { lock.lock(); oneShots.insert(token); lock.unlock() }
    func clearFaults() { lock.lock(); oneShots.removeAll(); lock.unlock(); offline = false; duplicateUploads = false; reorderDownloads = false; tamperNames = [] }
    private func trip(_ token: String) -> Bool { lock.lock(); defer { lock.unlock() }; return oneShots.remove(token) != nil }

    private func run<T>(_ op: String, _ body: () throws -> T) throws -> T {
        lock.lock(); trace.append(op); lock.unlock()
        if offline { throw CloudTransportError.offline }
        if trip("before:\(op)") { throw CloudTransportError.offline }
        if trip("crash:before:\(op)") { throw SyncError.simulatedCrash("before:\(op)") }
        let result = try body()
        if trip("crash:after:\(op)") { throw SyncError.simulatedCrash("after:\(op)") }
        if trip("drop:\(op)") { throw CloudTransportError.offline }
        return result
    }

    func heads(since version: Int64?) async throws -> CloudHeads {
        try run("heads") {
            server.lock.lock(); defer { server.lock.unlock() }
            if let version, version == server.version {
                return CloudHeads(version: server.version, unchanged: true, epoch: server.epoch, heads: nil, snapshot: nil,
                                  serverTime: server.serverNow(), readOnly: server.readOnly)
            }
            return CloudHeads(version: server.version, unchanged: nil, epoch: server.epoch, heads: server.heads,
                              snapshot: server.snapshot, serverTime: server.serverNow(), readOnly: server.readOnly)
        }
    }

    func requestUploads(_ items: [CloudUploadRequest]) async throws -> [CloudGrant] {
        try run("requestUploads") {
            server.lock.lock(); defer { server.lock.unlock() }
            if server.readOnly { throw CloudTransportError.readOnly }
            guard items.count <= 50 else { throw CloudTransportError.server(status: 400) }
            var grants: [CloudGrant] = []
            for item in items {
                let name = server.name(item.ref)
                let already = server.pending[name] ?? 0
                if server.committed + server.reserved - already + item.size > server.quotaLimit { throw CloudTransportError.overQuota }
                server.reserved += item.size - already
                server.pending[name] = item.size
                if item.size >= 8 << 20 { server.resumableGrants += 1 }
                grants.append(CloudGrant(name: name, url: "sim://\(name)", expiresAt: Date().addingTimeInterval(900),
                                         resumable: item.size >= 8 << 20 ? true : nil, headers: nil))
            }
            return grants
        }
    }

    func upload(_ data: Data, with grant: CloudGrant) async throws {
        try run("upload") {
            server.lock.lock(); defer { server.lock.unlock() }
            guard let reservedSize = server.pending[grant.name] ?? (server.objects[grant.name] != nil ? Int64(data.count) : nil) else {
                throw CloudTransportError.server(status: 403)
            }
            if Int64(data.count) > reservedSize { throw CloudTransportError.server(status: 400) }
            if server.objects[grant.name] == nil { server.ever[grant.name] = data }
            if server.objects[grant.name] == nil { server.objects[grant.name] = data }   // ifGenerationMatch=0: an existing object wins (412 = success)
            if duplicateUploads, server.objects[grant.name] == nil { server.objects[grant.name] = data }
        }
    }

    func commit(device: String, seq: Int64, crc: UInt32, extra: [CloudObjectRef], snapshot: CloudSnapshotInfo?) async throws -> CloudCommitResult {
        beforeCommit?()
        return try run("commit") {
            server.lock.lock(); defer { server.lock.unlock() }
            if server.readOnly { throw CloudTransportError.readOnly }
            let mainName = server.name(.change(device: device, seq: seq))
            var names = [mainName]
            if let snapshot { names.append(server.name(.snapshot(id: snapshot.id))) }
            for ref in extra { names.append(server.name(ref)) }
            for (i, name) in names.enumerated() {
                guard let data = server.objects[name] else { throw CloudTransportError.notUploaded }
                if i == 0 && CloudCRC32C.checksum(data) != crc { throw CloudTransportError.checksumMismatch }
            }
            let cur = server.heads[device] ?? CloudHead(seq: 0, crc: 0)
            var advance = false
            if seq == cur.seq && crc == cur.crc { /* identical retry */ }
            else if seq == cur.seq + 1 { advance = true }
            else { throw CloudTransportError.sequenceConflict(head: cur) }
            var setSnapshot = false
            if let snapshot, !(server.snapshot?.id == snapshot.id) {
                for (d, covered) in snapshot.covers {
                    let have = (d == device && advance) ? seq : (server.heads[d]?.seq ?? 0)
                    if covered < 0 || covered > have { server.rejectedSnapshots += 1; throw CloudTransportError.server(status: 400) }
                }
                if snapshot.version != (server.snapshot?.version ?? 0) + 1 { server.rejectedSnapshots += 1; throw CloudTransportError.server(status: 400) }
                setSnapshot = true
            }
            if advance { server.heads[device] = CloudHead(seq: seq, crc: crc); server.version += 1; server.commitLog.append((device, seq, mainName)) }
            if setSnapshot { server.snapshot = snapshot; if !advance { server.version += 1 } }
            for name in names {
                if let size = server.pending[name] {
                    server.reserved -= size
                    server.committed += Int64(server.objects[name]?.count ?? 0)
                    server.pending[name] = nil
                }
            }
            return CloudCommitResult(version: server.version, head: server.heads[device] ?? cur)
        }
    }

    func requestDownloads(_ refs: [CloudObjectRef]) async throws -> [CloudGrant] {
        try run("requestDownloads") {
            server.lock.lock(); defer { server.lock.unlock() }
            var grants: [CloudGrant] = []
            for ref in refs {
                let name = server.name(ref)
                guard server.objects[name] != nil else { throw CloudTransportError.server(status: 404) }
                grants.append(CloudGrant(name: name, url: "sim://\(name)", expiresAt: Date().addingTimeInterval(60), resumable: nil, headers: nil))
            }
            return reorderDownloads ? grants.reversed() : grants
        }
    }

    func download(with grant: CloudGrant) async throws -> Data {
        try run("download") {
            server.lock.lock(); defer { server.lock.unlock() }
            guard var data = server.objects[grant.name] else { throw CloudTransportError.server(status: 404) }
            server.downloadCount += 1
            if tamperNames.contains(where: { grant.name.contains($0) }), data.count > CloudCrypto.headerLength + 2 {
                data[data.startIndex + CloudCrypto.headerLength + 1] ^= 0x01
            }
            return data
        }
    }

    func delete(_ refs: [CloudObjectRef]) async throws -> Int {
        try run("delete") {
            server.lock.lock(); defer { server.lock.unlock() }
            var n = 0
            for ref in refs {
                let name = server.name(ref)
                if let data = server.objects.removeValue(forKey: name) {
                    server.committed = max(0, server.committed - Int64(data.count)); n += 1
                    server.deletedNames.append(name)
                }
                if let size = server.pending.removeValue(forKey: name) { server.reserved -= size }
            }
            return n
        }
    }
}
