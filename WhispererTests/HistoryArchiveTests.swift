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

    private struct Library {
        let database: HistoryDatabase
        let paths: HistoryArchive.Paths
        let root: URL
    }

    private func makeLibrary(_ name: String) throws -> Library {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryArchiveTests-\(name)-\(UUID().uuidString)")
        let paths = HistoryArchive.Paths(
            recordings: root.appendingPathComponent("Recordings"),
            meetingRecordings: root.appendingPathComponent("Recordings/Meetings"),
            meetingData: root.appendingPathComponent("Meetings"),
            staging: root.appendingPathComponent("tmp"))
        for dir in [paths.recordings, paths.meetingRecordings, paths.meetingData, paths.staging] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let database = HistoryDatabase(inMemory: true)
        Self.keepAlive.append(database)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Library(database: database, paths: paths, root: root)
    }

    private func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private func seed(_ lib: Library, transcriptions: Int, meetings: Int) async throws -> (t: [UUID], m: [UUID]) {
        let ctx = lib.database.newBackgroundContext()
        var tIDs: [UUID] = [], mIDs: [UUID] = []
        for i in 0..<transcriptions {
            let id = UUID(); tIDs.append(id)
            let name = "2026-11-0\(i + 1)_dictation_\(i).opus"
            try Data((0..<(2_000 + i * 997)).map { UInt8(($0 &* 31 &+ i) & 0xFF) }).write(to: lib.paths.recordings.appendingPathComponent(name))
            await ctx.perform {
                let e = TranscriptionEntity(context: ctx)
                e.id = id; e.timestamp = Date(timeIntervalSince1970: 1_790_000_000 + Double(i)); e.createdAt = e.timestamp
                e.lastModifiedAt = e.timestamp
                e.transcription = "Привет мир \(i) — שלום עולם \"quoted\"\nnew line"
                e.audioFileURL = name; e.duration = 3.5 + Double(i); e.wordCount = Int32(10 + i)
                e.language = i % 2 == 0 ? "ru" : "he"; e.modelUsed = "V3"
                e.isPinned = i == 0; e.isFlagged = i == 1
                e.editedTranscription = i == 2 ? "edited" : nil
                e.correctionsData = Data([1, 2, 3, UInt8(i)])
                e.isInProgress = false
            }
        }
        for i in 0..<meetings {
            let id = UUID(); mIDs.append(id)
            let name = "\(id.uuidString).opus"
            try Data((0..<(5_000 + i)).map { UInt8(($0 &* 7 &+ i) & 0xFF) }).write(to: lib.paths.meetingRecordings.appendingPathComponent(name))
            try Data("[{\"role\":\"user\"}]".utf8).write(to: lib.paths.meetingData.appendingPathComponent("\(id)-chat.json"))
            await ctx.perform {
                let e = MeetingEntity(context: ctx)
                e.id = id; e.title = "Meeting \(i) שלום"; e.createdAt = Date(timeIntervalSince1970: 1_790_100_000 + Double(i))
                e.duration = 120.25; e.audioFileURL = name; e.segmentsJSON = "[{\"text\":\"hello \(i)\"}]"
                e.aiSummaryJSON = "{\"x\":1}"; e.wordCount = 42; e.language = "he"; e.modelUsed = "V3"
                e.isInProgress = false; e.captureFailed = false; e.titleIsUserSet = true
            }
        }
        // One row that must never travel: a recording still in progress.
        await ctx.perform {
            let e = TranscriptionEntity(context: ctx)
            e.id = UUID(); e.timestamp = Date(); e.createdAt = Date(); e.lastModifiedAt = Date()
            e.transcription = "in progress"; e.language = "en"; e.modelUsed = "V3"; e.isInProgress = true
        }
        try await ctx.perform { try ctx.save() }
        return (tIDs, mIDs)
    }

    /// Rows as plain values, read inside the context: a managed object outlives neither it nor its
    /// store, and comparing faults against nothing passes for the wrong reason.
    private func fetchAll(_ lib: Library, _ entity: String) async throws -> [[String: Any]] {
        let ctx = lib.database.newBackgroundContext()
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

    private func locator(_ lib: Library) -> @Sendable (String) -> URL? {
        let dir = lib.paths.meetingRecordings
        return { name in
            let url = dir.appendingPathComponent((name as NSString).lastPathComponent)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    // MARK: - Round trip

    func testRoundTripKeepsEveryRowAttributeAndByte() async throws {
        let a = try makeLibrary("a"), b = try makeLibrary("b")
        let ids = try await seed(a, transcriptions: 5, meetings: 3)
        let archive = a.root.appendingPathComponent("out.aar")

        let exported = try await HistoryArchive.export(to: archive, database: a.database, paths: a.paths,
                                                       locateMeetingAudio: locator(a))
        XCTAssertEqual(exported.transcriptions, 5, "the in-progress row is not exported")
        XCTAssertEqual(exported.meetings, 3)
        XCTAssertEqual(exported.audioFiles, 8)
        XCTAssertGreaterThan(exported.archiveBytes, 0)

        let imported = try await HistoryArchive.importArchive(from: archive, database: b.database, paths: b.paths)
        XCTAssertEqual(imported.transcriptionsAdded, 5)
        XCTAssertEqual(imported.meetingsAdded, 3)
        XCTAssertEqual(imported.audioFilesAdded, 8)
        XCTAssertEqual(imported.chatsAdded, 3)
        XCTAssertEqual(imported.audioMissing, 0)

        let src = try await fetchAll(a, "TranscriptionEntity").filter { ($0["isInProgress"] as? Bool) == false }
        let dst = try await fetchAll(b, "TranscriptionEntity")
        XCTAssertEqual(dst.count, 5)
        for (x, y) in zip(src, dst) {
            XCTAssertEqual(Set(x.keys), Set(y.keys))
            for name in x.keys where name != "audioFileURL" {
                XCTAssertTrue((x[name] as? NSObject) == (y[name] as? NSObject), "\(name) differs")
            }
            let file = try XCTUnwrap(x["audioFileURL"] as? String)
            XCTAssertEqual(try sha(a.paths.recordings.appendingPathComponent(file)),
                           try sha(b.paths.recordings.appendingPathComponent(y["audioFileURL"] as! String)))
        }
        let meetingsDst = try await fetchAll(b, "MeetingEntity")
        XCTAssertEqual(Set(meetingsDst.compactMap { $0["id"] as? UUID }), Set(ids.m))
        for m in meetingsDst {
            let id = m["id"] as! UUID
            XCTAssertEqual(try sha(a.paths.meetingRecordings.appendingPathComponent("\(id).opus")),
                           try sha(b.paths.meetingRecordings.appendingPathComponent(m["audioFileURL"] as! String)))
            XCTAssertTrue(FileManager.default.fileExists(atPath: b.paths.meetingData.appendingPathComponent("\(id)-chat.json").path))
        }
        // No scratch folders left behind.
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: a.paths.staging.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: b.paths.staging.path).isEmpty)
    }

    func testImportingTwiceAddsNothingAndKeepsExistingRows() async throws {
        let a = try makeLibrary("a"), b = try makeLibrary("b")
        try await seed(a, transcriptions: 3, meetings: 1)
        let archive = a.root.appendingPathComponent("out.aar")
        try await HistoryArchive.export(to: archive, database: a.database, paths: a.paths, locateMeetingAudio: locator(a))
        _ = try await HistoryArchive.importArchive(from: archive, database: b.database, paths: b.paths)
        let again = try await HistoryArchive.importArchive(from: archive, database: b.database, paths: b.paths)
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.alreadyPresent, 4)
        let rows = try await fetchAll(b, "TranscriptionEntity")
        XCTAssertEqual(rows.count, 3)
    }

    func testImportMergesIntoANonEmptyLibraryAndRenamesCollidingAudio() async throws {
        let a = try makeLibrary("a"), b = try makeLibrary("b")
        try await seed(a, transcriptions: 2, meetings: 0)
        // The other workspace already has a different recording with the same file name.
        let clash = b.paths.recordings.appendingPathComponent("2026-11-01_dictation_0.opus")
        try Data("a different recording".utf8).write(to: clash)
        let local = try await seed(b, transcriptions: 0, meetings: 1)

        let archive = a.root.appendingPathComponent("out.aar")
        try await HistoryArchive.export(to: archive, database: a.database, paths: a.paths, locateMeetingAudio: locator(a))
        let summary = try await HistoryArchive.importArchive(from: archive, database: b.database, paths: b.paths)
        XCTAssertEqual(summary.transcriptionsAdded, 2)
        XCTAssertEqual(try Data(contentsOf: clash), Data("a different recording".utf8), "an existing file is never overwritten")
        let names = try await fetchAll(b, "TranscriptionEntity").compactMap { $0["audioFileURL"] as? String }
        XCTAssertTrue(names.contains { $0.contains("-imported") })
        for name in names { XCTAssertTrue(FileManager.default.fileExists(atPath: b.paths.recordings.appendingPathComponent(name).path)) }
        let meetings = try await fetchAll(b, "MeetingEntity")
        XCTAssertEqual(meetings.compactMap { $0["id"] as? UUID }, local.m, "local rows are untouched")
    }

    func testRowsWithoutAudioAreStillImported() async throws {
        let a = try makeLibrary("a"), b = try makeLibrary("b")
        try await seed(a, transcriptions: 2, meetings: 0)
        try FileManager.default.removeItem(at: a.paths.recordings.appendingPathComponent("2026-11-02_dictation_1.opus"))
        let archive = a.root.appendingPathComponent("out.aar")
        let exported = try await HistoryArchive.export(to: archive, database: a.database, paths: a.paths, locateMeetingAudio: locator(a))
        XCTAssertEqual(exported.transcriptions, 2)
        let summary = try await HistoryArchive.importArchive(from: archive, database: b.database, paths: b.paths)
        XCTAssertEqual(summary.transcriptionsAdded, 2)
        XCTAssertEqual(summary.audioMissing, 1)
    }

    // MARK: - Bad input

    func testAFileThatIsNotAnArchiveIsRefused() async throws {
        let b = try makeLibrary("b")
        let junk = b.root.appendingPathComponent("junk.aar")
        try Data("not an archive at all".utf8).write(to: junk)
        do {
            _ = try await HistoryArchive.importArchive(from: junk, database: b.database, paths: b.paths)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is HistoryArchive.ArchiveError)
        }
    }

    func testAnArchiveWithoutAManifestIsRefused() async throws {
        let b = try makeLibrary("b")
        let folder = b.root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        let archive = b.root.appendingPathComponent("plain.aar")
        try writeArchive(of: folder, to: archive, prefix: nil)
        do {
            _ = try await HistoryArchive.importArchive(from: archive, database: b.database, paths: b.paths)
            XCTFail("expected an error")
        } catch HistoryArchive.ArchiveError.notAnArchive {
        }
    }

    /// Apple's own writer refuses an entry name that climbs out ("ioError"), so a hostile archive
    /// has to come from elsewhere; the extraction filter is what stops it, tested here as a rule.
    func testEntryPathsThatEscapeAreRecognised() {
        for unsafe in ["../x", "a/../../x", "/etc/passwd", "audio/../../../x"] {
            XCTAssertTrue(HistoryArchive.isUnsafeEntryPath(unsafe), unsafe)
        }
        for safe in ["manifest.json", "audio/a.opus", "meeting-chat/1.json", "a..b/c"] {
            XCTAssertFalse(HistoryArchive.isUnsafeEntryPath(safe), safe)
        }
    }

    /// Test-only archive writer, independent of the code under test: `prefix` lets an entry name
    /// start with `../`, which the app's own writer never produces.
    private func writeArchive(of directory: URL, to destination: URL, prefix: String?) throws {
        let file = try XCTUnwrap(ArchiveByteStream.fileStream(path: FilePath(destination.path), mode: .writeOnly,
                                                              options: [.create, .truncate], permissions: FilePermissions(rawValue: 0o644)))
        let encoder = try XCTUnwrap(ArchiveStream.encodeStream(writingTo: file))
        try encoder.writeDirectoryContents(archiveFrom: FilePath(directory.path), path: prefix.map { FilePath($0) },
                                           keySet: ArchiveHeader.FieldKeySet("TYP,PAT,DAT,MOD")!)
        try encoder.close(); try file.close()
    }

    // MARK: - Scale

    /// A large library: 4 000 dictations and 200 meetings with 400 MB of incompressible audio.
    /// Opt-in; reports time and peak memory of export and import.
    func testLargeLibraryScale() async throws {
        guard ProcessInfo.processInfo.environment["HISTORY_ARCHIVE_SCALE"] != nil else { throw XCTSkip("set TEST_RUNNER_HISTORY_ARCHIVE_SCALE=1") }
        let a = try makeLibrary("big-a"), b = try makeLibrary("big-b")
        let ctx = a.database.newBackgroundContext()
        var megabytes = 0
        for i in 0..<4_200 {
            let isMeeting = i >= 4_000
            let id = UUID()
            let name = "\(isMeeting ? id.uuidString : "rec-\(i)").opus"
            let size = isMeeting ? 1_500_000 : 60_000
            var bytes = Data(count: size)
            bytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, size, $0.baseAddress!) }
            try bytes.write(to: (isMeeting ? a.paths.meetingRecordings : a.paths.recordings).appendingPathComponent(name))
            megabytes += size
            await ctx.perform {
                if isMeeting {
                    let e = MeetingEntity(context: ctx)
                    e.id = id; e.title = "Meeting \(i)"; e.createdAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
                    e.duration = 3_600; e.audioFileURL = name; e.language = "en"; e.modelUsed = "V3"
                    e.segmentsJSON = String(repeating: "{\"text\":\"a paragraph of a long meeting transcript\"},", count: 400)
                } else {
                    let e = TranscriptionEntity(context: ctx)
                    e.id = id; e.timestamp = Date(timeIntervalSince1970: 1_700_000_000 + Double(i)); e.createdAt = e.timestamp
                    e.lastModifiedAt = e.timestamp; e.transcription = String(repeating: "dictated words ", count: 30)
                    e.audioFileURL = name; e.language = "en"; e.modelUsed = "V3"
                }
            }
            if i % 500 == 0 { try await ctx.perform { try ctx.save() } }
        }
        try await ctx.perform { try ctx.save() }

        func residentMB() -> Double {
            var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
            _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: 1) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
            return Double(info.resident_size) / 1_048_576
        }
        let before = residentMB()
        let archive = a.root.appendingPathComponent("big.aar")
        let t0 = Date()
        let exported = try await HistoryArchive.export(to: archive, database: a.database, paths: a.paths, locateMeetingAudio: locator(a))
        let exportSeconds = Date().timeIntervalSince(t0)
        let afterExport = residentMB()
        let t1 = Date()
        let imported = try await HistoryArchive.importArchive(from: archive, database: b.database, paths: b.paths)
        let importSeconds = Date().timeIntervalSince(t1)
        print("[HistoryArchiveScale] \(megabytes / 1_048_576) MB audio, \(exported.transcriptions) + \(exported.meetings) rows → archive \(exported.archiveBytes / 1_048_576) MB; export \(String(format: "%.1f", exportSeconds)) s, import \(String(format: "%.1f", importSeconds)) s; resident \(Int(before)) → \(Int(afterExport)) → \(Int(residentMB())) MB")
        XCTAssertEqual(imported.transcriptionsAdded, 4_000)
        XCTAssertEqual(imported.meetingsAdded, 200)
        XCTAssertEqual(imported.audioFilesAdded, 4_200)
    }

    // MARK: - The machine's own library

    /// Exports the real library read-only and imports it into a scratch store: counts and audio must
    /// match, and the report says what it cost. Skipped when there is no history.
    func testOwnLibraryRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["HISTORY_ARCHIVE_REAL"] != nil else { throw XCTSkip("set TEST_RUNNER_HISTORY_ARCHIVE_REAL=1") }
        let scratch = try makeLibrary("real")
        let real = HistoryDatabase.shared
        let started = Date()
        let archive = scratch.root.appendingPathComponent("real.aar")
        let exported = try await HistoryArchive.export(
            to: archive, database: real,
            paths: HistoryArchive.Paths(recordings: AudioLibraryPaths.recordings,
                                        meetingRecordings: AudioLibraryPaths.meetingRecordings,
                                        meetingData: AudioLibraryPaths.meetingData,
                                        staging: scratch.paths.staging))
        let exportSeconds = Date().timeIntervalSince(started)
        let t1 = Date()
        let imported = try await HistoryArchive.importArchive(from: archive, database: scratch.database, paths: scratch.paths)
        let importSeconds = Date().timeIntervalSince(t1)
        print("[HistoryArchive] exported \(exported) in \(String(format: "%.2f", exportSeconds)) s; imported \(imported) in \(String(format: "%.2f", importSeconds)) s")
        XCTAssertEqual(imported.transcriptionsAdded, exported.transcriptions)
        XCTAssertEqual(imported.meetingsAdded, exported.meetings)
        XCTAssertEqual(imported.audioFilesAdded, exported.audioFiles)
        let copied = try FileManager.default.contentsOfDirectory(atPath: scratch.paths.recordings.path)
        XCTAssertGreaterThan(copied.count, 0)
    }
}
