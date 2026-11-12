//
//  HistoryArchive.swift
//  Whisperer
//
//  Export the application's whole history to files and import it into another workspace.
//
//  Format: Apple Archive (`.aar`, LZFSE) of a plain folder —
//
//      0-manifest.json          what is inside, which part of which set this is
//      dictations.jsonl         one Core Data row per line
//      meetings.jsonl           one Core Data row per line
//      dictionary.jsonl         the user's own dictionary entries (part 1 only)
//      statistics.json          the persisted records — best streak, typing speed (part 1 only)
//      command-chats.json       Command Mode conversations (part 1 only)
//      audio/                   dictation recordings, by stored file name
//      meeting-audio/           meeting recordings
//      meeting-chat/            the Ask-AI thread of each meeting
//
//  Why Apple Archive: it is the system's own archive format (Finder and Archive Utility open it),
//  streams in constant memory, compresses on all cores, works inside the App Sandbox with no
//  helper process and needs no dependency. Zip would need a third-party package to read back.
//  The audio is already Opus, so compression pays on the text; recordings are staged with APFS
//  clones (no second copy on disk) and stored as they are.
//
//  Large histories. Everything is bounded by one *part*:
//    - Export plans parts up front (rows in time order, each with its audio, packed under a size
//      cap) and writes them one at a time; only one part is ever staged.
//    - Every part is self-contained and importable alone, in any order; rows merge by id, so
//      importing part 2 before part 1, or the same part twice, is harmless.
//    - Import unpacks one part at a time, merges it, and deletes it before the next, so the scratch
//      space needed is one part, not the library. The manifest is read without unpacking the
//      rest, to show what a file holds and to refuse early when the disk cannot take it.
//  Scope is chosen at export (categories, time range, with or without audio) and again at import.
//
//  Rows are written generically from the Core Data model, so a column added to the model later
//  travels without touching this file. Import is a merge: nothing already here is overwritten.
//

import Foundation
import CoreData
import AppleArchive
import System

nonisolated enum HistoryArchive {

    // MARK: - Public types

    enum Category: String, CaseIterable, Codable, Sendable {
        case dictations, meetings, dictionary, commandChats, statistics
    }

    struct Environment: @unchecked Sendable {
        var database: HistoryDatabase
        var recordings: URL
        var meetingRecordings: URL
        var meetingData: URL
        var chatHistory: URL
        var staging: URL
        var defaults: UserDefaults
        var locateMeetingAudio: @Sendable (String) -> URL?
        /// Free bytes on the volume holding a URL. Injected so low-disk behaviour is testable.
        var freeSpace: @Sendable (URL) -> Int64?

        static var app: Environment {
            Environment(database: .shared,
                        recordings: AudioLibraryPaths.recordings,
                        meetingRecordings: AudioLibraryPaths.meetingRecordings,
                        meetingData: AudioLibraryPaths.meetingData,
                        chatHistory: AudioLibraryPaths.root.appendingPathComponent("ChatHistory"),
                        staging: FileManager.default.temporaryDirectory,
                        defaults: .standard,
                        locateMeetingAudio: { MeetingManager.locateAudio(storedName: $0) },
                        freeSpace: { HistoryArchive.availableBytes(at: $0) })
        }
    }

    struct ExportOptions: Sendable, Equatable {
        var categories: Set<Category> = Set(Category.allCases)
        var includeAudio = true
        var from: Date?
        var to: Date?
        /// Soft cap per file; nil writes one file. A single recording larger than the cap gets a part of its own.
        var maxPartBytes: Int64?
    }

    struct ImportOptions: Sendable, Equatable {
        var categories: Set<Category> = Set(Category.allCases)
        var includeAudio = true
        var from: Date?
        var to: Date?
    }

    struct Manifest: Codable, Sendable, Equatable {
        var format: Int
        var app: String
        var appVersion: String
        var createdAt: Date
        var device: String?
        var setID: UUID
        var part: Int
        var parts: Int
        var counts: [String: Int]
        var includesAudio: Bool
        var audioFiles: Int
        var audioBytes: Int64
        /// Bytes the archive unpacks to — what the disk must hold while it is imported.
        var unpackedBytes: Int64
        /// Files in the archive, for progress.
        var entryCount: Int
        var oldest: Date?
        var newest: Date?

        func count(_ category: Category) -> Int { counts[category.rawValue] ?? 0 }
    }

    struct Estimate: Sendable, Equatable {
        var counts: [Category: Int] = [:]
        var audioFiles = 0
        var audioBytes: Int64 = 0
        var textBytes: Int64 = 0
        var parts = 1
        /// Largest single part, in bytes: the scratch and destination space the export needs at once.
        var largestPartBytes: Int64 = 0
        var totalBytes: Int64 { audioBytes + textBytes }
    }

    struct Progress: Sendable {
        var phase: String
        var fraction: Double
        var detail: String? = nil
    }

    struct ExportResult: Sendable, Equatable {
        var files: [URL]
        var counts: [Category: Int]
        var audioFiles: Int
        var archiveBytes: Int64
    }

    struct ImportSummary: Sendable, Equatable {
        var dictationsAdded = 0
        var meetingsAdded = 0
        var dictionaryAdded = 0
        var chatsAdded = 0
        var meetingThreadsAdded = 0
        var statisticsMerged = false
        var alreadyPresent = 0
        var outsideRange = 0
        var audioFilesAdded = 0
        var audioMissing = 0
        var archives = 0
        var added: Int { dictationsAdded + meetingsAdded + dictionaryAdded + chatsAdded }
    }

    /// Set from the UI; polled by the long loops and by the archive streams.
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    enum ArchiveError: LocalizedError, Equatable {
        case streamUnavailable
        case notAnArchive
        case newerFormat(Int)
        case storeUnavailable
        case cancelled
        case notEnoughSpace(needed: Int64, available: Int64)
        case nothingSelected

        var errorDescription: String? {
            switch self {
            case .streamUnavailable: return "The archive file could not be opened."
            case .notAnArchive: return "This file is not a Whisperer history archive."
            case .newerFormat(let v): return "This archive was made by a newer version of Whisperer (format \(v)). Update the app to import it."
            case .storeUnavailable: return "The history database is not available."
            case .cancelled: return "Cancelled."
            case .notEnoughSpace(let needed, let available):
                let f = ByteCountFormatter()
                return "Not enough free space: this needs about \(f.string(fromByteCount: needed)) and \(f.string(fromByteCount: available)) is available. Free some space, or export in smaller parts."
            case .nothingSelected: return "Nothing is selected to export."
            }
        }
    }

    static let formatVersion = 2
    static let fileExtension = "aar"
    static let manifestName = "0-manifest.json"
    private static let legacyManifestName = "manifest.json"
    private static let batchSize = 200
    private static let rowEntities: [(category: Category, entity: String, file: String, audioDir: String)] = [
        (.dictations, "TranscriptionEntity", "dictations.jsonl", "audio"),
        (.meetings, "MeetingEntity", "meetings.jsonl", "meeting-audio"),
    ]
    private static let chatDir = "meeting-chat"

    static func suggestedFileName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "Whisperer History \(f.string(from: now)).\(fileExtension)"
    }

    /// `base.aar` → `base – part 2 of 5.aar`. A single part keeps the name the user chose.
    static func partURL(_ destination: URL, part: Int, of parts: Int) -> URL {
        guard parts > 1 else { return destination }
        let stem = destination.deletingPathExtension().lastPathComponent
        return destination.deletingLastPathComponent()
            .appendingPathComponent("\(stem) – part \(part) of \(parts).\(fileExtension)")
    }

    static func availableBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Planning

    /// One row of a dictation or meeting, with what it costs to carry.
    struct Item: Sendable, Equatable {
        var kind: Category            // .dictations or .meetings
        var id: UUID
        var createdAt: Date
        var audioName: String?
        var audioBytes: Int64
        var textBytes: Int64
        var cost: Int64 { audioBytes + textBytes }
    }

    /// Rows in time order, packed into parts of at most `cap` bytes (a row bigger than the cap gets a
    /// part to itself). nil cap = one part. Pure, so the packing is tested directly.
    static func partition(_ items: [Item], cap: Int64?) -> [[Item]] {
        guard let cap, cap > 0 else { return [items] }
        var parts: [[Item]] = []
        var current: [Item] = []
        var size: Int64 = 0
        for item in items {
            if !current.isEmpty, size + item.cost > cap {
                parts.append(current)
                current = []
                size = 0
            }
            current.append(item)
            size += item.cost
        }
        if !current.isEmpty { parts.append(current) }
        return parts.isEmpty ? [[]] : parts
    }

    private static func collectItems(_ options: ExportOptions, env: Environment,
                                     cancel: CancelFlag?) async throws -> [Item] {
        guard env.database.persistentContainer != nil else { throw ArchiveError.storeUnavailable }
        let context = env.database.newBackgroundContext()
        var items: [Item] = []
        for spec in rowEntities where options.categories.contains(spec.category) {
            let isMeeting = spec.category == .meetings
            let rows: [(UUID, Date, String?, Int)] = try await context.perform {
                let request = NSFetchRequest<NSDictionary>(entityName: spec.entity)
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["id", "createdAt", "audioFileURL", "wordCount"]
                var predicates = [NSPredicate(format: "isInProgress == NO")]
                if let from = options.from { predicates.append(NSPredicate(format: "createdAt >= %@", from as NSDate)) }
                if let to = options.to { predicates.append(NSPredicate(format: "createdAt <= %@", to as NSDate)) }
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
                request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
                return try context.fetch(request).compactMap { row in
                    guard let id = row["id"] as? UUID, let created = row["createdAt"] as? Date else { return nil }
                    return (id, created, row["audioFileURL"] as? String, (row["wordCount"] as? Int) ?? 0)
                }
            }
            for (index, row) in rows.enumerated() {
                if index % 500 == 0, cancel?.isCancelled == true { throw ArchiveError.cancelled }
                var audioBytes: Int64 = 0
                if options.includeAudio, let name = row.2, !name.isEmpty {
                    let url = isMeeting ? env.locateMeetingAudio(name)
                                        : existing(env.recordings.appendingPathComponent((name as NSString).lastPathComponent))
                    audioBytes = url.flatMap { fileSize($0) } ?? 0
                }
                // Text cost is an estimate: a meeting row carries its transcript three times over
                // (segments, summary, notes); a dictation is its words and a little more.
                let text: Int64 = isMeeting ? Int64(row.3) * 20 + 4_000 : Int64(row.3) * 8 + 400
                items.append(Item(kind: spec.category, id: row.0, createdAt: row.1, audioName: row.2,
                                  audioBytes: audioBytes, textBytes: text))
            }
        }
        return items.sorted { $0.createdAt < $1.createdAt }
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    private static func existing(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// What an export with these options would produce — counts, bytes, parts. Reads row ids and
    /// file sizes only, so it is fast on a large library and can run on every change of option.
    static func estimate(_ options: ExportOptions, env: Environment = .app,
                         cancel: CancelFlag? = nil) async throws -> Estimate {
        let items = try await collectItems(options, env: env, cancel: cancel)
        var estimate = Estimate()
        for item in items {
            estimate.counts[item.kind, default: 0] += 1
            estimate.audioBytes += item.audioBytes
            estimate.textBytes += item.textBytes
            if item.audioBytes > 0 { estimate.audioFiles += 1 }
        }
        let extras = try await extraCounts(options, env: env)
        for (category, n) in extras { estimate.counts[category] = n }
        let parts = partition(items, cap: options.maxPartBytes)
        estimate.parts = parts.count
        estimate.largestPartBytes = parts.map { $0.reduce(0) { $0 + $1.cost } }.max() ?? 0
        return estimate
    }

    private static func extraCounts(_ options: ExportOptions, env: Environment) async throws -> [Category: Int] {
        var result: [Category: Int] = [:]
        if options.categories.contains(.dictionary) {
            let context = env.database.newBackgroundContext()
            result[.dictionary] = try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: "DictionaryEntryEntity")
                request.predicate = NSPredicate(format: "isBuiltIn == NO")
                return try context.count(for: request)
            }
        }
        if options.categories.contains(.commandChats) {
            result[.commandChats] = commandChatSessions(env).count
        }
        if options.categories.contains(.statistics) {
            result[.statistics] = statisticsSnapshot(env).isEmpty ? 0 : 1
        }
        return result
    }

    // MARK: - Export

    /// Writes the parts next to `destination` and returns their URLs. On cancel or failure every file
    /// this call created is removed.
    static func export(_ options: ExportOptions, to destination: URL, env: Environment = .app,
                       cancel: CancelFlag = CancelFlag(),
                       progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> ExportResult {
        guard !options.categories.isEmpty else { throw ArchiveError.nothingSelected }
        let fm = FileManager.default
        progress(Progress(phase: "Counting", fraction: 0))
        let items = try await collectItems(options, env: env, cancel: cancel)
        let parts = partition(items, cap: options.maxPartBytes)

        // Fail before writing a byte, not at 90 %: the largest part has to fit at the destination and,
        // when the library is on another volume than the scratch folder (no APFS clones), there too.
        let largest = parts.map { $0.reduce(0) { $0 + $1.cost } }.max() ?? 0
        let totalNeeded = parts.reduce(Int64(0)) { $0 + $1.reduce(0) { $0 + $1.cost } }
        if let free = env.freeSpace(destination.deletingLastPathComponent()), free < totalNeeded + 50_000_000 {
            throw ArchiveError.notEnoughSpace(needed: totalNeeded + 50_000_000, available: free)
        }
        if !sameVolume(env.staging, env.recordings), let free = env.freeSpace(env.staging), free < largest + 50_000_000 {
            throw ArchiveError.notEnoughSpace(needed: largest + 50_000_000, available: free)
        }

        let setID = UUID()
        var created: [URL] = []
        var counts: [Category: Int] = [:]
        var audioFiles = 0
        do {
            for (index, part) in parts.enumerated() {
                if cancel.isCancelled { throw ArchiveError.cancelled }
                let url = partURL(destination, part: index + 1, of: parts.count)
                let label = parts.count > 1 ? "Part \(index + 1) of \(parts.count)" : "Exporting"
                let base = Double(index) / Double(parts.count)
                let span = 1 / Double(parts.count)
                let written = try await writePart(part, number: index + 1, of: parts.count, setID: setID,
                                                  options: options, to: url, env: env, cancel: cancel) { inner, detail in
                    progress(Progress(phase: label, fraction: base + span * inner, detail: detail))
                }
                created.append(url)
                audioFiles += written.audioFiles
                for (category, n) in written.counts { counts[category, default: 0] += n }
            }
        } catch {
            for url in created { try? fm.removeItem(at: url) }
            throw error
        }
        let bytes = created.reduce(Int64(0)) { $0 + (fileSize($1) ?? 0) }
        progress(Progress(phase: "Done", fraction: 1))
        return ExportResult(files: created, counts: counts, audioFiles: audioFiles, archiveBytes: bytes)
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func id(_ url: URL) -> NSObject? {
            var probe = url
            while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
                probe = probe.deletingLastPathComponent()
            }
            return (try? probe.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let x = id(a), let y = id(b) else { return true }
        return x.isEqual(y)
    }

    private static func writePart(_ items: [Item], number: Int, of total: Int, setID: UUID,
                                  options: ExportOptions, to destination: URL, env: Environment,
                                  cancel: CancelFlag,
                                  progress: @escaping @Sendable (Double, String?) -> Void) async throws
    -> (counts: [Category: Int], audioFiles: Int) {
        let fm = FileManager.default
        let stage = env.staging.appendingPathComponent("WhispererExport-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }

        let context = env.database.newBackgroundContext()
        var counts: [Category: Int] = [:]
        var audioFiles = 0
        var audioBytes: Int64 = 0
        var oldest: Date?, newest: Date?

        for spec in rowEntities where options.categories.contains(spec.category) {
            let mine = items.filter { $0.kind == spec.category }
            guard !mine.isEmpty else { continue }
            let isMeeting = spec.category == .meetings
            let rowsFile = stage.appendingPathComponent(spec.file)
            fm.createFile(atPath: rowsFile.path, contents: nil)
            let handle = try FileHandle(forWritingTo: rowsFile)
            defer { try? handle.close() }
            let audioStage = stage.appendingPathComponent(spec.audioDir, isDirectory: true)
            let chatStage = stage.appendingPathComponent(chatDir, isDirectory: true)
            var stagedNames = Set<String>()
            var written = 0

            for chunk in stride(from: 0, to: mine.count, by: batchSize) {
                if cancel.isCancelled { throw ArchiveError.cancelled }
                let slice = Array(mine[chunk..<min(chunk + batchSize, mine.count)])
                let ids = slice.map(\.id)
                let result: (rows: Int, audio: Int, bytes: Int64) = try await context.perform {
                    let request = NSFetchRequest<NSManagedObject>(entityName: spec.entity)
                    request.predicate = NSPredicate(format: "id IN %@", ids)
                    let objects = try context.fetch(request)
                    var buffer = Data()
                    var audio = 0
                    var bytes: Int64 = 0
                    var rows = 0
                    for object in objects {
                        var row = encodeRow(object)
                        if let name = object.value(forKey: "audioFileURL") as? String, !name.isEmpty {
                            let base = (name as NSString).lastPathComponent
                            row["audioFileURL"] = base
                            let source = isMeeting ? env.locateMeetingAudio(name)
                                                   : existing(env.recordings.appendingPathComponent(base))
                            if options.includeAudio, let source {
                                if stagedNames.insert(base).inserted {
                                    try fm.createDirectory(at: audioStage, withIntermediateDirectories: true)
                                    // `copyItem` clones on APFS: staged without a second copy on disk.
                                    try fm.copyItem(at: source, to: audioStage.appendingPathComponent(base))
                                    audio += 1
                                    bytes += fileSize(source) ?? 0
                                }
                            } else if options.includeAudio {
                                row["_audioMissing"] = true
                            } else {
                                // Text only: the row must not claim a file the archive does not hold.
                                row["audioFileURL"] = nil
                            }
                        }
                        if isMeeting, let id = object.value(forKey: "id") as? UUID {
                            let chat = env.meetingData.appendingPathComponent("\(id)-chat.json")
                            if fm.fileExists(atPath: chat.path) {
                                try fm.createDirectory(at: chatStage, withIntermediateDirectories: true)
                                try fm.copyItem(at: chat, to: chatStage.appendingPathComponent("\(id).json"))
                            }
                        }
                        if let line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                            buffer.append(line); buffer.append(0x0A); rows += 1
                        }
                    }
                    try handle.write(contentsOf: buffer)
                    context.reset()
                    return (rows, audio, bytes)
                }
                written += result.rows
                audioFiles += result.audio
                audioBytes += result.bytes
                progress(0.5 * Double(chunk + slice.count) / Double(max(items.count, 1)),
                         "\(spec.category == .meetings ? "Meetings" : "Dictations") \(written) of \(mine.count)")
            }
            counts[spec.category] = written
            if let first = mine.first?.createdAt { oldest = min(oldest ?? first, first) }
            if let last = mine.last?.createdAt { newest = max(newest ?? last, last) }
        }

        // Everything that is not a row of a part travels once, in the first.
        if number == 1 {
            if options.categories.contains(.dictionary) {
                counts[.dictionary] = try await writeDictionary(to: stage.appendingPathComponent("dictionary.jsonl"), env: env)
            }
            if options.categories.contains(.statistics) {
                let stats = statisticsSnapshot(env)
                if !stats.isEmpty {
                    try JSONSerialization.data(withJSONObject: stats, options: [.sortedKeys])
                        .write(to: stage.appendingPathComponent("statistics.json"))
                    counts[.statistics] = 1
                }
            }
            if options.categories.contains(.commandChats) {
                let sessions = commandChatSessions(env)
                if !sessions.isEmpty {
                    try JSONSerialization.data(withJSONObject: sessions, options: [.sortedKeys])
                        .write(to: stage.appendingPathComponent("command-chats.json"))
                    counts[.commandChats] = sessions.count
                }
            }
        }

        var entryCount = 0
        var unpacked: Int64 = 0
        if let walker = fm.enumerator(at: stage, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let url as URL in walker {
                let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if v?.isRegularFile == true { entryCount += 1; unpacked += Int64(v?.fileSize ?? 0) }
            }
        }
        let manifest = Manifest(
            format: formatVersion, app: "Whisperer",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            createdAt: Date(), device: Host.current().localizedName, setID: setID, part: number, parts: total,
            counts: Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) }),
            includesAudio: options.includeAudio, audioFiles: audioFiles, audioBytes: audioBytes,
            unpackedBytes: unpacked + 2_048, entryCount: entryCount + 1, oldest: oldest, newest: newest)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: stage.appendingPathComponent(manifestName))

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial")
        try? fm.removeItem(at: temporary)
        let total = max(entryCount, 1)
        do {
            try await Task.detached(priority: .userInitiated) {
                try writeArchive(of: stage, to: temporary, cancel: cancel) { written in
                    progress(0.5 + 0.5 * Double(written) / Double(total), "Compressing")
                }
            }.value
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
        return (counts, audioFiles)
    }

    private static func writeArchive(of directory: URL, to destination: URL, cancel: CancelFlag,
                                     written: @escaping @Sendable (Int) -> Void) throws {
        guard let file = ArchiveByteStream.fileStream(path: FilePath(destination.path), mode: .writeOnly,
                                                      options: [.create, .truncate],
                                                      permissions: FilePermissions(rawValue: 0o644)),
              let compressed = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: file),
              let encoder = ArchiveStream.encodeStream(writingTo: compressed) else {
            throw ArchiveError.streamUnavailable
        }
        let keys = ArchiveHeader.FieldKeySet("TYP,PAT,DAT,MOD,MTM")!
        let counter = Counter()
        do {
            try encoder.writeDirectoryContents(archiveFrom: FilePath(directory.path), keySet: keys,
                                               selectUsing: { message, _, _ in
                if cancel.isCancelled { return .cancel }
                if message == .encodeWriting { written(counter.next()) }
                return .ok
            })
        } catch {
            try? encoder.close(); try? compressed.close(); try? file.close()
            throw cancel.isCancelled ? ArchiveError.cancelled : error
        }
        try encoder.close()
        try compressed.close()
        try file.close()
    }

    // MARK: - Import

    /// What a file holds, read without unpacking the rest of it.
    static func preview(of url: URL) async throws -> Manifest {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("WhispererPeek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        return try await Task.detached(priority: .userInitiated) {
            try extract(url, to: work, only: [manifestName, legacyManifestName], cancel: nil, entries: nil)
            return try readManifest(in: work)
        }.value
    }

    private static func readManifest(in directory: URL) throws -> Manifest {
        let fm = FileManager.default
        let candidate = [manifestName, legacyManifestName]
            .map { directory.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
        guard let candidate, let data = try? Data(contentsOf: candidate) else { throw ArchiveError.notAnArchive }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Format 1 predates parts and categories; read it as one whole part.
        if let manifest = try? decoder.decode(Manifest.self, from: data) {
            guard manifest.app == "Whisperer" else { throw ArchiveError.notAnArchive }
            guard manifest.format <= formatVersion else { throw ArchiveError.newerFormat(manifest.format) }
            return manifest
        }
        guard let legacy = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              legacy["app"] as? String == "Whisperer", let format = legacy["format"] as? Int else { throw ArchiveError.notAnArchive }
        guard format <= formatVersion else { throw ArchiveError.newerFormat(format) }
        return Manifest(format: format, app: "Whisperer", appVersion: legacy["appVersion"] as? String ?? "",
                        createdAt: Date(), device: nil, setID: UUID(), part: 1, parts: 1,
                        counts: ["dictations": legacy["transcriptions"] as? Int ?? 0, "meetings": legacy["meetings"] as? Int ?? 0],
                        includesAudio: true, audioFiles: legacy["audioFiles"] as? Int ?? 0, audioBytes: 0,
                        unpackedBytes: 0, entryCount: 0, oldest: nil, newest: nil)
    }

    /// Imports every file given, one part at a time. A part is unpacked, merged and deleted before
    /// the next is touched, so the scratch space needed is one part.
    @discardableResult
    static func importArchives(_ urls: [URL], options: ImportOptions = ImportOptions(), env: Environment = .app,
                               cancel: CancelFlag = CancelFlag(),
                               progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> ImportSummary {
        guard env.database.persistentContainer != nil else { throw ArchiveError.storeUnavailable }
        var manifests: [(url: URL, manifest: Manifest)] = []
        for url in urls { manifests.append((url, try await preview(of: url))) }
        // Part 1 first: its dictionary and statistics are merged before rows reference anything.
        manifests.sort { ($0.manifest.setID.uuidString, $0.manifest.part) < ($1.manifest.setID.uuidString, $1.manifest.part) }

        var summary = ImportSummary()
        for (index, item) in manifests.enumerated() {
            if cancel.isCancelled { throw ArchiveError.cancelled }
            let base = Double(index) / Double(manifests.count)
            let span = 1 / Double(manifests.count)
            let label = manifests.count > 1 ? "File \(index + 1) of \(manifests.count)" : "Importing"
            try await importOne(item.url, manifest: item.manifest, options: options, env: env, cancel: cancel,
                                into: &summary) { inner, detail in
                progress(Progress(phase: label, fraction: base + span * inner, detail: detail))
            }
            summary.archives += 1
        }
        progress(Progress(phase: "Done", fraction: 1))
        return summary
    }

    private static func importOne(_ source: URL, manifest: Manifest, options: ImportOptions, env: Environment,
                                  cancel: CancelFlag, into summary: inout ImportSummary,
                                  progress: @escaping @Sendable (Double, String?) -> Void) async throws {
        let fm = FileManager.default
        if manifest.unpackedBytes > 0, let free = env.freeSpace(env.staging),
           free < manifest.unpackedBytes + 50_000_000 {
            throw ArchiveError.notEnoughSpace(needed: manifest.unpackedBytes + 50_000_000, available: free)
        }
        let work = env.staging.appendingPathComponent("WhispererImport-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let expected = max(manifest.entryCount, 1)
        try await Task.detached(priority: .userInitiated) {
            try extract(source, to: work, only: nil, cancel: cancel) { n in
                progress(0.4 * Double(n) / Double(expected), "Unpacking")
            }
        }.value
        if cancel.isCancelled { throw ArchiveError.cancelled }

        let context = env.database.newBackgroundContext()
        for spec in rowEntities where options.categories.contains(spec.category) {
            let rowsURL = work.appendingPathComponent(spec.file)
            guard fm.fileExists(atPath: rowsURL.path) else { continue }
            let isMeeting = spec.category == .meetings
            let audioFolder = work.appendingPathComponent(spec.audioDir, isDirectory: true)
            let destinationAudio = isMeeting ? env.meetingRecordings : env.recordings
            let chatSource = work.appendingPathComponent(chatDir, isDirectory: true)
            let total = max(manifest.count(spec.category), 1)

            let part: ImportSummary = try await context.perform {
                var part = ImportSummary()
                guard let description = NSEntityDescription.entity(forEntityName: spec.entity, in: context) else {
                    throw ArchiveError.storeUnavailable
                }
                let idRequest = NSFetchRequest<NSDictionary>(entityName: spec.entity)
                idRequest.resultType = .dictionaryResultType
                idRequest.propertiesToFetch = ["id"]
                var known = Set((try context.fetch(idRequest)).compactMap { $0["id"] as? UUID })

                let reader = try LineReader(url: rowsURL)
                var pending = 0, seen = 0
                while let line = reader.nextLine() {
                    if cancel.isCancelled { try? context.save(); throw ArchiveError.cancelled }
                    seen += 1
                    guard let row = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          let idString = row["id"] as? String, let id = UUID(uuidString: idString) else { continue }
                    if known.contains(id) { part.alreadyPresent += 1; continue }
                    if let seconds = (row["createdAt"] as? NSNumber)?.doubleValue {
                        let created = Date(timeIntervalSince1970: seconds)
                        if let from = options.from, created < from { part.outsideRange += 1; continue }
                        if let to = options.to, created > to { part.outsideRange += 1; continue }
                    }
                    known.insert(id)

                    let object = NSManagedObject(entity: description, insertInto: context)
                    decodeRow(row, into: object, description: description)

                    if let stored = object.value(forKey: "audioFileURL") as? String, !stored.isEmpty {
                        let base = (stored as NSString).lastPathComponent
                        let staged = audioFolder.appendingPathComponent(base)
                        if options.includeAudio, isSafeName(base), fm.fileExists(atPath: staged.path) {
                            try fm.createDirectory(at: destinationAudio, withIntermediateDirectories: true)
                            object.setValue(try place(staged, named: base, in: destinationAudio), forKey: "audioFileURL")
                            part.audioFilesAdded += 1
                        } else {
                            if options.includeAudio { part.audioMissing += 1 }
                            object.setValue(nil, forKey: "audioFileURL")
                        }
                    }
                    if isMeeting {
                        let chat = chatSource.appendingPathComponent("\(id).json")
                        if fm.fileExists(atPath: chat.path) {
                            try fm.createDirectory(at: env.meetingData, withIntermediateDirectories: true)
                            let target = env.meetingData.appendingPathComponent("\(id)-chat.json")
                            if !fm.fileExists(atPath: target.path) {
                                try fm.moveItem(at: chat, to: target)
                                part.meetingThreadsAdded += 1
                            }
                        }
                        part.meetingsAdded += 1
                    } else {
                        part.dictationsAdded += 1
                    }
                    pending += 1
                    if pending >= batchSize {
                        try context.save(); context.reset(); pending = 0
                        progress(0.4 + 0.5 * Double(seen) / Double(total), "\(isMeeting ? "Meetings" : "Dictations") \(seen) of \(total)")
                    }
                }
                if context.hasChanges { try context.save() }
                context.reset()
                return part
            }
            summary.dictationsAdded += part.dictationsAdded
            summary.meetingsAdded += part.meetingsAdded
            summary.alreadyPresent += part.alreadyPresent
            summary.outsideRange += part.outsideRange
            summary.audioFilesAdded += part.audioFilesAdded
            summary.audioMissing += part.audioMissing
            summary.meetingThreadsAdded += part.meetingThreadsAdded
        }

        if options.categories.contains(.dictionary) {
            summary.dictionaryAdded += try await mergeDictionary(from: work.appendingPathComponent("dictionary.jsonl"), env: env)
        }
        if options.categories.contains(.statistics) {
            summary.statisticsMerged = mergeStatistics(from: work.appendingPathComponent("statistics.json"), env: env) || summary.statisticsMerged
        }
        if options.categories.contains(.commandChats) {
            summary.chatsAdded += mergeCommandChats(from: work.appendingPathComponent("command-chats.json"), env: env)
        }
        progress(1, nil)
    }

    /// Unpacks `source` into `directory`. With `only`, every other entry is skipped and the stream is
    /// stopped once those are written — enough to read a manifest from the head of a large file.
    private static func extract(_ source: URL, to directory: URL, only: [String]?, cancel: CancelFlag?,
                                entries: (@Sendable (Int) -> Void)?) throws {
        guard let file = ArchiveByteStream.fileStream(path: FilePath(source.path), mode: .readOnly,
                                                      options: [], permissions: []),
              let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file),
              let decoder = ArchiveStream.decodeStream(readingFrom: decompressed) else {
            throw ArchiveError.notAnArchive
        }
        defer { try? decoder.close(); try? decompressed.close(); try? file.close() }
        let counter = Counter()
        let targets = Set(only ?? [])
        // Only paths inside the destination are written: an archive is input from outside.
        guard let extractor = ArchiveStream.extractStream(
            extractingTo: FilePath(directory.path),
            selectUsing: { message, path, _ in
                if cancel?.isCancelled == true { return .cancel }
                let text = path.string
                switch message {
                case .extractBegin:
                    if isUnsafeEntryPath(text) { return .skip }
                    if !targets.isEmpty, !targets.contains(text) { return .skip }
                    return .ok
                case .extractEnd:
                    entries?(counter.next())
                    return !targets.isEmpty && targets.contains(text) ? .cancel : .ok
                default:
                    return .ok
                }
            },
            flags: [.ignoreOperationNotPermitted]) else {
            throw ArchiveError.streamUnavailable
        }
        defer { try? extractor.close() }
        do {
            _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor)
        } catch {
            if cancel?.isCancelled == true { throw ArchiveError.cancelled }
            // Stopping after the manifest ends the stream early on purpose.
            if !targets.isEmpty, targets.contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) { return }
            throw ArchiveError.notAnArchive
        }
    }

    /// An entry that would land outside the extraction folder: absolute, or climbing with "..".
    static func isUnsafeEntryPath(_ path: String) -> Bool {
        path.hasPrefix("/") || path.split(separator: "/").contains("..")
    }

    /// A bare file name: no separators, no traversal, not hidden.
    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && name != ".."
    }

    /// Moves `file` into `folder` under `name`. A file already there with the same size is the same
    /// recording and is kept; a different one keeps its place and the import gets a new name.
    private static func place(_ file: URL, named name: String, in folder: URL) throws -> String {
        let fm = FileManager.default
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1 }
        var target = folder.appendingPathComponent(name)
        if fm.fileExists(atPath: target.path) {
            if size(target) == size(file) { return name }
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var counter = 1
            repeat {
                let candidate = "\(stem)-imported\(counter > 1 ? "-\(counter)" : "")" + (ext.isEmpty ? "" : ".\(ext)")
                target = folder.appendingPathComponent(candidate)
                counter += 1
            } while fm.fileExists(atPath: target.path)
        }
        try fm.moveItem(at: file, to: target)
        return target.lastPathComponent
    }

    // MARK: - Dictionary, statistics, command chats

    private static func writeDictionary(to file: URL, env: Environment) async throws -> Int {
        let context = env.database.newBackgroundContext()
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "DictionaryEntryEntity")
            request.predicate = NSPredicate(format: "isBuiltIn == NO")
            var buffer = Data()
            var count = 0
            for object in try context.fetch(request) {
                if let line = try? JSONSerialization.data(withJSONObject: encodeRow(object), options: [.sortedKeys]) {
                    buffer.append(line); buffer.append(0x0A); count += 1
                }
            }
            if count > 0 { try buffer.write(to: file) }
            return count
        }
    }

    /// Merged by what the entry *does*, not by id: the same correction typed on two Macs is one entry.
    private static func mergeDictionary(from file: URL, env: Environment) async throws -> Int {
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        let context = env.database.newBackgroundContext()
        return try await context.perform {
            guard let description = NSEntityDescription.entity(forEntityName: "DictionaryEntryEntity", in: context) else { return 0 }
            let request = NSFetchRequest<NSDictionary>(entityName: "DictionaryEntryEntity")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id", "incorrectForm", "correctForm"]
            var ids = Set<UUID>(), forms = Set<String>()
            for row in try context.fetch(request) {
                if let id = row["id"] as? UUID { ids.insert(id) }
                forms.insert(formKey(row["incorrectForm"] as? String, row["correctForm"] as? String))
            }
            let reader = try LineReader(url: file)
            var added = 0
            while let line = reader.nextLine() {
                guard let row = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let idString = row["id"] as? String, let id = UUID(uuidString: idString) else { continue }
                let key = formKey(row["incorrectForm"] as? String, row["correctForm"] as? String)
                if ids.contains(id) || forms.contains(key) { continue }
                ids.insert(id); forms.insert(key)
                decodeRow(row, into: NSManagedObject(entity: description, insertInto: context), description: description)
                added += 1
            }
            if context.hasChanges { try context.save() }
            context.reset()
            return added
        }
    }

    private static func formKey(_ incorrect: String?, _ correct: String?) -> String {
        "\((incorrect ?? "").lowercased())\u{1}\((correct ?? "").lowercased())"
    }

    private static let statisticKeys = ["bestStreak", "userTypingWPM"]

    private static func statisticsSnapshot(_ env: Environment) -> [String: Int] {
        var result: [String: Int] = [:]
        for key in statisticKeys where env.defaults.object(forKey: key) != nil { result[key] = env.defaults.integer(forKey: key) }
        return result
    }

    /// Records are merged, not replaced: the best streak is the larger of the two; a typing speed is
    /// taken only when this Mac has none. Everything else the statistics page shows is computed
    /// from the history, so it follows the rows.
    private static func mergeStatistics(from file: URL, env: Environment) -> Bool {
        guard let data = try? Data(contentsOf: file),
              let stats = (try? JSONSerialization.jsonObject(with: data)) as? [String: Int] else { return false }
        if let best = stats["bestStreak"] {
            env.defaults.set(max(best, env.defaults.integer(forKey: "bestStreak")), forKey: "bestStreak")
        }
        if let wpm = stats["userTypingWPM"], env.defaults.object(forKey: "userTypingWPM") == nil {
            env.defaults.set(wpm, forKey: "userTypingWPM")
        }
        return !stats.isEmpty
    }

    private static func commandChatSessions(_ env: Environment) -> [[String: Any]] {
        let file = env.chatHistory.appendingPathComponent("sessions.json")
        guard let data = try? Data(contentsOf: file),
              let sessions = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return sessions
    }

    /// Conversations are merged by id, newest first, and trimmed to the 50 the store keeps.
    private static func mergeCommandChats(from file: URL, env: Environment) -> Int {
        guard let data = try? Data(contentsOf: file),
              let incoming = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return 0 }
        var sessions = commandChatSessions(env)
        let known = Set(sessions.compactMap { $0["id"] as? String })
        let fresh = incoming.filter { ($0["id"] as? String).map { !known.contains($0) } ?? false }
        guard !fresh.isEmpty else { return 0 }
        sessions += fresh
        sessions.sort { (($0["createdAt"] as? Double) ?? 0) > (($1["createdAt"] as? Double) ?? 0) }
        if sessions.count > 50 { sessions = Array(sessions.prefix(50)) }
        try? FileManager.default.createDirectory(at: env.chatHistory, withIntermediateDirectories: true)
        if let out = try? JSONSerialization.data(withJSONObject: sessions) {
            try? out.write(to: env.chatHistory.appendingPathComponent("sessions.json"), options: .atomic)
        }
        return fresh.count
    }

    // MARK: - Rows

    /// Every attribute of the entity as JSON-safe values. Dates are seconds since 1970 (lossless),
    /// binary data is base64, UUIDs are strings; nil attributes are omitted.
    private static func encodeRow(_ object: NSManagedObject) -> [String: Any] {
        var row: [String: Any] = [:]
        for (name, attribute) in object.entity.attributesByName {
            guard let value = object.value(forKey: name) else { continue }
            switch attribute.attributeType {
            case .dateAttributeType:
                if let date = value as? Date { row[name] = date.timeIntervalSince1970 }
            case .UUIDAttributeType:
                if let uuid = value as? UUID { row[name] = uuid.uuidString }
            case .binaryDataAttributeType:
                if let data = value as? Data { row[name] = data.base64EncodedString() }
            case .URIAttributeType:
                if let url = value as? URL { row[name] = url.absoluteString }
            case .transformableAttributeType, .objectIDAttributeType, .compositeAttributeType:
                continue
            default:
                row[name] = value
            }
        }
        return row
    }

    private static func decodeRow(_ row: [String: Any], into object: NSManagedObject, description: NSEntityDescription) {
        for (name, attribute) in description.attributesByName {
            guard let raw = row[name], !(raw is NSNull) else { continue }
            switch attribute.attributeType {
            case .dateAttributeType:
                if let seconds = (raw as? NSNumber)?.doubleValue { object.setValue(Date(timeIntervalSince1970: seconds), forKey: name) }
            case .UUIDAttributeType:
                if let text = raw as? String, let uuid = UUID(uuidString: text) { object.setValue(uuid, forKey: name) }
            case .binaryDataAttributeType:
                if let text = raw as? String, let data = Data(base64Encoded: text) { object.setValue(data, forKey: name) }
            case .URIAttributeType:
                if let text = raw as? String, let url = URL(string: text) { object.setValue(url, forKey: name) }
            case .transformableAttributeType, .objectIDAttributeType, .compositeAttributeType:
                continue
            case .stringAttributeType:
                if let text = raw as? String { object.setValue(text, forKey: name) }
            default:
                object.setValue(raw, forKey: name)
            }
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

/// Reads a newline-delimited file in 1 MB blocks, so an import never holds a whole file.
private final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var finished = false

    init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }

    func nextLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.isEmpty { continue }
                return line
            }
            if finished {
                defer { buffer.removeAll() }
                return buffer.isEmpty ? nil : buffer
            }
            let chunk = (try? handle.read(upToCount: 1 << 20)) ?? Data()
            if chunk.isEmpty { finished = true } else { buffer.append(chunk) }
        }
    }
}
