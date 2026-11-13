//
//  SyncRowStore.swift
//  Whisperer
//
//  The adapter between the sync engine and the app's data: reads local rows to detect changes, and merges
//  remote rows in. It reuses HistoryArchive's generic row encoding, so a column added to the Core Data model
//  later syncs with no change here.
//
//  How local changes are captured, and why that cannot lose data:
//   - The capture is READ-ONLY with respect to the history store. It fetches rows, hashes their canonical
//     encoding and compares the hash with the one in the sidecar ledger. No attribute, index or persistent-history
//     option is added to the store; enabling Cloud therefore cannot alter or lose a row.
//   - A changed hash is a local edit (new HLC stamp, marked dirty); a ledger row whose object is gone is a
//     deletion (tombstone). A full scan runs at launch and periodically, and `NSManagedObjectContextDidSave`
//     only adds "look at this key" hints, so a crash, a missed notification or a save made by another process
//     never loses a change — the next full scan finds it.
//   - A mass-deletion guard refuses to turn a vanished store into a library-wide tombstone.
//

import Foundation
import CoreData
import CryptoKit

nonisolated struct SyncStoreEnvironment: @unchecked Sendable {
    var newContext: @Sendable () -> NSManagedObjectContext
    var defaults: UserDefaults
    var recordings: URL
    var meetingRecordings: URL
    var meetingData: URL
    var locateMeetingAudio: @Sendable (String) -> URL?

    init(newContext: @escaping @Sendable () -> NSManagedObjectContext, defaults: UserDefaults, recordings: URL,
         meetingRecordings: URL, meetingData: URL, locateMeetingAudio: (@Sendable (String) -> URL?)? = nil) {
        self.newContext = newContext
        self.defaults = defaults
        self.recordings = recordings
        self.meetingRecordings = meetingRecordings
        self.meetingData = meetingData
        self.locateMeetingAudio = locateMeetingAudio ?? { name in
            let url = meetingRecordings.appendingPathComponent((name as NSString).lastPathComponent)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// The app's own folders and its shared history database; nil when the history store could not be opened.
    @MainActor static func app(database: HistoryDatabase = .shared) -> SyncStoreEnvironment? {
        guard let container = database.persistentContainer else { return nil }
        nonisolated(unsafe) let shared = container
        return SyncStoreEnvironment(newContext: { shared.newBackgroundContext() }, defaults: .standard,
                             recordings: AudioLibraryPaths.recordings, meetingRecordings: AudioLibraryPaths.meetingRecordings,
                             meetingData: AudioLibraryPaths.meetingData,
                             locateMeetingAudio: { MeetingManager.locateAudio(storedName: $0) })
    }
}

nonisolated struct SyncScanResult: Sendable {
    var changed = 0
    var tombstoned = 0
    var rows: [String: JSONValue] = [:]
    var massDeleteBlocked = false
}

/// Pure merge rules (plan 9.4), tested directly.
nonisolated enum SyncMerge {
    /// Should `remote` replace what the ledger says is local? Audio announcements are handled separately.
    static func shouldApply(kind: SyncKind, local: LedgerRow?, remote: SyncOp) -> Bool {
        guard let local else { return true }
        if remote.isTombstone {
            if local.deleted { return false }
            return kind.deleteWins ? true : remote.stamp > local.stamp
        }
        if local.deleted && kind.deleteWins { return false }
        return remote.stamp > local.stamp
    }
}

nonisolated final class SyncRowStore: @unchecked Sendable {
    static let statKeys = ["bestStreak", "userTypingWPM"]
    private static let volatile: [SyncKind: Set<String>] = [.dictionary: ["useCount"]]

    let env: SyncStoreEnvironment
    let ledger: SyncLedger
    let clock: HybridLogicalClock
    let policy: SyncPolicy
    private let hooks: SyncHooks

    init(env: SyncStoreEnvironment, ledger: SyncLedger, clock: HybridLogicalClock, policy: SyncPolicy = SyncPolicy(),
         hooks: SyncHooks = .none) {
        self.env = env; self.ledger = ledger; self.clock = clock; self.policy = policy; self.hooks = hooks
    }

    private var device: String { ledger.deviceId }

    // MARK: - Hashing

    static func hash(_ json: JSONValue, kind: SyncKind) -> String {
        var value = json
        if case .object(var o) = json {
            for k in volatile[kind] ?? [] { o[k] = nil }
            if kind == .dictionary { o["id"] = nil }
            value = .object(o)
        }
        return SHA256.hash(data: value.canonicalData()).map { String(format: "%02x", $0) }.joined()
    }

    static func dictionaryKey(incorrect: String?, correct: String?) -> String {
        let digest = SHA256.hash(data: Data(HistoryArchive.formKey(incorrect, correct).utf8))
        return "w:" + digest.map { String(format: "%02x", $0) }.joined().prefix(32)
    }

    // MARK: - Audio files

    func localAudioURL(kind: SyncKind, name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        let base = (name as NSString).lastPathComponent
        switch kind {
        case .dictation:
            let url = env.recordings.appendingPathComponent(base)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .meeting:
            return env.locateMeetingAudio(name)
        default: return nil
        }
    }

    func audioDestination(kind: SyncKind, name: String) -> URL {
        let folder = kind == .meeting ? env.meetingRecordings : env.recordings
        return folder.appendingPathComponent((name as NSString).lastPathComponent)
    }

    private static func randomHex128() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Scan (local changes)

    /// `keys == nil` scans everything. Otherwise only the named keys (and a whole family for "d:*", "m:*", "w:*",
    /// "s:*", "c:*"). With `collect`, the current row of every requested key that exists is returned.
    func scan(keys: Set<String>?, collect: Bool = false) async throws -> SyncScanResult {
        try await recoverPendingApply()          // a merge interrupted by a crash is settled before anything is compared
        let context = env.newContext()
        return try await context.perform { [self] in
            var result = SyncScanResult()
            let now = clock.correctedNowMs()
            func wants(_ key: String, _ kind: SyncKind) -> Bool {
                keys == nil || keys!.contains(key) || keys!.contains("\(kind.rawValue):*")
            }
            func familyRequested(_ kind: SyncKind) -> Bool {
                keys == nil || keys!.contains { $0.hasPrefix("\(kind.rawValue):") }
            }
            var tombstoneCandidates: [(String, SyncKind)] = []

            // Dictations and meetings: rows with a unique id.
            for kind in [SyncKind.dictation, .meeting] where familyRequested(kind) {
                let fullFamily = keys == nil || keys!.contains("\(kind.rawValue):*")
                var seen = Set<String>()
                let request = NSFetchRequest<NSManagedObject>(entityName: kind.entityName!)
                request.fetchBatchSize = 200
                if !fullFamily, let keys {
                    let ids = keys.filter { $0.hasPrefix("\(kind.rawValue):") }.compactMap { UUID(uuidString: SyncKind.id(ofKey: $0)) }
                    request.predicate = NSPredicate(format: "id IN %@", ids as NSArray)
                }
                let objects = try context.fetch(request)
                for (index, object) in objects.enumerated() {
                    guard let id = object.value(forKey: "id") as? UUID else { continue }
                    let key = SyncKind.key(kind, id.uuidString)
                    seen.insert(key)
                    if (object.value(forKey: "isInProgress") as? Bool) == true { continue }
                    let json = try JSONValue.fromRow(HistoryArchive.encodeRow(object))
                    observe(key: key, kind: kind, json: json, audioName: object.value(forKey: "audioFileURL") as? String,
                            localId: nil, collect: collect, result: &result)
                    if index % 500 == 499 { context.refreshAllObjects() }
                }
                for key in candidateKeys(kind: kind, fullFamily: fullFamily, requested: keys) where !seen.contains(key) {
                    tombstoneCandidates.append((key, kind))
                }
                context.reset()
            }

            // Dictionary: small, always scanned whole; only requested keys are acted on.
            if familyRequested(.dictionary) {
                let request = NSFetchRequest<NSManagedObject>(entityName: "DictionaryEntryEntity")
                request.predicate = NSPredicate(format: "isBuiltIn == NO")
                var objects = try context.fetch(request)
                objects.sort { ($0.value(forKey: "id") as? UUID)?.uuidString ?? "" < ($1.value(forKey: "id") as? UUID)?.uuidString ?? "" }
                var seen = Set<String>()
                for object in objects {
                    guard let id = object.value(forKey: "id") as? UUID else { continue }
                    let key = Self.dictionaryKey(incorrect: object.value(forKey: "incorrectForm") as? String,
                                                  correct: object.value(forKey: "correctForm") as? String)
                    guard seen.insert(key).inserted else { continue }
                    if !wants(key, .dictionary) { continue }
                    let json = try JSONValue.fromRow(HistoryArchive.encodeRow(object))
                    observe(key: key, kind: .dictionary, json: json, audioName: nil, localId: id.uuidString, collect: collect, result: &result)
                }
                let fullFamily = keys == nil || keys!.contains("w:*")
                for key in candidateKeys(kind: .dictionary, fullFamily: fullFamily, requested: keys) where !seen.contains(key) {
                    tombstoneCandidates.append((key, .dictionary))
                }
                context.reset()
            }

            // Statistics records. Never deleted.
            if familyRequested(.stat) {
                for name in Self.statKeys where env.defaults.object(forKey: name) != nil {
                    let key = SyncKind.key(.stat, name)
                    if !wants(key, .stat) { continue }
                    let json = JSONValue.object(["v": .number(Double(env.defaults.integer(forKey: name)))])
                    observe(key: key, kind: .stat, json: json, audioName: nil, localId: nil, collect: collect, result: &result)
                }
            }

            // Meeting chat threads (files next to the meeting data).
            if familyRequested(.chat) {
                let fullFamily = keys == nil || keys!.contains("c:*")
                var seen = Set<String>()
                var names: [String] = []
                if fullFamily {
                    names = ((try? FileManager.default.contentsOfDirectory(atPath: env.meetingData.path)) ?? [])
                        .filter { $0.hasSuffix("-chat.json") }.map { String($0.dropLast("-chat.json".count)) }
                } else if let keys {
                    names = keys.filter { $0.hasPrefix("c:") && $0 != "c:*" }.map { SyncKind.id(ofKey: $0) }
                }
                for id in names {
                    let key = SyncKind.key(.chat, id)
                    let file = env.meetingData.appendingPathComponent("\(id)-chat.json")
                    guard let data = try? Data(contentsOf: file), let body = String(data: data, encoding: .utf8) else { continue }
                    seen.insert(key)
                    if ledger.row(SyncKind.key(.meeting, id))?.deleted == true { continue }     // a deleted meeting takes its chat with it
                    observe(key: key, kind: .chat, json: .object(["b": .string(body)]), audioName: nil, localId: nil, collect: collect, result: &result)
                }
                for key in candidateKeys(kind: .chat, fullFamily: fullFamily, requested: keys) where !seen.contains(key) {
                    tombstoneCandidates.append((key, .chat))
                }
            }

            // Deletions, behind the mass-deletion guard.
            if !tombstoneCandidates.isEmpty {
                let live = ledger.liveRowCount
                let approved = ledger.read { $0.massDeleteApproved }
                if !approved, tombstoneCandidates.count >= policy.massDeleteMinimum, tombstoneCandidates.count * 2 >= live {
                    result.massDeleteBlocked = true
                    Logger.warning("Cloud sync: \(tombstoneCandidates.count) of \(live) rows look deleted; holding the deletions back", subsystem: .app)
                } else {
                    for (key, _) in tombstoneCandidates {
                        let stamp = SyncStamp(hlc: clock.tick(), device: device)
                        ledger.mutate { s in
                            guard var row = s.rows[key], !row.deleted else { return }
                            row.hlc = stamp.hlc; row.dev = stamp.device; row.deleted = true; row.tombstoneAt = now
                            row.hash = ""; row.dirty = true
                            s.rows[key] = row
                            if s.firstDirtyAt == nil { s.firstDirtyAt = now }
                        }
                        result.tombstoned += 1
                    }
                    if ledger.read({ $0.massDeleteApproved }) { ledger.mutate { $0.massDeleteApproved = false } }
                }
            }
            return result
        }
    }

    private func candidateKeys(kind: SyncKind, fullFamily: Bool, requested: Set<String>?) -> [String] {
        if fullFamily {
            return ledger.read { s in s.rows.compactMap { $0.value.deleted ? nil : ($0.key.hasPrefix("\(kind.rawValue):") ? $0.key : nil) } }
        }
        return (requested ?? []).filter { $0.hasPrefix("\(kind.rawValue):") && $0.last != "*" && (ledger.row($0).map { !$0.deleted } ?? false) }
    }

    /// Compare one live row with the ledger; record a local change when it differs.
    private func observe(key: String, kind: SyncKind, json: JSONValue, audioName: String?, localId: String?,
                         collect: Bool, result: inout SyncScanResult) {
        let hash = Self.hash(json, kind: kind)
        let existing = ledger.row(key)
        if collect { result.rows[key] = json }
        if let existing {
            if existing.deleted && kind.deleteWins { return }          // a tombstone is final for unique-id rows
            if !existing.deleted && existing.hash == hash {
                if kind == .dictionary, existing.localId != localId { ledger.mutate { $0.rows[key]?.localId = localId } }
                assignAudioIfNeeded(key: key, kind: kind, audioName: audioName)
                return
            }
        }
        let stamp = SyncStamp(hlc: clock.tick(), device: device)
        let now = clock.correctedNowMs()
        ledger.mutate { s in
            var row = s.rows[key] ?? LedgerRow(stamp: stamp, hash: hash, dirty: true)
            row.hlc = stamp.hlc; row.dev = stamp.device; row.hash = hash; row.dirty = true
            row.deleted = false; row.tombstoneAt = nil
            if localId != nil { row.localId = localId }
            s.rows[key] = row
            if s.firstDirtyAt == nil { s.firstDirtyAt = now }
        }
        result.changed += 1
        assignAudioIfNeeded(key: key, kind: kind, audioName: audioName)
    }

    private func assignAudioIfNeeded(key: String, kind: SyncKind, audioName: String?) {
        guard kind == .dictation || kind == .meeting, let name = audioName, !name.isEmpty,
              let row = ledger.row(key), row.audioId == nil, !row.deleted,
              localAudioURL(kind: kind, name: name) != nil else { return }
        ledger.mutate { s in
            s.rows[key]?.audioId = Self.randomHex128()
            s.rows[key]?.audioKind = kind == .meeting ? "meetings" : "audio"
            s.rows[key]?.audioName = (name as NSString).lastPathComponent
            s.rows[key]?.audioUploaded = false
            s.rows[key]?.audioAcked = false
        }
    }

    // MARK: - Merge (remote changes)

    /// Applies ops in order on a background context in ONE save, then updates the ledger. Returns the keys of rows
    /// that changed locally. The caller wraps this in `pendingApplyKeys` and advances its cursor afterwards.
    @discardableResult
    func apply(_ ops: [SyncOp]) async throws -> Int {
        guard !ops.isEmpty else { return 0 }
        let context = env.newContext()
        let now = clock.correctedNowMs()
        let outcome: (staged: [String: LedgerRow], applied: Int, filesToRemove: [URL]) = try await context.perform { [self] in
            var staged: [String: LedgerRow] = [:]
            var applied = 0
            var filesToRemove: [URL] = []
            var safeRemove: [URL] = []                // files whose removal recovery may repeat: audio of a deleted row, chat of a deleted meeting
            var expect: [String: String] = [:]       // key -> store hash that proves the op landed ("∅" = gone)

            // Prefetch the objects the batch touches, once per entity.
            var existing: [String: NSManagedObject] = [:]   // key -> object (d/m by id)
            for kind in [SyncKind.dictation, .meeting] {
                let ids = ops.filter { SyncKind.of(key: $0.k) == kind }.compactMap { UUID(uuidString: SyncKind.id(ofKey: $0.k)) }
                guard !ids.isEmpty else { continue }
                let request = NSFetchRequest<NSManagedObject>(entityName: kind.entityName!)
                request.predicate = NSPredicate(format: "id IN %@", ids as NSArray)
                for object in try context.fetch(request) {
                    if let id = object.value(forKey: "id") as? UUID { existing[SyncKind.key(kind, id.uuidString)] = object }
                }
            }
            var dictionary: [String: NSManagedObject] = [:]
            if ops.contains(where: { SyncKind.of(key: $0.k) == .dictionary }) {
                let request = NSFetchRequest<NSManagedObject>(entityName: "DictionaryEntryEntity")
                request.predicate = NSPredicate(format: "isBuiltIn == NO")
                var all = try context.fetch(request)
                all.sort { ($0.value(forKey: "id") as? UUID)?.uuidString ?? "" < ($1.value(forKey: "id") as? UUID)?.uuidString ?? "" }
                for object in all {
                    let key = Self.dictionaryKey(incorrect: object.value(forKey: "incorrectForm") as? String,
                                                  correct: object.value(forKey: "correctForm") as? String)
                    if dictionary[key] == nil { dictionary[key] = object }
                }
            }

            for op in ops {
                guard let kind = SyncKind.of(key: op.k) else { continue }      // a newer app's kind: ignore, never fail
                clock.receive(op.stamp.hlc)
                let local = staged[op.k] ?? ledger.row(op.k)
                if kind == .chat, (staged[SyncKind.key(.meeting, SyncKind.id(ofKey: op.k))] ?? ledger.row(SyncKind.key(.meeting, SyncKind.id(ofKey: op.k))))?.deleted == true { continue }

                if let audio = op.aud {
                    guard var row = local, !row.deleted else { continue }
                    row.audioId = audio.id; row.audioKind = audio.kind; row.audioSize = audio.size; row.audioName = audio.name
                    row.audioUploaded = true; row.audioAcked = true
                    staged[op.k] = row
                    continue
                }
                if kind == .stat, op.row != nil, op.k == SyncKind.key(.stat, "bestStreak") {
                    // A record that only grows: merge by maximum (commutative), whatever the stamps.
                    let remote = Int(op.row?.objectValue?["v"]?.doubleValue ?? 0)
                    let mine = env.defaults.object(forKey: "bestStreak") != nil ? env.defaults.integer(forKey: "bestStreak") : Int.min
                    let value = max(remote, mine)
                    if value != mine { env.defaults.set(value, forKey: "bestStreak"); applied += 1 }
                    let hash = Self.hash(.object(["v": .number(Double(value))]), kind: .stat)
                    var row = local ?? LedgerRow(stamp: op.stamp, hash: hash, dirty: false)
                    row.hash = hash
                    if op.stamp > row.stamp { row.hlc = op.hlcValue; row.dev = op.dev }
                    row.dirty = row.dirty && mine > remote
                    row.syncedAt = now
                    staged[op.k] = row
                    expect[op.k] = hash
                    continue
                }
                guard SyncMerge.shouldApply(kind: kind, local: local, remote: op) else {
                    if op.isTombstone, var row = local, row.deleted, op.stamp > row.stamp {
                        row.hlc = op.hlcValue; row.dev = op.dev; row.tombstoneAt = op.at
                        staged[op.k] = row
                    }
                    continue
                }
                var carried = local ?? LedgerRow(stamp: op.stamp, hash: "", dirty: false)
                carried.hlc = op.hlcValue; carried.dev = op.dev; carried.dirty = false; carried.syncedAt = now

                if op.isTombstone {
                    switch kind {
                    case .dictation, .meeting:
                        if let object = existing[op.k] {
                            if let name = object.value(forKey: "audioFileURL") as? String, let url = localAudioURL(kind: kind, name: name) {
                                filesToRemove.append(url)
                                safeRemove.append(url)
                            }
                            context.delete(object); existing[op.k] = nil
                        }
                    case .dictionary:
                        if let object = dictionary[op.k] { context.delete(object); dictionary[op.k] = nil }
                    case .chat:
                        filesToRemove.append(env.meetingData.appendingPathComponent("\(SyncKind.id(ofKey: op.k))-chat.json"))
                    case .stat: break
                    }
                    carried.deleted = true; carried.tombstoneAt = op.at; carried.hash = ""
                    staged[op.k] = carried
                    expect[op.k] = "∅"
                    if kind == .meeting {      // a deleted meeting takes its chat thread with it
                        let chatKey = SyncKind.key(.chat, SyncKind.id(ofKey: op.k))
                        filesToRemove.append(env.meetingData.appendingPathComponent("\(SyncKind.id(ofKey: op.k))-chat.json"))
                        safeRemove.append(env.meetingData.appendingPathComponent("\(SyncKind.id(ofKey: op.k))-chat.json"))
                        if var chat = staged[chatKey] ?? ledger.row(chatKey), !chat.deleted {
                            chat.deleted = true; chat.tombstoneAt = op.at; chat.hash = ""; chat.dirty = false
                            staged[chatKey] = chat; expect[chatKey] = "∅"
                        }
                    }
                    applied += 1
                    continue
                }

                guard let json = op.row else { continue }
                switch kind {
                case .dictation, .meeting:
                    let object: NSManagedObject
                    if let found = existing[op.k] { object = found }
                    else {
                        guard let description = NSEntityDescription.entity(forEntityName: kind.entityName!, in: context) else { throw SyncError.storeUnavailable }
                        object = NSManagedObject(entity: description, insertInto: context)
                        existing[op.k] = object
                    }
                    guard try fill(object, from: json, keepId: false) else { context.delete(object); existing[op.k] = nil; continue }
                    carried.hash = Self.hash(try JSONValue.fromRow(HistoryArchive.encodeRow(object)), kind: kind)
                case .dictionary:
                    let object: NSManagedObject
                    if let found = dictionary[op.k] { object = found }
                    else {
                        guard let description = NSEntityDescription.entity(forEntityName: "DictionaryEntryEntity", in: context) else { throw SyncError.storeUnavailable }
                        object = NSManagedObject(entity: description, insertInto: context)
                        dictionary[op.k] = object
                    }
                    let isNew = object.isInserted
                    guard try fill(object, from: json, keepId: !isNew) else { context.delete(object); dictionary[op.k] = nil; continue }
                    carried.hash = Self.hash(try JSONValue.fromRow(HistoryArchive.encodeRow(object)), kind: .dictionary)
                    carried.localId = (object.value(forKey: "id") as? UUID)?.uuidString
                case .stat:
                    guard let value = json.objectValue?["v"]?.doubleValue else { continue }
                    env.defaults.set(Int(value), forKey: SyncKind.id(ofKey: op.k))
                    carried.hash = Self.hash(.object(["v": .number(Double(Int(value)))]), kind: .stat)
                case .chat:
                    guard let body = json.objectValue?["b"]?.stringValue else { continue }
                    try FileManager.default.createDirectory(at: env.meetingData, withIntermediateDirectories: true)
                    try Data(body.utf8).write(to: env.meetingData.appendingPathComponent("\(SyncKind.id(ofKey: op.k))-chat.json"), options: .atomic)
                    carried.hash = Self.hash(.object(["b": .string(body)]), kind: .chat)
                }
                carried.deleted = false; carried.tombstoneAt = nil
                staged[op.k] = carried
                expect[op.k] = carried.hash
                applied += 1
            }

            // Journal first: if the process dies between the store save and the ledger update, recovery can tell a merge that
            // landed (adopt the staged rows) from a user edit made meanwhile (a genuine local change).
            ledger.mutate { s in
                s.pendingApplyKeys = Array(expect.keys)
                s.pendingStaged = staged.filter { expect[$0.key] != nil }
                s.pendingExpect = expect
                s.pendingLanded = false
                s.pendingRemove = safeRemove.map(\.path)
            }
            try ledger.save()
            try hooks.checkpoint("beforeStoreSave")
            if context.hasChanges {
                do { try context.save() } catch {
                    context.rollback()
                    Logger.error("Cloud sync: merging a batch failed to save: \(error)", subsystem: .app)
                    throw error
                }
            }
            ledger.mutate { $0.pendingLanded = true }
            try ledger.save()                                   // the merge is now known to have landed in the store
            try hooks.checkpoint("afterStoreLanded")
            return (staged, applied, filesToRemove)
        }
        for url in outcome.filesToRemove { try? FileManager.default.removeItem(at: url) }
        try hooks.checkpoint("afterStoreSave")
        ledger.mutate { s in for (key, row) in outcome.staged { s.rows[key] = row } }
        return outcome.applied
    }

    /// Writes every attribute the row carries; optional attributes it omits become nil. A row that lacks a required
    /// attribute (a malformed or future-format op) is refused rather than failing the whole save.
    private func fill(_ object: NSManagedObject, from json: JSONValue, keepId: Bool) throws -> Bool {
        var dict = try json.toRow()
        if keepId { dict["id"] = nil }
        let description = object.entity
        for (name, attribute) in description.attributesByName where !attribute.isOptional && dict[name] == nil {
            let hasDefault = attribute.defaultValue != nil
            if !hasDefault && !(keepId && name == "id") && object.value(forKey: name) == nil { return false }
        }
        HistoryArchive.decodeRow(dict, into: object, description: description)
        for (name, attribute) in description.attributesByName where attribute.isOptional && dict[name] == nil && !(keepId && name == "id") {
            if object.value(forKey: name) != nil { object.setValue(nil, forKey: name) }
        }
        return true
    }

    /// The stale-device rule: a previously acknowledged row that the snapshot and the tail do not mention was
    /// deleted elsewhere. Remove it here without publishing a tombstone (the others already have it).
    func deleteLocally(keys: [String]) async throws -> Int {
        guard !keys.isEmpty else { return 0 }
        let context = env.newContext()
        let now = clock.correctedNowMs()
        let files: [URL] = try await context.perform { [self] in
            var files: [URL] = []
            for kind in [SyncKind.dictation, .meeting, .dictionary] {
                let mine = keys.filter { SyncKind.of(key: $0) == kind }
                guard !mine.isEmpty else { continue }
                let request = NSFetchRequest<NSManagedObject>(entityName: kind.entityName!)
                if kind == .dictionary { request.predicate = NSPredicate(format: "isBuiltIn == NO") }
                else {
                    let ids = mine.compactMap { UUID(uuidString: SyncKind.id(ofKey: $0)) }
                    request.predicate = NSPredicate(format: "id IN %@", ids as NSArray)
                }
                for object in try context.fetch(request) {
                    if kind == .dictionary {
                        let key = Self.dictionaryKey(incorrect: object.value(forKey: "incorrectForm") as? String,
                                                      correct: object.value(forKey: "correctForm") as? String)
                        guard mine.contains(key) else { continue }
                    } else if let name = object.value(forKey: "audioFileURL") as? String, let url = localAudioURL(kind: kind, name: name) {
                        files.append(url)
                    }
                    context.delete(object)
                }
            }
            for key in keys where SyncKind.of(key: key) == .chat {
                files.append(env.meetingData.appendingPathComponent("\(SyncKind.id(ofKey: key))-chat.json"))
            }
            if context.hasChanges { try context.save() }
            return files
        }
        for url in files { try? FileManager.default.removeItem(at: url) }
        ledger.mutate { s in
            for key in keys { s.rows[key]?.deleted = true; s.rows[key]?.tombstoneAt = now; s.rows[key]?.dirty = false; s.rows[key]?.hash = "" }
        }
        return keys.count
    }
}

nonisolated extension SyncOp {
    var hlcValue: HLC { HLC(wall: w, counter: c) }
}



nonisolated extension SyncRowStore {
    /// After a crash in the middle of a merge. If the store save is known to have landed, the staged ledger rows are
    /// adopted — the change scan then sees the user's edits made since (a changed or missing row) as genuine local
    /// changes, which is exactly what they are. If the save never landed nothing is adopted and the batch is simply
    /// fetched and merged again (the cursor only moves with a completed merge).
    func recoverPendingApply() async throws {
        let (keys, staged, landed, remove) = ledger.read { ($0.pendingApplyKeys, $0.pendingStaged, $0.pendingLanded, $0.pendingRemove) }
        guard !keys.isEmpty || landed else { return }
        if landed { for path in remove { try? FileManager.default.removeItem(atPath: path) } }
        ledger.mutate { s in
            if landed { for (key, row) in staged { s.rows[key] = row } }
            s.pendingApplyKeys = []; s.pendingStaged = [:]; s.pendingExpect = [:]; s.pendingLanded = false; s.pendingRemove = []
        }
        try ledger.save()
    }
}
