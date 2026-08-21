//
//  MeetingManager.swift
//  Whisperer
//
//  CoreData CRUD for meetings with lazy pagination.
//  Follows HistoryManager patterns exactly.
//

import Foundation
import CoreData
import Combine

// MARK: - Post-recording processing

/// What the app is doing to a meeting after the recording stops. Drives the processing
/// indicator so the wait between "stopped" and "overview ready" reads as work in progress
/// rather than a frozen screen.
enum MeetingProcessingPhase: Equatable {
    case finalizing
    case polishing
    case naming
    case summarizing

    var label: String {
        switch self {
        case .finalizing:  return "Finalizing transcript"
        case .polishing:   return "Re-transcribing audio"
        case .naming:      return "Naming your note"
        case .summarizing: return "Writing the overview"
        }
    }

    /// Short form for the header pill, where horizontal space is tight.
    var shortLabel: String {
        switch self {
        case .finalizing:  return "Finalizing"
        case .polishing:   return "Re-transcribing"
        case .naming:      return "Naming"
        case .summarizing: return "Summarizing"
        }
    }
}

@MainActor
class MeetingManager: ObservableObject {
    static let shared = MeetingManager()

    // MARK: - Published list state

    @Published var meetings: [MeetingListItem] = []
    @Published var isLoadingPage = false
    @Published var hasMorePages = false

    /// Meetings with a post-recording AI pass still running, keyed by meeting ID.
    @Published private(set) var processingPhases: [UUID: MeetingProcessingPhase] = [:]

    /// Optional short notice shown below the phase label in the processing banner.
    /// Non-nil when a stage was skipped or a condition worth surfacing to the user applies.
    @Published private(set) var processingNotices: [UUID: String] = [:]

    func setProcessing(_ phase: MeetingProcessingPhase?, notice: String? = nil, for meetingID: UUID) {
        if let phase {
            processingPhases[meetingID] = phase
            if let notice {
                processingNotices[meetingID] = notice
            } else {
                processingNotices.removeValue(forKey: meetingID)
            }
        } else {
            processingPhases.removeValue(forKey: meetingID)
            processingNotices.removeValue(forKey: meetingID)
        }
    }

    func processingPhase(for meetingID: UUID?) -> MeetingProcessingPhase? {
        guard let meetingID else { return nil }
        return processingPhases[meetingID]
    }

    func processingNotice(for meetingID: UUID?) -> String? {
        guard let meetingID else { return nil }
        return processingNotices[meetingID]
    }

    // MARK: - Pagination

    private var currentOffset = 0
    private let pageSize = 20
    private var loadGeneration = 0

    // MARK: - Internal

    private let database = HistoryDatabase.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        Task { await loadMeetings() }
    }

    // MARK: - Read (paginated)

    /// Reset list and load first page. Call once on init and after delete.
    func loadMeetings() async {
        // Opportunistically sweep for orphaned .wax files from the deleted RAG engine.
        cleanupOrphanedWaxFiles()
        loadGeneration += 1
        currentOffset = 0
        meetings = []
        hasMorePages = false
        await fetchNextPage()
    }

    /// Sweeps the Meetings directory and removes any .wax index files. These were
    /// written by the now-deleted MeetingRAGEngine and are no longer used.
    private func cleanupOrphanedWaxFiles() {
        let fm = FileManager.default
        let meetingsDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whisperer/Meetings", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: meetingsDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "wax" {
            try? fm.removeItem(at: file)
            Logger.info("MeetingManager: cleaned up orphaned .wax file \(file.lastPathComponent)", subsystem: .app)
        }
    }

    /// Append the next page of results. Safe to call repeatedly — guards against double-fetch.
    func loadNextPage() async {
        guard hasMorePages && !isLoadingPage else { return }
        await fetchNextPage()
    }

    private func fetchNextPage() async {
        let generation = loadGeneration
        let offset = currentOffset
        isLoadingPage = true

        let ctx = database.newBackgroundContext()
        let items = await ctx.perform { () -> [MeetingListItem] in
            let req = MeetingEntity.fetchRequest()
            req.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            req.fetchOffset = offset
            req.fetchLimit = self.pageSize
            guard let entities = try? ctx.fetch(req) else { return [] }
            return entities.map { MeetingListItem(from: $0) }
        }

        guard loadGeneration == generation else {
            isLoadingPage = false
            return
        }

        meetings.append(contentsOf: items)
        currentOffset = offset + items.count
        hasMorePages = items.count == pageSize
        isLoadingPage = false
    }

    /// Fetch a single full record (used by MeetingDetailViewModel and internal helpers).
    func meeting(id: UUID) async -> MeetingRecord? {
        let ctx = database.newBackgroundContext()
        return await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return nil }
            return MeetingRecord(from: entity)
        }
    }

    // MARK: - In-memory update helper

    private func updateItem(id: UUID, _ transform: (inout MeetingListItem) -> Void) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        transform(&meetings[i])
    }

    // MARK: - Create

    func beginSession(title: String, language: String, modelUsed: String) async -> UUID {
        let id = UUID()
        let ctx = database.newBackgroundContext()
        await ctx.perform {
            let entity = MeetingEntity(context: ctx)
            entity.id = id
            entity.title = title
            entity.createdAt = Date()
            entity.duration = 0
            entity.language = language
            entity.modelUsed = modelUsed
            entity.isInProgress = true
            entity.wordCount = 0
            try? ctx.save()
        }
        // Prepend to in-memory list — no full reload
        let newItem = MeetingListItem(id: id, title: title, language: language)
        meetings.insert(newItem, at: 0)
        currentOffset += 1
        return id
    }

    // MARK: - Append segment

    func appendSegment(meetingID: UUID, segment: MeetingSegment, duration: Double) async {
        let ctx = database.newBackgroundContext()
        let enc = encoder
        let dec = decoder
        let words = segment.text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.count

        await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return }

            var segments: [MeetingSegment] = []
            if let json = entity.segmentsJSON, let data = json.data(using: .utf8) {
                segments = (try? dec.decode([MeetingSegment].self, from: data)) ?? []
            }
            segments.append(segment)
            if let data = try? enc.encode(segments),
               let json = String(data: data, encoding: .utf8) {
                entity.segmentsJSON = json
            }
            entity.wordCount += Int32(words)
            entity.duration = duration
            try? ctx.save()
        }

        // Update scalar fields in-memory — no full reload
        updateItem(id: meetingID) {
            $0.wordCount += words
            $0.duration = duration
        }
    }

    // MARK: - Update segment (speaker rename / text edit)

    func updateSegment(meetingID: UUID, segment: MeetingSegment) async {
        let ctx = database.newBackgroundContext()
        let enc = encoder
        let dec = decoder
        await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return }

            var segments: [MeetingSegment] = []
            if let json = entity.segmentsJSON, let data = json.data(using: .utf8) {
                segments = (try? dec.decode([MeetingSegment].self, from: data)) ?? []
            }
            if let idx = segments.firstIndex(where: { $0.id == segment.id }) {
                segments[idx] = segment
            }
            if let data = try? enc.encode(segments),
               let json = String(data: data, encoding: .utf8) {
                entity.segmentsJSON = json
            }
            try? ctx.save()
        }
        // In-memory update handled by MeetingDetailViewModel.updateSegmentInMemory
    }

    /// Replace the whole segment array in one write.
    ///
    /// `updateSegment` decodes and re-encodes the entire blob per call, so writing N segments
    /// through it is quadratic. The polish pass rewrites every segment, so it uses this instead:
    /// one fetch, one encode, one save per batch.
    func updateSegments(meetingID: UUID, segments: [MeetingSegment]) async {
        let ctx = database.newBackgroundContext()
        let enc = encoder
        let words = segments.reduce(0) {
            $0 + $1.text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        }
        await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return }
            guard let data = try? enc.encode(segments),
                  let json = String(data: data, encoding: .utf8) else { return }
            entity.segmentsJSON = json
            entity.wordCount = Int32(words)
            try? ctx.save()
        }
        updateItem(id: meetingID) { $0.wordCount = words }
    }

    // MARK: - Bulk speaker rename

    func renameSpeaker(meetingID: UUID, oldName: String, newName: String) async {
        let ctx = database.newBackgroundContext()
        let enc = encoder
        let dec = decoder
        await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return }

            var segments: [MeetingSegment] = []
            if let json = entity.segmentsJSON, let data = json.data(using: .utf8) {
                segments = (try? dec.decode([MeetingSegment].self, from: data)) ?? []
            }
            for i in segments.indices where segments[i].speakerName == oldName {
                segments[i].speakerName = newName
            }
            if let data = try? enc.encode(segments),
               let json = String(data: data, encoding: .utf8) {
                entity.segmentsJSON = json
            }
            try? ctx.save()
        }
        // In-memory update handled by MeetingDetailViewModel.renameSpeakerInMemory
    }

    // MARK: - Finalize

    func finalizeSession(meetingID: UUID, duration: Double, audioFileURL: String?) async {
        let ctx = database.newBackgroundContext()
        let dec = decoder
        await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return }
            entity.isInProgress = false
            entity.duration = duration
            if let url = audioFileURL { entity.audioFileURL = url }
            try? ctx.save()
        }

        // Update in-memory list item — no full reload
        updateItem(id: meetingID) {
            $0.isInProgress = false
            $0.duration = duration
            if let url = audioFileURL { $0.audioFileURL = url }
        }
    }

    // MARK: - Discard

    func discardSession(meetingID: UUID) async {
        let ctx = database.newBackgroundContext()
        await ctx.perform {
            ctx.mergePolicy = NSOverwriteMergePolicy
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return }
            ctx.delete(entity)
            try? ctx.save()
        }
        meetings.removeAll { $0.id == meetingID }
        if currentOffset > 0 { currentOffset -= 1 }
    }

    // MARK: - Metadata updates

    func updateTitle(meetingID: UUID, title: String) async {
        let ctx = database.newBackgroundContext()
        await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return }
            entity.title = title
            try? ctx.save()
        }
        updateItem(id: meetingID) { $0.title = title }
    }

    /// Persist the language the meeting was actually spoken in.
    ///
    /// `beginSession` writes the *setting* into this column, which for the default Auto is the
    /// literal `"auto"` — never the resolved language. `MeetingLanguageTimeline` is what finally
    /// knows the answer, and the detail view's language chip reads it back from here.
    func updateLanguage(meetingID: UUID, language: String) async {
        let ctx = database.newBackgroundContext()
        await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return }
            entity.language = language
            try? ctx.save()
        }
    }

    func updateNotes(meetingID: UUID, notes: [MeetingNote]) async {
        let ctx = database.newBackgroundContext()
        let enc = encoder
        await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return }
            if let data = try? enc.encode(notes),
               let json = String(data: data, encoding: .utf8) {
                entity.notesJSON = json
            }
            try? ctx.save()
        }
        // Notes live in full MeetingRecord; no scalar to update in MeetingListItem
    }

    func updateAISummary(meetingID: UUID, summary: MeetingAISummary) async {
        let ctx = database.newBackgroundContext()
        let enc = encoder
        await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return }
            if let data = try? enc.encode(summary),
               let json = String(data: data, encoding: .utf8) {
                entity.aiSummaryJSON = json
            }
            try? ctx.save()
        }
        // MeetingDetailViewModel observes meetingOverviewDidGenerate and calls refreshDetail()
    }

    func updateActionItem(meetingID: UUID, item: MeetingActionItem) async {
        guard let meeting = await meeting(id: meetingID) else { return }
        guard var summary = meeting.aiSummary else { return }
        if let idx = summary.actionItems.firstIndex(where: { $0.id == item.id }) {
            summary.actionItems[idx] = item
        }
        await updateAISummary(meetingID: meetingID, summary: summary)
    }

    // MARK: - Crash recovery

    func loadInProgressSessions() async -> [MeetingRecord] {
        let ctx = database.newBackgroundContext()
        return await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "isInProgress == YES")
            guard let entities = try? ctx.fetch(req) else { return [] }
            return entities.map { MeetingRecord(from: $0) }
        }
    }

    func recoverCrashedSessions() async {
        let orphans = await loadInProgressSessions()
        guard !orphans.isEmpty else { return }
        Logger.info("Meeting crash recovery: finalizing \(orphans.count) interrupted session(s)", subsystem: .app)

        for record in orphans {
            if let pending = MeetingPendingStore.load(meetingID: record.id), !pending.text.isEmpty {
                Logger.info("Meeting crash recovery: recovering \(pending.text.count) chars for \(record.id)", subsystem: .app)
                let segment = MeetingSegment(
                    timestamp: pending.startTimestamp,
                    endTimestamp: record.duration,
                    text: pending.text,
                    speakerName: "Speaker 1",
                    speakerIndex: 0
                )
                await appendSegment(meetingID: record.id, segment: segment, duration: record.duration)
                MeetingPendingStore.clear(meetingID: record.id)
            }

            await finalizeSession(
                meetingID: record.id,
                duration: record.duration,
                audioFileURL: record.audioFileURL
            )
        }
    }

    // MARK: - Delete

    func deleteMeeting(meetingID: UUID) async {
        // Stop any polish run first — it would otherwise keep writing segments to a row
        // that is about to be deleted.
        MeetingTranscriptRefiner.shared.cancel(meetingID: meetingID)
        if let record = await meeting(id: meetingID), let url = record.resolvedAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
        // Remove any orphaned .wax index file (opportunistic — no Wax dependency needed).
        removeWaxFile(for: meetingID)
        await MeetingChatStore.shared.clear(meetingID: meetingID)
        await discardSession(meetingID: meetingID)
    }

    /// Removes a `.wax` index file for the given meeting ID if one exists on disk.
    private func removeWaxFile(for meetingID: UUID) {
        let meetingsDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whisperer/Meetings", isDirectory: true)
        let waxURL = meetingsDir.appendingPathComponent("\(meetingID).wax")
        guard FileManager.default.fileExists(atPath: waxURL.path) else { return }
        try? FileManager.default.removeItem(at: waxURL)
        Logger.info("MeetingManager: removed .wax index for \(meetingID)", subsystem: .app)
    }

    /// Meetings created before `cutoff`, with the on-disk size of each recording measured while
    /// the file still exists. The retention sweep deletes them one by one through
    /// `deleteMeeting` so the `.wax` index and the chat JSON go with the row — this only
    /// answers *which*.
    ///
    /// Ages on `createdAt` rather than file mtime (a refine pass rewrites mtime), and skips
    /// `isInProgress` rows, which belong to crash recovery.
    func expiredMeetings(before cutoff: Date) async -> [(id: UUID, audioBytes: Int64)] {
        let ctx = database.newBackgroundContext()
        return await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(
                format: "createdAt < %@ AND isInProgress == NO", cutoff as NSDate
            )
            guard let entities = try? ctx.fetch(req) else { return [] }

            let meetingsDir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Whisperer/Meetings")

            return entities.map { entity -> (UUID, Int64) in
                var bytes: Int64 = 0
                if let rel = entity.audioFileURL, !rel.isEmpty {
                    let url = meetingsDir.appendingPathComponent(rel)
                    bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        .flatMap { Int64($0) } ?? 0
                }
                return (entity.id, bytes)
            }
        }
    }

    // MARK: - Library compaction

    /// Meetings whose audio predates the Opus archive format, as `(id, bare filename)`.
    /// `isInProgress` rows are excluded — that file is still being written.
    func legacyAudioMeetings() async -> [(id: UUID, fileName: String)] {
        let ctx = database.newBackgroundContext()
        return await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "audioFileURL != nil AND isInProgress == NO")
            guard let entities = try? ctx.fetch(req) else { return [] }
            return entities.compactMap { entity in
                guard let name = entity.audioFileURL, !name.isEmpty else { return nil }
                guard !AudioArchiveFormat.isAlreadyArchived(URL(fileURLWithPath: name)) else { return nil }
                return (entity.id, name)
            }
        }
    }

    /// Repoint a meeting at a different file in `Meetings/`. Compaction commits this
    /// **before** unlinking the original, so a failed save leaves the row on a live file.
    func updateAudioFileName(meetingID: UUID, fileName: String) async -> Bool {
        let ctx = database.newBackgroundContext()
        let saved = await ctx.perform { () -> Bool in
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return false }
            entity.audioFileURL = fileName
            do {
                try ctx.save()
                return true
            } catch {
                Logger.error("Compaction: failed to repoint meeting \(meetingID): \(error)", subsystem: .audio)
                return false
            }
        }
        guard saved else { return false }
        updateItem(id: meetingID) { $0.audioFileURL = fileName }
        return true
    }
}
