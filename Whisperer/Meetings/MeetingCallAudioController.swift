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

import CoreAudio
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
    private var reportedSoundAfterSilence = false
    private let processMonitor = AudioProcessMonitor()
    /// The output device the tap's aggregate is clocked by. Switching to AirPods mid-call (Zoom
    /// has to be told by hand; Meet and Teams follow the system) leaves the old aggregate on a
    /// device the call no longer plays through, so the capture is rebuilt on the new one.
    private var outputDeviceID: AudioDeviceID?
    private var outputListener: AudioObjectPropertyListenerBlock?

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
        outputDeviceID = SystemAudioCapture.defaultOutputDeviceID()
        watchOutputDevice()
        // Mic and call levels for automatic speaker names; the closure keeps the mixer alive
        // past `stop()` so the final naming at the end of the meeting can still read them.
        session.sourceActivity = { mixer.sourceActivity }
        startedAt = Date()
        reportedSilence = false
        reportedSoundAfterSilence = false
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
        if let outputListener {
            var address = SystemAudioCapture.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, outputListener)
        }
        outputListener = nil
        outputDeviceID = nil
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
        rebindIfOutputChanged()
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

    private func watchOutputDevice() {
        var address = SystemAudioCapture.address(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rebindIfOutputChanged()
                self.applyRoute()
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
            outputListener = listener
        }
    }

    /// Rebuilds the tap on the current output device, feeding the same mixer — the recording's
    /// clock, levels and counters carry on; at most the switch's own fraction of a second is lost.
    /// If the rebuild fails the old capture is kept, so a switch never ends the call audio.
    private func rebindIfOutputChanged() {
        guard let capture, let mixer, let target,
              let current = SystemAudioCapture.defaultOutputDeviceID(), current != outputDeviceID else { return }
        let replacement = SystemAudioCapture(mixer: mixer)
        capture.stop()
        do {
            try replacement.start(target: target)
        } catch {
            Logger.warning("Meeting call audio: output changed but the tap could not move (\(error)) — keeping the old one", subsystem: .audio)
            try? capture.start(target: target)
            outputDeviceID = current
            return
        }
        self.capture = replacement
        outputDeviceID = current
        let (_, name) = SystemAudioCapture.currentOutputRoute()
        Logger.info("Meeting call audio: output switched to \(name) — call capture moved with it", subsystem: .audio)
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
        // The warning fires on a call that simply had not started yet, and read as "permission
        // off" on a Mac where it was on (2026-11-09: warned at 60 s, the tap peaked 0.122 later).
        // Say when sound does arrive, so the log answers which it was.
        if reportedSilence, !reportedSoundAfterSilence, let startedAt, let mixer, mixer.stats.peak > 0 {
            reportedSoundAfterSilence = true
            Logger.info(String(format: "Meeting call audio: sound arrived by %.0fs — the tap works; the silence was the call",
                               Date().timeIntervalSince(startedAt)), subsystem: .audio)
            return
        }
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
