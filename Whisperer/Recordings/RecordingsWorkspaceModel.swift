//
//  RecordingsWorkspaceModel.swift
//  Whisperer
//
//  State of the unified Recordings destination: one list over both stores, its filters and search, and
//  which recording is open. It reads `HistoryManager` and `MeetingManager`'s already-paged lists and
//  merges them (`RecordingListBuilder`); no record is copied or duplicated.
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
    /// A meeting whose recording produced no audio.
    var captureFailed = false
}

@MainActor
final class RecordingsWorkspaceModel: ObservableObject {
    static let shared = RecordingsWorkspaceModel()

    typealias KindFilter = RecordingKindFilter
    typealias MarkFilter = RecordingMarkFilter

    @Published var kindFilter: KindFilter = .all { didSet { filtersChanged() } }
    @Published var markFilter: MarkFilter = .none { didSet { filtersChanged() } }
    @Published var searchText = "" { didSet { searchChanged() } }
    @Published private(set) var items: [RecordingListItem] = []
    @Published var selectedID: RecordingID?
    /// The import flow is showing in the main area instead of a recording.
    @Published var isImporting = false
    /// Hides the list and the sidebar so the reader has the window.
    @Published var focusMode = false
    /// Whether the sidebar was showing when focus mode began, so leaving focus brings it back.
    var sidebarBeforeFocus = true
    /// How many recordings the current kind, pin/flag filter and search match in total — not just the loaded pages.
    @Published private(set) var totalCount = 0

    /// Rows to keep on screen before asking a store for another page, so a short list never looks finished.
    static let wantedRows = 30

    private let history: HistoryManager
    private let meetingStore: MeetingManager
    private var bag = Set<AnyCancellable>()
    private var meetingHits: [UUID: String?]?
    /// Bumped on every new search or filter, so a slow older one can never overwrite a newer one's results.
    private var filterGeneration = 0
    private var meetingTotal = 0
    private var searchTask: Task<Void, Never>?
    private var rebuildScheduled = false
    private var limiting: RecordingStoreSource?
    private var toppingUp = false
    private var reapplying = false

    init(history: HistoryManager = .shared, meetings: MeetingManager = .shared) {
        self.history = history
        self.meetingStore = meetings
        history.$transcriptions.sink { [weak self] _ in self?.historyChanged() }.store(in: &bag)
        history.$hasMorePages.sink { [weak self] _ in self?.scheduleRebuild() }.store(in: &bag)
        meetings.$meetings.sink { [weak self] _ in self?.scheduleRebuild() }.store(in: &bag)
        meetings.$hasMorePages.sink { [weak self] _ in self?.scheduleRebuild() }.store(in: &bag)
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
        return history.record(id: id.uuid).map(TranscriptDocument.kind(of:)) ?? .dictation
    }

    /// First time the list is shown: pick the most recent recording so the reader is never empty.
    func selectFirstIfNeeded() {
        guard selectedID == nil, !isImporting else { return }
        selectedID = items.first?.id
    }

    // MARK: Actions

    func togglePin(_ item: RecordingListItem) {
        switch item.id.store {
        case .transcription: history.setPinned(id: item.id.uuid, !item.isPinned)
        case .meeting: Task { await meetingStore.setPinned(meetingID: item.id.uuid, !item.isPinned) }
        }
    }

    func toggleFlag(_ item: RecordingListItem) {
        switch item.id.store {
        case .transcription: history.setFlagged(id: item.id.uuid, !item.isFlagged)
        case .meeting: Task { await meetingStore.setFlagged(meetingID: item.id.uuid, !item.isFlagged) }
        }
    }

    func rename(_ id: RecordingID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch id.store {
        case .transcription: history.setTitle(id: id.uuid, trimmed)
        case .meeting: Task { await meetingStore.updateTitle(meetingID: id.uuid, title: trimmed, userEdited: true) }
        }
    }

    /// Deletes the recording from its own store (audio, chat and, for meetings, the job queue and
    /// refiner state included) and moves the selection to a neighbour so the reader is not left stale.
    func delete(_ id: RecordingID) async {
        // Move first: the store emits as soon as the row is gone, and the list would fall back to its first row.
        if selectedID == id { selectedID = neighbourOf(id) }
        switch id.store {
        case .transcription:
            if let record = history.record(id: id.uuid) { try? await history.deleteTranscription(record) }
            await MeetingChatStore.shared.clear(meetingID: id.uuid)
        case .meeting:
            await meetingStore.deleteMeeting(meetingID: id.uuid)
        }
    }

    private func neighbourOf(_ id: RecordingID) -> RecordingID? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        if index + 1 < items.count { return items[index + 1].id }
        return index > 0 ? items[index - 1].id : nil
    }

    // MARK: Paging

    /// Called as rows scroll into view: near the end of the list, the store that bounds it loads its next page.
    func loadMoreIfNeeded(after item: RecordingListItem) {
        guard items.suffix(8).contains(where: { $0.id == item.id }) else { return }
        loadNextPage()
    }

    /// Keeps the list from looking finished when the cutoff has trimmed it short.
    private func topUp() {
        guard items.count < Self.wantedRows else { return }
        loadNextPage()
    }

    private func loadNextPage() {
        guard !toppingUp else { return }
        let source = limiting
        toppingUp = true
        Task {
            switch source {
            case .history: await history.loadNextPage()
            case .meetings: await meetingStore.loadNextPage()
            case nil:
                // Nothing is bounding the list (every store is fully loaded, or a filter excludes them).
                break
            }
            toppingUp = false
            rebuild()
        }
    }

    // MARK: Building the list

    private func historyChanged() {
        scheduleRebuild()
        reapplyIfStoreDrifted()
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.rebuildScheduled = false
            self?.rebuild()
        }
    }

    private func rebuild() {
        let output = RecordingListBuilder.build(.init(
            transcriptions: history.transcriptions, meetings: meetingStore.meetings,
            historyHasMore: history.hasMorePages, meetingsHaveMore: meetingStore.hasMorePages,
            kind: kindFilter, mark: markFilter, meetingHits: meetingHits, query: wantedQuery))
        limiting = output.limiting
        if items != output.items { items = output.items }
        updateTotal()
        // A selection that was deleted elsewhere moves to a neighbour; one that is merely filtered out
        // stays open, so typing in search never blanks the reader.
        if let selected = selectedID, !isStillStored(selected) { selectedID = output.items.first?.id }
        topUp()
    }

    private func isStillStored(_ id: RecordingID) -> Bool {
        if items.contains(where: { $0.id == id }) { return true }
        switch id.store {
        case .transcription: return history.record(id: id.uuid) != nil
        case .meeting: return meetingStore.meetings.contains { $0.id == id.uuid }
        }
    }

    // MARK: Search and marks

    private var wantedHistoryFilter: TranscriptionFilter {
        markFilter == .pinned ? .pinned : markFilter == .flagged ? .flagged : .all
    }

    private var wantedQuery: String? {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : query
    }

    private func filtersChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.applyFilters()
        }
    }

    private func searchChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.applyFilters()
        }
    }

    /// Re-runs both stores' queries for the current search and mark filter. A newer call makes an older one stand down
    /// at its next step, so rapid typing cannot leave the meetings of one query beside the dictations of another.
    private func applyFilters() async {
        filterGeneration += 1
        let generation = filterGeneration
        let query = wantedQuery
        // Meetings are filtered here, on what is loaded, so a search or a mark filter needs all of them
        // (there are far fewer than dictations); the matches themselves come from the store.
        if query != nil || markFilter != .none { await loadAllMeetings() }
        guard generation == filterGeneration else { return }
        let hits = query == nil ? nil : await meetingStore.search(query!)
        guard generation == filterGeneration else { return }
        meetingHits = hits
        await reloadHistory()
        guard generation == filterGeneration else { return }
        meetingTotal = await meetingStore.count(mark: markFilter)
        guard generation == filterGeneration else { return }
        rebuild()
    }

    private func updateTotal() {
        var total = 0
        if kindFilter.usesHistoryStore {
            total += history.count(filter: wantedHistoryFilter, kind: wantedKindScope, query: wantedQuery)
        }
        if kindFilter.usesMeetingStore {
            if let hits = meetingHits {
                total += markFilter == .none ? hits.count : items.filter { $0.kind == .meeting }.count
            } else if !meetingStore.hasMorePages {
                total += meetingStore.meetings.filter { markFilter == .none || (markFilter == .pinned ? $0.isPinned : $0.isFlagged) }.count
            } else {
                total += meetingTotal
            }
        }
        if totalCount != total { totalCount = total }
    }

    private func loadAllMeetings() async {
        var guardRail = 0
        while meetingStore.hasMorePages, guardRail < 500 {
            guardRail += 1
            if meetingStore.isLoadingPage { try? await Task.sleep(nanoseconds: 50_000_000); continue }
            await meetingStore.loadNextPage()
        }
    }

    private var wantedKindScope: HistoryKindScope {
        switch kindFilter {
        case .files: return .files
        case .dictation: return .dictation
        case .all, .meetings: return .any
        }
    }

    private func reloadHistory() async {
        await history.loadTranscriptions(filter: wantedHistoryFilter, searchQuery: wantedQuery, kind: wantedKindScope)
    }

    /// Another part of the app reloads the history store with its own idea of the filter — the workspace
    /// window does it every time it becomes key. The list must keep showing what the search box says.
    private func reapplyIfStoreDrifted() {
        guard !reapplying else { return }
        let storeQuery = history.currentSearchQuery.flatMap { $0.isEmpty ? nil : $0 }
        guard history.currentFilter != wantedHistoryFilter || storeQuery != wantedQuery || history.currentKindScope != wantedKindScope else { return }
        reapplying = true
        Task {
            await reloadHistory()
            reapplying = false
        }
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
