//
//  MeetingSilenceWatcher.swift
//  Whisperer
//
//  Runtime signal for silent-meeting detection.
//  Feeds audio samples into Silero VAD at ~1 Hz; latches off permanently on first speech.
//

import Foundation
import SwiftUI
import Combine

/// One-shot VAD watcher for a meeting session. Start it when recording begins, stop it
/// when the recording ends or speech is confirmed. Thread-safe: only `feed` and `feedRMS`
/// are called from background contexts; everything else is @MainActor.
@MainActor
final class MeetingSilenceWatcher: ObservableObject {

    // MARK: - Published state (drives toast + discard decision)

    /// True as soon as any voiced audio is confirmed — never reverts to false.
    @Published private(set) var speechDetected: Bool = false

    /// Derived UI stage — recomputed by the 1 Hz tick.
    @Published private(set) var stage: MeetingSilenceStage = .hidden

    /// Whether the user dismissed the toast for this session. Persists until `stop()`.
    @Published private(set) var dismissed: Bool = false

    // MARK: - Private

    private var vad: SileroVAD?
    private var sampleBuffer: [Float] = []
    private let sampleBufferSize = 16_000          // 1 s at 16 kHz
    private var pendingVADTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    /// Elapsed seconds supplied by MeetingSession.elapsedSeconds via AppState.
    /// The watcher doesn't own a timer — it piggybacks on the session's existing clock.
    private var elapsedSeconds: Double = 0

    // RMS fallback (when VAD model is unavailable)
    private var rmsSpeechFrames: Int = 0
    private let rmsFloor: Float = 0.015            // rough floor; 0.5s above this = speech
    private let rmsSpeechFramesNeeded: Int = 6     // ~0.5s at 12 Hz publish rate

    // MARK: - Lifecycle

    func start(vad: SileroVAD?) {
        self.vad = vad
        sampleBuffer.removeAll(keepingCapacity: true)
        speechDetected = false
        dismissed = false
        stage = .hidden
        elapsedSeconds = 0
        rmsSpeechFrames = 0
        startTick()
    }

    func stop() {
        pendingVADTask?.cancel()
        pendingVADTask = nil
        tickTask?.cancel()
        tickTask = nil
        sampleBuffer.removeAll()
    }

    /// Dismiss the toast for the rest of this session (does not stop recording).
    func dismiss() {
        dismissed = true
        updateStage()
    }

    // MARK: - Feed paths (called from AppState's onStreamingSamples / onAmplitudeUpdate)

    /// Called with raw audio samples (same buffer AppState passes to the transcriber).
    /// Non-isolated so AppState can call it without hopping.
    nonisolated func feed(_ samples: [Float]) {
        Task.detached { [weak self] in
            guard let self else { return }
            await self.appendSamples(samples)
        }
    }

    /// RMS fallback for when the VAD model is not loaded.
    /// Called from onAmplitudeUpdate (already on main, ~12 Hz).
    func feedRMS(_ rms: Float) {
        guard vad == nil, !speechDetected else { return }
        if rms > rmsFloor {
            rmsSpeechFrames += 1
            if rmsSpeechFrames >= rmsSpeechFramesNeeded {
                latchSpeech(source: "rms")
            }
        } else {
            // Decay slowly — one bad reading shouldn't reset a real signal
            rmsSpeechFrames = max(0, rmsSpeechFrames - 1)
        }
    }

    /// Called when a transcription chunk arrives with non-empty text — transcript is
    /// definitive regardless of VAD.
    func noteSpeech() {
        guard !speechDetected else { return }
        latchSpeech(source: "transcript")
    }

    // MARK: - Update elapsed (called by AppState's amplitude callback, once/tick)

    func updateElapsed(_ seconds: Double) {
        elapsedSeconds = seconds
    }

    // MARK: - Private

    @MainActor
    private func appendSamples(_ samples: [Float]) {
        guard !speechDetected else { return }
        sampleBuffer.append(contentsOf: samples)

        guard sampleBuffer.count >= sampleBufferSize, let vad else { return }
        let chunk = Array(sampleBuffer.prefix(sampleBufferSize))
        sampleBuffer.removeFirst(min(sampleBufferSize, sampleBuffer.count))

        // Cancel any running VAD check — only care about the freshest window
        pendingVADTask?.cancel()
        pendingVADTask = Task.detached(priority: .utility) { [weak self, chunk] in
            guard let self else { return }
            let found = vad.hasSpeech(samples: chunk)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.speechDetected else { return }
                if found { self.latchSpeech(source: "vad") }
            }
        }
    }

    private func latchSpeech(source: String) {
        guard !speechDetected else { return }
        Logger.info("MeetingSilenceWatcher: speech latched via \(source)", subsystem: .audio)
        speechDetected = true
        stage = .hidden
        pendingVADTask?.cancel()
        pendingVADTask = nil
        tickTask?.cancel()
        tickTask = nil
        sampleBuffer.removeAll()
    }

    private func updateStage() {
        stage = MeetingSilencePolicy.stage(
            elapsed: elapsedSeconds,
            speechDetected: speechDetected,
            dismissed: dismissed
        )
    }

    private func startTick() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run { [weak self] in
                    self?.updateStage()
                }
            }
        }
    }
}
