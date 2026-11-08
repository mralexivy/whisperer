//
//  TranscriptPolishController.swift
//  Whisperer
//
//  Runs "Polish with <AI>" for one meeting at a time and publishes its progress, so the
//  Transcript tab can show what is happening and who did it. Results are applied through
//  `.meetingSegmentsDidRefine`, the same path the recognizer's own refine pass uses.
//

import Combine
import Foundation

@MainActor
final class TranscriptPolishController: ObservableObject {
    static let shared = TranscriptPolishController()

    enum Phase: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished(changed: Int)
        case failed(String)
    }

    @Published private(set) var meetingID: UUID?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var providerID: AIProviderID?

    private var task: Task<Void, Never>?
    let store: ConnectedAIStore
    let defaults: UserDefaults
    /// Persists the polished array. Replaced in tests.
    var persist: (UUID, [MeetingSegment]) async -> Void = { id, segments in
        await MeetingManager.shared.updateSegments(meetingID: id, segments: segments)
    }

    /// `store` nil = `ConnectedAIStore.shared`, resolved here on the main actor (a default
    /// argument of `.shared` would be evaluated in a nonisolated context).
    init(store: ConnectedAIStore? = nil, defaults: UserDefaults = .standard) {
        self.store = store ?? .shared
        self.defaults = defaults
    }

    func phase(for meetingID: UUID) -> Phase {
        self.meetingID == meetingID ? phase : .idle
    }

    func provenance(for meetingID: UUID) -> MeetingAIProvenance? {
        MeetingAIProvenance.lookup(meetingID, defaults: defaults, key: MeetingAIProvenance.polishStoreKey)
    }

    var isRunning: Bool { if case .running = phase { return true } else { return false } }

    /// Polishes `segments` with the active provider (or `provider`, for tests).
    @discardableResult
    func start(meetingID: UUID, segments: [MeetingSegment], languageName: String?,
               provider explicit: (any MeetingIntelligenceProvider)? = nil) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        guard let provider = explicit ?? store.activeProvider() else {
            phase = .failed("Choose an AI on the LLM page first.")
            self.meetingID = meetingID
            return nil
        }
        self.meetingID = meetingID
        providerID = provider.id
        phase = .running(done: 0, total: max(1, MeetingTranscriptPolisher.chunks(for: segments).count))
        let defaults = self.defaults
        let persist = self.persist
        let started = Date()
        let chars = segments.reduce(0) { $0 + $1.text.count }
        Logger.info("Transcript polish: \(provider.id.rawValue) (\(provider.modelLabel ?? "default")) starting for \(meetingID), \(segments.count) card(s), \(chars) chars", subsystem: .transcription)
        // An immutable weak reference: the progress callback runs concurrently, so it must not
        // capture a mutable `weak var` (which is what a `[weak self]` capture list produces).
        weak let weakSelf = self
        let onProgress: @Sendable (Int, Int) -> Void = { done, total in
            Task { @MainActor in
                guard let self = weakSelf, self.meetingID == meetingID, self.isRunning else { return }
                self.phase = .running(done: done, total: max(total, 1))
            }
        }
        let t = Task { [weak self] in
            do {
                let outcome = try await MeetingTranscriptPolisher.polish(
                    segments, with: provider, languageName: languageName,
                    onProgress: onProgress)
                await persist(meetingID, outcome.segments)
                MeetingAIProvenance.record(
                    MeetingAIProvenance(source: provider.id.rawValue, model: provider.modelLabel, date: Date()),
                    for: meetingID, defaults: defaults, key: MeetingAIProvenance.polishStoreKey)
                NotificationCenter.default.post(name: .meetingSegmentsDidRefine, object: meetingID,
                                                userInfo: ["segments": outcome.segments])
                Logger.info("Transcript polish: \(provider.id.rawValue) changed \(outcome.changed) card(s), rejected \(outcome.rejected) for \(meetingID) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s", subsystem: .transcription)
                self?.phase = .finished(changed: outcome.changed)
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                let message = (error as? MeetingAIProviderError)?.localizedDescription ?? error.localizedDescription
                Logger.warning("Transcript polish: \(provider.id.rawValue) failed (\(error))", subsystem: .transcription)
                self?.phase = .failed(message)
            }
        }
        task = t
        return t
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    /// Restores the recognizer's text for every polished card.
    func undo(meetingID: UUID, segments: [MeetingSegment]) async {
        let restored = MeetingTranscriptPolisher.undo(segments)
        await persist(meetingID, restored)
        MeetingAIProvenance.forget(meetingID, defaults: defaults, key: MeetingAIProvenance.polishStoreKey)
        NotificationCenter.default.post(name: .meetingSegmentsDidRefine, object: meetingID,
                                        userInfo: ["segments": restored])
        if self.meetingID == meetingID { phase = .idle }
    }
}
