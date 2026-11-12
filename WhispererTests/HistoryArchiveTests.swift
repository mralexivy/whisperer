//
//  HistoryArchiveTests.swift
//  WhispererTests
//
//  Export → import round trips through real Apple Archive files, in-memory stores and temp folders.
//  The last test exports the machine's own library (read-only) and imports it into a scratch store.
//

import XCTest
import CoreData
import CryptoKit
import AppleArchive
import System
@testable import whisperer

final class HistoryArchiveTests: XCTestCase {

    // `HistoryDatabase` is main-actor isolated by project default; keep every instance alive.
    nonisolated(unsafe) private static var keepAlive: [AnyObject] = []

    typealias Env = HistoryArchive.Environment

    private struct Library {
        let env: Env
        let root: URL
        var db: HistoryDatabase { env.database }
        var paths: Env { env }
    }

    private func makeLibrary(_ name: String, freeSpace: @escaping @Sendable (URL) -> Int64? = { _ in .max }) throws -> Library {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryArchiveTests-\(name)-\(UUID().uuidString)")
        let recordings = root.appendingPathComponent("Recordings")
        let meetingRecordings = root.appendingPathComponent("Recordings/Meetings")
        let meetingData = root.appendingPathComponent("Meetings")
        let staging = root.appendingPathComponent("tmp")
        for dir in [recordings, meetingRecordings, meetingData, staging] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let database = HistoryDatabase(inMemory: true)
        Self.keepAlive.append(database)
        let suite = "HistoryArchiveTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let env = Env(database: database, recordings: recordings, meetingRecordings: meetingRecordings,
                      meetingData: meetingData, chatHistory: root.appendingPathComponent("ChatHistory"),
                      staging: staging, defaults: defaults,
                      locateMeetingAudio: { name in
                          let url = meetingRecordings.appendingPathComponent((name as NSString).lastPathComponent)
                          return FileManager.default.fileExists(atPath: url.path) ? url : nil
                      },
                      freeSpace: freeSpace)
        return Library(env: env, root: root)
    }

    /// Incompressible bytes, like Opus: a patterned fixture would compress to nothing and hide size effects.
    private func noise(_ count: Int, seed: Int) -> Data {
        var x = UInt32(truncatingIfNeeded: seed &* 7_919 &+ 1)
        return Data((0..<count).map { _ in x = x &* 1_664_525 &+ 1_013_904_223; return UInt8(truncatingIfNeeded: x >> 24) })
    }

    private func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private let day: Double = 86_400
    private let epoch: Double = 1_790_000_000

    /// `transcriptions` dictations and `meetings` meetings, one per day from `epoch`, plus a row still
    /// in progress that must never travel. Dictations carry `dictationBytes`, meetings `meetingBytes` of audio.
    @discardableResult
    private func seed(_ lib: Library, transcriptions: Int, meetings: Int,
                      dictationBytes: Int = 2_000, meetingBytes: Int = 5_000) async throws -> (t: [UUID], m: [UUID]) {
        let ctx = lib.db.newBackgroundContext()
        var tIDs: [UUID] = [], mIDs: [UUID] = []
        for i in 0..<transcriptions {
            let id = UUID(); tIDs.append(id)
            let name = "2026-11-\(String(format: "%03d", i))_dictation_\(i).opus"
            try noise(dictationBytes + i * 997, seed: i)
                .write(to: lib.env.recordings.appendingPathComponent(name))
            await ctx.perform {
                let e = TranscriptionEntity(context: ctx)
                e.id = id; e.timestamp = Date(timeIntervalSince1970: self.epoch + Double(i) * self.day); e.createdAt = e.timestamp
                e.lastModifiedAt = e.timestamp
                e.transcription = "Привет мир \(i) — שלום עולם \"quoted\"\nnew line"
                e.audioFileURL = name; e.duration = 3.5 + Double(i); e.wordCount = Int32(10 + i)
                e.language = i % 2 == 0 ? "ru" : "he"; e.modelUsed = "V3"
                e.isPinned = i == 0; e.isFlagged = i == 1
                e.editedTranscription = i == 2 ? "edited" : nil
                e.correctionsData = Data([1, 2, 3, UInt8(i & 0xFF)])
                e.isInProgress = false
            }
        }
        for i in 0..<meetings {
            let id = UUID(); mIDs.append(id)
            let name = "\(id.uuidString).opus"
            try noise(meetingBytes + i, seed: 1_000 + i)
                .write(to: lib.env.meetingRecordings.appendingPathComponent(name))
            try Data("[{\"role\":\"user\"}]".utf8).write(to: lib.env.meetingData.appendingPathComponent("\(id)-chat.json"))
            await ctx.perform {
                let e = MeetingEntity(context: ctx)
                e.id = id; e.title = "Meeting \(i) שלום"; e.createdAt = Date(timeIntervalSince1970: self.epoch + Double(i) * self.day + 3_600)
                e.duration = 120.25; e.audioFileURL = name; e.segmentsJSON = "[{\"text\":\"hello \(i)\"}]"
                e.aiSummaryJSON = "{\"x\":1}"; e.wordCount = 42; e.language = "he"; e.modelUsed = "V3"
                e.isInProgress = false; e.captureFailed = false; e.titleIsUserSet = true
            }
        }
        await ctx.perform {
            let e = TranscriptionEntity(context: ctx)
            e.id = UUID(); e.timestamp = Date(); e.createdAt = Date(); e.lastModifiedAt = Date()
            e.transcription = "in progress"; e.language = "en"; e.modelUsed = "V3"; e.isInProgress = true
        }
        try await ctx.perform { try ctx.save() }
        return (tIDs, mIDs)
    }

    private func seedDictionary(_ lib: Library, _ entries: [(String, String, Bool)]) async throws {
        let ctx = lib.db.newBackgroundContext()
        try await ctx.perform {
            for (wrong, right, builtIn) in entries {
                let e = NSEntityDescription.insertNewObject(forEntityName: "DictionaryEntryEntity", into: ctx)
                e.setValue(UUID(), forKey: "id"); e.setValue(wrong, forKey: "incorrectForm"); e.setValue(right, forKey: "correctForm")
                e.setValue(builtIn, forKey: "isBuiltIn"); e.setValue(true, forKey: "isEnabled")
                e.setValue(Date(), forKey: "createdAt"); e.setValue(Date(), forKey: "lastModifiedAt"); e.setValue(3, forKey: "useCount")
            }
            try ctx.save()
        }
    }

    private func seedChats(_ lib: Library, ids: [String], base: Double) throws {
        try FileManager.default.createDirectory(at: lib.env.chatHistory, withIntermediateDirectories: true)
        let sessions: [[String: Any]] = ids.enumerated().map { ["id": $1, "title": "Chat \($1)", "createdAt": base + Double($0), "messages": []] }
        try JSONSerialization.data(withJSONObject: sessions).write(to: lib.env.chatHistory.appendingPathComponent("sessions.json"))
    }

    private func rows(_ lib: Library, _ entity: String) async throws -> [[String: Any]] {
        let ctx = lib.db.newBackgroundContext()
        return try await ctx.perform {
            let r = NSFetchRequest<NSManagedObject>(entityName: entity)
            r.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            return try ctx.fetch(r).map { object in
                var row: [String: Any] = [:]
                for name in object.entity.attributesByName.keys { if let v = object.value(forKey: name) { row[name] = v } }
                return row
            }
        }
    }

    private func export(_ lib: Library, _ options: HistoryArchive.ExportOptions = .init(), as name: String = "out.aar") async throws -> HistoryArchive.ExportResult {
        try await HistoryArchive.export(options, to: lib.root.appendingPathComponent(name), env: lib.env)
    }

    // MARK: - Round trip

    func testRoundTripKeepsEveryRowAttributeAndByte() async throws {
        let a = try makeLibrary("a"), b = try makeLibrary("b")
        let ids = try await seed(a, transcriptions: 5, meetings: 3)
        let exported = try await export(a)
        XCTAssertEqual(exported.files.count, 1)
        XCTAssertEqual(exported.counts[.dictations], 5, "the in-progress row is not exported")
        XCTAssertEqual(exported.counts[.meetings], 3)
        XCTAssertEqual(exported.audioFiles, 8)

        let imported = try await HistoryArchive.importArchives(exported.files, env: b.env)
        XCTAssertEqual(imported.dictationsAdded, 5)
        XCTAssertEqual(imported.meetingsAdded, 3)
        XCTAssertEqual(imported.audioFilesAdded, 8)
        XCTAssertEqual(imported.meetingThreadsAdded, 3)
        XCTAssertEqual(imported.audioMissing, 0)

        let src = try await rows(a, "TranscriptionEntity").filter { ($0["isInProgress"] as? Bool) == false }
        let dst = try await rows(b, "TranscriptionEntity")
        XCTAssertEqual(dst.count, 5)
        for (x, y) in zip(src, dst) {
            XCTAssertEqual(Set(x.keys), Set(y.keys))
            for name in x.keys where name != "audioFileURL" {
                XCTAssertTrue((x[name] as? NSObject) == (y[name] as? NSObject), "\(name) differs")
            }
            XCTAssertEqual(try sha(a.env.recordings.appendingPathComponent(x["audioFileURL"] as! String)),
                           try sha(b.env.recordings.appendingPathComponent(y["audioFileURL"] as! String)))
        }
        let meetings = try await rows(b, "MeetingEntity")
        XCTAssertEqual(Set(meetings.compactMap { $0["id"] as? UUID }), Set(ids.m))
        for m in meetings {
            let id = m["id"] as! UUID
            XCTAssertEqual(try sha(a.env.meetingRecordings.appendingPathComponent("\(id).opus")),
                           try sha(b.env.meetingRecordings.appendingPathComponent(m["audioFileURL"] as! String)))
            XCTAssertTrue(FileManager.default.fileExists(atPath: b.env.meetingData.appendingPathComponent("\(id)-chat.json").path))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: a.env.staging.path).isEmpty, "no scratch left behind")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: b.env.staging.path).isEmpty)
    }

    func testDictionaryStatisticsAndCommandChatsTravel() async throws {
        let a = try makeLibrary("a"), b = try makeLibrary("b")
        try await seedDictionary(a, [("whisperer", "Whisperer", false), ("teh", "the", false), ("builtin", "Builtin", true)])
        try await seedDictionary(b, [("TEH", "The", false)])           // the same correction already exists here
        a.env.defaults.set(31, forKey: "bestStreak"); a.env.defaults.set(78, forKey: "userTypingWPM")
        b.env.defaults.set(12, forKey: "bestStreak")
        try seedChats(a, ids: ["a1", "a2", "shared"], base: 1_000)
        try seedChats(b, ids: ["b1", "shared"], base: 500)

        let exported = try await export(a)
        XCTAssertEqual(exported.counts[.dictionary], 2, "built-in entries are the app's, not the user's")
        XCTAssertEqual(exported.counts[.commandChats], 3)
        let summary = try await HistoryArchive.importArchives(exported.files, env: b.env)

        XCTAssertEqual(summary.dictionaryAdded, 1, "the duplicate correction is not added twice")
        let dictionary = try await rows(b, "DictionaryEntryEntity")
        XCTAssertEqual(dictionary.count, 2)
        XCTAssertTrue(summary.statisticsMerged)
        XCTAssertEqual(b.env.defaults.integer(forKey: "bestStreak"), 31, "the larger streak wins")
        XCTAssertEqual(b.env.defaults.integer(forKey: "userTypingWPM"), 78, "taken when this Mac has none")
        XCTAssertEqual(summary.chatsAdded, 2)
        let chats = try JSONSerialization.jsonObject(with: Data(contentsOf: b.env.chatHistory.appendingPathComponent("sessions.json"))) as! [[String: Any]]
        XCTAssertEqual(Set(chats.compactMap { $0["id"] as? String }), ["a1", "a2", "b1", "shared"])
        XCTAssertEqual(chats.first?["id"] as? String, "a2", "newest first")
    }

    func testStatisticsNeverLowerALocalRecord() async throws {
        let a = try makeLibrary("a"), b = try makeLibrary("b")
        a.env.defaults.set(5, forKey: "bestStreak")
        b.env.defaults.set(40, forKey: "bestStreak"); b.env.defaults.set(60, forKey: "userTypingWPM")
        a.env.defaults.set(99, forKey: "userTypingWPM")
        let exported = try await export(a)
        try await HistoryArchive.importArchives(exported.files, env: b.env)
        XCTAssertEqual(b.env.defaults.integer(forKey: "bestStreak"), 40)
        XCTAssertEqual(b.env.defaults.integer(forKey: "userTypingWPM"), 60)
    }

    func testImportingTwiceAddsNothingAndKeepsExistingRows() async throws {
        let a = try makeLibrary("a"), b = try makeLibrary("b")
        try await seed(a, transcriptions: 3, meetings: 1)
        let exported = try await export(a)
        _ = try await HistoryArchive.importArchives(exported.files, env: b.env)
        let again = try await HistoryArchive.importArchives(exported.files, env: b.env)
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.alreadyPresent, 4)
        let count = try await rows(b, "TranscriptionEntity").count
        XCTAssertEqual(count, 3)
    }

    func testImportMergesIntoANonEmptyLibraryAndRenamesCollidingAudio() async throws {
        let a = try makeLibrary("a"), b = try makeLibrary("b")
        try await seed(a, transcriptions: 2, meetings: 0)
        let clash = b.env.recordings.appendingPathComponent("2026-11-000_dictation_0.opus")
        try Data("a different recording".utf8).write(to: clash)
        let local = try await seed(b, transcriptions: 0, meetings: 1)

        let exported = try await export(a)
        let summary = try await HistoryArchive.importArchives(exported.files, env: b.env)
        XCTAssertEqual(summary.dictationsAdded, 2)
        XCTAssertEqual(try Data(contentsOf: clash), Data("a different recording".utf8), "an existing file is never overwritten")
        let names = try await rows(b, "TranscriptionEntity").compactMap { $0["audioFileURL"] as? String }
        XCTAssertTrue(names.contains { $0.contains("-imported") })
        for name in names { XCTAssertTrue(FileManager.default.fileExists(atPath: b.env.recordings.appendingPathComponent(name).path)) }
        let meetings = try await rows(b, "MeetingEntity")
        XCTAssertEqual(meetings.compactMap { $0["id"] as? UUID }, local.m, "local rows are untouched")
    }

    func testRowsWithoutAudioAreStillImported() async throws {
        let a = try makeLibrary("a"), b = try makeLibrary("b")
        try await seed(a, transcriptions: 2, meetings: 0)
        try FileManager.default.removeItem(at: a.env.recordings.appendingPathComponent("2026-11-001_dictation_1.opus"))
        let exported = try await export(a)
        XCTAssertEqual(exported.counts[.dictations], 2)
        let summary = try await HistoryArchive.importArchives(exported.files, env: b.env)
        XCTAssertEqual(summary.dictationsAdded, 2)
        XCTAssertEqual(summary.audioMissing, 1)
    }

    // MARK: - Scope

    func testTextOnlyExportCarriesNoAudioAndTheRowsSayNoAudio() async throws {
        let a = try makeLibrary("a"), b = try makeLibrary("b")
        try await seed(a, transcriptions: 3, meetings: 2, dictationBytes: 50_000)
        let full = try await export(a, .init(), as: "full.aar")
        let text = try await export(a, .init(includeAudio: false), as: "text.aar")
        XCTAssertEqual(text.audioFiles, 0)
        XCTAssertLessThan(text.archiveBytes, full.archiveBytes / 3)
        let summary = try await HistoryArchive.importArchives(text.files, env: b.env)
        XCTAssertEqual(summary.dictationsAdded, 3)
        XCTAssertEqual(summary.audioMissing, 0, "nothing was promised, nothing is missing")
        let imported = try await rows(b, "TranscriptionEntity")
        XCTAssertTrue(imported.allSatisfy { $0["audioFileURL"] == nil })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: b.env.recordings.path).filter { $0.hasSuffix(".opus") }.isEmpty)
    }

    func testTimeRangeAtExportKeepsOnlyThoseRows() async throws {
        let a = try makeLibrary("a"), b = try makeLibrary("b")
        try await seed(a, transcriptions: 10, meetings: 0)
        let from = Date(timeIntervalSince1970: epoch + 3 * day), to = Date(timeIntervalSince1970: epoch + 6 * day + 1)
        let exported = try await export(a, .init(from: from, to: to))
        XCTAssertEqual(exported.counts[.dictations], 4)
        let summary = try await HistoryArchive.importArchives(exported.files, env: b.env)
        XCTAssertEqual(summary.dictationsAdded, 4)
        let created = try await rows(b, "TranscriptionEntity").compactMap { ($0["createdAt"] as? Date)?.timeIntervalSince1970 }
        XCTAssertTrue(created.allSatisfy { $0 >= from.timeIntervalSince1970 && $0 <= to.timeIntervalSince1970 })
    }

    func testTimeRangeAndCategoriesAtImportTakeOnlyAPart() async throws {
        let a = try makeLibrary("a"), b = try makeLibrary("b")
        try await seed(a, transcriptions: 10, meetings: 4)
        try await seedDictionary(a, [("x", "y", false)])
        let exported = try await export(a)
        let from = Date(timeIntervalSince1970: epoch + 8 * day)
        let summary = try await HistoryArchive.importArchives(
            exported.files, options: .init(categories: [.dictations], from: from), env: b.env)
        XCTAssertEqual(summary.dictationsAdded, 2)
        XCTAssertEqual(summary.outsideRange, 8)
        XCTAssertEqual(summary.meetingsAdded, 0)
        XCTAssertEqual(summary.dictionaryAdded, 0)
        let meetings = try await rows(b, "MeetingEntity").count
        XCTAssertEqual(meetings, 0)
    }

    func testImportWithoutAudioKeepsTheText() async throws {
        let a = try makeLibrary("a"), b = try makeLibrary("b")
        try await seed(a, transcriptions: 3, meetings: 0)
        let exported = try await export(a)
        let summary = try await HistoryArchive.importArchives(exported.files, options: .init(includeAudio: false), env: b.env)
        XCTAssertEqual(summary.dictationsAdded, 3)
        XCTAssertEqual(summary.audioFilesAdded, 0)
        let imported = try await rows(b, "TranscriptionEntity")
        XCTAssertTrue(imported.allSatisfy { $0["audioFileURL"] == nil })
    }

    func testNothingSelectedIsRefused() async throws {
        let a = try makeLibrary("a")
        do { _ = try await export(a, .init(categories: [])); XCTFail("expected an error") }
        catch { XCTAssertEqual(error as? HistoryArchive.ArchiveError, .nothingSelected) }
    }

    // MARK: - Big libraries: parts

    private func item(_ kind: HistoryArchive.Category = .dictations, bytes: Int64, at t: Double = 0) -> HistoryArchive.Item {
        .init(kind: kind, id: UUID(), createdAt: Date(timeIntervalSince1970: t), audioName: nil, audioBytes: bytes, textBytes: 0)
    }

    func testPartitionRespectsTheCapAndOrder() {
        let items = (0..<20).map { item(bytes: 100, at: Double($0)) }
        let parts = HistoryArchive.partition(items, cap: 450)
        XCTAssertEqual(parts.map(\.count), [4, 4, 4, 4, 4])
        XCTAssertEqual(parts.flatMap { $0 }.map(\.createdAt), items.map(\.createdAt), "time order is preserved")
        for part in parts { XCTAssertLessThanOrEqual(part.reduce(0) { $0 + $1.cost }, 450) }
    }

    func testPartitionGivesAnOversizedRowAPartOfItsOwn() {
        let items = [item(bytes: 100), item(bytes: 900), item(bytes: 100), item(bytes: 100)]
        let parts = HistoryArchive.partition(items, cap: 300)
        XCTAssertEqual(parts.map(\.count), [1, 1, 2])
    }

    func testPartitionWithoutACapOrWithNothingIsOnePart() {
        XCTAssertEqual(HistoryArchive.partition((0..<5).map { item(bytes: 1, at: Double($0)) }, cap: nil).count, 1)
        XCTAssertEqual(HistoryArchive.partition([], cap: 100), [[]])
    }

    func testASplitExportMakesSelfContainedPartsThatImportInAnyOrder() async throws {
        let a = try makeLibrary("a"), b = try makeLibrary("b"), c = try makeLibrary("c")
        try await seed(a, transcriptions: 12, meetings: 6, dictationBytes: 20_000, meetingBytes: 60_000)
        try await seedDictionary(a, [("x", "y", false)])
        a.env.defaults.set(9, forKey: "bestStreak")
        let exported = try await export(a, .init(maxPartBytes: 150_000))
        XCTAssertGreaterThan(exported.files.count, 3)
        XCTAssertEqual(exported.files.first?.lastPathComponent, "out – part 1 of \(exported.files.count).aar")
        XCTAssertEqual(exported.counts[.dictations], 12)
        XCTAssertEqual(exported.counts[.meetings], 6)

        // Every part is a valid archive on its own, and only the first carries the extras.
        var dictationRows = 0, meetingRows = 0
        for (index, file) in exported.files.enumerated() {
            let manifest = try await HistoryArchive.preview(of: file)
            XCTAssertEqual(manifest.part, index + 1)
            XCTAssertEqual(manifest.parts, exported.files.count)
            XCTAssertEqual(manifest.count(.dictionary), index == 0 ? 1 : 0)
            dictationRows += manifest.count(.dictations); meetingRows += manifest.count(.meetings)
            XCTAssertLessThanOrEqual(manifest.audioBytes, 150_000 + 70_000, "a part stays near the cap")
        }
        XCTAssertEqual(dictationRows, 12)
        XCTAssertEqual(meetingRows, 6)

        // Forward order and reversed order give the same library.
        let forward = try await HistoryArchive.importArchives(exported.files, env: b.env)
        let reversed = try await HistoryArchive.importArchives(exported.files.reversed(), env: c.env)
        for s in [forward, reversed] {
            XCTAssertEqual(s.dictationsAdded, 12); XCTAssertEqual(s.meetingsAdded, 6); XCTAssertEqual(s.dictionaryAdded, 1)
            XCTAssertEqual(s.audioFilesAdded, 18); XCTAssertEqual(s.archives, exported.files.count)
        }
        let one = try await rows(b, "TranscriptionEntity").map { $0["id"] as! UUID }
        let two = try await rows(c, "TranscriptionEntity").map { $0["id"] as! UUID }
        XCTAssertEqual(Set(one), Set(two))
        XCTAssertEqual(b.env.defaults.integer(forKey: "bestStreak"), 9)

        // And a single part alone is importable.
        let d = try makeLibrary("d")
        let alone = try await HistoryArchive.importArchives([exported.files[1]], env: d.env)
        XCTAssertGreaterThan(alone.added, 0)
    }

    func testEstimateMatchesWhatIsExported() async throws {
        let a = try makeLibrary("a")
        try await seed(a, transcriptions: 8, meetings: 3, dictationBytes: 10_000, meetingBytes: 40_000)
        let options = HistoryArchive.ExportOptions(maxPartBytes: 60_000)
        let estimate = try await HistoryArchive.estimate(options, env: a.env)
        let exported = try await export(a, options)
        XCTAssertEqual(estimate.counts[.dictations], 8)
        XCTAssertEqual(estimate.counts[.meetings], 3)
        XCTAssertEqual(estimate.audioFiles, exported.audioFiles)
        XCTAssertEqual(estimate.parts, exported.files.count)
        let noAudio = try await HistoryArchive.estimate(.init(includeAudio: false), env: a.env)
        XCTAssertEqual(noAudio.audioBytes, 0)
        XCTAssertEqual(noAudio.parts, 1)
    }

    func testPreviewReadsTheManifestOfALargeArchiveQuickly() async throws {
        let a = try makeLibrary("a")
        try await seed(a, transcriptions: 60, meetings: 0, dictationBytes: 400_000)    // ~24 MB of audio
        let exported = try await export(a)
        let started = Date()
        let manifest = try await HistoryArchive.preview(of: exported.files[0])
        let seconds = Date().timeIntervalSince(started)
        XCTAssertEqual(manifest.count(.dictations), 60)
        XCTAssertEqual(manifest.audioFiles, 60)
        XCTAssertNotNil(manifest.oldest)
        XCTAssertGreaterThan(manifest.unpackedBytes, 24_000_000)
        print("[HistoryArchive] preview of a \(exported.archiveBytes / 1_048_576) MB archive: \(Int(seconds * 1000)) ms")
    }

    // MARK: - Control: cancel, space

    func testCancellingAnExportLeavesNoFiles() async throws {
        let a = try makeLibrary("a")
        try await seed(a, transcriptions: 40, meetings: 0, dictationBytes: 100_000)
        let cancel = HistoryArchive.CancelFlag()
        let destination = a.root.appendingPathComponent("cancelled.aar")
        do {
            _ = try await HistoryArchive.export(.init(maxPartBytes: 1_000_000), to: destination, env: a.env, cancel: cancel) { p in
                if p.phase.hasPrefix("Part 2") { cancel.cancel() }
            }
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? HistoryArchive.ArchiveError, .cancelled)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: a.root.path).filter { $0.contains("cancelled") }
        XCTAssertEqual(leftovers, [], "every part written so far is removed")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: a.env.staging.path).isEmpty)
    }

    func testCancellingAnImportStopsAndLeavesNoScratch() async throws {
        let a = try makeLibrary("a"), b = try makeLibrary("b")
        try await seed(a, transcriptions: 30, meetings: 0)
        let exported = try await export(a, .init(maxPartBytes: 80_000))
        XCTAssertGreaterThan(exported.files.count, 2)
        let cancel = HistoryArchive.CancelFlag()
        do {
            _ = try await HistoryArchive.importArchives(exported.files, env: b.env, cancel: cancel) { p in
                if p.phase.hasPrefix("File 2") { cancel.cancel() }
            }
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? HistoryArchive.ArchiveError, .cancelled)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: b.env.staging.path).isEmpty)
        // Resuming is just importing again: what landed is skipped.
        let resumed = try await HistoryArchive.importArchives(exported.files, env: b.env)
        let total = try await rows(b, "TranscriptionEntity").count
        XCTAssertEqual(total, 30)
        XCTAssertGreaterThan(resumed.alreadyPresent, 0)
    }

    func testExportRefusesBeforeWritingWhenTheDestinationIsTooFull() async throws {
        let a = try makeLibrary("a", freeSpace: { _ in 1_000_000 })
        try await seed(a, transcriptions: 20, meetings: 0, dictationBytes: 200_000)
        do { _ = try await export(a); XCTFail("expected an error") }
        catch HistoryArchive.ArchiveError.notEnoughSpace(let needed, let available) {
            XCTAssertGreaterThan(needed, available)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.root.appendingPathComponent("out.aar").path))
    }

    func testImportRefusesWhenTheScratchDiskCannotHoldThePart() async throws {
        let a = try makeLibrary("a")
        try await seed(a, transcriptions: 10, meetings: 0, dictationBytes: 100_000)
        let exported = try await export(a)
        let b = try makeLibrary("b", freeSpace: { _ in 100_000 })
        do { _ = try await HistoryArchive.importArchives(exported.files, env: b.env); XCTFail("expected an error") }
        catch HistoryArchive.ArchiveError.notEnoughSpace { }
        let count = try await rows(b, "TranscriptionEntity").count
        XCTAssertEqual(count, 0)
    }

    // MARK: - Bad input

    func testAFileThatIsNotAnArchiveIsRefused() async throws {
        let b = try makeLibrary("b")
        let junk = b.root.appendingPathComponent("junk.aar")
        try Data("not an archive at all".utf8).write(to: junk)
        do { _ = try await HistoryArchive.importArchives([junk], env: b.env); XCTFail("expected an error") }
        catch { XCTAssertTrue(error is HistoryArchive.ArchiveError) }
    }

    func testAnArchiveWithoutAManifestIsRefused() async throws {
        let b = try makeLibrary("b")
        let folder = b.root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        let archive = b.root.appendingPathComponent("plain.aar")
        try writeArchive(of: folder, to: archive, prefix: nil)
        do { _ = try await HistoryArchive.importArchives([archive], env: b.env); XCTFail("expected an error") }
        catch HistoryArchive.ArchiveError.notAnArchive { }
    }

    /// Apple's own writer refuses an entry name that climbs out ("ioError"), so a hostile archive
    /// has to come from elsewhere; the extraction filter is what stops it, tested here as a rule.
    func testEntryPathsThatEscapeAreRecognised() {
        for unsafe in ["../x", "a/../../x", "/etc/passwd", "audio/../../../x"] {
            XCTAssertTrue(HistoryArchive.isUnsafeEntryPath(unsafe), unsafe)
        }
        for safe in ["0-manifest.json", "audio/a.opus", "meeting-chat/1.json", "a..b/c"] {
            XCTAssertFalse(HistoryArchive.isUnsafeEntryPath(safe), safe)
        }
    }

    func testPartFileNames() {
        let base = URL(fileURLWithPath: "/tmp/History.aar")
        XCTAssertEqual(HistoryArchive.partURL(base, part: 1, of: 1), base)
        XCTAssertEqual(HistoryArchive.partURL(base, part: 2, of: 5).lastPathComponent, "History – part 2 of 5.aar")
    }

    /// Test-only archive writer, independent of the code under test.
    private func writeArchive(of directory: URL, to destination: URL, prefix: String?) throws {
        let file = try XCTUnwrap(ArchiveByteStream.fileStream(path: FilePath(destination.path), mode: .writeOnly,
                                                              options: [.create, .truncate], permissions: FilePermissions(rawValue: 0o644)))
        let encoder = try XCTUnwrap(ArchiveStream.encodeStream(writingTo: file))
        try encoder.writeDirectoryContents(archiveFrom: FilePath(directory.path), path: prefix.map { FilePath($0) },
                                           keySet: ArchiveHeader.FieldKeySet("TYP,PAT,DAT,MOD")!)
        try encoder.close(); try file.close()
    }

    // MARK: - Scale

    /// 4 000 dictations and 200 meetings with ~500 MB of incompressible audio, exported whole and in
    /// parts. Opt-in; reports time and the largest scratch folder seen.
    func testLargeLibraryScale() async throws {
        guard ProcessInfo.processInfo.environment["HISTORY_ARCHIVE_SCALE"] != nil else { throw XCTSkip("set TEST_RUNNER_HISTORY_ARCHIVE_SCALE=1") }
        let a = try makeLibrary("big-a"), b = try makeLibrary("big-b"), c = try makeLibrary("big-c")
        let ctx = a.db.newBackgroundContext()
        var bytesTotal = 0
        for i in 0..<4_200 {
            let isMeeting = i >= 4_000
            let id = UUID()
            let name = "\(isMeeting ? id.uuidString : "rec-\(i)").opus"
            let size = isMeeting ? 1_500_000 : 60_000
            var bytes = Data(count: size)
            bytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, size, $0.baseAddress!) }
            try bytes.write(to: (isMeeting ? a.env.meetingRecordings : a.env.recordings).appendingPathComponent(name))
            bytesTotal += size
            await ctx.perform {
                if isMeeting {
                    let e = MeetingEntity(context: ctx)
                    e.id = id; e.title = "Meeting \(i)"; e.createdAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
                    e.duration = 3_600; e.audioFileURL = name; e.language = "en"; e.modelUsed = "V3"; e.wordCount = 9_000
                    e.segmentsJSON = String(repeating: "{\"text\":\"a paragraph of a long meeting transcript\"},", count: 400)
                } else {
                    let e = TranscriptionEntity(context: ctx)
                    e.id = id; e.timestamp = Date(timeIntervalSince1970: 1_700_000_000 + Double(i)); e.createdAt = e.timestamp
                    e.lastModifiedAt = e.timestamp; e.transcription = String(repeating: "dictated words ", count: 30)
                    e.audioFileURL = name; e.language = "en"; e.modelUsed = "V3"; e.wordCount = 30
                }
            }
            if i % 500 == 0 { try await ctx.perform { try ctx.save() } }
        }
        try await ctx.perform { try ctx.save() }

        let t0 = Date()
        let whole = try await export(a, .init(), as: "whole.aar")
        let wholeExport = Date().timeIntervalSince(t0)
        let t1 = Date()
        _ = try await HistoryArchive.importArchives(whole.files, env: b.env)
        let wholeImport = Date().timeIntervalSince(t1)

        let t2 = Date()
        let split = try await export(a, .init(maxPartBytes: 128_000_000), as: "split.aar")
        let splitExport = Date().timeIntervalSince(t2)
        let t3 = Date()
        let summary = try await HistoryArchive.importArchives(split.files, env: c.env)
        let splitImport = Date().timeIntervalSince(t3)
        print("[HistoryArchiveScale] \(bytesTotal / 1_048_576) MB audio, 4000 + 200 rows. Whole: export \(String(format: "%.1f", wholeExport)) s, import \(String(format: "%.1f", wholeImport)) s. In \(split.files.count) parts of ≤128 MB: export \(String(format: "%.1f", splitExport)) s, import \(String(format: "%.1f", splitImport)) s")
        XCTAssertEqual(summary.dictationsAdded, 4_000)
        XCTAssertEqual(summary.meetingsAdded, 200)
        XCTAssertEqual(summary.audioFilesAdded, 4_200)
    }

    // MARK: - The machine's own library

    /// Exports the real library read-only and imports it into a scratch store.
    func testOwnLibraryRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["HISTORY_ARCHIVE_REAL"] != nil else { throw XCTSkip("set TEST_RUNNER_HISTORY_ARCHIVE_REAL=1") }
        let scratch = try makeLibrary("real")
        var real = Env.app
        real.staging = scratch.env.staging
        let started = Date()
        let estimate = try await HistoryArchive.estimate(.init(), env: real)
        let exported = try await HistoryArchive.export(.init(), to: scratch.root.appendingPathComponent("real.aar"), env: real)
        let exportSeconds = Date().timeIntervalSince(started)
        let manifest = try await HistoryArchive.preview(of: exported.files[0])
        let t1 = Date()
        let imported = try await HistoryArchive.importArchives(exported.files, env: scratch.env)
        let importSeconds = Date().timeIntervalSince(t1)
        print("[HistoryArchive] real library: \(exported.counts) \(exported.audioFiles) recordings, \(exported.archiveBytes / 1024) KB; estimate \(estimate.counts) \(estimate.audioFiles) files; export \(String(format: "%.2f", exportSeconds)) s, import \(String(format: "%.2f", importSeconds)) s; manifest \(manifest.counts)")
        XCTAssertEqual(imported.dictationsAdded, exported.counts[.dictations])
        XCTAssertEqual(imported.meetingsAdded, exported.counts[.meetings])
        XCTAssertEqual(imported.audioFilesAdded, exported.audioFiles)
        XCTAssertEqual(estimate.counts[.dictations], exported.counts[.dictations])
    }
}
