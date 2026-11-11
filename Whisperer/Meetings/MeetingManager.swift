//
//  MeetingManager.swift
//  Whisperer
//
//  CoreData CRUD for meetings with lazy pagination.
//  Follows HistoryManager patterns exactly.
//

import AVFoundation
import Foundation
import CoreData
import Combine

// MARK: - Post-recording processing

/// What the app is doing to a meeting after the recording stops. Drives the processing
/// indicator so the wait between "stopped" and "overview ready" reads as work in progress
/// rather than a frozen screen.
enum MeetingProcessingPhase: Equatable {
    case finalizing
    case fineTuning
    case naming
    case summarizing
    /// Waiting in queue behind another meeting's post-processing.
    case queued
    /// Post-processing paused because a new recording is in progress.
    case pausedForRecording

    var label: String {
        switch self {
        case .finalizing:         return "Finalizing transcript"
        case .fineTuning:         return "Fine-tuning the transcript"
        case .naming:             return "Naming your note"
        case .summarizing:        return "Writing the overview"
        case .queued:             return "Waiting to post-process"
        case .pausedForRecording: return "Paused — recording in progress"
        }
    }

    /// Short form for the header pill, where horizontal space is tight.
    var shortLabel: String {
        switch self {
        case .finalizing:         return "Finalizing"
        case .fineTuning:         return "Fine-tuning"
        case .naming:             return "Naming"
        case .summarizing:        return "Summarizing"
        case .queued:             return "Queued"
        case .pausedForRecording: return "Paused"
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

    func beginSession(title: String, language: String, modelUsed: String,
                      sourceBundleID: String? = nil, sourceAppName: String? = nil) async -> UUID {
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
            entity.sourceBundleID = sourceBundleID
            entity.sourceAppName = sourceAppName
            try? ctx.save()
        }
        // Prepend to in-memory list — no full reload
        let newItem = MeetingListItem(id: id, title: title, language: language,
                                     sourceBundleID: sourceBundleID, sourceAppName: sourceAppName)
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
        // The word count splits every card of a possibly hours-long transcript, so it runs on
        // the context's queue with the encode rather than on the main actor.
        let words: Int = await ctx.perform {
            let words = segments.reduce(0) {
                $0 + $1.text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
            }
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return words }
            guard let data = try? enc.encode(segments),
                  let json = String(data: data, encoding: .utf8) else { return words }
            entity.segmentsJSON = json
            entity.wordCount = Int32(words)
            try? ctx.save()
            return words
        }
        updateItem(id: meetingID) { $0.wordCount = words }
        NotificationCenter.default.post(name: .meetingSegmentsDidPersist, object: meetingID)
    }

    // MARK: - Bulk speaker rename

    /// Renames every segment that belongs to `speakerIndex` — keyed by index, not by name,
    /// so two speakers that happen to share a name are always updated independently.
    func renameSpeaker(meetingID: UUID, speakerIndex: Int, newName: String) async {
        let ctx = database.newBackgroundContext()
        let enc = encoder
        let dec = decoder
        do {
            _ = try await ctx.performAndSave("renameSpeaker") { ctx in
                let req = MeetingEntity.fetchRequest()
                req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
                req.fetchLimit = 1
                guard let entity = try ctx.fetch(req).first else {
                    Logger.debug("renameSpeaker: meeting \(meetingID) no longer exists", subsystem: .app)
                    return
                }
                var segments: [MeetingSegment] = []
                if let json = entity.segmentsJSON, let data = json.data(using: .utf8) {
                    segments = (try? dec.decode([MeetingSegment].self, from: data)) ?? []
                }
                // The index came from a normalized read (`MeetingRecord`); rename in the same
                // numbering, and store it that way so the row stops needing normalizing.
                segments = segments.normalizedSpeakerOrder()
                segments.renameSpeaker(index: speakerIndex, to: newName)
                if let data = try? enc.encode(segments),
                   let json = String(data: data, encoding: .utf8) {
                    entity.segmentsJSON = json
                }
            }
        } catch {
            Logger.error("renameSpeaker failed to save for meeting \(meetingID): \(error)", subsystem: .app)
        }
        // In-memory update handled by MeetingDetailViewModel.renameSpeakerInMemory
    }

    // MARK: - Finalize

    func finalizeSession(meetingID: UUID, duration: Double, audioFileURL: String?) async {
        let ctx = database.newBackgroundContext()
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
        NotificationCenter.default.post(name: .meetingSegmentsDidPersist, object: meetingID)
    }

    /// Flags a meeting whose input never delivered a non-silent sample.
    ///
    /// Row 39 of 2026-09-14 sat in history as an ordinary 58-minute meeting with 0 words, which
    /// is indistinguishable from a meeting nobody has opened yet. This is the difference.
    func markCaptureFailed(meetingID: UUID) async {
        let ctx = database.newBackgroundContext()
        await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return }
            entity.captureFailed = true
            try? ctx.save()
        }
        updateItem(id: meetingID) { $0.captureFailed = true }
        Logger.warning("Meeting \(meetingID) marked as capture-failed — no audio was ever received",
                       subsystem: .app)
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

    /// Update the meeting title.
    ///
    /// - Parameters:
    ///   - userEdited: Pass `true` when the change comes from a user action (typing in the
    ///     title field). The entity's `titleIsUserSet` flag is then set to `true` and is
    ///     never cleared — automatic LLM naming will not overwrite the title afterward.
    ///     Pass `false` for AI-generated titles; `titleIsUserSet` is left unchanged.
    func updateTitle(meetingID: UUID, title: String, userEdited: Bool) async {
        let ctx = database.newBackgroundContext()
        await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return }
            entity.title = title
            if userEdited { entity.titleIsUserSet = true }
            try? ctx.save()
        }
        updateItem(id: meetingID) { item in
            item.title = title
            if userEdited { item.titleIsUserSet = true }
        }
    }

    /// Attach the calendar invite's participants to a recording linked to that event.
    func updateParticipants(meetingID: UUID, participants: [MeetingParticipant]) async {
        guard let data = try? JSONEncoder().encode(participants),
              let json = String(data: data, encoding: .utf8) else { return }
        let ctx = database.newBackgroundContext()
        await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return }
            entity.participantsJSON = json
            try? ctx.save()
        }
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

    /// Read-modify-write of a meeting's notes inside one Core Data `perform`, so a note an AI
    /// app adds through MCP and one the user adds can't overwrite each other. Returns the new
    /// notes, or nil when the meeting doesn't exist.
    func mutateNotes(meetingID: UUID, _ transform: @escaping @Sendable ([MeetingNote]) -> [MeetingNote]) async -> [MeetingNote]? {
        let ctx = database.newBackgroundContext()
        let enc = encoder
        return await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", meetingID as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return nil }
            let current: [MeetingNote] = entity.notesJSON
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([MeetingNote].self, from: $0) } ?? []
            let updated = transform(current)
            if let data = try? enc.encode(updated), let json = String(data: data, encoding: .utf8) {
                entity.notesJSON = json
                try? ctx.save()
            }
            return updated
        }
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

    // MARK: - Audio file location

    /// Where a meeting's recording is: `Meetings/` once the meeting has ended, `Sessions/` while it
    /// records — the row names its file from the first second, so a crash, a force quit or an
    /// abandoned meeting still finds it. Defaults to `Meetings/` when neither exists yet.
    nonisolated static func audioURL(forFileName name: String) -> URL {
        locateAudio(storedName: name) ?? audioCandidates(storedName: name)[0]
    }

    /// Every place a meeting's recording has lived, in the order builds have used them. Rows keep
    /// whatever their build wrote — a bare name in `Meetings/` (the normal case), a name still in
    /// `Sessions/` (a meeting that never reached a normal stop), an absolute path or `file://` URL,
    /// and pre-Opus `.caf` / `.wav` / `.m4a` files the optional compaction never rewrote. Nothing
    /// is moved or renamed to make an old row fit; the lookup comes to the file.
    nonisolated static func audioCandidates(storedName raw: String) -> [URL] {
        let stored = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var urls: [URL] = []
        if stored.hasPrefix("file://"), let url = URL(string: stored) {
            urls.append(url)
        } else if stored.hasPrefix("/") {
            urls.append(URL(fileURLWithPath: stored))
        }
        let name = urls.first?.lastPathComponent ?? (stored as NSString).lastPathComponent
        let folders = AudioLibraryPaths.meetingAudioFolders
        for folder in folders { urls.append(folder.appendingPathComponent(name)) }
        let base = (name as NSString).deletingPathExtension
        for ext in ["opus", "caf", "wav", "m4a"] where ext != (name as NSString).pathExtension.lowercased() {
            for folder in folders { urls.append(folder.appendingPathComponent("\(base).\(ext)")) }
        }
        if urls.isEmpty || name.isEmpty { urls.insert(folders[0].appendingPathComponent(stored), at: 0) }
        return urls
    }

    /// The first candidate that exists, or nil when the recording is on none of them.
    nonisolated static func locateAudio(storedName name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        return audioCandidates(storedName: name).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Brings a meeting's recording into `Recordings/Meetings/`, where it is kept, from whichever
    /// older folder it is in (`Sessions/` — swept after 7 days — or the old `Meetings/`). Returns
    /// true when the file is there afterwards. Never overwrites, never deletes.
    @discardableResult
    nonisolated static func adoptSessionAudio(fileName name: String) -> Bool {
        let fm = FileManager.default
        let base = (name as NSString).lastPathComponent
        let dest = AudioLibraryPaths.meetingRecordings.appendingPathComponent(base)
        if fm.fileExists(atPath: dest.path) { return true }
        guard let source = locateAudio(storedName: name) else { return false }
        AudioLibraryPaths.ensure(AudioLibraryPaths.meetingRecordings)
        do {
            try fm.moveItem(at: source, to: dest)
        } catch {
            Logger.warning("Meetings: could not move \(base) into Recordings/Meetings (\(error.localizedDescription)) — it stays where it is", subsystem: .app)
            return false
        }
        return fm.fileExists(atPath: dest.path)
    }

    /// One pass at launch: every meeting's recording that is still in an older folder moves into
    /// `Recordings/Meetings/`, and a row holding a path instead of a name gets the name. A file is
    /// moved only when it exists and nothing is at the destination; a row is changed only after
    /// its file has arrived. Idempotent — a second run finds nothing to do.
    func migrateAudioLayout() async {
        let ctx = database.newBackgroundContext()
        let rows: [(id: UUID, name: String)] = await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "audioFileURL != nil AND audioFileURL != '' AND isInProgress == NO")
            return ((try? ctx.fetch(req)) ?? []).compactMap { e in e.audioFileURL.map { (e.id, $0) } }
        }
        let target = AudioLibraryPaths.meetingRecordings.standardizedFileURL.path
        var moved = 0, renamed = 0, failed = 0
        for row in rows {
            guard let located = Self.locateAudio(storedName: row.name) else { continue }
            let base = located.lastPathComponent
            if located.deletingLastPathComponent().standardizedFileURL.path != target {
                guard Self.adoptSessionAudio(fileName: located.path) else { failed += 1; continue }
                moved += 1
            }
            if row.name != base, await updateAudioFileName(meetingID: row.id, fileName: base) { renamed += 1 }
        }
        if moved + renamed + failed > 0 {
            Logger.info("Meetings: audio layout — \(moved) recording(s) moved into Recordings/Meetings, \(renamed) row(s) repointed, \(failed) left in place", subsystem: .app)
        }
    }

    /// Every file name a meeting row refers to — protected from the `Sessions/` sweep.
    func referencedAudioFileNames() async -> Set<String> {
        let ctx = database.newBackgroundContext()
        return await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "audioFileURL != nil")
            return Set(((try? ctx.fetch(req)) ?? []).compactMap { $0.audioFileURL.map { ($0 as NSString).lastPathComponent } })
        }
    }

    // MARK: - Orphaned recordings

    /// Gives meetings without audio back their recording, when it is still on disk.
    ///
    /// Builds before 2026-11-09 attached a meeting's file only at a normal stop, so a meeting
    /// abandoned when the mic failed (a 65-minute interview, lid closed at the end) kept its
    /// transcript but showed a 0:00 player, while its recording sat in `Sessions/`. A meeting is a
    /// candidate when its row names no file or names one `locateAudio` cannot find; a file is a
    /// candidate when no row refers to it. They are matched when the file was created within three
    /// minutes of the meeting's start and is at least a third of the meeting's length (dictation
    /// scraps are seconds long). Every meeting still without audio is logged with the name its
    /// row holds, so a report of a missing player can be traced. Runs at launch, after crash
    /// recovery and before the sweep.
    func reattachOrphanedRecordings() async {
        let ctx = database.newBackgroundContext()
        let rows: [(id: UUID, createdAt: Date, duration: Double, name: String?)] = await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "isInProgress == NO")
            return ((try? ctx.fetch(req)) ?? []).map { ($0.id, $0.createdAt, $0.duration, $0.audioFileURL) }
        }
        let orphans = await Task.detached(priority: .utility) {
            rows.filter { row in row.name.map { Self.locateAudio(storedName: $0) == nil } ?? true }
        }.value
        guard !orphans.isEmpty else { return }

        let referenced = Set(rows.compactMap { $0.name.flatMap { Self.locateAudio(storedName: $0)?.standardizedFileURL } })
        let fm = FileManager.default
        let files = [AudioLibraryPaths.meetingRecordings, AudioLibraryPaths.sessions, AudioLibraryPaths.meetingData].flatMap { dir -> [(url: URL, created: Date)] in
            return ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
                .filter { AudioArchiveFormat.isRecognizedAudio($0) && !referenced.contains($0.standardizedFileURL) }
                .compactMap { url in (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate).map { (url, $0) } }
        }
        var used = Set<URL>()
        var stillMissing: [String] = []
        for meeting in orphans {
            let candidates = files.filter { !used.contains($0.url) && abs($0.created.timeIntervalSince(meeting.createdAt)) <= 180 }
                .sorted { abs($0.created.timeIntervalSince(meeting.createdAt)) < abs($1.created.timeIntervalSince(meeting.createdAt)) }
            let match = candidates.first { file in
                guard let audio = try? AVAudioFile(forReading: file.url) else { return false }
                let seconds = Double(audio.length) / audio.processingFormat.sampleRate
                return seconds >= 20 && seconds >= meeting.duration / 3
            }
            guard let match else {
                if meeting.duration >= 20 {
                    stillMissing.append("\(meeting.id.uuidString.prefix(8)) \(Int(meeting.duration))s file=\(meeting.name ?? "none")")
                }
                continue
            }
            used.insert(match.url)
            let name = match.url.lastPathComponent
            guard Self.adoptSessionAudio(fileName: match.url.path) else { continue }
            guard await updateAudioFileName(meetingID: meeting.id, fileName: name) else { continue }
            Logger.info("Meetings: recording reattached to \(meeting.id) (\(name))", subsystem: .app)
        }
        if !stillMissing.isEmpty {
            Logger.warning("Meetings: \(stillMissing.count) meeting(s) with no recording on disk: "
                           + stillMissing.prefix(20).joined(separator: "; "), subsystem: .app)
        }
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

            if let name = record.audioFileURL { Self.adoptSessionAudio(fileName: name) }
            await finalizeSession(
                meetingID: record.id,
                duration: record.duration,
                audioFileURL: record.audioFileURL
            )
            // The "finally" of a meeting the app quit, crashed or lost power under: it gets the
            // same refine, polish and overview a normal stop queues. The refine re-decodes the
            // recording, so text the cards never received is recovered from the audio.
            if let recovered = await meeting(id: record.id),
               !recovered.segments.isEmpty || recovered.resolvedAudioURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                Logger.info("Meeting crash recovery: queuing processing for \(record.id)", subsystem: .app)
                MeetingJobQueue.shared.enqueue(meetingID: record.id, segments: recovered.segments,
                                               audioURL: recovered.resolvedAudioURL)
            }
        }
    }

    // MARK: - Delete

    func deleteMeeting(meetingID: UUID) async {
        // Stop any polish run first — it would otherwise keep writing segments to a row
        // that is about to be deleted.
        MeetingTranscriptRefiner.shared.cancel(meetingID: meetingID)
        MeetingJobQueue.shared.remove(meetingID: meetingID)
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

            return entities.map { entity -> (UUID, Int64) in
                var bytes: Int64 = 0
                if let rel = entity.audioFileURL, !rel.isEmpty, let url = Self.locateAudio(storedName: rel) {
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
