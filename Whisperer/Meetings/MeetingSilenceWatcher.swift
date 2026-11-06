//
//  MeetingSilenceWatcher.swift
//  Whisperer
//
//  Runtime signal for silent-meeting handling. Feeds audio into Silero VAD at ~1 Hz for the
//  whole meeting and drives `MeetingQuietTracker`, which decides what the card shows. See
//  `MeetingSilencePolicy.swift` for the two cases (started by mistake / went quiet).
//

import Foundation
import SwiftUI
import Combine

/// Start it when recording begins, stop it when the recording ends. Thread-safe: only `feed`
/// is called from background contexts; everything else is @MainActor.
@MainActor
final class MeetingSilenceWatcher: ObservableObject {

    // MARK: - Published state (drives the card and the discard decision)

    /// What the card shows.
    @Published private(set) var prompt: MeetingQuietPrompt = .none

    /// Any voice or content so far. Read at stop by the short-meeting discard rule.
    var speechDetected: Bool { tracker.speechDetected }
    /// Words or notes so far.
    var hasContent: Bool { tracker.hasContent }

    /// Fired once when an empty meeting's countdown runs out.
    var onAutoDiscard: (() -> Void)?

    // MARK: - Private

    private var tracker = MeetingQuietTracker()
    private var vad: SileroVAD?
    private var sampleBuffer: [Float] = []
    private let sampleBufferSize = 16_000          // 1 s at 16 kHz
    private var pendingVADTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var firedAutoDiscard = false

    /// Elapsed seconds supplied by MeetingSession.elapsedSeconds via AppState.
    /// The watcher doesn't own a clock — it piggybacks on the session's, which stops while paused.
    private var elapsedSeconds: Double = 0

    // RMS fallback (when VAD model is unavailable)
    private var rmsSpeechFrames: Int = 0
    private let rmsFloor: Float = 0.015            // rough floor; 0.5s above this = speech
    private let rmsSpeechFramesNeeded: Int = 6     // ~0.5s at 12 Hz publish rate
    /// Below this the input is digital silence — a dead or muted device, not a quiet room.
    private let signalFloor: Float = 0.001

    // MARK: - Lifecycle

    func start(vad: SileroVAD?) {
        self.vad = vad
        sampleBuffer.removeAll(keepingCapacity: true)
        tracker = MeetingQuietTracker()
        prompt = .none
        elapsedSeconds = 0
        rmsSpeechFrames = 0
        firedAutoDiscard = false
        startTick()
    }

    func stop() {
        pendingVADTask?.cancel()
        pendingVADTask = nil
        tickTask?.cancel()
        tickTask = nil
        sampleBuffer.removeAll()
        prompt = .none
    }

    /// "Keep recording" on the started-by-mistake card.
    func keep() {
        tracker.keep()
        prompt = tracker.prompt
        Logger.info("MeetingSilenceWatcher: user kept an empty meeting", subsystem: .audio)
    }

    /// "Keep going" on the quiet card, and the card's close button in either case.
    func dismiss() {
        switch tracker.prompt {
        case .startedByMistake: keep()
        case .wentQuiet: tracker.snoozeQuiet(at: elapsedSeconds); prompt = tracker.prompt
        case .none: break
        }
    }

    #if DEBUG
    /// Test seam: show a given prompt without running a meeting.
    func _setPromptForTesting(_ prompt: MeetingQuietPrompt) { self.prompt = prompt }
    #endif

    // MARK: - Feed paths (called from AppState's onStreamingSamples / onAmplitudeUpdate)

    /// Called with raw audio samples (same buffer AppState passes to the transcriber).
    /// Non-isolated so AppState can call it without hopping.
    nonisolated func feed(_ samples: [Float]) {
        Task.detached { [weak self] in
            guard let self else { return }
            await self.appendSamples(samples)
        }
    }

    /// RMS: marks the input alive, and stands in for the VAD when the model is not loaded.
    /// Called from onAmplitudeUpdate (already on main, ~12 Hz).
    func feedRMS(_ rms: Float) {
        if rms > signalFloor { tracker.noteAudioSignal() }
        guard vad == nil else { return }
        if rms > rmsFloor {
            rmsSpeechFrames += 1
            if rmsSpeechFrames >= rmsSpeechFramesNeeded {
                rmsSpeechFrames = 0
                tracker.noteVoice(at: elapsedSeconds)
            }
        } else {
            // Decay slowly — one bad reading shouldn't reset a real signal
            rmsSpeechFrames = max(0, rmsSpeechFrames - 1)
        }
    }

    /// Called when transcribed text or a note arrives — content is definitive regardless of VAD.
    func noteSpeech() {
        let wasEmpty = !tracker.hasContent
        tracker.noteContent(at: elapsedSeconds)
        prompt = tracker.prompt
        if wasEmpty { Logger.info("MeetingSilenceWatcher: first content", subsystem: .audio) }
    }

    // MARK: - Update elapsed (called by AppState's amplitude callback, once/tick)

    func updateElapsed(_ seconds: Double) {
        elapsedSeconds = seconds
    }

    // MARK: - Private

    @MainActor
    private func appendSamples(_ samples: [Float]) {
        sampleBuffer.append(contentsOf: samples)

        guard sampleBuffer.count >= sampleBufferSize, let vad else { return }
        let chunk = Array(sampleBuffer.prefix(sampleBufferSize))
        sampleBuffer.removeFirst(min(sampleBufferSize, sampleBuffer.count))

        // Cancel any running VAD check — only care about the freshest window
        pendingVADTask?.cancel()
        pendingVADTask = Task.detached(priority: .utility) { [weak self, chunk] in
            guard let self else { return }
            let found = vad.hasSpeech(samples: chunk)
            guard !Task.isCancelled, found else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.tracker.noteVoice(at: self.elapsedSeconds)
            }
        }
    }

    private func updatePrompt() {
        let app = AppState.shared
        let paused = app.isPaused || app.isMicMuted || app.meetingInterlude != nil
        tracker.update(elapsed: elapsedSeconds, capturePaused: paused)
        if prompt != tracker.prompt { prompt = tracker.prompt }
        if tracker.autoDiscardDue, !firedAutoDiscard {
            firedAutoDiscard = true
            Logger.info("MeetingSilenceWatcher: empty meeting countdown ran out at \(Int(elapsedSeconds))s", subsystem: .audio)
            onAutoDiscard?()
        }
    }

    private func startTick() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run { [weak self] in
                    self?.updatePrompt()
                }
            }
        }
    }
}
