//
//  CloudSyncHarness.swift
//  WhispererTests
//
//  Virtual devices (each with its own in-memory Core Data stack, folders, UserDefaults and sync engine) on a
//  shared simulated cloud, plus the seeded fuzz runner that checks the sync invariants.
//

import XCTest
import CoreData
import CryptoKit
@testable import whisperer

nonisolated struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
}

nonisolated final class SimClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Int64
    init(start: Int64 = 1_794_571_200_000) { ms = start }   // 2026-11-13
    func now() -> Int64 { lock.lock(); defer { lock.unlock() }; return ms }
    func advance(_ delta: Int64) { lock.lock(); ms += delta; lock.unlock() }
    var date: Date { Date(timeIntervalSince1970: Double(now()) / 1000) }
}

nonisolated final class CrashSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = Set<String>()
    func arm(_ point: String) { lock.lock(); armed.insert(point); lock.unlock() }
    func clear() { lock.lock(); armed.removeAll(); lock.unlock() }
    func check(_ point: String) throws {
        lock.lock(); let hit = armed.remove(point) != nil; lock.unlock()
        if hit { throw SyncError.simulatedCrash(point) }
    }
}

enum SimKeepAlive {
    nonisolated(unsafe) static var databases: [HistoryDatabase] = []
    private static let lock = NSLock()
    static func hold(_ db: HistoryDatabase) { lock.lock(); databases.append(db); lock.unlock() }
}

nonisolated final class SimDevice {
    let index: Int
    let id: String
    let db: HistoryDatabase
    let defaults: UserDefaults
    let suite: String
    let root: URL
    let recordings: URL, meetingRecordings: URL, meetingData: URL, cloudDir: URL
    let transport: InMemoryCloudTransport
    let clock: SimClock
    let ring: CloudKeyRing
    let crash = CrashSwitch()
    var skewMs: Int64 = 0
    var policy = SyncPolicy()
    var engine: SyncEngine?
    let identity: SyncIdentity
    let server: CloudSimServer
    var keyProvider: @Sendable () -> CloudKeyRing?
    var lastError: String?

    @MainActor
    init(index: Int, server: CloudSimServer, clock: SimClock, ring: CloudKeyRing, tag: String) throws {
        self.index = index
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = UInt8(index); for (i, c) in tag.utf8.enumerated() { bytes[1 + i % 14] ^= c }
        bytes[15] = UInt8(truncatingIfNeeded: tag.hashValue)
        self.id = bytes.map { String(format: "%02x", $0) }.joined()
        self.server = server; self.clock = clock; self.ring = ring
        db = HistoryDatabase(inMemory: true)
        SimKeepAlive.hold(db)
        suite = "CloudSim-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSim-\(UUID().uuidString)", isDirectory: true)
        recordings = root.appendingPathComponent("Recordings")
        meetingRecordings = root.appendingPathComponent("Meetings-audio")
        meetingData = root.appendingPathComponent("Meetings")
        cloudDir = root.appendingPathComponent("Cloud")
        for dir in [recordings, meetingRecordings, meetingData, cloudDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        transport = InMemoryCloudTransport(server: server)
        identity = SyncIdentity(accountId: server.accountId, epoch: server.epoch, deviceId: id)
        keyProvider = { ring }
    }

    func cleanUp() {
        engine = nil
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    var environment: SyncStoreEnvironment {
        let container = db.persistentContainer!
        nonisolated(unsafe) let shared = container
        return SyncStoreEnvironment(newContext: { shared.newBackgroundContext() }, defaults: defaults, recordings: recordings,
                                    meetingRecordings: meetingRecordings, meetingData: meetingData)
    }

    func makeEngine() throws -> SyncEngine {
        let clock = self.clock
        let device = self
        let crash = self.crash
        let engine = try SyncEngine(identity: identity, transport: transport, environment: environment, cloudDirectory: cloudDir,
                                    keyProvider: { [weak device] in device?.keyProvider() }, policy: policy,
                                    hooks: SyncHooks { try crash.check($0) },
                                    nowMs: { [weak device] in clock.now() + (device?.skewMs ?? 0) })
        self.engine = engine
        return engine
    }

    func currentEngine() throws -> SyncEngine { try engine ?? makeEngine() }

    /// A process death: everything in memory is gone; files and the Core Data store remain.
    func crashAndRestart() { engine = nil }

    /// One full cycle. Returns false when the engine "crashed" (and was dropped).
    @discardableResult
    func cycle(force: Bool = true) async -> Bool {
        do {
            try await currentEngine().runCycle(force: force)
            return true
        } catch SyncError.simulatedCrash {
            crashAndRestart()
            return false
        } catch {
            lastError = "\(error)"
            return true       // transient (offline, tampered, ...): the next cycle retries
        }
    }

    func capture() async {
        do { try await currentEngine().captureLocalChanges(full: true) } catch { XCTFail("capture failed: \(error)") }
    }

    // MARK: Local edits (what the app would do)

    private func save<T>(_ body: @escaping @Sendable (NSManagedObjectContext) throws -> T) async throws -> T {
        let context = db.persistentContainer!.newBackgroundContext()
        return try await context.perform {
            let r = try body(context)
            if context.hasChanges { try context.save() }
            return r
        }
    }

    func insertDictation(_ uuid: UUID, token: String, audio: Data?) async throws {
        let now = Date(timeIntervalSince1970: Double(clock.now() + skewMs) / 1000)
        var audioName: String?
        if let audio {
            audioName = "\(uuid.uuidString).opus"
            try audio.write(to: recordings.appendingPathComponent(audioName!))
        }
        let name = audioName
        try await save { ctx in
            let o = NSManagedObject(entity: NSEntityDescription.entity(forEntityName: "TranscriptionEntity", in: ctx)!, insertInto: ctx)
            o.setValue(uuid, forKey: "id"); o.setValue(now, forKey: "timestamp"); o.setValue(now, forKey: "createdAt"); o.setValue(now, forKey: "lastModifiedAt")
            o.setValue("ZQSECRET dictation \(token)", forKey: "transcription"); o.setValue("en", forKey: "language"); o.setValue("m", forKey: "modelUsed")
            o.setValue(name, forKey: "audioFileURL"); o.setValue(token, forKey: "notes"); o.setValue(false, forKey: "isPinned")
        }
    }

    func editDictation(_ uuid: UUID, token: String, pinned: Bool) async throws {
        try await save { ctx in
            let r = NSFetchRequest<NSManagedObject>(entityName: "TranscriptionEntity"); r.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            guard let o = try ctx.fetch(r).first else { return }
            o.setValue("ZQSECRET edited \(token)", forKey: "editedTranscription"); o.setValue(token, forKey: "notes"); o.setValue(pinned, forKey: "isPinned")
        }
    }

    func deleteDictation(_ uuid: UUID) async throws {
        let recordings = self.recordings
        try await save { ctx in
            let r = NSFetchRequest<NSManagedObject>(entityName: "TranscriptionEntity"); r.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            for o in try ctx.fetch(r) {
                if let n = o.value(forKey: "audioFileURL") as? String { try? FileManager.default.removeItem(at: recordings.appendingPathComponent(n)) }
                ctx.delete(o)
            }
        }
    }

    func insertMeeting(_ uuid: UUID, token: String) async throws {
        let now = Date(timeIntervalSince1970: Double(clock.now() + skewMs) / 1000)
        try await save { ctx in
            let o = NSManagedObject(entity: NSEntityDescription.entity(forEntityName: "MeetingEntity", in: ctx)!, insertInto: ctx)
            o.setValue(uuid, forKey: "id"); o.setValue("ZQSECRET meeting \(token)", forKey: "title"); o.setValue(now, forKey: "createdAt")
            o.setValue("en", forKey: "language"); o.setValue("m", forKey: "modelUsed")
            o.setValue("{\"segments\":\"\(token)\"}", forKey: "segmentsJSON"); o.setValue("{\"summary\":\"\(token)\"}", forKey: "aiSummaryJSON")
            o.setValue("{\"notes\":\"\(token)\"}", forKey: "notesJSON")
        }
    }

    func editMeeting(_ uuid: UUID, token: String) async throws {
        try await save { ctx in
            let r = NSFetchRequest<NSManagedObject>(entityName: "MeetingEntity"); r.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            guard let o = try ctx.fetch(r).first else { return }
            o.setValue("ZQSECRET meeting \(token)", forKey: "title"); o.setValue("{\"summary\":\"\(token)\"}", forKey: "aiSummaryJSON")
            o.setValue("{\"notes\":\"\(token)\"}", forKey: "notesJSON"); o.setValue("{\"segments\":\"\(token)\"}", forKey: "segmentsJSON")
        }
    }

    func deleteMeeting(_ uuid: UUID) async throws {
        try await save { ctx in
            let r = NSFetchRequest<NSManagedObject>(entityName: "MeetingEntity"); r.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            for o in try ctx.fetch(r) { ctx.delete(o) }
        }
        try? FileManager.default.removeItem(at: meetingData.appendingPathComponent("\(uuid.uuidString)-chat.json"))
    }

    func writeChat(_ uuid: UUID, body: String) throws {
        try Data(body.utf8).write(to: meetingData.appendingPathComponent("\(uuid.uuidString)-chat.json"), options: .atomic)
    }

    func addWord(_ incorrect: String, _ correct: String, token: String) async throws {
        let now = Date(timeIntervalSince1970: Double(clock.now() + skewMs) / 1000)
        try await save { ctx in
            let o = NSManagedObject(entity: NSEntityDescription.entity(forEntityName: "DictionaryEntryEntity", in: ctx)!, insertInto: ctx)
            o.setValue(UUID(), forKey: "id"); o.setValue(incorrect, forKey: "incorrectForm"); o.setValue(correct, forKey: "correctForm")
            o.setValue(now, forKey: "createdAt"); o.setValue(now, forKey: "lastModifiedAt"); o.setValue(token, forKey: "notes")
            o.setValue(false, forKey: "isBuiltIn")
        }
    }

    func editWord(_ incorrect: String, _ correct: String, token: String) async throws {
        try await save { ctx in
            let r = NSFetchRequest<NSManagedObject>(entityName: "DictionaryEntryEntity")
            for o in try ctx.fetch(r) where (o.value(forKey: "incorrectForm") as? String) == incorrect && (o.value(forKey: "correctForm") as? String) == correct {
                o.setValue(token, forKey: "notes")
            }
        }
    }

    func deleteWord(_ incorrect: String, _ correct: String) async throws {
        try await save { ctx in
            let r = NSFetchRequest<NSManagedObject>(entityName: "DictionaryEntryEntity")
            for o in try ctx.fetch(r) where (o.value(forKey: "incorrectForm") as? String) == incorrect && (o.value(forKey: "correctForm") as? String) == correct { ctx.delete(o) }
        }
    }

    // MARK: Reading state

    func liveIDs(_ entity: String) async throws -> [UUID] {
        try await save { ctx in
            let r = NSFetchRequest<NSManagedObject>(entityName: entity)
            return try ctx.fetch(r).compactMap { $0.value(forKey: "id") as? UUID }
        }
    }

    func hasWord(_ incorrect: String, _ correct: String) async throws -> Bool {
        try await save { ctx in
            let r = NSFetchRequest<NSManagedObject>(entityName: "DictionaryEntryEntity")
            return try ctx.fetch(r).contains { ($0.value(forKey: "incorrectForm") as? String) == incorrect && ($0.value(forKey: "correctForm") as? String) == correct }
        }
    }

    /// Canonical user-visible content of every synced row, key -> string. Audio is compared separately.
    func state() async throws -> [String: String] {
        var out: [String: String] = [:]
        let rows: [(String, String)] = try await save { ctx in
            var result: [(String, String)] = []
            for o in try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "TranscriptionEntity")) {
                guard let id = o.value(forKey: "id") as? UUID else { continue }
                let f = ["transcription", "editedTranscription", "notes", "isPinned", "isFlagged", "audioFileURL"].map { "\($0)=\(o.value(forKey: $0).map { "\($0)" } ?? "nil")" }.joined(separator: "|")
                result.append(("d:\(id.uuidString)", f))
            }
            for o in try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "MeetingEntity")) {
                guard let id = o.value(forKey: "id") as? UUID else { continue }
                let f = ["title", "segmentsJSON", "aiSummaryJSON", "notesJSON"].map { "\($0)=\(o.value(forKey: $0).map { "\($0)" } ?? "nil")" }.joined(separator: "|")
                result.append(("m:\(id.uuidString)", f))
            }
            for o in try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "DictionaryEntryEntity")) where (o.value(forKey: "isBuiltIn") as? Bool) != true {
                let key = SyncRowStore.dictionaryKey(incorrect: o.value(forKey: "incorrectForm") as? String, correct: o.value(forKey: "correctForm") as? String)
                result.append((key, "notes=\(o.value(forKey: "notes").map { "\($0)" } ?? "nil")"))
            }
            return result
        }
        for (k, v) in rows { out[k] = v }
        if defaults.object(forKey: "bestStreak") != nil { out["s:bestStreak"] = "\(defaults.integer(forKey: "bestStreak"))" }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: meetingData.path)) ?? [] where name.hasSuffix("-chat.json") {
            out["c:" + name.dropLast("-chat.json".count)] = (try? String(contentsOf: meetingData.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        return out
    }

    /// Audio files by row key -> SHA-256 of the bytes.
    func audioDigests() async throws -> [String: String] {
        var out: [String: String] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: recordings.path)) ?? [] {
            guard let data = try? Data(contentsOf: recordings.appendingPathComponent(name)) else { continue }
            out["d:" + (name as NSString).deletingPathExtension] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return out
    }
}
