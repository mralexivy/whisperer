//
//  MeetingCallAudioController.swift
//  Whisperer
//
//  Records the other side of a call. A meeting used to capture only the microphone, so with
//  headphones on, the other participants were simply not in the transcript. This owns a
//  `SystemAudioCapture` (Core Audio process tap on the call app) for the length of one meeting
//  and wires its `SystemAudioMixer` into `AudioRecorder`, which mixes the far end into the
//  stream every downstream consumer already reads — transcriber, diarizer, silence watcher and
//  the session file — so the transcript, the speaker attribution, the post-stop re-transcription
//  and playback all get both sides with no change to their clocks.
//
//  Falls back to microphone-only, with a log line and `MeetingSession.callAudioNote`, whenever
//  the tap cannot be built.
//

import Foundation

@MainActor
final class MeetingCallAudioController {

    /// UserDefaults key for Settings → Meeting Detection → "Record the other participants".
    static let settingKey = "meetingCaptureCallAudio"

    /// Default on: a meeting transcript with one side missing is the bug this exists to fix.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) == nil
            || UserDefaults.standard.bool(forKey: settingKey)
    }

    static let unavailableNote = "Recording your microphone only — call audio isn't available right now."

    private var capture: SystemAudioCapture?
    private var mixer: SystemAudioMixer?
    private weak var session: MeetingSession?
    private weak var recorder: AudioRecorder?
    private var target: CallAudioTapTarget?
    private var route: CallAudioOutputRoute?
    private var timer: Timer?
    private var startedAt: Date?
    private var reportedSilence = false
    private let processMonitor = AudioProcessMonitor()

    var isCapturing: Bool { capture != nil }

    func start(for session: MeetingSession, recorder: AudioRecorder?) {
        stop()
        guard Self.isEnabled else {
            Logger.info("Meeting call audio: off in Settings — recording the microphone only", subsystem: .audio)
            return
        }
        guard let recorder else { return }
        self.session = session
        self.recorder = recorder

        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.ivy.whisperer"
        let monitor = processMonitor
        let target = CallAudioTapTarget.choose(
            sourceBundleID: session.sourceBundleID,
            capturingBundleIDs: monitor.capturingBundleIDs(),
            ownBundleID: ownBundleID,
            processesFor: { monitor.processObjects(ownedBy: $0) },
            ownProcesses: monitor.ownProcessObjects()
        )

        let mixer = SystemAudioMixer()
        let capture = SystemAudioCapture(mixer: mixer)
        do {
            try capture.start(target: target)
        } catch {
            Logger.warning("Meeting call audio unavailable (\(error)) — recording the microphone only",
                           subsystem: .audio)
            session.callAudioNote = Self.unavailableNote
            return
        }
        self.capture = capture
        self.mixer = mixer
        self.target = target
        // Mic and call levels for automatic speaker names; the closure keeps the mixer alive
        // past `stop()` so the final naming at the end of the meeting can still read them.
        session.sourceActivity = { mixer.sourceActivity }
        startedAt = Date()
        reportedSilence = false
        recorder.systemAudioMixer = mixer
        Logger.info("Meeting call audio: capturing \(target.logLabel)", subsystem: .audio)

        applyRoute()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Idempotent — called from every path that ends meeting mode.
    func stop() {
        timer?.invalidate()
        timer = nil
        recorder?.systemAudioMixer = nil
        if let capture {
            capture.stop()
            if let stats = mixer?.stats {
                Logger.info("Meeting call audio: stopped — appended=\(stats.appended) mixed=\(stats.mixed) " +
                            "dropped=\(stats.dropped) underrun=\(stats.underrun) peak=\(String(format: "%.3f", stats.peak))",
                            subsystem: .audio)
            }
        }
        capture = nil
        mixer = nil
        target = nil
        route = nil
        recorder = nil
        session = nil
        startedAt = nil
    }

    // MARK: - Periodic upkeep

    private func tick() {
        guard capture != nil else { return }
        applyRoute()
        refreshProcesses()
        checkForDigitalSilence()
    }

    /// Headphones plugged in or pulled out mid-call change whether the far end is already in the
    /// microphone signal.
    private func applyRoute() {
        let (newRoute, name) = SystemAudioCapture.currentOutputRoute()
        guard newRoute != route else { return }
        route = newRoute
        mixer?.mode = newRoute.farEndMode
        Logger.info("Meeting call audio: output \(newRoute.rawValue) (\(name)) — " +
                    (newRoute.farEndMode == .add ? "mixing the call into the recording"
                                                 : "mixing the call in, microphone ducked while it talks"),
                    subsystem: .audio)
    }

    /// Chrome can start a new audio helper mid-call; a per-app tap would not hear it.
    private func refreshProcesses() {
        guard case .app(let bundleID, let current)? = target, let capture else { return }
        let latest = processMonitor.processObjects(ownedBy: bundleID)
        guard !latest.isEmpty, Set(latest) != Set(current) else { return }
        if capture.updateProcesses(latest) {
            target = .app(bundleID: bundleID, processes: latest)
            Logger.info("Meeting call audio: \(bundleID) now \(latest.count) process(es)", subsystem: .audio)
        }
    }

    /// A denied "System Audio Recording" permission does not fail anything — the tap just
    /// delivers exact zeros. A real call is never digitally silent for a minute while the
    /// microphone is live, so say so once in the log (the UI stays quiet: a muted call or a
    /// call that has not started produces the same zeros, and a false alarm would be worse).
    private func checkForDigitalSilence() {
        guard !reportedSilence, let startedAt, let mixer,
              Date().timeIntervalSince(startedAt) > 60 else { return }
        let stats = mixer.stats
        if stats.appended > 0, stats.peak == 0 {
            reportedSilence = true
            Logger.warning("Meeting call audio: only digital silence after 60s — the call is silent, " +
                           "or System Audio Recording is off for Whisperer in Privacy & Security",
                           subsystem: .audio)
        } else if stats.appended == 0 {
            reportedSilence = true
            Logger.warning("Meeting call audio: the tap has delivered nothing after 60s", subsystem: .audio)
        }
    }
}
