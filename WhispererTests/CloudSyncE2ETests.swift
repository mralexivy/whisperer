//
//  CloudSyncE2ETests.swift
//  WhispererTests
//
//  The whole Whisperer Cloud stack, for real: several virtual Macs, each with its own Core Data store, device key,
//  key ring, CloudAccountController and SyncEngine, talking through the real CloudHTTPTransport to the real Go
//  handlers (server/cmd/devserver: in-memory stores, a fake Cloud Storage speaking the signed-URL + resumable
//  protocol, a test Apple root). Opt in with TEST_RUNNER_CLOUD_DEVSERVER=http://127.0.0.1:8788.
//

import XCTest
import CoreData
import CryptoKit
@testable import whisperer

// MARK: - Dev server window onto the bucket

extension CloudAccountE2ETests.DevServer {
    func objects(prefix: String = "") async throws -> [String: Int] {
        var c = URLComponents(url: base.appendingPathComponent("dev/objects"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "prefix", value: prefix)]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Int]) ?? [:]
    }

    func rawObject(_ name: String) async throws -> Data {
        var c = URLComponents(url: base.appendingPathComponent("dev/object"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "name", value: name)]
        let (data, response) = try await URLSession.shared.data(from: c.url!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return data
    }

    func overwrite(_ name: String, with data: Data) async throws {
        var c = URLComponents(url: base.appendingPathComponent("dev/object"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "name", value: name)]
        var request = URLRequest(url: c.url!)
        request.httpMethod = "PUT"
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    /// Names of the stored objects that contain `marker` as raw bytes.
    func grep(_ marker: String) async throws -> (matches: [String], scanned: Int) {
        let out = try await post("dev/grep", ["marker": marker])
        return ((out["matches"] as? [String]) ?? [], (out["scanned"] as? Int) ?? 0)
    }

    func setPlan(tier: String, storedBytes: Int64, downloadBytes: Int64 = 1 << 40, grants: Int = 100_000) async throws {
        _ = try await post("dev/set-plan", ["tier": tier, "storedBytes": storedBytes, "monthlyDownloadBytes": downloadBytes, "monthlyUploadGrants": grants])
    }
}

// MARK: - A transport that can be switched off

nonisolated final class GateTransport: CloudTransport, @unchecked Sendable {
    private let inner: CloudTransport
    private let lock = NSLock()
    private var _offline = false
    private(set) var calls = 0
    var offline: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _offline }
        set { lock.lock(); _offline = newValue; lock.unlock() }
    }

    init(_ inner: CloudTransport) { self.inner = inner }

    private func gate() throws {
        lock.lock(); calls += 1; let off = _offline; lock.unlock()
        if off { throw CloudTransportError.offline }
    }

    func heads(since version: Int64?) async throws -> CloudHeads { try gate(); return try await inner.heads(since: version) }
    func requestUploads(_ items: [CloudUploadRequest]) async throws -> [CloudGrant] { try gate(); return try await inner.requestUploads(items) }
    func upload(_ data: Data, with grant: CloudGrant) async throws { try gate(); try await inner.upload(data, with: grant) }
    func commit(device: String, seq: Int64, crc: UInt32, extra: [CloudObjectRef], snapshot: CloudSnapshotInfo?) async throws -> CloudCommitResult {
        try gate(); return try await inner.commit(device: device, seq: seq, crc: crc, extra: extra, snapshot: snapshot)
    }
    func requestDownloads(_ refs: [CloudObjectRef]) async throws -> [CloudGrant] { try gate(); return try await inner.requestDownloads(refs) }
    func download(with grant: CloudGrant) async throws -> Data { try gate(); return try await inner.download(with: grant) }
    func delete(_ refs: [CloudObjectRef]) async throws -> Int { try gate(); return try await inner.delete(refs) }
    func upload(fileAt url: URL, size: Int64, with grant: CloudGrant) async throws { try gate(); try await inner.upload(fileAt: url, size: size, with: grant) }
    func download(with grant: CloudGrant, to url: URL) async throws { try gate(); try await inner.download(with: grant, to: url) }
}

// MARK: - A Mac: real account controller + real engine over a virtual Mac's Core Data store

@MainActor
final class E2EMac {
    let mac: CloudAccountE2ETests.SimMac
    /// The virtual Mac's store, folders and local-edit helpers. Its own (in-memory-transport) engine is never used.
    let local: SimDevice
    private(set) var gate: GateTransport?
    private(set) var engine: SyncEngine?
    private(set) var identity: SyncIdentity?

    init(mac: CloudAccountE2ETests.SimMac, tag: String) throws {
        self.mac = mac
        local = try SimDevice(index: 0, server: CloudSimServer(), clock: SimClock(), ring: CloudKeyRing(), tag: tag)
    }

    func cleanUp() { engine = nil; local.cleanUp() }

    /// Builds the engine the way CloudRuntime does: identity from the controller, one ledger/outbox per epoch.
    func attach(policy: SyncPolicy = SyncPolicy()) throws {
        guard let id = mac.controller.identity else { throw XCTSkip("controller has no identity (state \(mac.controller.state))") }
        let identity = SyncIdentity(accountId: id.accountId, epoch: Int(id.epoch), deviceId: id.deviceId)
        let gate = GateTransport(mac.transport())
        let keys = mac.keys
        let engine = try SyncEngine(identity: identity, transport: gate, environment: local.environment,
                                    cloudDirectory: local.cloudDir.appendingPathComponent("e\(identity.epoch)"),
                                    keyProvider: { try? keys.loadRing() }, policy: policy)
        self.gate = gate; self.engine = engine; self.identity = identity
    }

    /// A process restart: the engine is rebuilt from its ledger and outbox.
    func restart(policy: SyncPolicy = SyncPolicy()) throws { engine = nil; try attach(policy: policy) }

    /// What the app's change observer does after every save.
    func noteEdit() async { try? await engine?.captureLocalChanges(full: true) }

    @discardableResult
    func sync(_ rounds: Int = 3) async -> SyncStatus {
        var status = SyncStatus()
        for _ in 0..<rounds {
            try? await engine?.captureLocalChanges(full: true)
            if let engine { status = await engine.syncNow() }
        }
        return status
    }

    func status() async -> SyncStatus { await engine?.status ?? SyncStatus() }
    func state() async throws -> [String: String] { try await local.state() }

    func insertDictations(_ count: Int, prefix: String, wordsPerRow: Int = 40) async throws {
        let container = local.db.persistentContainer!
        nonisolated(unsafe) let shared = container
        let context = shared.newBackgroundContext()
        let now = Date()
        try await context.perform {
            for i in 0..<count {
                let o = NSManagedObject(entity: NSEntityDescription.entity(forEntityName: "TranscriptionEntity", in: context)!, insertInto: context)
                let when = now.addingTimeInterval(Double(-i))
                o.setValue(UUID(), forKey: "id"); o.setValue(when, forKey: "timestamp"); o.setValue(when, forKey: "createdAt"); o.setValue(when, forKey: "lastModifiedAt")
                let body = (0..<wordsPerRow).map { "w\(($0 &* 2654435761 &+ i) % 9973)" }.joined(separator: " ")
                o.setValue("ZQSECRET \(prefix) \(i) \(body)", forKey: "transcription"); o.setValue("en", forKey: "language"); o.setValue("m", forKey: "modelUsed")
                o.setValue("\(prefix)-\(i)", forKey: "notes"); o.setValue(false, forKey: "isPinned")
            }
            try context.save()
        }
    }

    func dictationCount() async throws -> Int { try await local.liveIDs("TranscriptionEntity").count }
    func localAudioFile(_ id: UUID) -> URL { local.recordings.appendingPathComponent("\(id.uuidString).opus") }
}

// MARK: - Tests

final class CloudSyncE2ETests: XCTestCase {
    typealias DevServer = CloudAccountE2ETests.DevServer
    typealias Subscription = CloudAccountE2ETests.Subscription
    typealias SimMac = CloudAccountE2ETests.SimMac

    private var server: DevServer!
    private var macs: [E2EMac] = []
    private var accountId = ""
    private let markers = ["ZQSECRET", "ZQAUDIOMARK"]

    override func setUpWithError() throws {
        try super.setUpWithError()
        let raw = ProcessInfo.processInfo.environment["CLOUD_DEVSERVER"] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_CLOUD_DEVSERVER"]
        guard let raw, let url = URL(string: raw) else { throw XCTSkip("Set TEST_RUNNER_CLOUD_DEVSERVER=http://127.0.0.1:8788 with the devserver running") }
        server = DevServer(base: url)
    }

    override func tearDown() async throws {
        if server != nil {
            try? await server.fault(["dropChunks": [:], "dropGets": [:], "errorNext": [:]])
            try? await server.setPlan(tier: "starter", storedBytes: 5 << 30, downloadBytes: 2 << 30, grants: 1000)
        }
        await MainActor.run { for m in macs { m.cleanUp() }; macs = [] }
        try await super.tearDown()
    }

    // MARK: Helpers

    private func random(_ n: Int) -> Data {
        var d = Data(count: n)
        d.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return d
    }

    private func audio(_ n: Int) -> Data { Data("ZQAUDIOMARK".utf8) + random(n) }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func track(_ m: E2EMac) async -> E2EMac { await MainActor.run { macs.append(m) }; return m }

    /// Mac A: purchase -> account -> library -> recovery step done, engine attached.
    private func firstMac(_ sub: Subscription, tag: String = "A") async throws -> E2EMac {
        let sim = await SimMac(server: server)
        await MainActor.run { sim.purchasing.onPurchase = { [server] _ in try? await sub.mint(server!) } }
        await sim.controller.purchase(sub.product)
        let offer = await sim.controller.state
        XCTAssertEqual(offer, .offerRecoveryKey)
        await sim.controller.finishRecoveryKey()
        let state = await sim.controller.state
        XCTAssertEqual(state, .ready)
        let mac = try await track(try await E2EMac(mac: sim, tag: tag))
        try await mac.attach()
        accountId = mac.identity?.accountId ?? ""
        return mac
    }

    /// Another Mac of the same Apple Account: same subscription, the library key arrives (iCloud Keychain), it enrols.
    private func joiningMac(_ sub: Subscription, from a: E2EMac, tag: String) async throws -> E2EMac {
        let sim = await SimMac(server: server)
        let jws = try await sub.mint(server)
        await MainActor.run { sim.purchasing.jws = jws }
        try await a.mac.shareKeys(with: sim)
        await sim.controller.refresh()
        let state = await sim.controller.state
        XCTAssertEqual(state, .ready, "\(tag) must be enrolled")
        let mac = try await track(try await E2EMac(mac: sim, tag: tag))
        try await mac.attach()
        return mac
    }

    /// Every Mac syncs, in turn, until nothing moves.
    private func converge(_ list: [E2EMac], rounds: Int = 3) async {
        for _ in 0..<rounds { for m in list { await m.sync(1) } }
    }

    private func assertConverged(_ a: E2EMac, _ b: E2EMac, file: StaticString = #filePath, line: UInt = #line) async throws {
        let sa = try await a.state(), sb = try await b.state()
        XCTAssertEqual(sa, sb, "both Macs hold identical rows", file: file, line: line)
        XCTAssertFalse(sa.isEmpty, file: file, line: line)
    }

    private func assertNoPlaintext(file: StaticString = #filePath, line: UInt = #line) async throws {
        var scanned = 0
        for marker in markers {
            let r = try await server.grep(marker)
            scanned = r.scanned
            XCTAssertEqual(r.matches, [], "plaintext \(marker) found in the bucket", file: file, line: line)
        }
        XCTAssertGreaterThan(scanned, 0, "the bucket has objects to scan", file: file, line: line)
    }

    private func bucketNames(_ epoch: Int? = nil) async throws -> [String] {
        let all = try await server.objects().keys.sorted().filter { $0.contains("/users/\(accountId)/") }
        guard let epoch else { return all }
        return all.filter { $0.contains("/e\(epoch)/") }
    }

    private func appendTiming(_ line: String) {
        NSLog("CLOUD-E2E %@", line)
        let url = URL(fileURLWithPath: "/tmp/cloud-e2e-timings.txt")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
    }

    // MARK: 1. Two Macs converge

    func testScenario1_TwoMacsConvergeThroughTheRealStack() async throws {
        let sub = Subscription()
        let a = try await firstMac(sub)

        // Mac A's library: dictations (two with audio), a meeting with transcript + summary + chat, words, a statistic.
        let ids = (0..<5).map { _ in UUID() }
        let audioA = audio(6000), audioB = audio(9000)
        for (i, id) in ids.enumerated() {
            try await a.local.insertDictation(id, token: "d\(i)", audio: i == 0 ? audioA : (i == 1 ? audioB : nil))
        }
        let meeting = UUID()
        try await a.local.insertMeeting(meeting, token: "weekly")
        try await a.local.writeChat(meeting, body: "{\"chat\":\"ZQSECRET what was decided\"}")
        try await a.local.addWord("ZQSECRETteh", "the", token: "w1")
        try await a.local.addWord("ZQSECRETrecieve", "receive", token: "w2")
        try await a.local.addWord("ZQSECRETseperate", "separate", token: "w3")
        a.local.defaults.set(11, forKey: "bestStreak")

        let statusA = await a.sync(3)
        XCTAssertEqual(statusA.phase, .idle, "\(statusA)")
        XCTAssertEqual(statusA.pendingChanges, 0)
        XCTAssertEqual(statusA.pendingAudio, 0)
        let uploaded = try await bucketNames(1)
        XCTAssertTrue(uploaded.contains { $0.contains("/changes/") })
        XCTAssertEqual(uploaded.filter { $0.contains("/audio/") }.count, 2)
        try await assertNoPlaintext()

        // Mac B: same keychain key, enrols, syncs, ends with identical rows. Audio comes on demand.
        let b = try await joiningMac(sub, from: a, tag: "B")
        let statusB = await b.sync(3)
        XCTAssertEqual(statusB.phase, .idle, "\(statusB)")
        try await assertConverged(a, b)
        let stateB = try await b.state()
        XCTAssertEqual(stateB.keys.filter { $0.hasPrefix("d:") }.count, 5)
        XCTAssertEqual(stateB.keys.filter { $0.hasPrefix("m:") }.count, 1)
        XCTAssertEqual(stateB.keys.filter { $0.hasPrefix("w:") }.count, 3)
        XCTAssertEqual(stateB["s:bestStreak"], "11")
        XCTAssertEqual(b.local.defaults.integer(forKey: "bestStreak"), 11)
        let missing = try await b.engine!.missingAudio()
        XCTAssertEqual(missing.files, 2)
        let url = try await b.engine!.ensureAudio(dictationID: ids[0])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(url)), audioA)

        // An edit on B and a delete on A propagate.
        try await b.local.editDictation(ids[2], token: "edited-on-B", pinned: true)
        try await b.local.editMeeting(meeting, token: "summary-edited-on-B")
        await b.noteEdit()
        try await a.local.deleteDictation(ids[3])
        await a.noteEdit()
        await converge([b, a, b, a])
        try await assertConverged(a, b)
        let sa = try await a.state()
        XCTAssertNil(sa["d:\(ids[3].uuidString)"], "the delete reached B and A kept it deleted")
        XCTAssertTrue(sa["d:\(ids[2].uuidString)"]?.contains("edited-on-B") == true)
        XCTAssertTrue(sa["m:\(meeting.uuidString)"]?.contains("summary-edited-on-B") == true)
        let live = try await b.local.liveIDs("TranscriptionEntity")
        XCTAssertFalse(live.contains(ids[3]))

        // Concurrent offline edits: B is offline while both change the same row, B deletes another, both add words.
        b.gate!.offline = true
        try await a.local.editDictation(ids[2], token: "A-offline", pinned: false)
        try await a.local.addWord("ZQSECRETadress", "address", token: "from-a")
        await a.noteEdit()
        try await Task.sleep(for: .milliseconds(30))
        try await b.local.editDictation(ids[2], token: "B-offline-later", pinned: true)
        try await b.local.deleteDictation(ids[4])
        try await b.local.addWord("ZQSECRETwierd", "weird", token: "from-b")
        await b.noteEdit()
        let offline = await b.sync(1)
        XCTAssertEqual(offline.phase, .offline)
        XCTAssertGreaterThan(offline.pendingChanges, 0, "B's edits wait")
        await a.sync(2)                       // A uploads while B cannot reach the server
        b.gate!.offline = false
        await converge([b, a, b, a])
        try await assertConverged(a, b)
        let sc = try await a.state()
        XCTAssertTrue(sc["d:\(ids[2].uuidString)"]?.contains("B-offline-later") == true, "the later edit wins: \(sc["d:\(ids[2].uuidString)"] ?? "nil")")
        XCTAssertNil(sc["d:\(ids[4].uuidString)"])
        XCTAssertEqual(sc.keys.filter { $0.hasPrefix("w:") }.count, 5)

        // A process restart of one engine changes nothing.
        try b.restart()
        await converge([b, a])
        try await assertConverged(a, b)
        try await assertNoPlaintext()
    }

    // MARK: 2. Large audio through the resumable path

    func testScenario2_TwentyMegabyteAudioResumesAfterAMidUploadFailureAndDownloadsOnDemand() async throws {
        let sub = Subscription()
        let a = try await firstMac(sub)
        let b = try await joiningMac(sub, from: a, tag: "B")
        let id = UUID()
        let big = audio(20 << 20)
        try await a.local.insertDictation(id, token: "long recording", audio: big)

        let before = try await server.stats()
        try await server.fault(["dropChunks": ["after": 1, "count": 1, "persist": false]])
        let status = await a.sync(3)
        let after = try await server.stats()
        XCTAssertEqual(status.phase, .idle, "\(status)")
        XCTAssertEqual(status.pendingAudio, 0)
        XCTAssertEqual((after["dropped"] ?? 0) - (before["dropped"] ?? 0), 1, "the injected failure fired")
        XCTAssertEqual((after["sessionStarts"] ?? 0) - (before["sessionStarts"] ?? 0), 1, "one resumable session, resumed")
        XCTAssertGreaterThanOrEqual((after["statusQueries"] ?? 0) - (before["statusQueries"] ?? 0), 1)
        let audioObjects = try await bucketNames(1).filter { $0.contains("/audio/") }
        XCTAssertEqual(audioObjects.count, 1)
        try await assertNoPlaintext()

        await b.sync(3)
        let rows = try await b.state()
        XCTAssertNotNil(rows["d:\(id.uuidString)"])
        let digests0 = try await b.local.audioDigests()
        XCTAssertTrue(digests0.isEmpty, "audio is not downloaded until asked")
        try await server.fault(["dropGets": ["after": 1, "count": 1]])
        let url = try await b.engine!.ensureAudio(dictationID: id)
        let file = try XCTUnwrap(url)
        let downloaded = try Data(contentsOf: file)
        XCTAssertEqual(downloaded.count, big.count)
        XCTAssertEqual(sha(downloaded), sha(big), "byte-identical")
        let digests = try await b.local.audioDigests()
        XCTAssertEqual(digests["d:\(id.uuidString)"], sha(big))
        let finalStats = try await server.stats()
        XCTAssertGreaterThanOrEqual((finalStats["dropped"] ?? 0) - (after["dropped"] ?? 0), 1, "the download was cut once too")
    }

    // MARK: 3. Large library

    func testScenario3_TwoThousandDictationsUploadAndRestoreOnABrandNewMac() async throws {
        let sub = Subscription()
        let a = try await firstMac(sub)
        try await a.insertDictations(2_000, prefix: "bulk")
        let withAudio = (0..<3).map { _ in UUID() }
        for id in withAudio { try await a.local.insertDictation(id, token: "has-audio", audio: audio(4000)) }

        let t0 = Date()
        let statusA = await a.sync(3)
        let upload = Date().timeIntervalSince(t0)
        XCTAssertEqual(statusA.phase, .idle, "\(statusA)")
        XCTAssertEqual(statusA.pendingChanges, 0)
        let sizes = try await server.objects(prefix: "whisperer-dev/users/\(accountId)/")
        let changeBytes = sizes.filter { $0.key.contains("/changes/") }.values.reduce(0, +)
        appendTiming("2003-dictation initial upload from A: \(String(format: "%.2f", upload)) s, change objects \(changeBytes) bytes in \(sizes.filter { $0.key.contains("/changes/") }.count) batches")
        try await assertNoPlaintext()

        let c = try await joiningMac(sub, from: a, tag: "C")
        let t1 = Date()
        let statusC = await c.sync(2)
        let restore = Date().timeIntervalSince(t1)
        XCTAssertEqual(statusC.phase, .idle, "\(statusC)")
        let count = try await c.dictationCount()
        XCTAssertEqual(count, 2_003)
        appendTiming("2003-dictation restore on brand-new Mac C (account join excluded): \(String(format: "%.2f", restore)) s")
        try await assertConverged(a, c)
        let missing = try await c.engine!.missingAudio()
        XCTAssertEqual(missing.files, 3)
    }

    // MARK: 4. Lapse and resubscribe

    func testScenario4_ExpiredSubscriptionIsReadOnlyThenResubscribingRestoresWriting() async throws {
        var sub = Subscription()
        sub.expiresInSeconds = 900
        let a = try await firstMac(sub)
        let b = try await joiningMac(sub, from: a, tag: "B")
        let ids = (0..<3).map { _ in UUID() }
        for (i, id) in ids.enumerated() { try await a.local.insertDictation(id, token: "pre\(i)", audio: nil) }
        await converge([a, b])
        try await assertConverged(a, b)

        // A uploads one more edit that B has not seen yet, then the subscription lapses.
        try await a.local.editDictation(ids[0], token: "before-lapse", pinned: true)
        await a.noteEdit()
        await a.sync(2)
        try await server.advanceClock(seconds: 7200)

        // B (read-only now) still downloads and merges what was already in the cloud.
        let statusB = await b.sync(2)
        XCTAssertEqual(statusB.phase, .readOnly, "\(statusB)")
        let sb = try await b.state()
        XCTAssertTrue(sb["d:\(ids[0].uuidString)"]?.contains("before-lapse") == true, "downloads and merges continue while read-only")

        // Local edits on both Macs are kept but not uploaded.
        let objectsBefore = try await server.objects()
        try await a.local.editDictation(ids[1], token: "A-while-lapsed", pinned: false)
        await a.noteEdit()
        try await b.local.insertDictation(UUID(), token: "B-new-while-lapsed", audio: audio(3000))
        await b.noteEdit()
        let statusA = await a.sync(2)
        XCTAssertEqual(statusA.phase, .readOnly, "\(statusA)")
        XCTAssertGreaterThan(statusA.pendingChanges, 0, "the edit waits")
        await b.sync(2)
        let objectsAfter = try await server.objects()
        XCTAssertEqual(objectsAfter, objectsBefore, "a lapsed library accepted no writes")
        let lapsed = await a.mac.controller.state
        XCTAssertEqual(lapsed, .readOnly(.expired))

        // Resubscribe: a newer transaction on the same chain. Writing resumes and everything converges.
        var renewed = sub; renewed.expiresInSeconds = 30 * 24 * 3600
        let jws = try await renewed.mint(server)
        await MainActor.run { a.mac.purchasing.jws = jws; b.mac.purchasing.jws = jws }
        await a.mac.controller.refresh()
        await b.mac.controller.refresh()
        let backA = await a.mac.controller.state, backB = await b.mac.controller.state
        XCTAssertEqual(backA, .ready); XCTAssertEqual(backB, .ready)
        await converge([a, b, a, b])
        try await assertConverged(a, b)
        let sa = try await a.state()
        XCTAssertTrue(sa["d:\(ids[1].uuidString)"]?.contains("A-while-lapsed") == true)
        XCTAssertTrue(sa.values.contains { $0.contains("B-new-while-lapsed") })
        let finalA = await a.status(), finalB = await b.status()
        XCTAssertEqual(finalA.phase, .idle); XCTAssertEqual(finalB.phase, .idle)
        XCTAssertEqual(finalA.pendingChanges + finalB.pendingChanges + finalA.pendingAudio + finalB.pendingAudio, 0)
        try await assertNoPlaintext()
    }

    // MARK: 5. Revoke

    func testScenario5_RevokedMacStopsSyncingWithAClearStatusAndCannotReadOrWrite() async throws {
        let sub = Subscription()
        let a = try await firstMac(sub)
        let b = try await joiningMac(sub, from: a, tag: "B")
        let id = UUID()
        try await a.local.insertDictation(id, token: "shared", audio: nil)
        await converge([a, b])
        try await assertConverged(a, b)
        let identityB = try XCTUnwrap(b.identity)

        // B has an unsynced edit when A removes it.
        try await b.local.editDictation(id, token: "B-edit-after-revoke", pinned: true)
        await b.noteEdit()
        await a.mac.controller.refreshAccount()
        await a.mac.controller.revokeDevice(id: identityB.deviceId)
        let objectsBefore = try await server.objects()

        // And A keeps working.
        try await a.local.insertDictation(UUID(), token: "A-after-revoke", audio: nil)
        await a.noteEdit()
        let statusA = await a.sync(2)
        XCTAssertEqual(statusA.phase, .idle, "\(statusA)")

        let stateBeforeB = try await b.state()
        let statusB = await b.sync(2)
        guard case .error(let message) = statusB.phase else { return XCTFail("B must report an error, got \(statusB.phase)") }
        XCTAssertTrue(message.lowercased().contains("removed"), "a clear message: \(message)")
        let stateAfterB = try await b.state()
        XCTAssertEqual(stateAfterB, stateBeforeB, "B did not read what A wrote after the revoke")
        XCTAssertFalse(stateAfterB.values.contains { $0.contains("A-after-revoke") })
        let objectsAfter = try await server.objects()
        let newObjects = Set(objectsAfter.keys).subtracting(objectsBefore.keys)
        for name in newObjects {
            let raw = try await server.rawObject(name)
            XCTAssertNil(raw.range(of: Data("B-edit-after-revoke".utf8)))
        }
        let grep = try await server.grep("B-edit-after-revoke")
        XCTAssertEqual(grep.matches, [])
        for _ in 0..<50 { if await b.mac.controller.state == .deviceRevoked { break }; try await Task.sleep(for: .milliseconds(20)) }
        let identity = await b.mac.controller.identity
        XCTAssertNil(identity, "B's controller dropped its session at once")
        let controllerState = await b.mac.controller.state
        XCTAssertEqual(controllerState, .deviceRevoked)
        // Its local history is intact.
        let rows = try await b.local.liveIDs("TranscriptionEntity")
        XCTAssertTrue(rows.contains(id))
        // The status stays "removed" on every later attempt.
        let again = await b.sync(1)
        XCTAssertEqual(again.phase, statusB.phase)
        let transport = try XCTUnwrap(b.gate)
        do { _ = try await transport.requestUploads([CloudUploadRequest(ref: .audio(id: random(16).cloudHex), size: 10)]); XCTFail("uploads must be refused") } catch {
            XCTAssertNotNil(error as? CloudTransportError)
        }
        do { _ = try await transport.requestDownloads([.change(device: identityB.deviceId, seq: 1)]); XCTFail("downloads must be refused") } catch {
            XCTAssertNotNil(error as? CloudTransportError)
        }

        // A fresh start gives B a new device identity and it can sync again without losing local history.
        await b.mac.controller.startOver()
        let ready = await b.mac.controller.state
        XCTAssertEqual(ready, .ready)
        try b.attach()
        await converge([b, a, b, a])
        try await assertConverged(a, b)
        let merged = try await b.state()
        XCTAssertTrue(merged.values.contains { $0.contains("A-after-revoke") })
        XCTAssertTrue(merged["d:\(id.uuidString)"]?.contains("B-edit-after-revoke") == true, "B's pending edit was uploaded by the new device")
        try await assertNoPlaintext()
    }

    // MARK: 6. Reset

    func testScenario6_ResetStartsANewEpochAndTheOtherMacNeedsTheNewKeyWithoutLosingHistory() async throws {
        let sub = Subscription()
        let a = try await firstMac(sub)
        let b = try await joiningMac(sub, from: a, tag: "B")
        let ids = (0..<4).map { _ in UUID() }
        for (i, id) in ids.enumerated() { try await a.local.insertDictation(id, token: "old\(i)", audio: i == 0 ? audio(5000) : nil) }
        try await a.local.insertMeeting(UUID(), token: "old-meeting")
        await converge([a, b, a])
        try await assertConverged(a, b)
        let epoch1Objects = try await bucketNames(1)
        XCTAssertFalse(epoch1Objects.isEmpty)
        let oldKey = try a.mac.keys.loadRing().keys[1]

        // The wrong phrase changes nothing; the right one starts epoch 2 with a new key.
        await a.mac.controller.resetLibrary(confirmation: "reset")
        let unchanged = await a.mac.controller.state
        XCTAssertEqual(unchanged, .ready)
        await a.mac.controller.resetLibrary(confirmation: CloudResetPhrase.phrase)
        await a.mac.controller.finishRecoveryKey()
        let afterReset = await a.mac.controller.state
        XCTAssertEqual(afterReset, .ready)
        let newIdentityOpt = await a.mac.controller.identity
        let newIdentity = try XCTUnwrap(newIdentityOpt)
        XCTAssertEqual(newIdentity.epoch, 2)
        XCTAssertNotEqual(try a.mac.keys.loadRing().keys[1], oldKey)

        // The old epoch's objects are still in the bucket (7-day hold); nothing of the new epoch exists yet.
        let stillThere = try await bucketNames(1)
        XCTAssertEqual(stillThere, epoch1Objects, "epoch 1 objects are held, not deleted")
        let e2Empty = try await bucketNames(2)
        XCTAssertTrue(e2Empty.isEmpty)

        // B, still on epoch 1, keeps a local edit made after the reset.
        try await b.local.insertDictation(UUID(), token: "B-made-during-reset", audio: nil)
        await b.noteEdit()
        let bStateBefore = try await b.state()
        let epochStatus = await b.sync(1)
        guard case .error = epochStatus.phase else { return XCTFail("B's old-epoch engine must stop with an error, got \(epochStatus.phase)") }
        let bStateStopped = try await b.state()
        XCTAssertEqual(bStateStopped, bStateBefore, "history untouched")

        // B wakes before A has re-uploaded anything. Its Keychain still holds the OLD key (same version number as the new one):
        // it must wait for the new key, never write into the clean library under the dead one.
        await b.mac.controller.refresh()
        let bWaiting = await b.mac.controller.state
        XCTAssertEqual(bWaiting, .needsKey(CloudNeedsKey(recoveryAvailable: false, wrongKey: true)), "a stale key is recognised after a reset elsewhere")
        let e2StillEmpty = try await bucketNames(2)
        XCTAssertTrue(e2StillEmpty.isEmpty)

        // A re-uploads everything into a clean library under the new key (a new engine: one ledger per epoch).
        try a.attach()
        let statusA = await a.sync(3)
        XCTAssertEqual(statusA.phase, .idle, "\(statusA)")
        XCTAssertEqual(statusA.pendingChanges + statusA.pendingAudio, 0)
        let e2 = try await bucketNames(2)
        XCTAssertTrue(e2.contains { $0.contains("/changes/") })
        XCTAssertEqual(e2.filter { $0.contains("/audio/") }.count, 1)
        let e1After = try await bucketNames(1)
        XCTAssertEqual(e1After, epoch1Objects)

        // iCloud Keychain delivers the new key to B.
        try a.mac.shareKeys(with: b.mac)
        await b.mac.controller.recheckKey()
        await b.mac.controller.refresh()
        let bReady = await b.mac.controller.state
        XCTAssertEqual(bReady, .ready)
        let bId2Opt = await b.mac.controller.identity
        let bId2 = try XCTUnwrap(bId2Opt)
        XCTAssertEqual(bId2.epoch, 2)
        try b.attach()
        await converge([b, a, b, a])
        try await assertConverged(a, b)
        let merged = try await b.state()
        XCTAssertTrue(merged.values.contains { $0.contains("B-made-during-reset") }, "B's history survived and was uploaded into the new library")
        XCTAssertEqual(merged.keys.filter { $0.hasPrefix("m:") }.count, 1)
        XCTAssertEqual(merged.keys.filter { $0.hasPrefix("d:") }.count, 5)
        try await assertNoPlaintext()
    }

    // MARK: 7. Tamper

    func testScenario7_ATamperedChangeObjectIsRefusedAndTheMacRecoversWhenItIsRestored() async throws {
        let sub = Subscription()
        let a = try await firstMac(sub)
        let b = try await joiningMac(sub, from: a, tag: "B")
        let id = UUID()
        try await a.local.insertDictation(id, token: "original", audio: nil)
        await converge([a, b])
        try await assertConverged(a, b)

        try await a.local.editDictation(id, token: "edit-two", pinned: true)
        try await a.local.insertDictation(UUID(), token: "second-row", audio: nil)
        await a.noteEdit()
        await a.sync(2)
        let aId = try XCTUnwrap(a.identity).deviceId
        let changes = try await bucketNames(1).filter { $0.contains("/changes/\(aId)/") }
        let latest = try XCTUnwrap(changes.last)
        let original = try await server.rawObject(latest)
        var forged = original
        forged[forged.count / 2] ^= 0x01
        try await server.overwrite(latest, with: forged)

        let before = try await b.state()
        let status = await b.sync(2)
        guard case .error(let message) = status.phase else { return XCTFail("tampering must be reported, got \(status.phase)") }
        XCTAssertTrue(message.contains("verification"), message)
        let kept = try await b.state()
        XCTAssertEqual(kept, before, "B kept its existing rows and merged nothing from the forged object")
        XCTAssertFalse(kept.values.contains { $0.contains("edit-two") })

        try await server.overwrite(latest, with: original)
        let recovered = await b.sync(2)
        XCTAssertEqual(recovered.phase, .idle, "\(recovered)")
        try await assertConverged(a, b)
        let after = try await b.state()
        XCTAssertTrue(after["d:\(id.uuidString)"]?.contains("edit-two") == true)
        try await assertNoPlaintext()
    }

    // MARK: 8. Quota

    func testScenario8_OverQuotaPausesUploadsAndDeletesStillFreeSpace() async throws {
        var sub = Subscription()
        sub.product = CloudProduct(tier: .starter, period: .monthly)
        try await server.setPlan(tier: "starter", storedBytes: 2 << 20)
        let a = try await firstMac(sub)
        let b = try await joiningMac(sub, from: a, tag: "B")

        // 1.2 MB of audio fits a 2 MB plan.
        let big = UUID(), small = UUID()
        try await a.local.insertDictation(big, token: "big audio", audio: audio(1_200_000))
        try await a.local.insertDictation(small, token: "small", audio: nil)
        let ok = await a.sync(3)
        XCTAssertEqual(ok.phase, .idle, "\(ok)")
        let bigObjects = try await bucketNames(1).filter { $0.contains("/audio/") }
        XCTAssertEqual(bigObjects.count, 1)

        // Another 1.2 MB does not: uploads pause with overQuota; local data is safe.
        let second = UUID()
        try await a.local.insertDictation(second, token: "second big audio", audio: audio(1_200_000))
        let full = await a.sync(2)
        XCTAssertEqual(full.phase, .overQuota, "\(full)")
        XCTAssertGreaterThan(full.pendingAudio + full.pendingChanges, 0)
        let secondFile = a.localAudioFile(second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondFile.path))
        let audioCount = try await bucketNames(1).filter { $0.contains("/audio/") }.count
        XCTAssertEqual(audioCount, 1, "the over-quota audio was not stored")

        // B (reads are unaffected) merges what is there.
        await b.sync(2)
        let sb = try await b.state()
        XCTAssertNotNil(sb["d:\(big.uuidString)"])

        // Deleting the big recording frees the cloud copy, and then the paused upload resumes.
        try await a.local.deleteDictation(big)
        await a.noteEdit()
        let freed = await a.sync(4)
        let remaining = try await bucketNames(1).filter { $0.contains("/audio/") }
        XCTAssertEqual(freed.phase, .idle, "after the delete there is room again: \(freed)")
        XCTAssertEqual(remaining.count, 1, "the deleted recording's object is gone and the second one is stored")
        await converge([b, a])
        try await assertConverged(a, b)
        try await assertNoPlaintext()
    }

    func testScenario8b_DowngradedBelowWhatIsStoredBlocksUploadsButTheDeleteStillFreesSpace() async throws {
        var sub = Subscription()
        sub.product = CloudProduct(tier: .starter, period: .monthly)
        try await server.setPlan(tier: "starter", storedBytes: 4 << 20)
        let a = try await firstMac(sub)
        let big = UUID()
        try await a.local.insertDictation(big, token: "will be deleted", audio: audio(1_500_000))
        let ok = await a.sync(3)
        XCTAssertEqual(ok.phase, .idle, "\(ok)")

        // The plan shrinks below what is stored (a downgrade): nothing new may be added, nothing is removed.
        try await server.setPlan(tier: "starter", storedBytes: 500_000)
        try await a.local.insertDictation(UUID(), token: "new while over", audio: nil)
        await a.noteEdit()
        let over = await a.sync(2)
        XCTAssertEqual(over.phase, .overQuota, "\(over)")
        let storedAudio = try await bucketNames(1).filter { $0.contains("/audio/") }.count
        XCTAssertEqual(storedAudio, 1)

        // The user deletes the big recording to get back under the limit: the delete must work even though uploads are refused.
        try await a.local.deleteDictation(big)
        await a.noteEdit()
        let after = await a.sync(4)
        let remaining = try await bucketNames(1).filter { $0.contains("/audio/") }.count
        XCTAssertEqual(remaining, 0, "deleting freed the cloud copy while over quota")
        XCTAssertEqual(after.phase, .idle, "and the paused text upload resumed: \(after)")
        XCTAssertEqual(after.pendingChanges, 0)
    }
}
