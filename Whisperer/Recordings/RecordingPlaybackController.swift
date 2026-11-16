//
//  RecordingPlaybackController.swift
//  Whisperer
//
//  One playback session for the whole Recordings workspace. It owns the single `SeekableAudioPlayer`,
//  so the full player in the sidebar and the compact bar under the reader are two faces of the same
//  session: moving between tabs, hiding the sidebar or entering focus mode never creates a second
//  engine or resets the position.
//
//  Position policy (all recording types): selecting a different recording starts it at 0, paused —
//  what meetings already did.
//

import Combine
import Foundation

@MainActor
final class RecordingPlaybackController: ObservableObject {

    enum Availability: Equatable {
        case none           // nothing selected
        case noAudio        // the recording has none
        case missing        // it had audio that is no longer on disk
        case ready
    }

    let player: SeekableAudioPlayer

    @Published private(set) var recordingID: RecordingID?
    @Published private(set) var availability: Availability = .none
    @Published private(set) var waveform: [Float] = []
    /// The paragraph the playhead is inside. Changes a few times a minute, not 30 times a second.
    @Published private(set) var playheadParagraphID: String?
    /// A passage to scroll to and flash (a cited paragraph, a search hit). Changes only on request.
    @Published private(set) var revealed: Reveal?

    struct Reveal: Equatable { let paragraphID: String; let token: Int }

    private var timeline: [(id: String, start: Double, end: Double)] = []
    private var bag = Set<AnyCancellable>()
    private var waveformTask: Task<Void, Never>?
    private var revealToken = 0

    init(player: SeekableAudioPlayer? = nil) {
        self.player = player ?? SeekableAudioPlayer()
        // Recompute the playhead paragraph from the clock, but publish only when it changes.
        self.player.$currentTime
            .map { [weak self] time in self?.paragraphID(at: time) }
            .removeDuplicates()
            .sink { [weak self] id in self?.playheadParagraphID = id }
            .store(in: &bag)
    }

    // MARK: Selection

    /// Makes `document` the recording the session is about. A different recording replaces the old one
    /// (its audio stops, nothing overlaps); the same one — even rebuilt after an edit — keeps playing.
    func select(_ document: TranscriptDocument?) {
        guard let document else {
            recordingID = nil
            availability = .none
            timeline = []
            waveform = []
            player.unload()
            playheadParagraphID = nil
            return
        }
        setTimeline(of: document)
        let sameRecording = recordingID == document.id
        recordingID = document.id

        if let url = document.audioURL {
            availability = .ready
            if !sameRecording || player.loadedURL != url {
                player.show(url: url)
                loadWaveform(url)
            }
        } else {
            availability = document.audioFileName == nil ? .noAudio : .missing
            if !sameRecording { player.unload(); waveform = [] }
        }
    }

    private func setTimeline(of document: TranscriptDocument) {
        let starts = document.paragraphs.map(\.start)
        guard !starts.isEmpty, starts.allSatisfy({ $0 != nil }) else { timeline = []; return }
        timeline = document.paragraphs.enumerated().map { index, paragraph in
            let start = paragraph.start ?? 0
            let next = index + 1 < document.paragraphs.count ? document.paragraphs[index + 1].start : nil
            return (paragraph.id, start, paragraph.end.map { max($0, start) } ?? next ?? start + 60)
        }
    }

    private func paragraphID(at time: Double) -> String? {
        guard !timeline.isEmpty, player.isPlaying || time > 0 else { return nil }
        // Last paragraph that has started; binary search keeps this cheap at 30 Hz on a long recording.
        var low = 0, high = timeline.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if timeline[mid].start <= time { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found.map { timeline[$0].id }
    }

    private func loadWaveform(_ url: URL) {
        waveformTask?.cancel()
        waveform = []
        waveformTask = Task { [weak self] in
            let bars = await Task.detached(priority: .utility) {
                WaveformGenerator.generateWaveform(from: url, sampleCount: 120)
            }.value
            guard !Task.isCancelled else { return }
            self?.waveform = bars
        }
    }

    // MARK: Commands

    var isAvailable: Bool { availability == .ready }

    func togglePlay() {
        guard isAvailable else { return }
        player.isPlaying ? player.pause() : player.play()
    }

    func seek(to seconds: Double) {
        guard isAvailable else { return }
        player.seek(to: seconds)
    }

    /// Jumps to a paragraph that has a time. Untimed paragraphs are only revealed, never given a time.
    func seek(toParagraph paragraph: TranscriptParagraph) {
        if let start = paragraph.start { seek(to: start) }
    }

    /// Scrolls the reader to a paragraph and flashes it — a citation or a search hit.
    func reveal(paragraphID: String) {
        revealToken += 1
        revealed = Reveal(paragraphID: paragraphID, token: revealToken)
    }

    /// A citation tap: open the passage, and seek when it has a time.
    func open(citation paragraph: TranscriptParagraph) {
        reveal(paragraphID: paragraph.id)
        seek(toParagraph: paragraph)
    }
}
