//
//  RecordingDetailModel.swift
//  Whisperer
//
//  Loads the open recording as a `TranscriptDocument` and keeps it current. A load that finishes after
//  the selection moved on is dropped, so a slow recording can never appear under the one now selected.
//

import Combine
import Foundation

@MainActor
final class RecordingDetailModel: ObservableObject {
    @Published private(set) var document: TranscriptDocument?
    /// The meeting itself for meetings; a record assembled from the document for everything else.
    /// What Overview, Ask AI, Notes and People are written against.
    @Published private(set) var meetingRecord: MeetingRecord?
    @Published private(set) var isLoading = false
    /// Show the recognizer's text instead of the polished / edited version.
    @Published var showOriginal = false

    private var currentID: RecordingID?
    private var generation = 0
    private var bag = Set<AnyCancellable>()

    init() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [.meetingSegmentsDidRefine, .meetingOverviewDidGenerate, .meetingOverviewDidFail,
                                          .meetingTitleDidGenerate, .recordingDidChange]
        for name in names {
            center.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] note in
                guard let self, let uuid = note.object as? UUID, uuid == self.currentID?.uuid else { return }
                self.reload()
            }.store(in: &bag)
        }
        // Edits made from the list (pin, flag, rename) and by the history store itself.
        HistoryManager.shared.$transcriptions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.currentID?.store == .transcription else { return }
                self.refreshFromHistoryIfChanged()
            }.store(in: &bag)
    }

    func select(_ id: RecordingID?) {
        guard id != currentID else { return }
        currentID = id
        showOriginal = false
        generation += 1
        guard id != nil else { document = nil; meetingRecord = nil; isLoading = false; return }
        // The old recording stays on screen under a skeleton rather than flashing the previous one's
        // content in a new header.
        document = nil
        meetingRecord = nil
        isLoading = true
        reload()
    }

    func reload() {
        guard let id = currentID else { return }
        generation += 1
        let mine = generation
        Task { [weak self] in
            let loaded = await Self.load(id)
            guard let self, mine == self.generation, self.currentID == id else { return }
            self.document = loaded?.document
            self.meetingRecord = loaded?.record
            self.isLoading = false
        }
    }

    fileprivate func setLoaded(document: TranscriptDocument, record: MeetingRecord) {
        currentID = document.id
        generation += 1
        self.document = document
        meetingRecord = record
        isLoading = false
    }

    private var lastModified: Date?
    private func refreshFromHistoryIfChanged() {
        guard let id = currentID, let record = HistoryManager.shared.record(id: id.uuid) else { return }
        guard record.lastModifiedAt != lastModified else { return }
        lastModified = record.lastModifiedAt
        let doc = TranscriptDocument(transcription: record)
        guard doc != document else { return }
        document = doc
        meetingRecord = doc.asMeetingRecord()
    }

    private static func load(_ id: RecordingID) async -> (document: TranscriptDocument, record: MeetingRecord)? {
        switch id.store {
        case .meeting:
            guard let record = await MeetingManager.shared.meeting(id: id.uuid) else { return nil }
            return (TranscriptDocument(meeting: record), record)
        case .transcription:
            guard let record = HistoryManager.shared.record(id: id.uuid) else { return nil }
            let document = TranscriptDocument(transcription: record)
            return (document, document.asMeetingRecord())
        }
    }

    /// The paragraphs the reader shows right now.
    var shownParagraphs: [TranscriptParagraph] {
        guard let document else { return [] }
        return showOriginal ? (document.originalParagraphs ?? document.paragraphs) : document.paragraphs
    }
}

extension RecordingDetailModel {
    /// Shows a recording that is not in either store — for tests that render the workspace around fixtures.
    func showForTesting(document: TranscriptDocument, record: MeetingRecord) {
        setLoaded(document: document, record: record)
    }
}
