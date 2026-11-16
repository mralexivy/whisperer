//
//  RecordingsWorkspaceModel.swift
//  Whisperer
//
//  State of the unified Recordings destination: one list over both stores, its filters and search, and
//  which recording is open. It reads `HistoryManager` and `MeetingManager`'s already-paged lists and
//  merges them; no record is copied or duplicated.
//

import Combine
import Foundation

nonisolated struct RecordingListItem: Identifiable, Equatable, Sendable {
    let id: RecordingID
    var kind: RecordingKind
    var title: String
    var preview: String
    var date: Date
    var duration: Double
    var isPinned: Bool
    var isFlagged: Bool
    var isInProgress: Bool
    var sourceName: String?
    var sourceBundleID: String?
}

@MainActor
final class RecordingsWorkspaceModel: ObservableObject {
    static let shared = RecordingsWorkspaceModel()

    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All", meetings = "Meetings", dictation = "Dictation", files = "Files"
        var id: String { rawValue }
        func includes(_ kind: RecordingKind) -> Bool {
            switch self {
            case .all: return true
            case .dictation: return kind == .dictation
            case .meetings: return kind == .meeting
            case .files: return kind == .file
            }
        }
    }

    enum MarkFilter: String, CaseIterable { case none, pinned, flagged }

    @Published var kindFilter: KindFilter = .all { didSet { rebuild() } }
    @Published var markFilter: MarkFilter = .none { didSet { markFilterChanged() } }
    @Published var oldestFirst = false { didSet { rebuild() } }
    @Published var searchText = "" { didSet { searchChanged() } }
    @Published private(set) var items: [RecordingListItem] = []
    @Published var selectedID: RecordingID?
    /// The import flow is showing in the main area instead of a recording.
    @Published var isImporting = false
    /// Hides the list and the sidebar so the reader has the window.
    @Published var focusMode = false

    private var bag = Set<AnyCancellable>()
    private var meetingMatches: Set<UUID>?
    private var searchTask: Task<Void, Never>?
    private var rebuildScheduled = false

    private init() {
        HistoryManager.shared.$transcriptions
            .sink { [weak self] _ in self?.scheduleRebuild() }.store(in: &bag)
        MeetingManager.shared.$meetings
            .sink { [weak self] _ in self?.scheduleRebuild() }.store(in: &bag)
    }

    // MARK: Selection

    /// Opens a recording: shows it in the main area, makes it the selection and clears a filter that
    /// would hide it.
    func open(_ id: RecordingID) {
        isImporting = false
        if !kindFilter.includes(kind(of: id)) { kindFilter = .all }
        selectedID = id
    }

    private func kind(of id: RecordingID) -> RecordingKind {
        if let item = items.first(where: { $0.id == id }) { return item.kind }
        if id.store == .meeting { return .meeting }
        return HistoryManager.shared.record(id: id.uuid).map(TranscriptDocument.kind(of:)) ?? .dictation
    }

    /// First time the list is shown: pick the most recent recording so the reader is never empty.
    func selectFirstIfNeeded() {
        guard selectedID == nil, !isImporting else { return }
        selectedID = items.first?.id
    }

    // MARK: Actions

    func togglePin(_ item: RecordingListItem) {
        switch item.id.store {
        case .transcription: HistoryManager.shared.setPinned(id: item.id.uuid, !item.isPinned)
        case .meeting: Task { await MeetingManager.shared.setPinned(meetingID: item.id.uuid, !item.isPinned) }
        }
    }

    func toggleFlag(_ item: RecordingListItem) {
        switch item.id.store {
        case .transcription: HistoryManager.shared.setFlagged(id: item.id.uuid, !item.isFlagged)
        case .meeting: Task { await MeetingManager.shared.setFlagged(meetingID: item.id.uuid, !item.isFlagged) }
        }
    }

    func rename(_ id: RecordingID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch id.store {
        case .transcription: HistoryManager.shared.setTitle(id: id.uuid, trimmed)
        case .meeting: Task { await MeetingManager.shared.updateTitle(meetingID: id.uuid, title: trimmed, userEdited: true) }
        }
    }

    /// Deletes the recording from its own store (audio, chat and, for meetings, the job queue and
    /// refiner state included) and moves the selection to a neighbour so the reader is not left stale.
    func delete(_ id: RecordingID) async {
        let neighbour = neighbourOf(id)
        switch id.store {
        case .transcription:
            if let record = HistoryManager.shared.record(id: id.uuid) {
                try? await HistoryManager.shared.deleteTranscription(record)
            }
            await MeetingChatStore.shared.clear(meetingID: id.uuid)
        case .meeting:
            await MeetingManager.shared.deleteMeeting(meetingID: id.uuid)
        }
        if selectedID == id { selectedID = neighbour }
    }

    private func neighbourOf(_ id: RecordingID) -> RecordingID? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        if index + 1 < items.count { return items[index + 1].id }
        return index > 0 ? items[index - 1].id : nil
    }

    func loadMoreIfNeeded(after item: RecordingListItem) {
        guard item.id == items.suffix(5).first?.id || items.suffix(5).contains(where: { $0.id == item.id }) else { return }
        Task {
            await HistoryManager.shared.loadNextPage()
            await MeetingManager.shared.loadNextPage()
        }
    }

    // MARK: Building the list

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.rebuildScheduled = false
            self?.rebuild()
        }
    }

    private func rebuild() {
        var merged: [RecordingListItem] = []
        var seen = Set<RecordingID>()

        for record in HistoryManager.shared.transcriptions {
            let kind = TranscriptDocument.kind(of: record)
            guard kindFilter.includes(kind) else { continue }
            let text = record.editedTranscription ?? record.aiEnhancedText ?? record.transcription
            let item = RecordingListItem(
                id: .dictation(record.id), kind: kind,
                title: record.title ?? TranscriptDocument.derivedTitle(from: text),
                preview: String((record.title == nil ? TranscriptDocument.previewAfterTitle(text) : text).prefix(140)).replacingOccurrences(of: "\n", with: " "),
                date: record.timestamp, duration: record.duration, isPinned: record.isPinned, isFlagged: record.isFlagged,
                isInProgress: false, sourceName: kind == .file ? record.sourceFileName : record.targetAppName,
                sourceBundleID: record.targetAppBundleID)
            if seen.insert(item.id).inserted { merged.append(item) }
        }

        if kindFilter.includes(.meeting) {
            for meeting in MeetingManager.shared.meetings {
                if let matches = meetingMatches, !matches.contains(meeting.id) { continue }
                switch markFilter {
                case .pinned where !meeting.isPinned: continue
                case .flagged where !meeting.isFlagged: continue
                default: break
                }
                let item = RecordingListItem(
                    id: .meeting(meeting.id), kind: .meeting, title: meeting.title,
                    preview: meeting.captureFailed ? "No audio was captured" : "\(meeting.wordCount) words",
                    date: meeting.createdAt, duration: meeting.duration, isPinned: meeting.isPinned, isFlagged: meeting.isFlagged,
                    isInProgress: meeting.isInProgress, sourceName: meeting.sourceAppName, sourceBundleID: meeting.sourceBundleID)
                if seen.insert(item.id).inserted { merged.append(item) }
            }
        }

        merged.sort { oldestFirst ? $0.date < $1.date : $0.date > $1.date }
        if items != merged { items = merged }
        // A selection that was deleted elsewhere moves to a neighbour; one that is merely filtered out
        // stays open, so typing in search never blanks the reader.
        if let selected = selectedID, !isStillStored(selected) { selectedID = merged.first?.id }
    }

    private func isStillStored(_ id: RecordingID) -> Bool {
        if items.contains(where: { $0.id == id }) { return true }
        switch id.store {
        case .transcription: return HistoryManager.shared.record(id: id.uuid) != nil
        case .meeting: return MeetingManager.shared.meetings.contains { $0.id == id.uuid }
        }
    }

    // MARK: Search and marks

    private func markFilterChanged() {
        Task { await reloadHistory() }
        rebuild()
    }

    private func searchChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            let query = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            self.meetingMatches = query.isEmpty ? nil : await MeetingManager.shared.searchIDs(query)
            await self.reloadHistory()
            self.rebuild()
        }
    }

    private func reloadHistory() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter: TranscriptionFilter = markFilter == .pinned ? .pinned : markFilter == .flagged ? .flagged : .all
        await HistoryManager.shared.loadTranscriptions(filter: filter, searchQuery: query.isEmpty ? nil : query)
    }
}

/// Times in the Recordings UI follow the user's 12 / 24-hour setting, as the old history list did.
enum RecordingTimeFormat {
    private static let twelve: DateFormatter = make(TimeFormatSetting.twelveHour)
    private static let twentyFour: DateFormatter = make(TimeFormatSetting.twentyFourHour)

    private static func make(_ setting: TimeFormatSetting) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = setting.dateFormat
        return f
    }

    static func string(_ date: Date, setting: String) -> String {
        (setting == TimeFormatSetting.twentyFourHour.rawValue ? twentyFour : twelve).string(from: date)
    }
}
