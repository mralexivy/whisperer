//
//  SyncEngine.swift
//  Whisperer
//
//  The sync engine facade (plan 9). One actor serialises every step, so capture, upload and merge never interleave.
//
//  A cycle: heads poll -> download + merge -> capture local changes -> upload (outbox first) -> audio -> snapshot.
//  Nothing here talks to the network except through `CloudTransport`, and nothing is wired into app launch.
//

import Foundation
import CoreData
import CryptoKit

/// Poll cadence (plan 9.1). Pure, so it is tested directly.
nonisolated enum SyncCadence {
    static let serverMinimum: TimeInterval = 20
    static let foreground: TimeInterval = 30
    static let background: TimeInterval = 5 * 60
    static let idleCeiling: TimeInterval = 30 * 60
    /// Idle cycles before the interval starts doubling.
    static let idleGrace = 10

    static func interval(foreground isForeground: Bool, idleCycles: Int) -> TimeInterval {
        let base = isForeground ? foreground : background
        let extra = max(0, idleCycles - idleGrace)
        let scaled = base * pow(2, Double(min(extra, 12)))
        return max(serverMinimum, min(idleCeiling, scaled))
    }
}

actor SyncEngine {
    let identity: SyncIdentity
    let policy: SyncPolicy
    private let transport: CloudTransport
    private let store: SyncRowStore
    private let ledger: SyncLedger
    private let clock: HybridLogicalClock
    private let outbox: SyncOutbox
    private let keyProvider: @Sendable () -> CloudKeyRing?
    private let hooks: SyncHooks
    private let nowMs: @Sendable () -> Int64

    private(set) var status = SyncStatus()
    private var statusSubscribers: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
    private var hints = Set<String>()
    private var lastFullScanMs: Int64?
    private var syncing = false
    private var lastHeads: CloudHeads?
    private var serverReadOnly = false
    private var deletionsHeldBack = false

    // Run loop
    private var loopTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var isForeground = true
    private var idleCycles = 0
    private var retryAfter: TimeInterval?
    private let sleeper: @Sendable (TimeInterval) async -> Void

    init(identity: SyncIdentity, transport: CloudTransport, environment: SyncStoreEnvironment, cloudDirectory: URL?,
         keyProvider: @escaping @Sendable () -> CloudKeyRing?, policy: SyncPolicy = SyncPolicy(), hooks: SyncHooks = .none,
         nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         sleeper: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) throws {
        self.identity = identity
        self.policy = policy
        self.transport = transport
        self.keyProvider = keyProvider
        self.hooks = hooks
        self.nowMs = nowMs
        self.sleeper = sleeper
        let ledger = try SyncLedger(url: cloudDirectory?.appendingPathComponent("ledger.json"), deviceId: identity.deviceId, epoch: identity.epoch)
        self.ledger = ledger

        // The newest stamp the ledger holds — ours or merged from another Mac — so a restarted clock still orders a new edit
        // after everything this Mac has already seen; bounded so a poisoned stamp cannot drag the clock into the future.
        let seen = ledger.read { s in
            max(s.lastHLC, s.rows.values.map(\.hlc).max() ?? .zero, s.pendingStaged.values.map(\.hlc).max() ?? .zero)
        }
        let clock = HybridLogicalClock(nowMs: nowMs)
        clock.restoreOffset(ledger.read { $0.clockOffsetMs })
        clock.receive(seen)              // bounded by corrected-now + 24 h
        self.clock = clock
        self.store = SyncRowStore(env: environment, ledger: ledger, clock: clock, policy: policy, hooks: hooks)
        self.outbox = try SyncOutbox(directory: (cloudDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("whisperer-sync-\(UUID().uuidString)")).appendingPathComponent("Outbox"))
        status.lastSyncAt = ledger.read { $0.lastSyncAt }.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        status.phase = ledger.read { $0.paused } ? .paused : .idle
    }

    // MARK: - Public API for the UI / account layer

    /// Status updates, starting with the current one.
    func statusUpdates() -> AsyncStream<SyncStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
        continuation.yield(status)
        statusSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { statusSubscribers[id] = nil }

    /// The account layer calls this once the key proof against the server's verifier has passed.
    func markKeyVerified() { ledger.mutate { $0.keyEverWorked = true } }

    func pause() {
        ledger.mutate { $0.paused = true }
        try? ledger.save()
        setPhase(.paused)
    }

    func resume() {
        ledger.mutate { $0.paused = false }
        try? ledger.save()
        setPhase(.idle)
        wake()
    }

    /// The user confirmed that a large number of deletions is intended (see the mass-deletion guard).
    func approveMassDeletion() { ledger.mutate { $0.massDeleteApproved = true }; deletionsHeldBack = false; lastFullScanMs = nil }

    /// A save the app made: keys (or "d:*", "w:*" ...) worth a look at the next cycle.
    func noteLocalChange(keys: Set<String>) { hints.formUnion(keys) }

    /// Runs one cycle now and returns the resulting status. Never throws: failures become the status.
    @discardableResult
    func syncNow() async -> SyncStatus {
        do { try await runCycle(force: true) } catch { setPhase(phase(for: error)) }
        return status
    }

    /// One cycle; throws what went wrong (tests and the fuzz harness need the raw error, incl. simulated crashes).
    func runCycle(force: Bool) async throws {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        if ledger.read({ $0.paused }) { setPhase(.paused); return }
        guard let ring = keyProvider(), !ring.isEmpty else { setPhase(.needsKey); return }
        setPhase(.syncing)
        do {
            let issue = try await cycle(ring: ring, force: force)
            refreshCounts()
            status.lastSyncAt = ledger.read { $0.lastSyncAt }.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            setPhase(issue ?? (serverReadOnly ? .readOnly : (deletionsHeldBack
                ? .error("Many items look deleted on this Mac; confirm before they are removed from the cloud") : .idle)))
        } catch {
            refreshCounts()
            if case SyncError.simulatedCrash = error { throw error }
            setPhase(phase(for: error))
            throw error
        }
    }

    // MARK: Run loop (cadence)

    func start(foreground: Bool = true) {
        isForeground = foreground
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.loopIteration()
            }
        }
    }

    func stop() {
        loopTask?.cancel(); loopTask = nil
        sleepTask?.cancel(); sleepTask = nil
    }

    func setForeground(_ value: Bool) { isForeground = value; if value { wake() } }

    /// Wake / launch / network back: run a cycle immediately.
    func wake() {
        idleCycles = 0
        sleepTask?.cancel()
    }

    private func loopIteration() async {
        let before = ledger.read { ($0.uploadedChanges, $0.downloadedChanges) }
        do { try await runCycle(force: false) } catch {
            if case CloudTransportError.rateLimited(let after) = error { retryAfter = after }
        }
        let after = ledger.read { ($0.uploadedChanges, $0.downloadedChanges) }
        let moreWork = status.pendingChanges > 0 || status.pendingAudio > 0
        if before == after && !moreWork { idleCycles += 1 } else { idleCycles = 0 }
        var delay = SyncCadence.interval(foreground: isForeground, idleCycles: idleCycles)
        if moreWork, status.phase == .idle { delay = 1 }
        if let r = retryAfter { delay = max(delay, r, SyncCadence.serverMinimum); retryAfter = nil }
        let sleeper = self.sleeper
        let task = Task { await sleeper(delay) }
        sleepTask = task
        await task.value
        sleepTask = nil
    }

    // MARK: - Status

    private func setPhase(_ phase: SyncPhase) {
        status.phase = phase
        publish()
    }

    private func refreshCounts() {
        let s = ledger.snapshot
        status.pendingChanges = s.rows.values.reduce(0) { $0 + ($1.dirty ? 1 : 0) }
        status.pendingAudio = s.rows.values.reduce(0) { $0 + (($1.audioId != nil && !$1.audioAcked && !$1.deleted) ? 1 : 0) }
        status.uploadedChanges = s.uploadedChanges
        status.downloadedChanges = s.downloadedChanges
        switch s.initialPhase {
        case .text, .audio: status.initialUpload = (s.initialDone, s.initialTotal)
        default: status.initialUpload = nil
        }
        publish()
    }

    private func publish() { for c in statusSubscribers.values { c.yield(status) } }

    private func phase(for error: Error) -> SyncPhase {
        switch error {
        case CloudTransportError.offline: return .offline
        case CloudTransportError.overQuota: return .overQuota
        case CloudTransportError.readOnly: return .readOnly
        case CloudTransportError.unauthorized: return .error("Signed out — reconnecting")
        case CloudTransportError.deviceRevoked: return .error("This Mac was removed from the account")
        case CloudTransportError.rateLimited: return .error("Too many requests — slowing down")
        case SyncError.needsKey: return .needsKey
        case SyncError.tampered(let why): return .error("A cloud object failed verification (\(why)); it was not merged")
        case SyncError.paused: return .paused
        default: return .error("\(error)")
        }
    }

    // MARK: - The cycle

    private func cycle(ring: CloudKeyRing, force: Bool) async throws -> SyncPhase? {
        let since = ledger.read { $0.serverVersion }
        let heads = try await transport.heads(since: since > 0 ? since : nil)
        lastHeads = heads
        if let server = heads.serverTime { clock.observeServerTime(server); ledger.mutate { $0.clockOffsetMs = clock.serverOffsetMs } }
        if let epoch = heads.epoch, epoch != identity.epoch { throw SyncError.epochMismatch(server: epoch, local: identity.epoch) }
        serverReadOnly = heads.readOnly ?? false
        try hooks.checkpoint("afterHeads")
        // Local edits are stamped BEFORE remote changes are merged, so a merge can never overwrite an edit the ledger
        // does not know about yet.
        try await captureLocalChanges()

        if heads.unchanged != true || !outbox.entries().isEmpty {
            if heads.unchanged != true { try await downloadAndMerge(heads, ring: ring) }
        }
        let now = clock.correctedNowMs()
        ledger.mutate { s in
            if heads.unchanged != true { s.serverVersion = heads.version }
            s.lastFullSyncAt = now
            s.lastSyncAt = now
            s.lastHLC = clock.last
        }
        if let snap = heads.snapshot { noteSnapshot(snap) }
        try ledger.save()

        // Local changes.
        try await captureLocalChanges()
        await freeDeletedAudio()           // needs no quota and no commit, so it also runs over quota and while read-only

        var issue: SyncPhase?
        if !serverReadOnly {
            do {
                try await uploadPhase(ring: ring, force: force)
                try await maybeSnapshot(ring: ring, heads: heads)
            } catch CloudTransportError.overQuota { issue = .overQuota }
            catch CloudTransportError.readOnly { serverReadOnly = true }
        }
        ledger.mutate { $0.lastHLC = clock.last }
        try ledger.save()
        return issue
    }

    private func noteSnapshot(_ snap: CloudSnapshotInfo) {
        ledger.mutate { s in
            if snap.version > s.snapshotVersion {
                s.snapshotVersion = snap.version; s.snapshotId = snap.id; s.snapshotCovers = snap.covers
                s.batchesSinceSnapshot = 0; s.lastSnapshotAt = clock.correctedNowMs()
            }
        }
    }

    /// Detect local changes. A full scan at first use, at launch and periodically; otherwise only hinted keys.
    func captureLocalChanges(full: Bool = false) async throws {
        let now = clock.correctedNowMs()
        let phase = ledger.read { $0.initialPhase }
        let fullDue = full || phase == .notStarted || lastFullScanMs == nil
            || Double(now - (lastFullScanMs ?? 0)) > policy.fullScanEvery * 1000
        var result: SyncScanResult
        if fullDue {
            result = try await store.scan(keys: nil)
            lastFullScanMs = now
            hints.removeAll()
        } else if !hints.isEmpty {
            let keys = hints; hints.removeAll()
            result = try await store.scan(keys: keys)
        } else { return }
        if phase == .notStarted {
            let total = ledger.dirtyCount
            ledger.mutate { s in s.initialPhase = .text; s.initialTotal = total; s.initialDone = 0 }
        }
        if fullDue || result.massDeleteBlocked { deletionsHeldBack = result.massDeleteBlocked }
        try ledger.save()
    }

    // MARK: - Download + merge

    private func objectContext(_ ref: CloudObjectRef) -> CloudObjectContext {
        CloudObjectContext(accountId: identity.accountId, epoch: UInt64(identity.epoch), objectName: ref.relativeName)
    }

    private func open(_ blob: Data, ref: CloudObjectRef, ring: CloudKeyRing) throws -> Data {
        do {
            let plain = try CloudCrypto.decrypt(blob, keyForVersion: { ring.symmetricKey(version: $0) }, context: objectContext(ref))
            ledger.mutate { $0.keyEverWorked = true }
            return plain
        } catch CloudCryptoError.unknownKeyVersion {
            throw SyncError.needsKey
        } catch CloudCryptoError.authenticationFailed {
            // Wrong key and tampering look the same to AES-GCM. A Mac that has never authenticated anything under
            // this key has no evidence the key is right; one that has, has evidence the object was altered.
            if ledger.read({ $0.keyEverWorked }) { throw SyncError.tampered(ref.relativeName) }
            throw SyncError.needsKey
        } catch {
            throw SyncError.tampered("\(ref.relativeName): \(error)")
        }
    }

    private func fetch(_ refs: [CloudObjectRef], ring: CloudKeyRing) async throws -> [CloudObjectRef: Data] {
        var out: [CloudObjectRef: Data] = [:]
        for group in stride(from: 0, to: refs.count, by: 50).map({ Array(refs[$0..<min($0 + 50, refs.count)]) }) {
            let grants = try await transport.requestDownloads(group)
            for ref in group {
                guard let grant = grants.first(where: { $0.name.hasSuffix(ref.relativeName) }) else { throw SyncError.malformed("no grant for \(ref.relativeName)") }
                out[ref] = try await transport.download(with: grant)
            }
        }
        return out
    }

    private func isStale(now: Int64) -> Bool {
        guard let last = ledger.read({ $0.lastFullSyncAt }) else { return false }
        return Double(now - last) > Double(policy.tombstoneHorizonDays) * 86_400_000
    }

    private func downloadAndMerge(_ heads: CloudHeads, ring: CloudKeyRing) async throws {
        let me = identity.deviceId
        let now = clock.correctedNowMs()
        func cursor(_ d: String) -> Int64 { d == me ? ledger.read { $0.committedSeq } : ledger.read { $0.cursors[d] ?? 0 } }
        var seenKeys = Set<String>()
        var snapshotApplied = false
        let stale = isStale(now: now)

        if let snap = heads.snapshot {
            let behind = snap.covers.contains { cursor($0.key) < $0.value }
            if behind || stale {
                let ref = CloudObjectRef.snapshot(id: snap.id)
                let blob = try await fetch([ref], ring: ring)[ref]!
                let plain = try open(blob, ref: ref, ring: ring)
                let payload: SyncSnapshotPayload
                do { payload = try JSONDecoder().decode(SyncSnapshotPayload.self, from: plain) } catch { throw SyncError.tampered("snapshot payload: \(error)") }
                for chunk in stride(from: 0, to: payload.ops.count, by: policy.snapshotChunk).map({ Array(payload.ops[$0..<min($0 + policy.snapshotChunk, payload.ops.count)]) }) {
                    try await merge(chunk, advance: nil)
                }
                for op in payload.ops { seenKeys.insert(op.k) }
                ledger.mutate { s in
                    for (d, seq) in snap.covers {
                        if d == me { s.committedSeq = max(s.committedSeq, seq) } else { s.cursors[d] = max(s.cursors[d] ?? 0, seq) }
                    }
                }
                snapshotApplied = true
                try ledger.save()
            }
        }

        // The tail: every device's batches after our cursor.
        let pendingOwn = outbox.entries()
        for (device, head) in (heads.heads ?? [:]).sorted(by: { $0.key < $1.key }) {
            let have = cursor(device)
            guard head.seq > have else { continue }
            if device == me, let mine = pendingOwn.first(where: { $0.seq == head.seq }), mine.crc == head.crc { continue }   // our own commit; the replay will settle it
            let refs = ((have + 1)...head.seq).map { CloudObjectRef.change(device: device, seq: $0) }
            for group in stride(from: 0, to: refs.count, by: 50).map({ Array(refs[$0..<min($0 + 50, refs.count)]) }) {
                let blobs = try await fetch(group, ring: ring)
                for ref in group {                                   // in seq order, whatever order delivery had
                    let plain = try open(blobs[ref]!, ref: ref, ring: ring)
                    let payload: SyncBatchPayload
                    do { payload = try JSONDecoder().decode(SyncBatchPayload.self, from: plain) } catch { throw SyncError.tampered("batch payload: \(error)") }
                    guard payload.device == device, payload.seq == ref.seq else { throw SyncError.tampered("batch does not match its name") }
                    for op in payload.ops { seenKeys.insert(op.k) }
                    try await merge(payload.ops, advance: (device, ref.seq!))
                    try hooks.checkpoint("afterBatchMerged")
                }
            }
        }

        // Stale device: previously acknowledged rows that neither the snapshot nor the tail mention were deleted elsewhere.
        if stale && snapshotApplied {
            let doomed = ledger.read { s in
                s.rows.compactMap { (key, row) -> String? in
                    guard row.syncedAt != nil, !row.deleted, !seenKeys.contains(key), SyncKind.of(key: key) != .stat else { return nil }
                    return key
                }
            }
            if !doomed.isEmpty {
                _ = try await store.deleteLocally(keys: doomed)
                try ledger.save()
                Logger.info("Cloud sync: stale device removed \(doomed.count) rows deleted elsewhere", subsystem: .app)
            }
        }
    }

    /// One batch (or snapshot chunk): merge in a single save together with the cursor advance.
    private func merge(_ ops: [SyncOp], advance: (device: String, seq: Int64)?) async throws {
        do { try await store.apply(ops) } catch {
            ledger.reload()
            throw error
        }
        ledger.mutate { s in
            if let advance {
                if advance.device == identity.deviceId { s.committedSeq = max(s.committedSeq, advance.seq) }
                else { s.cursors[advance.device] = advance.seq }
                s.batchesSinceSnapshot += 1
            }
            s.downloadedChanges += ops.count
            s.pendingApplyKeys = []; s.pendingStaged = [:]; s.pendingExpect = [:]; s.pendingLanded = false; s.pendingRemove = []
            s.keyEverWorked = true
        }
        try ledger.save()
    }

    // MARK: - Upload

    private func uploadPhase(ring: CloudKeyRing, force: Bool) async throws {
        try await drainOutbox(ring: ring)
        while true {
            let (eligible, age) = eligibleDirty()
            guard !eligible.isEmpty else { break }
            let due = force || eligible.count >= policy.batchMaxChanges || age >= policy.batchMaxAge
                || ledger.read({ $0.initialPhase == .text })
            guard due else { break }
            guard try await buildBatch(from: eligible, ring: ring) else { break }
            try await drainOutbox(ring: ring)
        }
        // Text first: audio only once the text is in the cloud (and, on first enable, once all the text is).
        if eligibleDirty().0.isEmpty && outbox.entries().isEmpty {
            if ledger.read({ $0.initialPhase == .text }) { ledger.mutate { $0.initialPhase = .audio }; try ledger.save() }
            try await uploadAudio(ring: ring)
            try await acknowledgeAudio(ring: ring)
            if ledger.read({ $0.initialPhase == .audio }) && pendingAudioCount() == 0 {
                ledger.mutate { $0.initialPhase = .done }; try ledger.save()
            }
        }
        refreshInitialProgress()
    }

    private func pendingAudioCount() -> Int {
        ledger.read { s in s.rows.values.reduce(0) { $0 + (($1.audioId != nil && !$1.audioAcked && !$1.deleted) ? 1 : 0) } }
    }

    private func refreshInitialProgress() {
        let total = ledger.read { $0.initialTotal }
        let dirty = eligibleDirty().0.count + outbox.entries().reduce(0) { $0 + $1.keys.count }
        ledger.mutate { s in if s.initialPhase == .text { s.initialDone = max(s.initialDone, max(0, total - dirty)) } }
    }

    /// Dirty rows not already encrypted in the outbox at their current stamp, oldest first, plus the age of the oldest.
    private func eligibleDirty() -> ([String], TimeInterval) {
        let inflight = outbox.inFlight()
        let (keys, first): ([String], Int64?) = ledger.read { s in
            let rows = s.rows.filter { $0.value.dirty && inflight[$0.key] != $0.value.stamp }
            let ordered = rows.sorted { ($0.value.stamp, $0.key) < ($1.value.stamp, $1.key) }.map(\.key)
            return (ordered, s.firstDirtyAt)
        }
        let age = first.map { Double(clock.correctedNowMs() - $0) / 1000 } ?? 0
        return (keys, age)
    }

    private func encrypt(_ plain: Data, ref: CloudObjectRef, ring: CloudKeyRing) throws -> Data {
        guard let current = ring.current() else { throw SyncError.needsKey }
        return try CloudCrypto.encrypt(plain, key: current.key, keyVersion: current.version, context: objectContext(ref))
    }

    /// Builds one batch from the oldest dirty rows. Returns false when nothing was left to put in it.
    private func buildBatch(from eligible: [String], ring: CloudKeyRing) async throws -> Bool {
        let initial = ledger.read { $0.initialPhase == .text }
        let cap = initial ? policy.initialBatchMaxChanges : policy.batchMaxChanges
        let taken = Array(eligible.prefix(cap))
        let scan = try await store.scan(keys: Set(taken), collect: true)
        let now = clock.correctedNowMs()

        var ops: [SyncOp] = []
        var keys: [OutboxKey] = []
        var bytes = 0
        var skipped: [String] = []
        for key in taken {
            guard var row = ledger.row(key) else { continue }
            var op: SyncOp
            let hlc = clock.clampedForPublishing(row.hlc)
            if hlc != row.hlc { ledger.mutate { $0.rows[key]?.hlc = hlc }; row.hlc = hlc }
            if row.deleted { op = SyncOp(key: key, stamp: row.stamp, at: row.tombstoneAt ?? now, tombstone: true) }
            else if let json = scan.rows[key] { op = SyncOp(key: key, stamp: row.stamp, at: now, row: json) }
            else { skipped.append(key); continue }
            let size = (try? JSONEncoder().encode(op).count) ?? 0
            if !ops.isEmpty && bytes + size > policy.batchMaxBytes { break }
            bytes += size
            ops.append(op)
            keys.append(OutboxKey(key: key, stamp: row.stamp, tombstone: row.deleted))
        }
        if !skipped.isEmpty {
            ledger.mutate { s in for key in skipped { s.rows[key]?.dirty = false } }
        }
        guard !ops.isEmpty else { try ledger.save(); return !skipped.isEmpty }
        let seq = (outbox.entries().last?.seq ?? ledger.read { $0.committedSeq }) + 1
        try writeBatch(seq: seq, ops: ops, keys: keys, audio: [], snapshot: nil, ring: ring)
        return true
    }

    private func writeBatch(seq: Int64, ops: [SyncOp], keys: [OutboxKey], audio: [SyncAudioRef], snapshot: OutboxSnapshot?, ring: CloudKeyRing) throws {
        let payload = SyncBatchPayload(device: identity.deviceId, seq: seq, ops: ops)
        let plain = try JSONEncoder().encode(payload)
        let ref = CloudObjectRef.change(device: identity.deviceId, seq: seq)
        let cipher = try encrypt(plain, ref: ref, ring: ring)
        let entry = OutboxEntry(seq: seq, crc: CloudCRC32C.checksum(cipher), size: Int64(cipher.count), keys: keys,
                                audioRefs: audio, snapshot: snapshot, createdAt: clock.correctedNowMs())
        try outbox.write(entry, ciphertext: cipher)
        try ledger.save()
        try hooks.checkpoint("afterOutboxWrite")
    }

    private enum Attempt { case committed, renumbered }

    private func drainOutbox(ring: CloudKeyRing) async throws {
        var renumbers = 0
        while let entry = outbox.entries().first {
            switch try await uploadAndCommit(entry, ring: ring) {
            case .committed: break
            case .renumbered:
                renumbers += 1
                if renumbers > 5 { throw SyncError.malformed("sequence counter would not settle") }
            }
        }
    }

    private func uploadAndCommit(_ entryIn: OutboxEntry, ring: CloudKeyRing) async throws -> Attempt {
        var entry = entryIn
        let ref = CloudObjectRef.change(device: identity.deviceId, seq: entry.seq)
        if let snap = entry.snapshot, FileManager.default.fileExists(atPath: outbox.snapshotURL(snap.id).path) {
            try await uploadFile(outbox.snapshotURL(snap.id), ref: .snapshot(id: snap.id), size: snap.size)
        }
        let data = try outbox.ciphertext(seq: entry.seq)
        var attempts = 0
        while true {
            attempts += 1
            let grants = try await transport.requestUploads([CloudUploadRequest(ref: ref, size: Int64(data.count))])
            guard let grant = grants.first else { throw SyncError.malformed("no upload grant") }
            try await transport.upload(data, with: grant)
            try hooks.checkpoint("afterUpload")
            do {
                let result = try await transport.commit(device: identity.deviceId, seq: entry.seq, crc: entry.crc,
                                                        extra: entry.audioRefs.map { $0.kind == "meetings" ? CloudObjectRef.meeting(id: $0.id) : CloudObjectRef.audio(id: $0.id) },
                                                        snapshot: entry.snapshot.map { CloudSnapshotInfo(id: $0.id, covers: $0.covers, version: $0.version) })
                _ = result
                try hooks.checkpoint("afterCommit")
                finalize(entry)
                return .committed
            } catch CloudTransportError.sequenceConflict(let head) {
                if head.seq == entry.seq && head.crc == entry.crc { finalize(entry); return .committed }
                try renumber(from: head.seq, ring: ring)
                return .renumbered
            } catch CloudTransportError.checksumMismatch {
                // An object of ours already sits at this name with other bytes (an orphan from lost state):
                // objects are immutable, so remove it and upload ours.
                guard attempts < 3 else { throw CloudTransportError.checksumMismatch }
                _ = try await transport.delete([ref])
            } catch CloudTransportError.notUploaded {
                guard attempts < 3 else { throw CloudTransportError.notUploaded }
            } catch CloudTransportError.server(let status) where entry.snapshot != nil && (400..<500).contains(status) {
                // The snapshot claim was refused (someone compacted first, or covers moved): ship the batch without it.
                if let snap = entry.snapshot {
                    _ = try? await transport.delete([.snapshot(id: snap.id)])
                    outbox.removeFile(outbox.snapshotURL(snap.id))
                }
                entry.snapshot = nil
                try outbox.updateMeta(entry)
            }
        }
    }

    /// The server's head for this device disagrees with our counter: adopt it and re-encrypt what is waiting under
    /// the right sequence numbers (the sequence number is bound into the ciphertext's AAD).
    private func renumber(from headSeq: Int64, ring: CloudKeyRing) throws {
        ledger.mutate { $0.committedSeq = headSeq }
        var next = headSeq + 1
        for entry in outbox.entries() {
            let oldRef = CloudObjectRef.change(device: identity.deviceId, seq: entry.seq)
            let plain = try open(try outbox.ciphertext(seq: entry.seq), ref: oldRef, ring: ring)
            var payload = try JSONDecoder().decode(SyncBatchPayload.self, from: plain)
            outbox.remove(seq: entry.seq)
            payload.seq = next
            let newRef = CloudObjectRef.change(device: identity.deviceId, seq: next)
            let cipher = try encrypt(try JSONEncoder().encode(payload), ref: newRef, ring: ring)
            var updated = entry
            updated.seq = next; updated.crc = CloudCRC32C.checksum(cipher); updated.size = Int64(cipher.count)
            try outbox.write(updated, ciphertext: cipher)
            next += 1
        }
        try ledger.save()
    }

    private func finalize(_ entry: OutboxEntry) {
        let now = clock.correctedNowMs()
        ledger.mutate { s in
            s.committedSeq = max(s.committedSeq, entry.seq)
            for k in entry.keys {
                guard var row = s.rows[k.key] else { continue }
                if row.stamp == k.stamp {
                    row.dirty = false; row.syncedAt = now
                    s.rows[k.key] = row
                }
            }
            for ref in entry.audioRefs {
                for (key, var row) in s.rows where row.audioId == ref.id { row.audioAcked = true; row.audioUploaded = true; s.rows[key] = row }
            }
            s.uploadedChanges += entry.keys.count + entry.audioRefs.count
            s.batchesSinceSnapshot += 1
            if !s.rows.values.contains(where: { $0.dirty }) { s.firstDirtyAt = nil }
            if let snap = entry.snapshot {
                s.snapshotVersion = snap.version; s.snapshotId = snap.id; s.snapshotCovers = snap.covers
                s.batchesSinceSnapshot = 0; s.lastSnapshotAt = now
            }
        }
        try? ledger.save()
        outbox.remove(seq: entry.seq)
        for ref in entry.audioRefs { outbox.removeFile(outbox.audioURL(ref.id)) }
        if let snap = entry.snapshot { outbox.removeFile(outbox.snapshotURL(snap.id)); pendingCompaction = snap }
    }

    private var pendingCompaction: OutboxSnapshot?

    // MARK: - Audio

    private func uploadFile(_ url: URL, ref: CloudObjectRef, size: Int64) async throws {
        let grants = try await transport.requestUploads([CloudUploadRequest(ref: ref, size: size)])
        guard let grant = grants.first else { throw SyncError.malformed("no upload grant") }
        try await transport.upload(fileAt: url, size: size, with: grant)
    }

    private func audioRef(kind: String, id: String) -> CloudObjectRef { kind == "meetings" ? .meeting(id: id) : .audio(id: id) }

    private func uploadAudio(ring: CloudKeyRing) async throws {
        guard let current = ring.current() else { throw SyncError.needsKey }
        let todo: [(String, LedgerRow)] = ledger.read { s in
            s.rows.filter { $0.value.audioId != nil && !$0.value.audioUploaded && !$0.value.deleted }
                .sorted { $0.key < $1.key }.prefix(25).map { ($0.key, $0.value) }
        }
        for (key, row) in todo {
            guard let id = row.audioId, let kindString = row.audioKind, let name = row.audioName,
                  let kind = SyncKind.of(key: key) else { continue }
            let ref = audioRef(kind: kindString, id: id)
            let encrypted = outbox.audioURL(id)
            if !FileManager.default.fileExists(atPath: encrypted.path) {
                guard let source = store.localAudioURL(kind: kind, name: name) else {
                    ledger.mutate { $0.rows[key]?.audioId = nil }          // the file is gone; nothing to upload
                    continue
                }
                let summary = try CloudCrypto.encryptFile(from: source, to: encrypted, key: current.key, keyVersion: current.version, context: objectContext(ref))
                ledger.mutate { $0.rows[key]?.audioSize = Int64(summary.ciphertextBytes) }
                try ledger.save()
            }
            let size = Int64((try? encrypted.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try await uploadFile(encrypted, ref: ref, size: size)
            try hooks.checkpoint("afterAudioUpload")
            ledger.mutate { s in s.rows[key]?.audioUploaded = true; s.rows[key]?.audioSize = size }
            try ledger.save()
        }
    }

    /// Removes the cloud copy of audio whose row was deleted on this Mac. Deletion is allowed over quota and while read-only,
    /// so a user who is over their plan can always free space by deleting. The row keeps its audio id until the object is gone,
    /// so a failed or interrupted delete is retried by every later cycle (the ledger is the durable queue).
    private func freeDeletedAudio() async {
        let doomed: [(String, LedgerRow)] = ledger.read { s in
            s.rows.filter { $0.value.deleted && $0.value.audioId != nil }.sorted { $0.key < $1.key }.prefix(200).map { ($0.key, $0.value) }
        }
        guard !doomed.isEmpty else { return }
        let refs = doomed.compactMap { (_, row) -> CloudObjectRef? in
            guard let id = row.audioId, row.audioUploaded || row.audioAcked else { return nil }
            return audioRef(kind: row.audioKind ?? "audio", id: id)
        }
        for group in stride(from: 0, to: refs.count, by: 50).map({ Array(refs[$0..<min($0 + 50, refs.count)]) }) {
            do { _ = try await transport.delete(group) } catch { return }
        }
        ledger.mutate { s in
            for (key, _) in doomed { s.rows[key]?.audioId = nil; s.rows[key]?.audioAcked = false; s.rows[key]?.audioUploaded = false }
        }
        for (_, row) in doomed { if let id = row.audioId { outbox.removeFile(outbox.audioURL(id)) } }
        try? ledger.save()
    }

    /// Announce uploaded audio: a batch whose ops say "audio is available" and whose commit names the objects.
    private func acknowledgeAudio(ring: CloudKeyRing) async throws {
        while true {
            let ready: [(String, LedgerRow)] = ledger.read { s in
                s.rows.filter { $0.value.audioId != nil && $0.value.audioUploaded && !$0.value.audioAcked && !$0.value.deleted }
                    .sorted { $0.key < $1.key }.prefix(policy.batchMaxChanges).map { ($0.key, $0.value) }
            }
            guard !ready.isEmpty else { break }
            var ops: [SyncOp] = [], refs: [SyncAudioRef] = []
            let now = clock.correctedNowMs()
            for (key, row) in ready {
                let audio = SyncAudioRef(id: row.audioId!, kind: row.audioKind ?? "audio", size: row.audioSize ?? 0, name: row.audioName ?? "")
                ops.append(SyncOp(key: key, stamp: SyncStamp(hlc: clock.tick(), device: identity.deviceId), at: now, audio: audio))
                refs.append(audio)
            }
            let seq = (outbox.entries().last?.seq ?? ledger.read { $0.committedSeq }) + 1
            try writeBatch(seq: seq, ops: ops, keys: [], audio: refs, snapshot: nil, ring: ring)
            try await drainOutbox(ring: ring)
        }
    }

    /// The local file for a row's audio, downloading and decrypting it first if this Mac does not have it.
    /// `rowKey` is "d:<UUID>" or "m:<UUID>"; returns nil when the row has no audio anywhere.
    func ensureAudio(rowKey: String) async throws -> URL? {
        guard let kind = SyncKind.of(key: rowKey), let row = ledger.row(rowKey), !row.deleted,
              let name = row.audioName else { return nil }
        if let url = store.localAudioURL(kind: kind, name: name) { return url }
        guard let id = row.audioId, row.audioAcked, let ring = keyProvider(), !ring.isEmpty else { return nil }
        let ref = audioRef(kind: row.audioKind ?? "audio", id: id)
        let grants = try await transport.requestDownloads([ref])
        guard let grant = grants.first else { throw SyncError.malformed("no download grant") }
        let encrypted = outbox.scratchURL("dl-\(id).enc")
        defer { outbox.removeFile(encrypted) }
        try await transport.download(with: grant, to: encrypted)
        let destination = store.audioDestination(kind: kind, name: name)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = outbox.scratchURL("dl-\(id).dec")
        do {
            try CloudCrypto.decryptFile(from: encrypted, to: partial, keyForVersion: { ring.symmetricKey(version: $0) }, context: objectContext(ref))
        } catch CloudCryptoError.authenticationFailed {
            outbox.removeFile(partial); throw SyncError.tampered(ref.relativeName)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    func ensureAudio(dictationID: UUID) async throws -> URL? { try await ensureAudio(rowKey: SyncKind.key(.dictation, dictationID.uuidString)) }
    func ensureAudio(meetingID: UUID) async throws -> URL? { try await ensureAudio(rowKey: SyncKind.key(.meeting, meetingID.uuidString)) }

    /// How much audio this Mac does not have yet (shown before "Download all").
    func missingAudio() -> (files: Int, bytes: Int64) {
        var files = 0, bytes: Int64 = 0
        for (key, row) in ledger.snapshot.rows where row.audioAcked && !row.deleted && row.audioId != nil {
            guard let kind = SyncKind.of(key: key), let name = row.audioName, store.localAudioURL(kind: kind, name: name) == nil else { continue }
            files += 1; bytes += row.audioSize ?? 0
        }
        return (files, bytes)
    }

    /// Downloads every missing audio file. Stops at the first limit error (allowance, plan); the rest stay missing.
    @discardableResult
    func downloadAllAudio(progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Int {
        let keys = ledger.snapshot.rows.filter { (key, row) in
            guard row.audioAcked, !row.deleted, row.audioId != nil, let kind = SyncKind.of(key: key), let name = row.audioName else { return false }
            return store.localAudioURL(kind: kind, name: name) == nil
        }.keys.sorted()
        var done = 0
        for key in keys {
            if try await ensureAudio(rowKey: key) != nil { done += 1 }
            progress?(done, keys.count)
        }
        return done
    }

    // MARK: - Snapshots and compaction (plan 9.5)

    private func maybeSnapshot(ring: CloudKeyRing, heads: CloudHeads) async throws {
        let s = ledger.snapshot
        let now = clock.correctedNowMs()
        let ageDue = s.lastSnapshotAt.map { Double(now - $0) > Double(policy.snapshotAfterDays) * 86_400_000 } ?? false
        guard s.batchesSinceSnapshot > policy.snapshotAfterBatches || (ageDue && s.batchesSinceSnapshot > 0) else {
            try await compactIfNeeded()
            return
        }
        try await writeSnapshot(ring: ring, heads: heads)
        try await compactIfNeeded()
    }

    /// Writes and commits a snapshot of everything this Mac has applied. Only when nothing of ours is in flight,
    /// so the snapshot never claims more than the writer actually applied.
    @discardableResult
    func writeSnapshot(ring: CloudKeyRing, heads: CloudHeads? = nil) async throws -> Bool {
        guard outbox.entries().isEmpty, eligibleDirty().0.isEmpty else { return false }
        let scan = try await store.scan(keys: nil, collect: true)
        guard eligibleDirty().0.isEmpty else { return false }            // the scan found fresh local edits: next cycle
        let s = ledger.snapshot
        let now = clock.correctedNowMs()
        let horizon = now - Int64(policy.tombstoneHorizonDays) * 86_400_000
        var ops: [SyncOp] = []
        for (key, row) in s.rows.sorted(by: { $0.key < $1.key }) {
            if row.deleted {
                if let at = row.tombstoneAt, at >= horizon { ops.append(SyncOp(key: key, stamp: row.stamp, at: at, tombstone: true)) }
            } else if let json = scan.rows[key] {
                ops.append(SyncOp(key: key, stamp: row.stamp, at: now, row: json))
                if row.audioAcked, let id = row.audioId {
                    ops.append(SyncOp(key: key, stamp: row.stamp, at: now,
                                      audio: SyncAudioRef(id: id, kind: row.audioKind ?? "audio", size: row.audioSize ?? 0, name: row.audioName ?? "")))
                }
            }
        }
        var covers = s.cursors.filter { $0.value > 0 }
        if s.committedSeq > 0 { covers[identity.deviceId] = s.committedSeq }
        guard !covers.isEmpty else { return false }
        let version = max(s.snapshotVersion, heads?.snapshot?.version ?? lastHeads?.snapshot?.version ?? 0) + 1
        let id = Self.randomHex128()
        let ref = CloudObjectRef.snapshot(id: id)
        let plain = try JSONEncoder().encode(SyncSnapshotPayload(device: identity.deviceId, covers: covers, ops: ops))
        let cipher = try encrypt(plain, ref: ref, ring: ring)
        try cipher.write(to: outbox.snapshotURL(id), options: .atomic)
        let info = OutboxSnapshot(id: id, covers: covers, version: version, size: Int64(cipher.count), crc: CloudCRC32C.checksum(cipher),
                                  previousId: s.snapshotId, previousCovers: s.snapshotCovers)
        let seq = ledger.read { $0.committedSeq } + 1
        try writeBatch(seq: seq, ops: [], keys: [], audio: [], snapshot: info, ring: ring)
        try await drainOutbox(ring: ring)
        return true
    }

    /// After a snapshot, batches covered by the PREVIOUS snapshot are redundant (a Mac behind its covers fast-forwards
    /// from the current one) and are deleted by exact name, together with the previous snapshot object.
    private func compactIfNeeded() async throws {
        guard let snap = pendingCompaction else { return }
        var refs: [CloudObjectRef] = []
        let done = ledger.read { $0.compactedUpTo }
        for (device, upTo) in snap.previousCovers.sorted(by: { $0.key < $1.key }) where upTo > (done[device] ?? 0) {
            for seq in ((done[device] ?? 0) + 1)...upTo { refs.append(.change(device: device, seq: seq)) }
        }
        if let prev = snap.previousId { refs.append(.snapshot(id: prev)) }
        for group in stride(from: 0, to: refs.count, by: 50).map({ Array(refs[$0..<min($0 + 50, refs.count)]) }) {
            _ = try await transport.delete(group)
        }
        ledger.mutate { s in for (d, upTo) in snap.previousCovers { s.compactedUpTo[d] = max(s.compactedUpTo[d] ?? 0, upTo) } }
        pendingCompaction = nil
        try ledger.save()
    }

    private static func randomHex128() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Introspection (tests)

    func ledgerSnapshot() -> LedgerState { ledger.snapshot }
    func outboxEntries() -> [OutboxEntry] { outbox.entries() }
}

// MARK: - Change hints from Core Data saves

/// Turns `NSManagedObjectContextDidSave` into "look at this key" hints for the engine. Hints are an optimisation
/// only: the periodic and launch-time full scans find anything this misses.
nonisolated final class SyncChangeObserver: @unchecked Sendable {
    private var token: NSObjectProtocol?

    init(coordinator: NSPersistentStoreCoordinator?, deliver: @escaping @Sendable (Set<String>) -> Void) {
        token = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: nil) { note in
            guard let context = note.object as? NSManagedObjectContext else { return }
            if let coordinator, context.persistentStoreCoordinator !== coordinator { return }
            var keys = Set<String>()
            for slot in [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey] {
                guard let objects = note.userInfo?[slot] as? Set<NSManagedObject> else { continue }
                for object in objects {
                    switch object.entity.name {
                    case "TranscriptionEntity": if let id = object.value(forKey: "id") as? UUID { keys.insert(SyncKind.key(.dictation, id.uuidString)) }
                    case "MeetingEntity": if let id = object.value(forKey: "id") as? UUID { keys.insert(SyncKind.key(.meeting, id.uuidString)) }
                    case "DictionaryEntryEntity": keys.insert("w:*")
                    default: break
                    }
                }
            }
            if !keys.isEmpty { deliver(keys) }
        }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}
