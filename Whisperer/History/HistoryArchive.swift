//
//  HistoryArchive.swift
//  Whisperer
//
//  Export all history to one file and import it into another workspace.
//
//  Format: an Apple Archive (`.aar`, LZFSE) of a plain folder —
//
//      manifest.json            format version, counts, app version
//      transcriptions.jsonl     one Core Data row per line
//      meetings.jsonl           one Core Data row per line
//      audio/                   dictation recordings, by their stored file name
//      meeting-audio/           meeting recordings
//      meeting-chat/            the Ask-AI thread of each meeting
//
//  Why Apple Archive: it is the system's own archive format (Finder and Archive Utility open it),
//  streams in constant memory, compresses on all cores, keeps working inside the App Sandbox with
//  no helper process, and needs no dependency. Zip would need a third-party package to read back.
//  The audio is already Opus, so compression pays on the text; the recordings are staged with
//  APFS clones (no second copy on disk) and stored as they are.
//
//  Rows are written generically from the Core Data model (every attribute of the entity), so a
//  column added to the model later is exported and imported without touching this file. Import is a
//  merge: a row whose id already exists is skipped, never overwritten.
//

import Foundation
import CoreData
import AppleArchive
import System

nonisolated enum HistoryArchive {

    // MARK: - Public types

    struct Paths: Sendable {
        var recordings: URL
        var meetingRecordings: URL
        var meetingData: URL
        var staging: URL

        static var app: Paths {
            Paths(recordings: AudioLibraryPaths.recordings,
                  meetingRecordings: AudioLibraryPaths.meetingRecordings,
                  meetingData: AudioLibraryPaths.meetingData,
                  staging: FileManager.default.temporaryDirectory)
        }
    }

    struct Progress: Sendable {
        var phase: String
        var fraction: Double
    }

    struct ExportSummary: Sendable, Equatable {
        var transcriptions = 0
        var meetings = 0
        var audioFiles = 0
        var audioBytes: Int64 = 0
        var archiveBytes: Int64 = 0
    }

    struct ImportSummary: Sendable, Equatable {
        var transcriptionsAdded = 0
        var meetingsAdded = 0
        var alreadyPresent = 0
        var audioFilesAdded = 0
        var audioMissing = 0
        var chatsAdded = 0
        var added: Int { transcriptionsAdded + meetingsAdded }
    }

    enum ArchiveError: LocalizedError {
        case streamUnavailable
        case notAnArchive
        case newerFormat(Int)
        case storeUnavailable

        var errorDescription: String? {
            switch self {
            case .streamUnavailable: return "The archive file could not be opened."
            case .notAnArchive: return "This file is not a Whisperer history archive."
            case .newerFormat(let v): return "This archive was made by a newer version of Whisperer (format \(v)). Update the app to import it."
            case .storeUnavailable: return "The history database is not available."
            }
        }
    }

    static let formatVersion = 1
    static let fileExtension = "aar"

    private static let entities: [(name: String, file: String, audioDir: String)] = [
        ("TranscriptionEntity", "transcriptions.jsonl", "audio"),
        ("MeetingEntity", "meetings.jsonl", "meeting-audio"),
    ]
    private static let chatDir = "meeting-chat"
    private static let batchSize = 200

    static func suggestedFileName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "Whisperer History \(f.string(from: now)).\(fileExtension)"
    }

    // MARK: - Export

    @discardableResult
    static func export(to destination: URL,
                       database: HistoryDatabase = .shared,
                       paths: Paths = .app,
                       locateMeetingAudio: @escaping @Sendable (String) -> URL? = { MeetingManager.locateAudio(storedName: $0) },
                       progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> ExportSummary {
        let fm = FileManager.default
        let stage = paths.staging.appendingPathComponent("WhispererExport-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }

        guard database.persistentContainer != nil else { throw ArchiveError.storeUnavailable }
        let context = database.newBackgroundContext()
        var summary = ExportSummary()
        var stagedAudio = Set<String>()

        for (index, entity) in entities.enumerated() {
            progress(Progress(phase: "Collecting \(entity.name == "MeetingEntity" ? "meetings" : "transcriptions")",
                              fraction: Double(index) / Double(entities.count + 1) * 0.8))
            let rowsFile = stage.appendingPathComponent(entity.file)
            fm.createFile(atPath: rowsFile.path, contents: nil)
            let handle = try FileHandle(forWritingTo: rowsFile)
            defer { try? handle.close() }
            let audioStage = stage.appendingPathComponent(entity.audioDir, isDirectory: true)
            let chatStage = stage.appendingPathComponent(chatDir, isDirectory: true)
            let isMeeting = entity.name == "MeetingEntity"

            // Rows are written and their files staged inside one `perform`, in batches, so a
            // library of any size is never held in memory.
            let counts: (rows: Int, audio: Int, bytes: Int64, staged: Set<String>) = try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: entity.name)
                request.predicate = NSPredicate(format: "isInProgress == NO")
                request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
                request.fetchBatchSize = batchSize
                let objects = try context.fetch(request)
                var rows = 0, audio = 0
                var bytes: Int64 = 0
                var staged = stagedAudio
                var buffer = Data()
                for object in objects {
                    var row = encodeRow(object)
                    if let name = object.value(forKey: "audioFileURL") as? String, !name.isEmpty {
                        let base = (name as NSString).lastPathComponent
                        let source = isMeeting ? locateMeetingAudio(name)
                                               : existing(paths.recordings.appendingPathComponent(base))
                        if let source {
                            if staged.insert("\(entity.audioDir)/\(base)").inserted {
                                try fm.createDirectory(at: audioStage, withIntermediateDirectories: true)
                                // `copyItem` clones on APFS: the recording is staged without a second copy.
                                try fm.copyItem(at: source, to: audioStage.appendingPathComponent(base))
                                audio += 1
                                bytes += (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                            }
                            row["audioFileURL"] = base
                        } else {
                            row["audioFileURL"] = base
                            row["_audioMissing"] = true
                        }
                    }
                    if isMeeting, let id = object.value(forKey: "id") as? UUID {
                        let chat = paths.meetingData.appendingPathComponent("\(id)-chat.json")
                        if fm.fileExists(atPath: chat.path) {
                            try fm.createDirectory(at: chatStage, withIntermediateDirectories: true)
                            try fm.copyItem(at: chat, to: chatStage.appendingPathComponent("\(id).json"))
                        }
                    }
                    if let line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                        buffer.append(line)
                        buffer.append(0x0A)
                        rows += 1
                    }
                    if buffer.count > 1 << 20 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
                    if rows % batchSize == 0 { context.refreshAllObjects() }
                }
                try handle.write(contentsOf: buffer)
                return (rows, audio, bytes, staged)
            }
            stagedAudio = counts.staged
            summary.audioFiles += counts.audio
            summary.audioBytes += counts.bytes
            if isMeeting { summary.meetings = counts.rows } else { summary.transcriptions = counts.rows }
        }

        let manifest: [String: Any] = [
            "format": formatVersion,
            "app": "Whisperer",
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "transcriptions": summary.transcriptions,
            "meetings": summary.meetings,
            "audioFiles": summary.audioFiles,
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: stage.appendingPathComponent("manifest.json"))

        progress(Progress(phase: "Compressing", fraction: 0.85))
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial")
        try? fm.removeItem(at: temporary)
        do {
            try await Task.detached(priority: .userInitiated) { try writeArchive(of: stage, to: temporary) }.value
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
        summary.archiveBytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        progress(Progress(phase: "Done", fraction: 1))
        return summary
    }

    private static func existing(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func writeArchive(of directory: URL, to destination: URL) throws {
        guard let file = ArchiveByteStream.fileStream(path: FilePath(destination.path), mode: .writeOnly,
                                                      options: [.create, .truncate],
                                                      permissions: FilePermissions(rawValue: 0o644)),
              let compressed = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: file),
              let encoder = ArchiveStream.encodeStream(writingTo: compressed) else {
            throw ArchiveError.streamUnavailable
        }
        let keys = ArchiveHeader.FieldKeySet("TYP,PAT,DAT,MOD,MTM")!
        do {
            try encoder.writeDirectoryContents(archiveFrom: FilePath(directory.path), keySet: keys)
        } catch {
            try? encoder.close(); try? compressed.close(); try? file.close()
            throw error
        }
        try encoder.close()
        try compressed.close()
        try file.close()
    }

    // MARK: - Import

    @discardableResult
    static func importArchive(from source: URL,
                              database: HistoryDatabase = .shared,
                              paths: Paths = .app,
                              progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> ImportSummary {
        let fm = FileManager.default
        guard database.persistentContainer != nil else { throw ArchiveError.storeUnavailable }
        let work = paths.staging.appendingPathComponent("WhispererImport-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        progress(Progress(phase: "Reading archive", fraction: 0.05))
        try await Task.detached(priority: .userInitiated) { try extractArchive(at: source, to: work) }.value

        let manifestURL = work.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              manifest["app"] as? String == "Whisperer",
              let version = manifest["format"] as? Int else { throw ArchiveError.notAnArchive }
        guard version <= formatVersion else { throw ArchiveError.newerFormat(version) }

        let context = database.newBackgroundContext()
        var summary = ImportSummary()
        for (index, entity) in entities.enumerated() {
            let isMeeting = entity.name == "MeetingEntity"
            progress(Progress(phase: "Importing \(isMeeting ? "meetings" : "transcriptions")",
                              fraction: 0.3 + 0.6 * Double(index) / Double(entities.count)))
            let rowsURL = work.appendingPathComponent(entity.file)
            guard fm.fileExists(atPath: rowsURL.path) else { continue }
            let audioFolder = work.appendingPathComponent(entity.audioDir, isDirectory: true)
            let destinationAudio = isMeeting ? paths.meetingRecordings : paths.recordings
            let chatSource = work.appendingPathComponent(chatDir, isDirectory: true)

            let part: ImportSummary = try await context.perform {
                var part = ImportSummary()
                guard let description = NSEntityDescription.entity(forEntityName: entity.name, in: context) else {
                    throw ArchiveError.storeUnavailable
                }
                let idRequest = NSFetchRequest<NSDictionary>(entityName: entity.name)
                idRequest.resultType = .dictionaryResultType
                idRequest.propertiesToFetch = ["id"]
                var known = Set((try context.fetch(idRequest)).compactMap { $0["id"] as? UUID })

                let reader = try LineReader(url: rowsURL)
                var pending = 0
                while let line = reader.nextLine() {
                    guard let row = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          let idString = row["id"] as? String, let id = UUID(uuidString: idString) else { continue }
                    if known.contains(id) { part.alreadyPresent += 1; continue }
                    known.insert(id)

                    let object = NSManagedObject(entity: description, insertInto: context)
                    decodeRow(row, into: object, description: description)

                    if let stored = object.value(forKey: "audioFileURL") as? String, !stored.isEmpty {
                        let base = (stored as NSString).lastPathComponent
                        let staged = audioFolder.appendingPathComponent(base)
                        if isSafeName(base), fm.fileExists(atPath: staged.path) {
                            try fm.createDirectory(at: destinationAudio, withIntermediateDirectories: true)
                            let final = try place(staged, named: base, in: destinationAudio)
                            object.setValue(final, forKey: "audioFileURL")
                            part.audioFilesAdded += 1
                        } else {
                            part.audioMissing += 1
                        }
                    }
                    if isMeeting {
                        let chat = chatSource.appendingPathComponent("\(id).json")
                        if fm.fileExists(atPath: chat.path) {
                            try fm.createDirectory(at: paths.meetingData, withIntermediateDirectories: true)
                            let target = paths.meetingData.appendingPathComponent("\(id)-chat.json")
                            if !fm.fileExists(atPath: target.path) {
                                try fm.moveItem(at: chat, to: target)
                                part.chatsAdded += 1
                            }
                        }
                        part.meetingsAdded += 1
                    } else {
                        part.transcriptionsAdded += 1
                    }
                    pending += 1
                    if pending >= batchSize {
                        try context.save()
                        context.reset()
                        pending = 0
                    }
                }
                if context.hasChanges { try context.save() }
                context.reset()
                return part
            }
            summary.transcriptionsAdded += part.transcriptionsAdded
            summary.meetingsAdded += part.meetingsAdded
            summary.alreadyPresent += part.alreadyPresent
            summary.audioFilesAdded += part.audioFilesAdded
            summary.audioMissing += part.audioMissing
            summary.chatsAdded += part.chatsAdded
        }
        progress(Progress(phase: "Done", fraction: 1))
        return summary
    }

    private static func extractArchive(at source: URL, to directory: URL) throws {
        guard let file = ArchiveByteStream.fileStream(path: FilePath(source.path), mode: .readOnly,
                                                      options: [], permissions: []),
              let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file),
              let decoder = ArchiveStream.decodeStream(readingFrom: decompressed) else {
            throw ArchiveError.notAnArchive
        }
        defer { try? decoder.close(); try? decompressed.close(); try? file.close() }
        // Only paths inside the destination are written: an archive is input from outside.
        guard let extractor = ArchiveStream.extractStream(
            extractingTo: FilePath(directory.path),
            selectUsing: { message, path, _ in
                guard message == .extractBegin else { return .ok }
                return isUnsafeEntryPath(path.string) ? .skip : .ok
            },
            flags: [.ignoreOperationNotPermitted]) else {
            throw ArchiveError.streamUnavailable
        }
        defer { try? extractor.close() }
        do {
            _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor)
        } catch {
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
