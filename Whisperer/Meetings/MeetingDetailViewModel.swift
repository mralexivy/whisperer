//
//  MeetingDetailViewModel.swift
//  Whisperer
//
//  Owns the full MeetingRecord for the currently selected meeting.
//  Decodes JSON once on selection; paginates segments 20 at a time for fast first-paint.
//

import Foundation
import Combine
import SwiftUI
import CoreData

@MainActor
final class MeetingDetailViewModel: ObservableObject {
    @Published var meeting: MeetingRecord? = nil
    @Published var isLoading = false
    @Published var displayedSegments: [MeetingSegment] = []
    @Published var hasMoreSegments = false

    private(set) var allSegments: [MeetingSegment] = []
    private(set) var loadedMeetingID: UUID? = nil
    private let pageSize = 20
    /// Bumped by every `load`; only the newest load may publish its result or clear
    /// `isLoading`. An older fetch that lands late used to switch the skeleton off while the
    /// current meeting was still loading, which flashed "no transcript".
    private var loadGeneration = 0
    /// Reads a meeting from Core Data. Replaced in tests.
    var fetcher: (UUID) async -> MeetingRecord?

    // MARK: Prose / RTL cache
    //
    // `MeetingTranscriptText.plainProse` joins every segment and `isRightToLeft` scans
    // up to 2 000 characters — both are expensive on large meetings. They are recomputed
    // only when the segment content or the original-toggle flag changes, preventing
    // unnecessary work on every playhead tick or speaker-filter update.

    private(set) var cachedProse: String = ""
    private(set) var cachedIsRTL: Bool = false
    private var proseCacheKey: ProseCacheKey = .empty

    private struct ProseCacheKey: Equatable {
        let segmentCount: Int
        let lastID: UUID?
        let lastTextHash: Int
        let showOriginal: Bool
        static let empty = ProseCacheKey(segmentCount: 0, lastID: nil, lastTextHash: 0, showOriginal: false)
    }

    /// Must be called by the view before reading `cachedProse` or `cachedIsRTL`.
    ///
    /// - Parameters:
    ///   - segments: The full segment array (all pages, original-toggle applied).
    ///   - showOriginal: Whether the raw ASR text is being shown.
    ///   - languageCode: The meeting's configured language, used as a direction fallback.
    func updateProseCache(segments: [MeetingSegment], showOriginal: Bool, languageCode: String?) {
        let key = ProseCacheKey(
            segmentCount: segments.count,
            lastID: segments.last?.id,
            lastTextHash: segments.last?.text.hashValue ?? 0,
            showOriginal: showOriginal
        )
        guard key != proseCacheKey else { return }
        proseCacheKey = key
        cachedProse = MeetingTranscriptText.plainProse(from: segments)
        cachedIsRTL = MeetingTranscriptText.isRightToLeft(
            segments: segments,
            fallback: TranscriptionLanguage(rawValue: languageCode ?? ""))
    }

    private var notificationObservers = Set<AnyCancellable>()

    init(fetcher: ((UUID) async -> MeetingRecord?)? = nil) {
        self.fetcher = fetcher ?? { id in await MeetingDetailViewModel.fetchRecord(id) }
        // Refresh when AI overview generates so MeetingOverviewView sees the new aiSummary.
        NotificationCenter.default.publisher(for: .meetingOverviewDidGenerate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notif in
                guard let self,
                      let id = notif.object as? UUID,
                      id == self.loadedMeetingID else { return }
                Task { await self.refreshDetail() }
            }
            .store(in: &notificationObservers)

        // The transcript of the shown meeting was saved after it was loaded (the end of a
        // recording, the refine pass, a polish): show the saved version.
        NotificationCenter.default.publisher(for: .meetingSegmentsDidPersist)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notif in
                guard let self, let id = notif.object as? UUID, id == self.loadedMeetingID else { return }
                Task { await self.refreshDetail() }
            }
            .store(in: &notificationObservers)
    }

    /// What the workspace calls whenever the selection is (re)established — on change *and*
    /// on appear. The selection outlives this object (it lives in the parent), so a fresh
    /// view model with an already-selected meeting must still load it.
    func select(_ id: UUID?) async {
        guard let id else { clear(); return }
        if id == loadedMeetingID, meeting != nil { return }
        clear()
        await load(meetingID: id)
    }

    /// Re-fetches the shown meeting when the library row says it changed (word count or
    /// duration differ from what is loaded) — e.g. a transcript saved after the load.
    func refreshIfStale(listItem: MeetingListItem?) async {
        guard let item = listItem, item.id == loadedMeetingID, !isLoading, let m = meeting else { return }
        let loadedWords = m.segments.reduce(0) {
            $0 + $1.text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        }
        if item.wordCount != loadedWords || (m.segments.isEmpty && item.wordCount > 0) {
            await refreshDetail()
        }
    }

    // MARK: - Load

    func load(meetingID: UUID) async {
        // Skip if already loaded (but allow force if meeting is nil, e.g. after clear())
        guard meetingID != loadedMeetingID || meeting == nil else { return }
        loadedMeetingID = meetingID
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        meeting = nil
        displayedSegments = []
        allSegments = []
        hasMoreSegments = false

        let record = await fetcher(meetingID)

        // A newer load (another meeting, or this one again after a clear) owns the state now.
        guard generation == loadGeneration, loadedMeetingID == meetingID else { return }

        allSegments = record?.segments ?? []
        displayedSegments = Array(allSegments.prefix(pageSize))
        hasMoreSegments = allSegments.count > pageSize

        withAnimation(.easeInOut(duration: 0.25)) {
            meeting = record
            isLoading = false
        }
    }

    func loadMoreSegments() {
        guard hasMoreSegments else { return }
        let nextCount = min(displayedSegments.count + pageSize, allSegments.count)
        displayedSegments = Array(allSegments.prefix(nextCount))
        hasMoreSegments = displayedSegments.count < allSegments.count
    }

    func refreshDetail() async {
        guard let id = loadedMeetingID else { return }
        let record = await fetcher(id)
        guard loadedMeetingID == id, let record else { return }
        allSegments = record.segments
        // Extend display window but never shrink it
        let keepCount = max(displayedSegments.count, pageSize)
        displayedSegments = Array(allSegments.prefix(keepCount))
        hasMoreSegments = displayedSegments.count < allSegments.count
        meeting = record
    }

    func clear() {
        loadedMeetingID = nil
        loadGeneration += 1
        meeting = nil
        displayedSegments = []
        allSegments = []
        hasMoreSegments = false
        isLoading = false
        cachedProse = ""
        cachedIsRTL = false
        proseCacheKey = .empty
    }

    // MARK: - In-memory mutation helpers

    func updateSegmentInMemory(_ updated: MeetingSegment) {
        if var m = meeting, let idx = m.segments.firstIndex(where: { $0.id == updated.id }) {
            m.segments[idx] = updated
            meeting = m
        }
        if let idx = allSegments.firstIndex(where: { $0.id == updated.id }) {
            allSegments[idx] = updated
        }
        if let idx = displayedSegments.firstIndex(where: { $0.id == updated.id }) {
            displayedSegments[idx] = updated
        }
    }

    /// Swap in a whole polished array in one pass. Calling `updateSegmentInMemory` per segment
    /// would republish `displayedSegments` N times, and every publish costs a full transcript
    /// relayout in `SelectableTranscriptView`.
    func applyRefinedSegments(_ refined: [MeetingSegment]) {
        guard !refined.isEmpty else { return }
        let byID = Dictionary(refined.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        if var m = meeting {
            for i in m.segments.indices {
                if let r = byID[m.segments[i].id] { m.segments[i] = r }
            }
            meeting = m
        }
        for i in allSegments.indices {
            if let r = byID[allSegments[i].id] { allSegments[i] = r }
        }
        // Never shrink the window — the polish pass can add nothing, but the tail chunk may
        // have grown allSegments since the last page load.
        let keepCount = max(displayedSegments.count, min(pageSize, allSegments.count))
        displayedSegments = Array(allSegments.prefix(keepCount))
        hasMoreSegments = displayedSegments.count < allSegments.count
    }

    /// Renames every segment belonging to `speakerIndex`, keyed by index so two speakers
    /// sharing a name are always updated independently.
    func renameSpeakerInMemory(index speakerIndex: Int, to newName: String) {
        if var m = meeting {
            m.segments.renameSpeaker(index: speakerIndex, to: newName)
            meeting = m
        }
        allSegments.renameSpeaker(index: speakerIndex, to: newName)
        displayedSegments.renameSpeaker(index: speakerIndex, to: newName)
    }

    func updateTitleInMemory(_ title: String, userEdited: Bool = false) {
        if var m = meeting {
            m.title = title
            if userEdited { m.titleIsUserSet = true }
            meeting = m
        }
    }

    // MARK: - CoreData fetch

    nonisolated static func fetchRecord(_ id: UUID) async -> MeetingRecord? {
        let ctx = await HistoryDatabase.shared.newBackgroundContext()
        return await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return nil }
            return MeetingRecord(from: entity)
        }
    }
}
