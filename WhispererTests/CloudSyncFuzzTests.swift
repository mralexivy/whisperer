//
//  CloudSyncFuzzTests.swift
//  WhispererTests
//
//  Seeded fuzz of the whole sync engine: 2-4 virtual devices with in-memory Core Data stacks do random inserts,
//  edits and deletes (dictations, meetings, dictionary words, statistics, chats, audio) with offline windows,
//  injected transport faults, crashes at every checkpoint and restarts, late joiners, clock skew and snapshots.
//
//  Invariants, checked after quiescence:
//   1. every device holds the identical state;
//   2. that state equals what merging every COMMITTED batch yields (no acknowledged write is lost, nothing extra);
//   3. in skew-free runs it also equals the model of "the last write wins, a delete is final";
//   4. a deleted dictation / meeting never reappears, on any device;
//   5. no plaintext marker is ever present in any object the cloud held;
//   6. audio bytes are identical on every device after "download all";
//   7. nothing is left dirty, in the outbox or half-applied.
//
//  Normal run: 50 seeds. Opt in to more:  TEST_RUNNER_CLOUD_FUZZ_RUNS=2000  (and TEST_RUNNER_CLOUD_FUZZ_START=<first seed>).
//

import XCTest
import CoreData
import CryptoKit
@testable import whisperer

enum CloudFuzz {
    struct Model {
        struct Dict { var ins: String; var edit: (tok: String, pinned: Bool)?; var audio: String?; var name: String? }
        var dictations: [String: Dict] = [:]           // key -> live row
        var meetings: [String: String] = [:]           // key -> token
        var deletedUnique = Set<String>()              // d:/m: keys ever deleted
        var words: [String: String] = [:]              // sync key -> notes token
        var chats: [String: String] = [:]
        var best = Int.min
    }

    static let wordPool = [("teh", "the"), ("recieve", "receive"), ("wierd", "weird"), ("definately", "definitely"), ("acommodate", "accommodate"), ("seperate", "separate")]

    static func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func render(dictation m: Model.Dict) -> String {
        let nilStr = "nil"
        return "transcription=ZQSECRET dictation \(m.ins)|editedTranscription=\(m.edit.map { "ZQSECRET edited \($0.tok)" } ?? nilStr)|notes=\(m.edit?.tok ?? m.ins)|isPinned=\((m.edit?.pinned ?? false) ? 1 : 0)|isFlagged=0|audioFileURL=\(m.name ?? nilStr)"
    }
    static func render(meeting tok: String) -> String {
        "title=ZQSECRET meeting \(tok)|segmentsJSON={\"segments\":\"\(tok)\"}|aiSummaryJSON={\"summary\":\"\(tok)\"}|notesJSON={\"notes\":\"\(tok)\"}"
    }

    /// Merge of every committed batch, computed independently of the engine's merge code.
    static func oracle(server: CloudSimServer, ring: CloudKeyRing) throws -> [String: String] {
        var best: [String: (SyncStamp, SyncOp)] = [:]
        var deleted = Set<String>()
        var bestStreak = Int.min
        server.lock.lock(); let log = server.commitLog; let ever = server.ever; let prefix = server.prefix; server.lock.unlock()
        for entry in log {
            guard let blob = ever[entry.name] else { throw SyncError.malformed("committed object missing \(entry.name)") }
            let rel = String(entry.name.dropFirst(prefix.count))
            let ctx = CloudObjectContext(accountId: server.accountId, epoch: UInt64(server.epoch), objectName: rel)
            let plain = try CloudCrypto.decrypt(blob, keyForVersion: { ring.symmetricKey(version: $0) }, context: ctx)
            let payload = try JSONDecoder().decode(SyncBatchPayload.self, from: plain)
            for op in payload.ops where op.aud == nil {
                guard let kind = SyncKind.of(key: op.k) else { continue }
                if op.k == "s:bestStreak" { bestStreak = max(bestStreak, Int(op.row?.objectValue?["v"]?.doubleValue ?? 0)); continue }
                if kind.deleteWins && op.isTombstone { deleted.insert(op.k) }
                if let cur = best[op.k], cur.0 >= op.stamp { continue }
                best[op.k] = (op.stamp, op)
            }
        }
        var out: [String: String] = [:]
        func s(_ v: JSONValue?) -> String {
            switch v { case .string(let x): return x; case .bool(let b): return b ? "1" : "0"; case .number(let n): return "\(Int(n))"; default: return "nil" }
        }
        for (key, (_, op)) in best {
            guard let kind = SyncKind.of(key: key), !op.isTombstone, !(kind.deleteWins && deleted.contains(key)), let row = op.row?.objectValue else { continue }
            switch kind {
            case .dictation:
                out[key] = ["transcription", "editedTranscription", "notes", "isPinned", "isFlagged", "audioFileURL"].map { "\($0)=\(s(row[$0]))" }.joined(separator: "|")
            case .meeting:
                out[key] = ["title", "segmentsJSON", "aiSummaryJSON", "notesJSON"].map { "\($0)=\(s(row[$0]))" }.joined(separator: "|")
            case .dictionary: out[key] = "notes=\(s(row["notes"]))"
            case .chat: if !deleted.contains("m:" + SyncKind.id(ofKey: key)) { out[key] = s(row["b"]) }
            case .stat: break
            }
        }
        if bestStreak != Int.min { out["s:bestStreak"] = "\(bestStreak)" }
        return out
    }

    @MainActor
    static func run(seed: UInt64, steps: Int = 36, tracePath: String? = nil) async -> String? {
        var rng = SplitMix64(seed: seed)
        let skewed = seed % 4 == 3
        let withSnapshots = seed % 3 == 0
        let server = CloudSimServer()
        let clock = SimClock()
        server.serverNow = { clock.date }
        var keyBytes = Data(count: 32); for i in 0..<32 { keyBytes[i] = UInt8(truncatingIfNeeded: Int(seed) &* 31 &+ i &* 7) }
        var ring = CloudKeyRing(); try? ring.insert(keyBytes, version: 1)
        let count = 2 + rng.below(3)
        var devices: [SimDevice] = []
        var joinAt: [Int] = []
        var log: [String] = []
        func note(_ s: String) { log.append(s) }
        do {
            for i in 0..<count {
                let d = try SimDevice(index: i, server: server, clock: clock, ring: ring, tag: "s\(seed)")
                if withSnapshots { d.policy.snapshotAfterBatches = 4 }
                if skewed { d.skewMs = [86_400_000, -86_400_000, 365 * 86_400_000, -365 * 86_400_000][rng.below(4)] }
                devices.append(d)
                joinAt.append(i < 2 ? 0 : 1 + rng.below(steps / 2))
            }
        } catch { return "seed \(seed): setup failed \(error)" }
        defer { for d in devices { d.cleanUp() } }

        var model = Model()
        let skewFree = !skewed
        var audioBytes: [String: Data] = [:]
        var tokenCounter = 0
        func token() -> String { tokenCounter += 1; return "t\(seed)-\(tokenCounter)" }

        for step in 0..<steps {
            clock.advance(Int64(1000 + rng.below(4000)))
            let live = devices.indices.filter { joinAt[$0] <= step }
            guard !live.isEmpty else { continue }
            let d = devices[live[rng.below(live.count)]]
            let r = rng.below(100)
            do {
                switch r {
                case 0..<18:    // new dictation
                    let id = UUID(); let key = "d:\(id.uuidString)"; let tok = token()
                    var audio: Data?
                    if rng.chance(35) { audio = Data("AUDIOMARK-\(tok)-".utf8) + Data((0..<(200 + rng.below(3000))).map { _ in UInt8(truncatingIfNeeded: rng.next()) }) }
                    try await d.insertDictation(id, token: tok, audio: audio)
                    await d.capture()
                    let name = audio == nil ? nil : "\(id.uuidString).opus"
                    model.dictations[key] = .init(ins: tok, edit: nil, audio: audio.map(hex), name: name)
                    if let audio { audioBytes[key] = audio }
                    note("\(step) dev\(d.index) +dictation \(key.suffix(4))")
                case 18..<34:   // edit dictation
                    let ids = try await d.liveIDs("TranscriptionEntity")
                    guard let id = ids.isEmpty ? nil : ids[rng.below(ids.count)] else { continue }
                    let key = "d:\(id.uuidString)"; let tok = token(); let pinned = rng.chance(50)
                    try await d.editDictation(id, token: tok, pinned: pinned)
                    await d.capture()
                    if var row = model.dictations[key], !model.deletedUnique.contains(key) { row.edit = (tok, pinned); model.dictations[key] = row }
                    note("\(step) dev\(d.index) ~dictation \(key.suffix(4))")
                case 34..<42:   // delete dictation
                    let ids = try await d.liveIDs("TranscriptionEntity")
                    guard let id = ids.isEmpty ? nil : ids[rng.below(ids.count)] else { continue }
                    let key = "d:\(id.uuidString)"
                    try await d.deleteDictation(id)
                    await d.capture()
                    model.dictations[key] = nil; model.deletedUnique.insert(key); audioBytes[key] = nil
                    note("\(step) dev\(d.index) -dictation \(key.suffix(4))")
                case 42..<48:   // meeting insert / edit
                    let ids = try await d.liveIDs("MeetingEntity")
                    if ids.isEmpty || rng.chance(40) {
                        let id = UUID(); let tok = token()
                        try await d.insertMeeting(id, token: tok); await d.capture()
                        model.meetings["m:\(id.uuidString)"] = tok
                        note("\(step) dev\(d.index) +meeting")
                    } else {
                        let id = ids[rng.below(ids.count)]; let key = "m:\(id.uuidString)"; let tok = token()
                        try await d.editMeeting(id, token: tok); await d.capture()
                        if model.meetings[key] != nil, !model.deletedUnique.contains(key) { model.meetings[key] = tok }
                        note("\(step) dev\(d.index) ~meeting")
                    }
                case 48..<51:   // meeting delete
                    let ids = try await d.liveIDs("MeetingEntity")
                    guard let id = ids.isEmpty ? nil : ids[rng.below(ids.count)] else { continue }
                    let key = "m:\(id.uuidString)"
                    try await d.deleteMeeting(id); await d.capture()
                    model.meetings[key] = nil; model.deletedUnique.insert(key); model.chats["c:\(id.uuidString)"] = nil
                    note("\(step) dev\(d.index) -meeting")
                case 51..<66:   // dictionary add / edit / delete
                    let (inc, cor) = wordPool[rng.below(wordPool.count)]
                    let key = SyncRowStore.dictionaryKey(incorrect: inc, correct: cor)
                    let has = try await d.hasWord(inc, cor)
                    let tok = token()
                    if !has { try await d.addWord(inc, cor, token: tok); model.words[key] = tok }
                    else if rng.chance(60) { try await d.editWord(inc, cor, token: tok); model.words[key] = tok }
                    else { try await d.deleteWord(inc, cor); model.words[key] = nil }
                    await d.capture()
                    note("\(step) dev\(d.index) word \(inc)")
                case 66..<69:   // statistic
                    let n = (d.defaults.object(forKey: "bestStreak") != nil ? d.defaults.integer(forKey: "bestStreak") : 0) + 1 + rng.below(4)
                    d.defaults.set(n, forKey: "bestStreak"); await d.capture()
                    model.best = max(model.best, n)
                    note("\(step) dev\(d.index) best \(n)")
                case 69..<73:   // chat thread of a meeting this device has
                    let ids = try await d.liveIDs("MeetingEntity")
                    guard let id = ids.isEmpty ? nil : ids[rng.below(ids.count)] else { continue }
                    let tok = token()
                    try d.writeChat(id, body: "ZQSECRET chat \(tok)"); await d.capture()
                    if !model.deletedUnique.contains("m:\(id.uuidString)") { model.chats["c:\(id.uuidString)"] = "ZQSECRET chat \(tok)" }
                    note("\(step) dev\(d.index) chat")
                case 73..<90:   // a sync cycle, maybe with a fault armed first
                    if rng.chance(30) {
                        let tokens = ["crash:after:commit", "crash:before:commit", "crash:after:upload", "drop:commit", "drop:upload", "before:heads",
                                      "drop:requestUploads", "crash:after:download", "drop:download", "crash:before:requestDownloads", "drop:heads"]
                        let hooks = ["afterOutboxWrite", "beforeStoreSave", "afterStoreLanded", "afterStoreSave", "afterBatchMerged", "afterHeads", "afterUpload", "afterCommit", "afterAudioUpload"]
                        if rng.chance(50) { let t = tokens[rng.below(tokens.count)]; d.transport.arm(t); note("arm \(t)") }
                        else { let h = hooks[rng.below(hooks.count)]; d.crash.arm(h); note("arm hook \(h)") }
                    }
                    let ok = await d.cycle(force: rng.chance(60))
                    note("\(step) dev\(d.index) cycle crashed=\(!ok)")
                case 90..<95:   // offline window
                    d.transport.offline.toggle()
                    note("\(step) dev\(d.index) offline=\(d.transport.offline)")
                default:
                    if rng.chance(50) { d.crashAndRestart(); note("\(step) dev\(d.index) restart") }
                    else { d.transport.reorderDownloads.toggle() }
                }
            if ProcessInfo.processInfo.environment["CLOUD_FUZZ_TRACE"] == "1" {
                let wk = ProcessInfo.processInfo.environment["CLOUD_FUZZ_KEY"] ?? "w:5252fd0bb36fcb665e713f9a579c3d0f"
                var line = "T\(step) r=\(r) dev\(d.index):"
                for (i, dv) in devices.enumerated() where joinAt[i] <= step {
                    let has = ((try? await dv.state()) ?? [:])[wk] != nil
                    var led = "-"
                    if let e = dv.engine { let l = await e.ledgerSnapshot(); if let row = l.rows[wk] { led = "\(row.hlc.wall % 1_000_000_000),\(row.hlc.counter)\(row.deleted ? "D" : "L")\(row.dirty ? "*" : "")" } }
                    line += " [d\(i) store=\(has ? 1 : 0) led=\(led)]"
                }
                note(line)
            }
            } catch { return "seed \(seed): step \(step) threw \(error)\n" + log.suffix(12).joined(separator: "\n") }
        }

        // Quiescence: faults off, everyone online, cycle until nothing moves.
        for d in devices { d.transport.clearFaults(); d.crash.clear() }
        var lastVersion: Int64 = -1
        var stable = 0
        for round in 0..<16 {
            clock.advance(60_000)
            for d in devices {
                await d.cycle(force: true)
                if ProcessInfo.processInfo.environment["CLOUD_FUZZ_TRACE"] == "1" {
                    let wk = ProcessInfo.processInfo.environment["CLOUD_FUZZ_KEY"] ?? "w:5252fd0bb36fcb665e713f9a579c3d0f"
                    var line = "Q\(round) dev\(d.index) err=\(d.lastError ?? "-"):"
                    for (i, dv) in devices.enumerated() {
                        let has = ((try? await dv.state()) ?? [:])[wk] != nil
                        var led = "-"
                        if let e = dv.engine { let l = await e.ledgerSnapshot(); if let row = l.rows[wk] { led = "\(row.hlc.wall % 1_000_000_000),\(row.hlc.counter)\(row.deleted ? "D" : "L")\(row.dirty ? "*" : "")" } }
                        line += " [d\(i) store=\(has ? 1 : 0) led=\(led)]"
                    }
                    note(line)
                }
            }
            let v = server.version
            let states = await devices.asyncMap { (try? await $0.state()) ?? [:] }
            let equal = states.dropFirst().allSatisfy { $0 == states[0] }
            let clean = await devices.asyncMap { d -> Bool in
                guard let e = d.engine else { return false }
                let l = await e.ledgerSnapshot(); let ob = await e.outboxEntries()
                return ob.isEmpty && l.pendingApplyKeys.isEmpty && !l.rows.values.contains { $0.dirty }
            }.allSatisfy { $0 }
            if v == lastVersion && equal && clean { stable += 1 } else { stable = 0 }
            lastVersion = v
            if stable >= 2 { break }
            if round == 15 {
                var info: [String] = []
                for (i, d) in devices.enumerated() {
                    if let e = d.engine { let l = await e.ledgerSnapshot(); let ob = await e.outboxEntries()
                        info.append("dev\(i) lastError=\(d.lastError ?? "-") dirty=\(l.rows.filter { $0.value.dirty }.map { $0.key.suffix(6) }) outbox=\(ob.map(\.seq)) committedSeq=\(l.committedSeq) cursors=\(l.cursors) head=\(server.heads[d.id]?.seq ?? 0)") }
                }
                if let k = Set(states[0].keys).union(states.last?.keys ?? [:].keys).first(where: { states[0][$0] != states.last?[$0] }) {
                    info.append("history \(k):\n" + history(server: server, ring: ring, key: k, devices: devices))
                    for (i, d) in devices.enumerated() { if let e = d.engine { let l = await e.ledgerSnapshot(); info.append("dev\(i) ledger=\(String(describing: l.rows[k]))") } }
                }
                return "seed \(seed): did not quiesce (equal=\(equal) clean=\(clean) version=\(v))\n\(info.joined(separator: "\n"))\n\(diff(states[0], states.last ?? [:]))\n" + log.suffix(60).joined(separator: "\n")
            }
        }

        // 1. identical state
        let states = await devices.asyncMap { (try? await $0.state()) ?? [:] }
        for i in 1..<states.count where states[i] != states[0] {
            return "seed \(seed): device \(i) differs from device 0\n\(diff(states[0], states[i]))\n" + log.suffix(15).joined(separator: "\n")
        }
        // 2. equals the merge of committed batches
        do {
            let expected = try oracle(server: server, ring: ring)
            if states[0] != expected { return "seed \(seed): state != committed-merge oracle\n\(diff(states[0], expected))\n" + log.suffix(15).joined(separator: "\n") }
        } catch { return "seed \(seed): oracle failed \(error)" }
        // 3. equals the model (clocks agree)
        if skewFree {
            var expected: [String: String] = [:]
            for (k, v) in model.dictations { expected[k] = render(dictation: v) }
            for (k, v) in model.meetings { expected[k] = render(meeting: v) }
            for (k, v) in model.words { expected[k] = "notes=\(v)" }
            for (k, v) in model.chats { expected[k] = v }
            if model.best != Int.min { expected["s:bestStreak"] = "\(model.best)" }
            // A chat of a deleted meeting is not tracked by the model's meeting list; chats are independent keys.
            if states[0] != expected {
                let keys = Set(states[0].keys).union(expected.keys).filter { states[0][$0] != expected[$0] }.sorted()
                let hist = keys.prefix(2).map { "\($0):\n" + history(server: server, ring: ring, key: $0, devices: devices) }.joined(separator: "\n")
                var rowsInfo: [String] = []
                for (i, d) in devices.enumerated() { if let e = d.engine, let k = keys.first { let l = await e.ledgerSnapshot(); rowsInfo.append("dev\(i) ledger[\(k.suffix(6))]=\(String(describing: l.rows[k])) committedSeq=\(l.committedSeq) cursors=\(l.cursors)") } }
                return "seed \(seed): state != model\n\(diff(states[0], expected))\n\(hist)\n\(rowsInfo.joined(separator: "\n"))\n" + log.suffix(40).joined(separator: "\n")
            }
        }
        // 4. deletions are final
        for key in model.deletedUnique where states[0][key] != nil { return "seed \(seed): deleted row \(key) came back" }
        // 5. nothing readable on the wire
        for (name, blob) in server.ever {
            for marker in ["ZQSECRET", "AUDIOMARK"] where blob.range(of: Data(marker.utf8)) != nil { return "seed \(seed): plaintext marker \(marker) in \(name)" }
        }
        // 6. audio is identical everywhere after "download all"
        for d in devices { _ = try? await d.currentEngine().downloadAllAudio() }
        let digests = try? await devices.asyncMap { try await $0.audioDigests() }
        if let digests {
            for (i, dig) in digests.enumerated() {
                for (key, row) in model.dictations where row.audio != nil && states[0][key] != nil {
                    if dig[key] != row.audio { return "seed \(seed): device \(i) audio for \(key) is \(dig[key] ?? "missing"), expected \(row.audio!)" }
                }
            }
        }
        if let tracePath { try? log.joined(separator: "\n").write(toFile: tracePath, atomically: true, encoding: .utf8) }
        return nil
    }

    static func diff(_ a: [String: String], _ b: [String: String]) -> String {
        var lines: [String] = []
        for k in Set(a.keys).union(b.keys).sorted() where a[k] != b[k] {
            lines.append("  \(k): \(a[k] ?? "<absent>")  vs  \(b[k] ?? "<absent>")")
            if lines.count >= 8 { break }
        }
        return lines.joined(separator: "\n")
    }
}

extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for e in self { out.append(try await transform(e)) }
        return out
    }
}

@MainActor
final class CloudSyncFuzzTests: XCTestCase {
    func testSeededFuzz() async throws {
        let env = ProcessInfo.processInfo.environment
        let runs = Int(env["CLOUD_FUZZ_RUNS"] ?? "") ?? 50
        let start = UInt64(env["CLOUD_FUZZ_START"] ?? "") ?? 1
        var failures: [String] = []
        var ran = 0
        let began = Date()
        for seed in start..<(start + UInt64(runs)) {
            try? "\(seed)".write(toFile: "/tmp/dd-sync-fuzz-progress.txt", atomically: true, encoding: .utf8)
            if let failure = await CloudFuzz.run(seed: seed) { failures.append(failure); if failures.count >= 3 { break } }
            ran += 1
        }
        let summary = "CLOUD_FUZZ seeds run: \(ran) (start \(start)), failures: \(failures.count), seconds: \(Int(Date().timeIntervalSince(began)))"
        NSLog("%@", summary)
        try? (summary + "\n" + failures.joined(separator: "\n---\n")).write(toFile: "/tmp/dd-sync-fuzz-result-\(start).txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(failures.isEmpty, "\(summary)\n" + failures.joined(separator: "\n---\n"))
    }
}

extension CloudFuzz {
    /// Every committed op for a key, with its stamp — for failure reports.
    static func history(server: CloudSimServer, ring: CloudKeyRing, key: String, devices: [SimDevice]) -> String {
        server.lock.lock(); let log = server.commitLog; let ever = server.ever; let prefix = server.prefix; server.lock.unlock()
        var lines: [String] = []
        for entry in log {
            guard let blob = ever[entry.name] else { continue }
            let ctx = CloudObjectContext(accountId: server.accountId, epoch: UInt64(server.epoch), objectName: String(entry.name.dropFirst(prefix.count)))
            guard let plain = try? CloudCrypto.decrypt(blob, keyForVersion: { ring.symmetricKey(version: $0) }, context: ctx),
                  let payload = try? JSONDecoder().decode(SyncBatchPayload.self, from: plain) else { continue }
            let dev = devices.firstIndex { $0.id == entry.device } ?? -1
            for op in payload.ops where op.k == key {
                lines.append("  dev\(dev) seq\(entry.seq) stamp(\(op.w),\(op.c)) \(op.isTombstone ? "DEL" : (op.aud != nil ? "AUD" : "UPSERT \(op.row?.objectValue?["notes"]?.stringValue ?? "")"))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
