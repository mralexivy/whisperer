//
//  SeekableAudioPlayer.swift
//  Whisperer
//
//  AVAudioEngine-based audio player that correctly seeks the app's Ogg Opus format.
//
//  AVAudioPlayer.currentTime = t appears to work (read-back returns t) but never moves the
//  decoder on seekable-but-unindexed Ogg Opus files. AVAudioFile random access is exact;
//  scheduleSegment(startingFrame:) picks up from any frame position.
//
//  Replaces AudioPlayer (AudioPlayerView) and MeetingAudioPlayer (MeetingPlayerCard).
//

import Foundation
import AVFoundation
import Combine

@MainActor
final class SeekableAudioPlayer: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var isPlaying = false
    @Published var isLoading = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var playbackRate: Float = 1.0
    @Published var loadedURL: URL?
    /// True while the user is dragging; position timer pauses so the playhead tracks the drag.
    @Published var isScrubbing = false

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    // MARK: - Private engine components

    private var audioFile: AVAudioFile?
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let pitchNode = AVAudioUnitTimePitch()   // pitch-preserving rate

    /// Frame the most-recent schedule started from.
    private var seekFrame: AVAudioFramePosition = 0
    /// Total frame length of the loaded file.
    private var totalFrames: AVAudioFramePosition = 0
    /// File's sample rate — may differ from engine's (e.g. Opus decodes to 48 kHz).
    private var fileSampleRate: Double = 0

    /// Monotonically-incrementing tag so stale completion closures don't fire.
    private var scheduleGeneration: Int = 0

    private var positionTimer: Timer?

    // MARK: - Init

    override init() {
        // Restore persisted speed, matching AudioPlayer behaviour.
        let storedRate = UserDefaults.standard.float(forKey: "audioPlaybackSpeed")
        super.init()
        if storedRate > 0 { playbackRate = storedRate }

        setupEngine()
        observeEngineConfigChange()
    }

    deinit {
        // AVAudioEngine and AVAudioPlayerNode are not @MainActor — tearing them down here is fine.
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    func load(url: URL) {
        stop()
        isLoading = true
        loadedURL = nil
        let capture = url
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let file = try AVAudioFile(forReading: capture)
                let dur = Double(file.length) / file.processingFormat.sampleRate
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.audioFile = file
                    self.totalFrames = file.length
                    self.fileSampleRate = file.processingFormat.sampleRate
                    self.duration = dur
                    self.seekFrame = 0
                    self.currentTime = 0
                    self.isLoading = false
                    self.loadedURL = capture
                }
            } catch {
                Logger.error("SeekableAudioPlayer: failed to load \(capture.lastPathComponent): \(error)", subsystem: .app)
                await MainActor.run { [weak self] in
                    self?.isLoading = false
                }
            }
        }
    }

    func play() {
        guard let file = audioFile, duration > 0 else { return }
        startEngineIfNeeded()

        // If we finished naturally and play is pressed again, restart from the top.
        if !isPlaying && currentTime >= duration - 0.05 {
            seekFrame = 0
            currentTime = 0
        }

        scheduleAndPlay(file: file, wasPlaying: false)
        isPlaying = true
        startPositionTimer()
    }

    func pause() {
        playerNode.pause()
        isPlaying = false
        // Capture position so the timer doesn't drift when it stops.
        currentTime = readCurrentTime()
        stopPositionTimer()
    }

    func stop() {
        scheduleGeneration += 1
        playerNode.stop()
        isPlaying = false
        stopPositionTimer()
        seekFrame = 0
        currentTime = 0
    }

    func seek(to time: Double) {
        guard duration > 0, let file = audioFile else { return }
        let clamped = min(max(time, 0), duration)
        seekFrame = AVAudioFramePosition(clamped * fileSampleRate)
        currentTime = clamped

        scheduleGeneration += 1
        playerNode.stop()   // cancels any pending schedules

        if isPlaying {
            startEngineIfNeeded()
            scheduleAndPlay(file: file, wasPlaying: true)
        }
    }

    func skipBack(_ seconds: Double = 15) { seek(to: currentTime - seconds) }
    func skipForward(_ seconds: Double = 30) { seek(to: currentTime + seconds) }

    func setRate(_ rate: Float) {
        playbackRate = rate
        UserDefaults.standard.set(rate, forKey: "audioPlaybackSpeed")
        pitchNode.rate = rate
    }

    // MARK: - Position timer

    private func startPositionTimer() {
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying, !self.isScrubbing else { return }
                self.currentTime = self.readCurrentTime()
            }
        }
        RunLoop.main.add(positionTimer!, forMode: .common)
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func readCurrentTime() -> Double {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleTime >= 0 else {
            return Double(seekFrame) / max(fileSampleRate, 1)
        }
        let played = Double(seekFrame) / fileSampleRate + Double(playerTime.sampleTime) / (pitchNode.rate > 0 ? Double(pitchNode.rate) : 1) / playerTime.sampleRate
        return min(played, duration)
    }

    // MARK: - Engine setup

    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(pitchNode)
        // Connect in chain; format is negotiated at play time when the file is known.
        engine.connect(playerNode, to: pitchNode, format: nil)
        engine.connect(pitchNode, to: engine.mainMixerNode, format: nil)
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            Logger.error("SeekableAudioPlayer: engine start failed: \(error)", subsystem: .app)
        }
    }

    private func observeEngineConfigChange() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    @objc private nonisolated func handleEngineConfigChange() {
        // Device reconfigured — rebuild and reschedule from current position.
        Task { @MainActor [weak self] in
            guard let self, let file = self.audioFile else { return }
            let wasPlaying = self.isPlaying
            self.seekFrame = AVAudioFramePosition(self.currentTime * self.fileSampleRate)
            // Engine will auto-stop on config change; restart it.
            do { try self.engine.start() } catch {
                Logger.error("SeekableAudioPlayer: engine restart after config change failed: \(error)", subsystem: .app)
                self.isPlaying = false
                self.stopPositionTimer()
                return
            }
            if wasPlaying {
                self.scheduleAndPlay(file: file, wasPlaying: true)
            }
        }
    }

    // MARK: - Schedule helper

    private func scheduleAndPlay(file: AVAudioFile, wasPlaying: Bool) {
        let frameCount = totalFrames - seekFrame
        guard frameCount > 0 else {
            // Already at or past end.
            isPlaying = false
            currentTime = duration
            return
        }
        pitchNode.rate = playbackRate

        let generation = scheduleGeneration

        playerNode.scheduleSegment(
            file,
            startingFrame: seekFrame,
            frameCount: AVAudioFrameCount(frameCount),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.scheduleGeneration == generation else { return }
                self.isPlaying = false
                self.currentTime = self.duration   // park at end
                self.stopPositionTimer()
            }
        }

        playerNode.play()
    }
}
