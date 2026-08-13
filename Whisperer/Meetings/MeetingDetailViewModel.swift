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
    private var loadedMeetingID: UUID? = nil
    private let pageSize = 20

    private var notificationObservers = Set<AnyCancellable>()

    init() {
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
    }

    // MARK: - Load

    func load(meetingID: UUID) async {
        // Skip if already loaded (but allow force if meeting is nil, e.g. after clear())
        guard meetingID != loadedMeetingID || meeting == nil else { return }
        loadedMeetingID = meetingID
        isLoading = true
        meeting = nil
        displayedSegments = []
        allSegments = []
        hasMoreSegments = false

        let record = await fetchRecord(meetingID)

        // Discard stale result if a different meeting was selected during the async fetch
        guard loadedMeetingID == meetingID else {
            isLoading = false
            return
        }

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
        let record = await fetchRecord(id)
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
        meeting = nil
        displayedSegments = []
        allSegments = []
        hasMoreSegments = false
        isLoading = false
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

    func renameSpeakerInMemory(from oldName: String, to newName: String) {
        if var m = meeting {
            for i in m.segments.indices where m.segments[i].speakerName == oldName {
                m.segments[i].speakerName = newName
            }
            meeting = m
        }
        for i in allSegments.indices where allSegments[i].speakerName == oldName {
            allSegments[i].speakerName = newName
        }
        for i in displayedSegments.indices where displayedSegments[i].speakerName == oldName {
            displayedSegments[i].speakerName = newName
        }
    }

    func updateTitleInMemory(_ title: String) {
        if var m = meeting {
            m.title = title
            meeting = m
        }
    }

    // MARK: - CoreData fetch

    private func fetchRecord(_ id: UUID) async -> MeetingRecord? {
        let ctx = HistoryDatabase.shared.newBackgroundContext()
        return await ctx.perform {
            let req = MeetingEntity.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            req.fetchLimit = 1
            guard let entity = try? ctx.fetch(req).first else { return nil }
            return MeetingRecord(from: entity)
        }
    }
}
