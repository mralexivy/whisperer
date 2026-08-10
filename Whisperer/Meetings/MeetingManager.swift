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
    case naming
    case summarizing

    var label: String {
        switch self {
        case .finalizing:  return "Finalizing transcript"
        case .naming:      return "Naming your note"
        case .summarizing: return "Writing the overview"
        }
    }

    /// Short form for the header pill, where horizontal space is tight.
    var shortLabel: String {
        switch self {
        case .finalizing:  return "Finalizing"
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

    func setProcessing(_ phase: MeetingProcessingPhase?, for meetingID: UUID) {
        if let phase {
            processingPhases[meetingID] = phase
        } else {
            processingPhases.removeValue(forKey: meetingID)
        }
    }

    func processingPhase(for meetingID: UUID?) -> MeetingProcessingPhase? {
        guard let meetingID else { return nil }
        return processingPhases[meetingID]
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
        loadGeneration += 1
        currentOffset = 0
        meetings = []
        hasMorePages = false
        await fetchNextPage()
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
        var segments: [MeetingSegment] = []
        let dec = decoder
        await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return }
            entity.isInProgress = false
            entity.duration = duration
            if let url = audioFileURL { entity.audioFileURL = url }
            if let json = entity.segmentsJSON, let data = json.data(using: .utf8) {
                segments = (try? dec.decode([MeetingSegment].self, from: data)) ?? []
            }
            try? ctx.save()
        }

        // Update in-memory list item — no full reload
        updateItem(id: meetingID) {
            $0.isInProgress = false
            $0.duration = duration
            if let url = audioFileURL { $0.audioFileURL = url }
        }

        // Index RAG only for this newly finalized meeting
        let id = meetingID
        let segs = segments
        if !segs.isEmpty {
            Task.detached(priority: .background) {
                await MeetingAIService.shared.indexMeeting(meetingID: id, segments: segs)
            }
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
        if let record = await meeting(id: meetingID), let url = record.resolvedAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
        await MeetingRAGEngine.shared.deleteIndex(meetingID)
        await MeetingChatStore.shared.clear(meetingID: meetingID)
        await discardSession(meetingID: meetingID)
    }
}
