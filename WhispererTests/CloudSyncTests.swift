//
//  CloudSyncTests.swift
//  WhispererTests
//
//  The sync engine against the simulated cloud: clock, ledger, merge rules, batching, crash replay, sequence
//  conflicts, tampering, keys, stale devices, clock skew, quota, read-only, snapshots, audio, first-enable upload,
//  and the proof that enabling Cloud never alters existing history. (The randomised version is CloudSyncFuzzTests.)
//

import XCTest
import CoreData
import CryptoKit
@testable import whisperer

// MARK: - World

@MainActor
final class SyncWorld {
    let server = CloudSimServer()
    let clock = SimClock()
    let ring: CloudKeyRing
    var devices: [SimDevice] = []

    init(devices n: Int = 2, ring: CloudKeyRing? = nil, configure: (SimDevice) -> Void = { _ in }) throws {
        if let ring { self.ring = ring } else {
            var r = CloudKeyRing(); try r.insert(Data((0..<32).map { UInt8($0 &+ 1) }), version: 1); self.ring = r
        }
        server.serverNow = { [clock] in clock.date }
        for i in 0..<n {
            let d = try SimDevice(index: i, server: server, clock: clock, ring: self.ring, tag: "world")
            configure(d)
            devices.append(d)
        }
    }

    func cleanUp() { for d in devices { d.cleanUp() } }

    /// Everyone cycles (forced) a few times, a minute apart.
    func settle(_ rounds: Int = 4) async {
        for _ in 0..<rounds {
            clock.advance(60_000)
            for d in devices { await d.cycle(force: true) }
        }
    }

    func decrypt(_ name: String) throws -> Data {
        let ctx = CloudObjectContext(accountId: server.accountId, epoch: UInt64(server.epoch), objectName: String(name.dropFirst(server.prefix.count)))
        return try CloudCrypto.decrypt(server.ever[name]!, keyForVersion: { self.ring.symmetricKey(version: $0) }, context: ctx)
    }
}

@MainActor
class CloudSyncTestCase: XCTestCase {
    func makeWorld(_ n: Int = 2, ring: CloudKeyRing? = nil, configure: (SimDevice) -> Void = { _ in }) throws -> SyncWorld {
        let w = try SyncWorld(devices: n, ring: ring, configure: configure)
        addTeardownBlock { @MainActor in w.cleanUp() }
        return w
    }
}

// MARK: - Clock, cadence, merge rules, ledger

final class CloudSyncClockTests: XCTestCase {
    private let day: Int64 = 86_400_000
    private let year: Int64 = 365 * 86_400_000

    func testTickIsMonotonicEvenWhenTheClockGoesBackwards() {
        let c = SimClock(start: 1_000_000)
        let hlc = HybridLogicalClock(nowMs: { c.now() })
        let a = hlc.tick(), b = hlc.tick()
        XCTAssertLessThan(a, b)
        c.advance(-500_000)
        let d = hlc.tick()
        XCTAssertLessThan(b, d)
        XCTAssertEqual(d.wall, b.wall)
    }

    func testServerTimeCorrectsAClockThatIsOffBy_1Day_1Year() {
        for offset in [day, -day, year, -year] {
            let real = SimClock(start: 1_794_571_200_000)
            let hlc = HybridLogicalClock(nowMs: { real.now() + offset })
            hlc.observeServerTime(real.date)
            XCTAssertEqual(hlc.correctedNowMs(), real.now(), accuracy: 2, "offset \(offset)")
            XCTAssertEqual(Double(hlc.tick().wall), Double(real.now()), accuracy: 2)
            XCTAssertEqual(hlc.serverOffsetMs, -offset)
        }
    }

    func testStampsMadeBeforeServerContactDoNotPoisonLaterEdits() {
        let real = SimClock(start: 1_794_571_200_000)
        let hlc = HybridLogicalClock(nowMs: { real.now() + 365 * 86_400_000 })
        let early = hlc.tick()
        XCTAssertGreaterThan(early.wall, real.now() + 300 * 86_400_000)
        hlc.observeServerTime(real.date)
        XCTAssertEqual(Double(hlc.tick().wall), Double(real.now()), accuracy: 2, "the far-future stamp must not drag later edits with it")
        XCTAssertEqual(hlc.clampedForPublishing(early).wall, real.now(), "a stamp more than 24 h ahead is brought back to now before it is published")
    }

    func testRemoteStampMoreThan24HoursAheadIsNotBelieved() {
        let real = SimClock(start: 1_794_571_200_000)
        let hlc = HybridLogicalClock(nowMs: { real.now() })
        hlc.receive(HLC(wall: real.now() + 10 * day, counter: 3))
        XCTAssertLessThanOrEqual(hlc.last.wall, real.now() + day)
        hlc.receive(HLC(wall: real.now() + 3_600_000, counter: 7))
        XCTAssertEqual(hlc.last.wall, real.now() + day, "already at the ceiling")
        let h2 = HybridLogicalClock(nowMs: { real.now() })
        h2.receive(HLC(wall: real.now() + 3_600_000, counter: 7))
        XCTAssertEqual(h2.last, HLC(wall: real.now() + 3_600_000, counter: 7), "an hour ahead is believed")
        XCTAssertGreaterThan(h2.tick(), HLC(wall: real.now() + 3_600_000, counter: 7))
    }

    func testStampOrderingBreaksTiesByDevice() {
        let a = SyncStamp(hlc: HLC(wall: 5, counter: 1), device: "aa")
        let b = SyncStamp(hlc: HLC(wall: 5, counter: 1), device: "bb")
        let c = SyncStamp(hlc: HLC(wall: 5, counter: 2), device: "aa")
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
    }

    func testCadence() {
        XCTAssertEqual(SyncCadence.interval(foreground: true, idleCycles: 0), 30)
        XCTAssertEqual(SyncCadence.interval(foreground: false, idleCycles: 0), 300)
        XCTAssertEqual(SyncCadence.interval(foreground: true, idleCycles: 10), 30)
        XCTAssertEqual(SyncCadence.interval(foreground: true, idleCycles: 12), 120)
        XCTAssertEqual(SyncCadence.interval(foreground: true, idleCycles: 500), 1800, "idle backoff stops at 30 minutes")
        XCTAssertEqual(SyncCadence.interval(foreground: false, idleCycles: 500), 1800)
        XCTAssertGreaterThanOrEqual(SyncCadence.interval(foreground: true, idleCycles: 0), SyncCadence.serverMinimum)
    }

    func testMergeRules() {
        func op(_ k: String, _ w: Int64, tomb: Bool = false, dev: String = "bb") -> SyncOp {
            SyncOp(key: k, stamp: SyncStamp(hlc: HLC(wall: w, counter: 0), device: dev), at: 0, row: tomb ? nil : .object([:]), tombstone: tomb)
        }
        func row(_ w: Int64, deleted: Bool = false, dev: String = "aa") -> LedgerRow {
            LedgerRow(stamp: SyncStamp(hlc: HLC(wall: w, counter: 0), device: dev), hash: "h", dirty: false, deleted: deleted)
        }
        // unknown row: always applied
        XCTAssertTrue(SyncMerge.shouldApply(kind: .dictation, local: nil, remote: op("d:1", 1)))
        // last writer wins, row-level; equal stamps are a no-op (idempotence)
        XCTAssertTrue(SyncMerge.shouldApply(kind: .dictation, local: row(5), remote: op("d:1", 6)))
        XCTAssertFalse(SyncMerge.shouldApply(kind: .dictation, local: row(5), remote: op("d:1", 4)))
        XCTAssertFalse(SyncMerge.shouldApply(kind: .dictation, local: row(5, dev: "bb"), remote: op("d:1", 5)))
        XCTAssertTrue(SyncMerge.shouldApply(kind: .dictation, local: row(5, dev: "aa"), remote: op("d:1", 5, dev: "bb")), "device id breaks an exact tie")
        // a tombstone beats every edit for unique-id rows, whatever the stamps; an edit never revives one
        XCTAssertTrue(SyncMerge.shouldApply(kind: .dictation, local: row(50), remote: op("d:1", 1, tomb: true)))
        XCTAssertFalse(SyncMerge.shouldApply(kind: .meeting, local: row(1, deleted: true), remote: op("m:1", 99)))
        // dictionary entries and chats merge by stamp in both directions (the same word can be added again)
        XCTAssertFalse(SyncMerge.shouldApply(kind: .dictionary, local: row(50), remote: op("w:1", 1, tomb: true)))
        XCTAssertTrue(SyncMerge.shouldApply(kind: .dictionary, local: row(1, deleted: true), remote: op("w:1", 9)))
        XCTAssertFalse(SyncMerge.shouldApply(kind: .dictionary, local: row(9, deleted: true), remote: op("w:1", 1)))
        // a tombstone for a tombstone changes nothing
        XCTAssertFalse(SyncMerge.shouldApply(kind: .dictation, local: row(1, deleted: true), remote: op("d:1", 2, tomb: true)))
    }

    func testOpsAndBatchesRoundTripThroughJSON() throws {
        let row = JSONValue.object(["a": .string("x"), "n": .number(1.5), "b": .bool(true), "z": .null, "l": .array([.number(1), .string("é")])])
        let op = SyncOp(key: "d:1", stamp: SyncStamp(hlc: HLC(wall: 7, counter: 2), device: "dd"), at: 9, row: row)
        let data = try JSONEncoder().encode(SyncBatchPayload(device: "dd", seq: 3, ops: [op]))
        let back = try JSONDecoder().decode(SyncBatchPayload.self, from: data)
        XCTAssertEqual(back.ops, [op])
        XCTAssertEqual(row.canonicalData(), try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(row)).canonicalData())
    }
}

final class CloudSyncLedgerTests: XCTestCase {
    func testLedgerSurvivesARestartAndNeverTouchesTheHistoryStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ledger.json")
        let a = try SyncLedger(url: url, deviceId: "dev", epoch: 1)
        a.mutate { s in
            s.rows["d:1"] = LedgerRow(stamp: SyncStamp(hlc: HLC(wall: 9, counter: 1), device: "dev"), hash: "abc", dirty: true)
            s.cursors["other"] = 4; s.committedSeq = 2
        }
        try a.save()
        let b = try SyncLedger(url: url, deviceId: "ignored", epoch: 9)
        XCTAssertEqual(b.row("d:1")?.hash, "abc")
        XCTAssertEqual(b.read { $0.cursors["other"] }, 4)
        XCTAssertEqual(b.deviceId, "dev", "the persisted identity wins")
        a.mutate { $0.committedSeq = 99 }
        b.mutate { $0.committedSeq = 5 }
        b.reload()
        XCTAssertEqual(b.read { $0.committedSeq }, 2, "reload drops unsaved edits")
    }
}

// MARK: - Engine

final class CloudSyncEngineTests: CloudSyncTestCase {

    func testTwoMacsConvergeOnEveryKindOfRow() async throws {
        let w = try makeWorld()
        let (a, b) = (w.devices[0], w.devices[1])
        let did = UUID(), mid = UUID()
        try await a.insertDictation(did, token: "d1", audio: nil)
        try await a.insertMeeting(mid, token: "m1")
        try a.writeChat(mid, body: "thread")
        try await a.addWord("teh", "the", token: "w1")
        a.defaults.set(7, forKey: "bestStreak")
        await w.settle()
        let sa = try await a.state(), sb = try await b.state()
        XCTAssertEqual(sa, sb)
        XCTAssertEqual(sb.count, 5, "dictation, meeting, chat, word and the streak: \(sb.keys)")
        XCTAssertEqual(b.defaults.integer(forKey: "bestStreak"), 7)
        // edits and deletes travel too
        try await b.editDictation(did, token: "d2", pinned: true)
        try await b.deleteMeeting(mid)
        try await b.deleteWord("teh", "the")
        a.defaults.set(9, forKey: "bestStreak"); b.defaults.set(8, forKey: "bestStreak")
        await b.capture(); await a.capture()
        await w.settle()
        let ta = try await a.state(), tb = try await b.state()
        XCTAssertEqual(ta, tb)
        XCTAssertNil(ta["m:\(mid.uuidString)"])
        XCTAssertEqual(ta["s:bestStreak"], "9", "the best streak merges by maximum")
        XCTAssertTrue(ta["d:\(did.uuidString)"]?.contains("notes=d2") == true)
    }

    func testTheNewerEditWinsAndAnOldDuplicateBatchChangesNothing() async throws {
        let w = try makeWorld()
        let (a, b) = (w.devices[0], w.devices[1])
        let id = UUID()
        try await a.insertDictation(id, token: "orig", audio: nil)
        await w.settle()
        w.clock.advance(5_000)
        try await a.editDictation(id, token: "older", pinned: false); await a.capture()
        w.clock.advance(5_000)
        try await b.editDictation(id, token: "newer", pinned: true); await b.capture()
        await w.settle()
        for d in w.devices { try await aTrue(try await d.state()["d:\(id.uuidString)"]!.contains("notes=newer")) }
        // replay the same remote batches (the cursor save was "lost"): nothing changes — the merge is idempotent
        let before = try await a.state()
        a.crashAndRestart()
        let raw = try SyncLedger(url: a.cloudDir.appendingPathComponent("ledger.json"), deviceId: a.id, epoch: 1)
        raw.mutate { $0.cursors = [:]; $0.serverVersion = 0 }
        try raw.save()
        await a.cycle(force: true)
        try await aEqual(try await before, try await a.state())
        let uploads = w.server.commitLog.count
        await w.settle(2)
        XCTAssertEqual(w.server.commitLog.count, uploads, "re-merging old batches did not look like new local edits")
    }

    func testBatchesCloseAt50ChangesAt5MinutesAndAt4MB() async throws {
        let w = try makeWorld(1)
        let a = w.devices[0]
        await a.cycle(force: true)                                  // enrol: initial phase done, nothing to send
        for i in 0..<49 { try await a.insertDictation(UUID(), token: "n\(i)", audio: nil) }
        await a.capture()
        await a.cycle(force: false)
        XCTAssertEqual(w.server.version, 0, "49 changes younger than 5 minutes stay open")
        try await a.insertDictation(UUID(), token: "fifty", audio: nil); await a.capture()
        await a.cycle(force: false)
        XCTAssertEqual(w.server.version, 1, "the 50th change closes the batch")
        var payload = try JSONDecoder().decode(SyncBatchPayload.self, from: try w.decrypt(w.server.commitLog[0].name))
        XCTAssertEqual(payload.ops.count, 50)
        // age
        try await a.insertDictation(UUID(), token: "lonely", audio: nil); await a.capture()
        await a.cycle(force: false)
        XCTAssertEqual(w.server.version, 1)
        w.clock.advance(5 * 60_000 + 1000)
        await a.cycle(force: false)
        XCTAssertEqual(w.server.version, 2, "a change older than 5 minutes closes the batch")
        payload = try JSONDecoder().decode(SyncBatchPayload.self, from: try w.decrypt(w.server.commitLog[1].name))
        XCTAssertEqual(payload.ops.count, 1)
        // size: 7 rows of ~1 MB split into batches under 4 MB
        let big = String(repeating: "x", count: 1_000_000)
        let ctxContainer = a.db.persistentContainer!
        let ctx = ctxContainer.newBackgroundContext()
        try await ctx.perform {
            for i in 0..<7 {
                let o = NSManagedObject(entity: NSEntityDescription.entity(forEntityName: "TranscriptionEntity", in: ctx)!, insertInto: ctx)
                let now = Date()
                o.setValue(UUID(), forKey: "id"); o.setValue(now, forKey: "timestamp"); o.setValue(now, forKey: "createdAt"); o.setValue(now, forKey: "lastModifiedAt")
                o.setValue(big + "\(i)", forKey: "transcription"); o.setValue("en", forKey: "language"); o.setValue("m", forKey: "modelUsed")
            }
            try ctx.save()
        }
        await a.capture()
        let before = w.server.commitLog.count
        await a.cycle(force: true)
        let created = w.server.commitLog.dropFirst(before)
        XCTAssertGreaterThanOrEqual(created.count, 2)
        for entry in created {
            let plain = try w.decrypt(entry.name)
            XCTAssertLessThanOrEqual(plain.count, 4 << 20 + 1_100_000, "a batch closes at 4 MB (one row of slack)")
        }
        XCTAssertEqual(created.reduce(0) { $0 + ((try? JSONDecoder().decode(SyncBatchPayload.self, from: try w.decrypt($1.name)).ops.count) ?? 0) }, 7)
    }

    func testALibraryOf10000DictationsIsCutIntoSizeCappedBatchesAndArrivesComplete() async throws {
        let w = try makeWorld(2)
        let (a, b) = (w.devices[0], w.devices[1])
        let ctx = a.db.persistentContainer!.newBackgroundContext()
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 20)
        try await ctx.perform {
            let entity = NSEntityDescription.entity(forEntityName: "TranscriptionEntity", in: ctx)!
            for i in 0..<10_000 {
                let o = NSManagedObject(entity: entity, insertInto: ctx)
                let now = Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
                o.setValue(UUID(), forKey: "id"); o.setValue(now, forKey: "timestamp"); o.setValue(now, forKey: "createdAt"); o.setValue(now, forKey: "lastModifiedAt")
                o.setValue("\(i) \(text)", forKey: "transcription"); o.setValue("en", forKey: "language"); o.setValue("m", forKey: "modelUsed")
                if i % 1000 == 999 { try ctx.save(); ctx.reset() }
            }
            if ctx.hasChanges { try ctx.save() }
        }
        await a.cycle(force: true)
        let batches = w.server.commitLog
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertLessThan(batches.count, 40, "10,000 rows are a handful of objects, not 200 of 50 changes")
        var total = 0
        for entry in batches {
            let plain = try w.decrypt(entry.name)
            XCTAssertLessThanOrEqual(plain.count, 5 << 20, "every batch is size-capped")
            total += try JSONDecoder().decode(SyncBatchPayload.self, from: plain).ops.count
        }
        XCTAssertEqual(total, 10_000)
        let phase = try await a.currentEngine().status.phase
        XCTAssertEqual(phase, .idle)
        await b.cycle(force: true)
        let count = try await b.liveIDs("TranscriptionEntity").count
        XCTAssertEqual(count, 10_000)
    }

    func testACrashAfterUploadReplaysIdenticalBytesAndAnAcknowledgedCommitIsNotDoubled() async throws {
        let w = try makeWorld(2)
        let (a, b) = (w.devices[0], w.devices[1])
        try await a.insertDictation(UUID(), token: "x", audio: nil); await a.capture()
        a.transport.arm("crash:after:upload")
        let ok = await a.cycle(force: true)
        XCTAssertFalse(ok, "the process died after the upload")
        let name = w.server.prefix + "changes/\(a.id)/000000000001"
        let uploaded = try XCTUnwrap(w.server.allObjects()[name])
        XCTAssertEqual(w.server.version, 0, "not committed, so invisible")
        let outboxBytes = try await a.currentEngine().outboxEntries()
        XCTAssertEqual(outboxBytes.count, 1)
        await a.cycle(force: true)
        XCTAssertEqual(w.server.allObjects()[name], uploaded, "immutable: the replay did not change the object")
        XCTAssertEqual(w.server.version, 1)
        XCTAssertEqual(CloudCRC32C.checksum(uploaded), w.server.heads[a.id]?.crc)
        // a commit that succeeded but whose reply was lost, then a crash before the bookkeeping
        try await a.insertDictation(UUID(), token: "y", audio: nil); await a.capture()
        a.crash.arm("afterCommit")
        let crashed2 = await a.cycle(force: true)
        XCTAssertFalse(crashed2)
        XCTAssertEqual(w.server.version, 2)
        await a.cycle(force: true)
        XCTAssertEqual(w.server.version, 2, "the identical retry is accepted without a second advance")
        let leftover = try await a.currentEngine().outboxEntries()
        XCTAssertTrue(leftover.isEmpty)
        await w.settle(2)
        try await aEqual(try await b.state(), try await a.state())
        // a dropped reply
        try await a.insertDictation(UUID(), token: "z", audio: nil); await a.capture()
        a.transport.arm("drop:commit")
        await a.cycle(force: true)
        await a.cycle(force: true)
        XCTAssertEqual(w.server.version, 3)
        XCTAssertEqual(w.server.commitLog.count, 3)
    }

    func testSequenceConflictResyncsTheCounterFromTheReturnedHead() async throws {
        let w = try makeWorld(2)
        let (a, b) = (w.devices[0], w.devices[1])
        // The server already holds five batches of this device id (a reinstalled / restored Mac).
        let server = w.server, aid = a.id
        a.transport.beforeCommit = { server.lock.lock(); server.heads[aid] = CloudHead(seq: 5, crc: 77); server.version += 1; server.lock.unlock() }
        try await a.insertDictation(UUID(), token: "after-restore", audio: nil); await a.capture()
        await a.cycle(force: true)
        a.transport.beforeCommit = nil
        XCTAssertEqual(w.server.heads[a.id]?.seq, 6, "the batch was renumbered to head + 1")
        let blob = try w.decrypt(w.server.prefix + "changes/\(a.id)/000000000006")
        XCTAssertEqual(try JSONDecoder().decode(SyncBatchPayload.self, from: blob).seq, 6, "re-encrypted for its new place: the sequence number is bound into the ciphertext")
        let leftover = try await a.currentEngine().outboxEntries()
        XCTAssertTrue(leftover.isEmpty)
        _ = b
    }

    func testAFlippedByteIsRefusedAndNeverMerged() async throws {
        let w = try makeWorld(2)
        let (a, b) = (w.devices[0], w.devices[1])
        try await a.insertDictation(UUID(), token: "one", audio: nil); await a.capture()
        await w.settle(2)
        let known = try await b.state()
        XCTAssertEqual(known.count, 1)
        // a second batch is tampered with in transit
        let bad = UUID()
        try await a.insertDictation(bad, token: "two", audio: nil); await a.capture()
        await a.cycle(force: true)
        b.transport.tamperNames = ["changes/\(a.id)/000000000002"]
        let status = try await b.currentEngine().syncNow()
        guard case .error = status.phase else { return XCTFail("expected an error status, got \(status.phase)") }
        try await aEqual(try await b.state(), known, "nothing from the tampered batch was merged")
        let cursor = try await b.currentEngine().ledgerSnapshot().cursors[a.id]
        XCTAssertEqual(cursor, 1, "the cursor did not move past the refused batch")
        b.transport.clearFaults()
        await b.cycle(force: true)
        try await aEqual(try await b.state(), try await a.state(), "the untampered copy merges")
    }

    func testAMacThatHasNeverReadAnythingTreatsAFailedObjectAsAWrongKey() async throws {
        let w = try makeWorld(1)
        let a = w.devices[0]
        try await a.insertDictation(UUID(), token: "secret", audio: nil); await a.capture()
        await a.cycle(force: true)
        var other = CloudKeyRing(); try other.insert(Data(repeating: 9, count: 32), version: 1)
        let b = try SimDevice(index: 1, server: w.server, clock: w.clock, ring: other, tag: "wrongkey")
        addTeardownBlock { @MainActor in b.cleanUp() }
        let status = try await b.currentEngine().syncNow()
        XCTAssertEqual(status.phase, .needsKey)
        try await aEqual(try await b.state().count, 0)
        // no key at all
        b.keyProvider = { nil }
        let none = try await b.currentEngine().syncNow()
        XCTAssertEqual(none.phase, .needsKey)
        // an unknown key VERSION is a missing key as well
        var v2 = CloudKeyRing(); try v2.insert(Data(repeating: 1, count: 32), version: 2)
        b.keyProvider = { v2 }
        let unknown = try await b.currentEngine().syncNow()
        XCTAssertEqual(unknown.phase, .needsKey)
        try await aEqual(try await b.state().count, 0)
    }

    func testAStaleMacDeletesAcknowledgedRowsThatNoLongerExistAndUploadsNeverAcknowledgedOnes() async throws {
        let w = try makeWorld(2) { $0.policy.snapshotAfterBatches = 0 }
        let (a, b) = (w.devices[0], w.devices[1])
        let keep = UUID(), gone = UUID()
        try await a.insertDictation(keep, token: "keep", audio: nil)
        try await a.insertDictation(gone, token: "gone", audio: nil)
        await w.settle(3)
        try await aEqual(try await b.state().count, 2)
        // B goes away. A deletes a row; 100 days pass; A compacts, which drops the old tombstone.
        b.transport.offline = true
        let offlineOnly = UUID()
        try await b.insertDictation(offlineOnly, token: "made-offline", audio: nil); await b.capture()
        try await a.deleteDictation(gone); await a.capture()
        await a.cycle(force: true)
        w.clock.advance(100 * 86_400_000)
        w.clock.advance(1000)
        try await a.insertDictation(UUID(), token: "later", audio: nil); await a.capture()
        for _ in 0..<3 { w.clock.advance(60_000); await a.cycle(force: true) }
        let snap = try XCTUnwrap(w.server.snapshot)
        let snapOps = try JSONDecoder().decode(SyncSnapshotPayload.self, from: try w.decrypt(w.server.name(.snapshot(id: snap.id)))).ops
        XCTAssertNil(snapOps.first { $0.k == "d:\(gone.uuidString)" }, "the tombstone is older than the 90-day horizon and was dropped")
        // B returns.
        b.transport.offline = false
        await w.settle(4)
        let sb = try await b.state(), sa = try await a.state()
        XCTAssertEqual(sa, sb)
        XCTAssertNil(sb["d:\(gone.uuidString)"], "a previously acknowledged row absent from snapshot and tail was deleted elsewhere: it must not come back")
        XCTAssertNotNil(sb["d:\(keep.uuidString)"])
        XCTAssertNotNil(sa["d:\(offlineOnly.uuidString)"], "a row never acknowledged uploads as new")
    }

    func testClockSkewOfADayOrAYearNeitherPoisonsNorSilencesADevice() async throws {
        let skews: [Int64] = [86_400_000, -86_400_000, 365 * 86_400_000, -365 * 86_400_000]
        for skew in skews {
            let w = try makeWorld(2) { $0.skewMs = $0.index == 0 ? skew : 0 }
            let (a, b) = (w.devices[0], w.devices[1])
            let id = UUID()
            try await b.insertDictation(id, token: "base", audio: nil)
            await w.settle(3)
            // A edits before it has ever heard the server time again in this incarnation: the stamp is skewed.
            a.crashAndRestart()
            w.clock.advance(10_000)
            try await a.editDictation(id, token: "a-edit", pinned: false); await a.capture()
            w.clock.advance(600_000)
            try await b.editDictation(id, token: "b-later", pinned: true); await b.capture()
            await w.settle(4)
            let sa = try await a.state(), sb = try await b.state()
            XCTAssertEqual(sa, sb, "skew \(skew)")
            XCTAssertTrue(sa["d:\(id.uuidString)"]!.contains("notes=b-later"), "the really-later edit wins with skew \(skew): \(sa["d:\(id.uuidString)"]!)")
            // and a skewed Mac that has talked to the server is heard again
            w.clock.advance(600_000)
            try await a.editDictation(id, token: "a-final", pinned: false); await a.capture()
            await w.settle(4)
            try await aTrue(try await b.state()["d:\(id.uuidString)"]!.contains("notes=a-final"), "skew \(skew)")
            let ceiling = w.clock.now() + 86_400_000 + 60_000
            for (_, row) in try await a.currentEngine().ledgerSnapshot().rows { XCTAssertLessThanOrEqual(row.hlc.wall, ceiling) }
            w.cleanUp()
        }
    }

    func testAFullPlanPausesUploadsButKeepsMergingThenResumes() async throws {
        let w = try makeWorld(2)
        let (a, b) = (w.devices[0], w.devices[1])
        try await b.insertDictation(UUID(), token: "from-b", audio: nil); await b.capture()
        await b.cycle(force: true)
        w.server.quotaLimit = 10                       // full
        let mine = UUID()
        try await a.insertDictation(mine, token: "from-a", audio: nil); await a.capture()
        let status = try await a.currentEngine().syncNow()
        XCTAssertEqual(status.phase, .overQuota)
        try await aEqual(try await a.state().count, 2, "downloads and merges continue while uploads are paused")
        XCTAssertGreaterThan(status.pendingChanges, 0, "nothing is dropped")
        let entries = try await a.currentEngine().outboxEntries()
        XCTAssertEqual(entries.count, 1, "the encrypted batch waits on disk")
        w.server.quotaLimit = .max
        await w.settle(3)
        try await aEqual(try await b.state(), try await a.state())
        try await aNotNil(try await b.state()["d:\(mine.uuidString)"])
    }

    func testDeletingARecordingFreesItsCloudAudioEvenWhenThePlanIsOverQuota() async throws {
        let w = try makeWorld(1)
        let a = w.devices[0]
        let id = UUID()
        try await a.insertDictation(id, token: "big", audio: Data("AUDIO".utf8) + Data(repeating: 7, count: 6000))
        await w.settle(3)
        XCTAssertTrue(w.server.allObjects().keys.contains { $0.contains("/audio/") })
        w.server.quotaLimit = 100                      // a downgrade: stored data now exceeds the plan, every upload is refused
        try await a.insertDictation(UUID(), token: "new", audio: nil); await a.capture()
        let over = try await a.currentEngine().syncNow()
        XCTAssertEqual(over.phase, .overQuota)
        try await a.deleteDictation(id); await a.capture()
        _ = try await a.currentEngine().syncNow()
        XCTAssertFalse(w.server.allObjects().keys.contains { $0.contains("/audio/") }, "the delete freed the cloud copy although uploads are refused")
        w.server.quotaLimit = .max
        await w.settle(3)
        let final = try await a.currentEngine().syncNow()
        XCTAssertEqual(final.phase, .idle)
        XCTAssertEqual(final.pendingChanges, 0)
    }

    func testReadOnlyModeUploadsNothingButStillMerges() async throws {
        let w = try makeWorld(2)
        let (a, b) = (w.devices[0], w.devices[1])
        try await a.insertDictation(UUID(), token: "before-lapse", audio: nil); await a.capture()
        await a.cycle(force: true)
        w.server.readOnly = true
        let local = UUID()
        try await b.insertDictation(local, token: "local-only", audio: nil); await b.capture()
        let versionBefore = w.server.version
        let status = try await b.currentEngine().syncNow()
        XCTAssertEqual(status.phase, .readOnly)
        XCTAssertEqual(w.server.version, versionBefore, "no upload while read-only")
        try await aEqual(try await b.state().count, 2, "merges continue: A's earlier row arrived")
        XCTAssertTrue(b.transport.trace.filter { $0 == "requestUploads" || $0 == "commit" }.isEmpty)
        w.server.readOnly = false
        await w.settle(3)
        try await aNotNil(try await a.state()["d:\(local.uuidString)"], "after the plan is back the local change goes up")
    }

    func testSnapshotsCompactTheLogAndANewMacFastForwards() async throws {
        let w = try makeWorld(2) { $0.policy.snapshotAfterBatches = 3 }
        let (a, b) = (w.devices[0], w.devices[1])
        var ids: [UUID] = []
        for i in 0..<14 {
            let id = UUID(); ids.append(id)
            try await a.insertDictation(id, token: "r\(i)", audio: nil); await a.capture()
            if i == 2 { await b.cycle(force: true) }           // B syncs early, then lags behind
            w.clock.advance(60_000)
            await a.cycle(force: true)
        }
        XCTAssertNotNil(w.server.snapshot)
        XCTAssertGreaterThan(w.server.snapshot!.version, 1)
        XCTAssertFalse(w.server.deletedNames.isEmpty, "batches covered by the previous snapshot were deleted by exact name")
        XCTAssertTrue(w.server.deletedNames.allSatisfy { $0.contains("/changes/") || $0.contains("/snapshots/") })
        // B (behind the covers) and a brand-new Mac C both reach the same state
        let c = try SimDevice(index: 2, server: w.server, clock: w.clock, ring: w.ring, tag: "newmac")
        addTeardownBlock { @MainActor in c.cleanUp() }
        w.devices.append(c)
        let downloadsBefore = w.server.downloadCount
        await w.settle(3)
        let sa = try await a.state()
        XCTAssertEqual(sa.count, 14)
        for d in [b, c] { try await aEqual(try await d.state(), sa) }
        XCTAssertLessThan(w.server.downloadCount - downloadsBefore, 14 + 6, "fast-forward: snapshot + tail, not every batch since the beginning")
    }

    func testARefusedSnapshotClaimDoesNotBlockTheBatch() async throws {
        let w = try makeWorld(1) { $0.policy.snapshotAfterBatches = 0 }
        let a = w.devices[0]
        try await a.insertDictation(UUID(), token: "one", audio: nil); await a.capture()
        await a.cycle(force: true)                                  // batch 1, then snapshot v1 (accepted)
        XCTAssertEqual(w.server.snapshot?.version, 1)
        let server = w.server
        a.transport.beforeCommit = { server.lock.lock(); server.snapshot = CloudSnapshotInfo(id: String(repeating: "c", count: 32), covers: [:], version: 7); server.lock.unlock() }
        try await a.insertDictation(UUID(), token: "two", audio: nil); await a.capture()
        await a.cycle(force: true)                                  // the text batch commits; the snapshot claim (v2) loses the compare-and-set
        a.transport.beforeCommit = nil
        XCTAssertGreaterThanOrEqual(w.server.rejectedSnapshots, 1)
        XCTAssertEqual(w.server.snapshot?.version, 7, "the other writer's snapshot stands")
        XCTAssertGreaterThanOrEqual(w.server.heads[a.id]?.seq ?? 0, 3, "the batches themselves still committed")
        let leftovers = try await a.currentEngine().outboxEntries()
        XCTAssertTrue(leftovers.isEmpty)
        XCTAssertTrue(w.server.deletedNames.contains { $0.contains("/snapshots/") }, "the refused snapshot object was removed")
        let dirty = try await a.currentEngine().ledgerSnapshot().rows.values.filter { $0.dirty }
        XCTAssertTrue(dirty.isEmpty)
    }

    func testAudioUploadsAfterTextIsAnnouncedAndDownloadsOnDemand() async throws {
        let w = try makeWorld(2)
        let (a, b) = (w.devices[0], w.devices[1])
        let id = UUID()
        let audio = Data("AUDIOMARK".utf8) + Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try await a.insertDictation(id, token: "spoken", audio: audio)
        await w.settle(4)
        let names = w.server.allObjects().keys.sorted()
        XCTAssertTrue(names.contains { $0.contains("/audio/") }, "audio is a separate encrypted object")
        // text batch committed before the audio announcement
        let first = try JSONDecoder().decode(SyncBatchPayload.self, from: try w.decrypt(w.server.commitLog[0].name))
        XCTAssertNotNil(first.ops.first?.row)
        XCTAssertNil(first.ops.first?.aud)
        let second = try JSONDecoder().decode(SyncBatchPayload.self, from: try w.decrypt(w.server.commitLog[1].name))
        XCTAssertNotNil(second.ops.first?.aud)
        // B has the row but not the file until asked
        let key = "d:\(id.uuidString)"
        try await aNotNil(try await b.state()[key])
        try await aTrue(try await b.audioDigests().isEmpty)
        let missing = try await b.currentEngine().missingAudio()
        XCTAssertEqual(missing.files, 1)
        let url = try await b.currentEngine().ensureAudio(dictationID: id)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(url)), audio)
        let again = try await b.currentEngine().missingAudio()
        XCTAssertEqual(again.files, 0)
        for blob in w.server.allObjects().values { XCTAssertNil(blob.range(of: Data("AUDIOMARK".utf8))) }
        // "download all" on a third Mac
        let c = try SimDevice(index: 2, server: w.server, clock: w.clock, ring: w.ring, tag: "dl-all")
        addTeardownBlock { @MainActor in c.cleanUp() }
        await c.cycle(force: true)
        let n = try await c.currentEngine().downloadAllAudio()
        XCTAssertEqual(n, 1)
        try await aEqual(try await c.audioDigests()[key], CloudFuzz.hex(audio))
        // a deleted row's audio object is removed from the cloud
        try await a.deleteDictation(id); await a.capture()
        await w.settle(3)
        XCTAssertFalse(w.server.allObjects().keys.contains { $0.contains("/audio/") })
    }

    func testObjectsOf8MBOrMoreAreOfferedTheResumablePathAndStreamThroughFiles() async throws {
        let w = try makeWorld(2)
        let (a, b) = (w.devices[0], w.devices[1])
        let id = UUID()
        var rng = SplitMix64(seed: 99)           // incompressible: the engine compresses before it encrypts
        let big = Data((0..<(9 << 20)).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        try await a.insertDictation(id, token: "long meeting audio", audio: big)
        await w.settle(4)
        XCTAssertNil(a.lastError, "cycle error: \(a.lastError ?? "")")
        XCTAssertTrue(w.server.allObjects().keys.contains { $0.contains("/audio/") }, "the audio object was uploaded")
        XCTAssertEqual(w.server.resumableGrants, 1, "the engine only passes the size; the grant says resumable")
        let url = try await b.currentEngine().ensureAudio(dictationID: id)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(url)).count, big.count)
        XCTAssertEqual(CloudFuzz.hex(try Data(contentsOf: XCTUnwrap(url))), CloudFuzz.hex(big))
    }

    func testTheSameDictionaryWordAddedOnTwoMacsIsOneEntry() async throws {
        let w = try makeWorld(2)
        let (a, b) = (w.devices[0], w.devices[1])
        try await a.addWord("teh", "the", token: "from-a")
        w.clock.advance(1000)
        try await b.addWord("Teh", "The", token: "from-b")      // same entry by what it does (case-insensitive)
        try await b.addWord("seperate", "separate", token: "only-b")
        await a.capture(); await b.capture()
        await w.settle(4)
        let sa = try await a.state(), sb = try await b.state()
        XCTAssertEqual(sa, sb)
        XCTAssertEqual(sa.keys.filter { $0.hasPrefix("w:") }.count, 2)
    }

    func testFirstEnableUploadsTextFirstThenAudioAndResumesAfterACrash() async throws {
        let w = try makeWorld(2) { $0.policy.initialBatchMaxChanges = 20 }
        let (a, b) = (w.devices[0], w.devices[1])
        var audioIDs: [UUID] = []
        for i in 0..<110 {
            let id = UUID()
            let audio: Data? = i % 10 == 0 ? Data("a\(i)".utf8) + Data(repeating: UInt8(i), count: 300) : nil
            if audio != nil { audioIDs.append(id) }
            try await a.insertDictation(id, token: "h\(i)", audio: audio)
        }
        // the cloud is switched on: crash after the second text batch
        a.crash.arm("afterCommit")
        try await aFalse(await a.cycle(force: true))
        var s = try await a.currentEngine().ledgerSnapshot()
        XCTAssertEqual(s.initialPhase, .text, "still in the text phase after the crash")
        XCTAssertGreaterThan(s.initialTotal, 100)
        a.crash.arm("afterCommit")
        try await aFalse(await a.cycle(force: true))
        await a.cycle(force: true)
        await a.cycle(force: true)
        s = try await a.currentEngine().ledgerSnapshot()
        XCTAssertEqual(s.initialPhase, .done)
        XCTAssertEqual(s.rows.values.filter { $0.dirty }.count, 0)
        // order on the wire: every text batch before any audio announcement
        var sawAudio = false
        for entry in w.server.commitLog {
            let payload = try JSONDecoder().decode(SyncBatchPayload.self, from: try w.decrypt(entry.name))
            let hasAudio = payload.ops.contains { $0.aud != nil }
            if hasAudio { sawAudio = true } else { XCTAssertFalse(sawAudio, "text batch after audio started") }
        }
        XCTAssertTrue(sawAudio)
        await b.cycle(force: true)
        let n = try await b.liveIDs("TranscriptionEntity").count
        XCTAssertEqual(n, 110)
        let missing = try await b.currentEngine().missingAudio()
        XCTAssertEqual(missing.files, audioIDs.count)
    }

    func testNothingOnTheWireIsReadable() async throws {
        let w = try makeWorld(2)
        let a = w.devices[0]
        try await a.insertDictation(UUID(), token: "alpha", audio: Data("AUDIOMARK-payload".utf8))
        try await a.insertMeeting(UUID(), token: "beta")
        try await a.addWord("teh", "the", token: "gamma")
        await w.settle(4)
        XCTAssertGreaterThan(w.server.allObjects().count, 2)
        for (name, blob) in w.server.allObjects() {
            XCTAssertEqual(Array(blob.prefix(4)), Array("WCV1".utf8), name)
            for marker in ["ZQSECRET", "AUDIOMARK", "alpha", "beta", "gamma", "transcription", "dictation"] {
                XCTAssertNil(blob.range(of: Data(marker.utf8)), "\(marker) readable in \(name)")
            }
        }
    }

    func testPauseResumeAndTheStatusStream() async throws {
        let w = try makeWorld(1)
        let a = w.devices[0]
        let engine = try a.currentEngine()
        var seen: [SyncPhase] = []
        let stream = await engine.statusUpdates()
        let collector = Task { for await s in stream { seen.append(s.phase); if seen.count > 6 { break } } }
        try await a.insertDictation(UUID(), token: "p", audio: nil); await a.capture()
        await engine.pause()
        let trace0 = a.transport.trace.count
        let paused = await engine.syncNow()
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertEqual(a.transport.trace.count, trace0, "paused: no network at all")
        XCTAssertEqual(w.server.version, 0)
        await engine.resume()
        let status = await engine.syncNow()
        XCTAssertEqual(status.phase, .idle)
        XCTAssertEqual(w.server.version, 1)
        XCTAssertNotNil(status.lastSyncAt)
        collector.cancel()
        XCTAssertTrue(seen.contains(.paused))
        XCTAssertTrue(seen.contains(.syncing))
        a.transport.offline = true
        try await a.insertDictation(UUID(), token: "q", audio: nil); await a.capture()
        let off = await engine.syncNow()
        XCTAssertEqual(off.phase, .offline)
    }

    func testTheRunLoopPollsAtTheCadenceAndWakesImmediately() async throws {
        let w = try makeWorld(1)
        let a = w.devices[0]
        let delays = DelayLog()
        let engine = try SyncEngine(identity: a.identity, transport: a.transport, environment: a.environment, cloudDirectory: a.cloudDir,
                                    keyProvider: { [ring = w.ring] in ring }, nowMs: { [clock = w.clock] in clock.now() },
                                    sleeper: { delay in await delays.add(delay); try? await Task.sleep(for: .milliseconds(20)) })
        await engine.start(foreground: true)
        for _ in 0..<200 { if await delays.count >= 3 { break }; try await Task.sleep(for: .milliseconds(10)) }
        await engine.stop()
        let all = await delays.values
        XCTAssertGreaterThanOrEqual(all.count, 3)
        XCTAssertEqual(all.first, 30, "foreground cadence")
        let heads = a.transport.trace.filter { $0 == "heads" }.count
        XCTAssertGreaterThanOrEqual(heads, 3)
    }

    func testTheMassDeletionGuardHoldsBackTheDeletionOfAVanishedStore() async throws {
        let w = try makeWorld(2)
        let (a, b) = (w.devices[0], w.devices[1])
        for i in 0..<40 { try await a.insertDictation(UUID(), token: "k\(i)", audio: nil) }
        await w.settle(3)
        try await aEqual(try await b.liveIDs("TranscriptionEntity").count, 40)
        // the store looks empty (restored backup, failed load...)
        let ctx = a.db.persistentContainer!.newBackgroundContext()
        try await ctx.perform {
            for o in try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "TranscriptionEntity")) { ctx.delete(o) }
            try ctx.save()
        }
        await a.capture()
        await a.cycle(force: true)
        await w.settle(2)
        try await aEqual(try await b.liveIDs("TranscriptionEntity").count, 40, "40 deletions at once are not published without confirmation")
        let status = try await a.currentEngine().status
        guard case .error = status.phase else { return XCTFail("the user should be asked: \(status.phase)") }
        try await a.currentEngine().approveMassDeletion()
        await w.settle(3)
        try await aEqual(try await b.liveIDs("TranscriptionEntity").count, 0, "confirmed deletions go through")
    }

    func testCoreDataSavesAreTurnedIntoChangeHints() async throws {
        let w = try makeWorld(1)
        let a = w.devices[0]
        let box = HintBox()
        let observer = SyncChangeObserver(coordinator: a.db.persistentContainer!.persistentStoreCoordinator) { box.add($0) }
        let id = UUID()
        try await a.insertDictation(id, token: "hint", audio: nil)
        try await a.addWord("a", "b", token: "w")
        try await a.deleteDictation(id)
        XCTAssertTrue(box.keys.contains("d:\(id.uuidString)"))
        XCTAssertTrue(box.keys.contains("w:*"))
        withExtendedLifetime(observer) {}
    }
}

actor DelayLog {
    var values: [TimeInterval] = []
    var count: Int { values.count }
    func add(_ v: TimeInterval) { values.append(v) }
}

final class HintBox: @unchecked Sendable {
    private let lock = NSLock()
    private var set = Set<String>()
    func add(_ k: Set<String>) { lock.lock(); set.formUnion(k); lock.unlock() }
    var keys: Set<String> { lock.lock(); defer { lock.unlock() }; return set }
}

extension SyncEngine {
    func currentStatusPhase() -> SyncPhase { status.phase }
}

// MARK: - Existing history is never altered

final class CloudSyncHistorySafetyTests: CloudSyncTestCase {

    private func canonicalDump(_ container: NSPersistentContainer) throws -> [String] {
        let ctx = container.newBackgroundContext()
        var lines: [String] = []
        try ctx.performAndWait {
            for entity in ["TranscriptionEntity", "MeetingEntity", "DictionaryEntryEntity"] {
                let rows = try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: entity))
                lines += try rows.map { entity + ":" + String(decoding: try JSONValue.fromRow(HistoryArchive.encodeRow($0)).canonicalData(), as: UTF8.self) }
            }
        }
        return lines.sorted()
    }

    /// A store file produced by the current app model (same options as HistoryDatabase) still opens and keeps every
    /// row after the engine has scanned it, uploaded it and merged other Macs' changes into it.
    func testEnablingCloudLeavesAnExistingHistoryStoreFileUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "WhispererHistory", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))

        func open(_ url: URL) throws -> NSPersistentContainer {
            let container = NSPersistentContainer(name: "WhispererHistory", managedObjectModel: model)
            let d = NSPersistentStoreDescription(url: url)
            d.shouldMigrateStoreAutomatically = true
            d.shouldInferMappingModelAutomatically = true
            container.persistentStoreDescriptions = [d]
            var failure: Error?
            container.loadPersistentStores { _, error in failure = error }
            if let failure { throw failure }
            return container
        }

        // 1. a store as the shipping app writes it
        let original = root.appendingPathComponent("history.sqlite")
        var container = try open(original)
        let ctx = container.newBackgroundContext()
        try await ctx.perform {
            for i in 0..<40 {
                let t = NSManagedObject(entity: NSEntityDescription.entity(forEntityName: "TranscriptionEntity", in: ctx)!, insertInto: ctx)
                let now = Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
                t.setValue(UUID(), forKey: "id"); t.setValue(now, forKey: "timestamp"); t.setValue(now, forKey: "createdAt"); t.setValue(now, forKey: "lastModifiedAt")
                t.setValue("old dictation \(i) é ✓", forKey: "transcription"); t.setValue("en", forKey: "language"); t.setValue("m", forKey: "modelUsed")
                t.setValue(Int32(3), forKey: "wordCount"); t.setValue(i % 2 == 0, forKey: "isPinned")
                if i < 6 {
                    let m = NSManagedObject(entity: NSEntityDescription.entity(forEntityName: "MeetingEntity", in: ctx)!, insertInto: ctx)
                    m.setValue(UUID(), forKey: "id"); m.setValue("old meeting \(i)", forKey: "title"); m.setValue(now, forKey: "createdAt")
                    m.setValue("en", forKey: "language"); m.setValue("m", forKey: "modelUsed"); m.setValue("{\"s\":\(i)}", forKey: "segmentsJSON")
                    let w = NSManagedObject(entity: NSEntityDescription.entity(forEntityName: "DictionaryEntryEntity", in: ctx)!, insertInto: ctx)
                    w.setValue(UUID(), forKey: "id"); w.setValue("wrong\(i)", forKey: "incorrectForm"); w.setValue("right\(i)", forKey: "correctForm")
                    w.setValue(now, forKey: "createdAt"); w.setValue(now, forKey: "lastModifiedAt")
                }
            }
            try ctx.save()
        }
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
        container = NSPersistentContainer(name: "unused", managedObjectModel: model)

        // 2. a copy of the file is what we test on
        let copy = root.appendingPathComponent("copy/history.sqlite")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: original.path + suffix) {
            try FileManager.default.copyItem(atPath: original.path + suffix, toPath: copy.path + suffix)
        }
        let metaBefore = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: copy)
        let live = try open(copy)
        let before = try canonicalDump(live)
        XCTAssertEqual(before.count, 40 + 6 + 6, "the existing file opens and holds its rows")

        // 3. Cloud is enabled on it: scan, upload, and merge a change that arrives from another Mac
        let w = try makeWorld(2)
        let engineDevice = w.devices[0], other = w.devices[1]
        nonisolated(unsafe) let shared = live
        let env = SyncStoreEnvironment(newContext: { shared.newBackgroundContext() }, defaults: engineDevice.defaults, recordings: engineDevice.recordings,
                                       meetingRecordings: engineDevice.meetingRecordings, meetingData: engineDevice.meetingData)
        let engine = try SyncEngine(identity: engineDevice.identity, transport: engineDevice.transport, environment: env, cloudDirectory: engineDevice.cloudDir,
                                    keyProvider: { [ring = w.ring] in ring }, nowMs: { [clock = w.clock] in clock.now() })
        _ = await engine.syncNow()
        _ = await engine.syncNow()
        XCTAssertGreaterThan(w.server.version, 0, "the whole history went up")
        // another Mac adds one row; it merges in, and nothing existing changes
        try await other.insertDictation(UUID(), token: "from-the-other-mac", audio: nil)
        await other.cycle(force: true)
        _ = await engine.syncNow()
        let after = try canonicalDump(live)
        XCTAssertEqual(Set(before).subtracting(after), [], "no existing row was altered or removed")
        XCTAssertEqual(after.count, before.count + 1)

        // 4. the file still opens with the app model and says nothing about Cloud
        for store in live.persistentStoreCoordinator.persistentStores { try live.persistentStoreCoordinator.remove(store) }
        let metaAfter = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: copy)
        XCTAssertEqual(metaBefore["NSStoreModelVersionHashes"] as? NSDictionary, metaAfter["NSStoreModelVersionHashes"] as? NSDictionary, "schema unchanged")
        XCTAssertNil(metaAfter["NSPersistentHistoryTrackingKey"], "no persistent-history option was switched on")
        let reopened = try open(copy)
        XCTAssertEqual(try canonicalDump(reopened).count, 53)
        for store in reopened.persistentStoreCoordinator.persistentStores { try reopened.persistentStoreCoordinator.remove(store) }
        withExtendedLifetime(container) {}
    }

    func testTheScanIsReadOnlyForALargeExistingLibrary() async throws {
        let w = try makeWorld(1)
        let a = w.devices[0]
        for i in 0..<30 { try await a.insertDictation(UUID(), token: "pre\(i)", audio: nil) }
        let before = try await a.state()
        _ = try await a.currentEngine().ledgerSnapshot()
        await a.capture()
        await a.cycle(force: true)
        await a.cycle(force: true)
        try await aEqual(try await a.state(), before)
    }
}

// XCTest's assertions cannot take `await` inside their autoclosures; these evaluate first.
func aEqual<T: Equatable>(_ a: @autoclosure () async throws -> T, _ b: @autoclosure () async throws -> T, _ message: String = "",
                          file: StaticString = #filePath, line: UInt = #line) async throws {
    let x = try await a(), y = try await b()
    XCTAssertEqual(x, y, message, file: file, line: line)
}
func aTrue(_ a: @autoclosure () async throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
    let x = try await a(); XCTAssertTrue(x, message, file: file, line: line)
}
func aFalse(_ a: @autoclosure () async throws -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
    let x = try await a(); XCTAssertFalse(x, message, file: file, line: line)
}
func aNil<T>(_ a: @autoclosure () async throws -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
    let x = try await a(); XCTAssertNil(x, message, file: file, line: line)
}
func aNotNil<T>(_ a: @autoclosure () async throws -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
    let x = try await a(); XCTAssertNotNil(x, message, file: file, line: line)
}
