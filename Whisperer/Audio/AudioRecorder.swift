//
//  AudioRecorder.swift
//  Whisperer
//
//  Microphone capture using AVAudioEngine for real-time streaming.
//  Engine lifecycle is delegated to AudioEngineLifecycle (actor), which is the
//  sole owner of AVAudioEngine. AudioRecorder owns sample delivery, disk write,
//  watchdogs, and device monitoring.
//

import AVFoundation
import Accelerate
import CoreAudio
import AudioToolbox

// MARK: - Failure Tracking

enum RecordingFailureReason: String {
    case explicitDeviceBindFailed = "explicit_device_bind_failed"
    case audioUnitInitFailed = "audio_unit_init_failed"
    case invalidFormat = "invalid_format"
    case noAudioFlowAfterStart = "no_audio_flow_after_start"
    case deviceLostDuringRecording = "device_lost_during_recording"
    case restartOnDefaultFailed = "restart_on_default_failed"
    case engineCreationFailed = "engine_creation_failed"
    case tapInstallFailed = "tap_install_failed"
    case microphonePermissionDenied = "microphone_permission_denied"
}

struct StartupFailure {
    let stage: String
    let route: ResolvedInputRoute
    let generation: Int
    let reason: RecordingFailureReason
    let osStatus: OSStatus?
    let elapsedMs: Int

    func log() {
        Logger.event(.recFail, .audio, [
            "stage": .string(stage),
            "reason": .string(reason.rawValue),
            "gen": .int(generation),
            "ms": .int(elapsedMs)
        ], level: .error)
    }
}

class AudioRecorder: NSObject {

    // MARK: - Engine (owned by actor)

    private let engineLifecycle = AudioEngineLifecycle()

    // Last device ID bound by the actor — used for sync diagnostics (healthState, debugSnapshot)
    private var cachedEngineDeviceID: AudioDeviceID?

    /// The device the live engine is bound to, for callers that need to act on it (the Island's
    /// un-mute repair). `nil` when no engine is up.
    var engineDeviceID: AudioDeviceID? { cachedEngineDeviceID }

    // MARK: - Recording state

    private let isRecordingLock = NSLock()
    private var _isRecording = false
    private var isRecording: Bool {
        get { isRecordingLock.lock(); defer { isRecordingLock.unlock() }; return _isRecording }
        set { isRecordingLock.lock(); _isRecording = newValue; isRecordingLock.unlock() }
    }
    private var currentURL: URL?

    // MARK: - Callbacks

    var onAmplitudeUpdate: ((Float) -> Void)?
    var onStreamingSamples: (([Float]) -> Void)?
    var onDeviceRecovery: ((RecordingFailureReason) -> Void)?
    /// Capture has permanently failed. Carries the diagnosis so the caller can tell the user
    /// *why* rather than the old generic "microphone stopped responding".
    var onAudioFlowTimeout: ((InputHealthVerdict) -> Void)?
    /// Capture has gone silent and recovery has begun. Fired within ~1.5 s of the first silent
    /// buffer, long before the retry budget is spent, so the user can be warned while there is
    /// still a meeting left to save. Fires once per silence episode.
    var onCaptureTrouble: ((InputHealthVerdict) -> Void)?
    /// Audio came back after an episode of silence.
    var onCaptureRecovered: (() -> Void)?

    // MARK: - Audio flow tracking

    private var lastAudioCallbackTime: Date?
    private(set) var audioProgressCounter: UInt64 = 0

    // MARK: - Watchdogs

    private var audioFlowWatchdog: DispatchSourceTimer?
    private let audioFlowTimeout: TimeInterval = 3.0

    // MARK: - Recovery

    private var recoveryAttemptCount: Int = 0

    /// How long the recorder keeps fighting for audio before giving up for good.
    ///
    /// This used to be one flat `maxRecoveryAttempts = 3` for everything, which is how a
    /// 58-minute meeting was abandoned 9 seconds in and never retried. A two-second dictation
    /// genuinely wants a short leash — the user is holding a key and can just release it and
    /// try again. A meeting wants the opposite: nobody is watching, the transient may clear in
    /// twenty seconds, and surrender costs the entire recording.
    enum RecoveryPolicy: Equatable {
        /// Push-to-talk. Three quick attempts, then fail so the HUD can clear.
        case dictation
        /// Meetings and in-app recording. Never stops trying while the session is open.
        case longForm

        var maxAttempts: Int? {
            switch self {
            case .dictation: return 3
            case .longForm:  return nil   // unbounded
            }
        }

        /// Backoff before attempt `n` (1-based). Dictation stays flat and fast; long-form backs
        /// off so an hour-long outage costs a handful of rebuilds rather than thousands.
        func settleDelay(attempt: Int) -> TimeInterval {
            switch self {
            case .dictation:
                return 0.3
            case .longForm:
                return min(10.0, 0.3 * pow(2.0, Double(max(0, attempt - 1))))
            }
        }
    }

    private var recoveryPolicy: RecoveryPolicy = .dictation

    // MARK: - Silence detection

    private var consecutiveSilentCallbacks: Int = 0
    private let silenceRecoveryThreshold: Int = 18  // ~1.5s at 48kHz/4096 buffer
    /// Guards `onCaptureTrouble` so one silence episode produces one warning, not one per buffer.
    private var hasReportedSilenceEpisode = false
    /// Set once any non-silent sample has been seen in this recording. Distinguishes "the mic
    /// died mid-meeting" (partial audio worth keeping) from "the mic never worked at all"
    /// (the 2026-09-14 case — 58 minutes of nothing).
    private(set) var hasEverReceivedNonSilentAudio = false

    // MARK: - Recorder state machine

    private enum RecorderState: CustomStringConvertible {
        case idle
        case starting(generation: Int)
        case recording(generation: Int)
        case stopping(generation: Int)
        case recovering(generation: Int)

        var generation: Int? {
            switch self {
            case .idle: return nil
            case .starting(let g), .recording(let g), .stopping(let g), .recovering(let g): return g
            }
        }

        var description: String {
            switch self {
            case .idle:              return "idle"
            case .starting(let g):  return "starting(gen=\(g))"
            case .recording(let g): return "recording(gen=\(g))"
            case .stopping(let g):  return "stopping(gen=\(g))"
            case .recovering(let g): return "recovering(gen=\(g))"
            }
        }
    }

    private var recorderState: RecorderState = .idle
    private var currentGeneration = 0

    // MARK: - Startup progress (read cross-thread by AppState's startup watchdog)

    private let startupLock = NSLock()
    private var _startupInFlight: (generation: Int, since: Date)?

    /// Non-nil while a `startRecording` attempt is in flight.
    var startupInFlightSince: Date? {
        startupLock.lock(); defer { startupLock.unlock() }
        return _startupInFlight?.since
    }

    private func markStartupInFlight(generation: Int) {
        startupLock.lock()
        _startupInFlight = (generation: generation, since: Date())
        startupLock.unlock()
    }

    private func clearStartupInFlight(generation: Int) {
        startupLock.lock()
        if _startupInFlight?.generation == generation { _startupInFlight = nil }
        startupLock.unlock()
    }

    private func abortWedgedStartup(generation: Int, after seconds: TimeInterval) {
        guard case .starting(let g) = recorderState, g == generation else { return }
        Logger.event(.engBuild, .audio, ["warn": .string("wedged"), "after_s": .int(Int(seconds)), "gen": .int(generation)], level: .error)
        currentGeneration += 1
        recorderState = .idle
        clearStartupInFlight(generation: generation)
        discardSessionAudio()
    }

    // MARK: - Timing

    private var recordingStartTime: Date?
    private let startupGracePeriod: TimeInterval = 1.5
    private let startupHardDeadline: TimeInterval = 20.0

    // MARK: - Diagnostics

    private(set) var lastEngineStartError: Error?

    // MARK: - Disk write (Ogg Opus, 16 kHz mono, parallel with Float32 callback)

    /// Written through `AudioArchiveWriter`, not `AVAudioFile`. `AVAudioFile(forWriting:)` infers
    /// the container from the path extension, and `makeSessionAudioURL()` hands it a `.opus` —
    /// which no `AVAudioFile` settings dictionary can produce. Writing the session with
    /// `int16Format.settings` therefore failed on *every* recording, and the `try?` around it
    /// swallowed the reason, so the only trace was `rec.fail fail=session_file`. Result: no
    /// session audio on disk since 2026-08-15 while history rows kept recording a
    /// `sessionAudioURL` that pointed at a file which was never created.
    ///
    /// **Touched only on `sessionWriteQueue`.** `AudioArchiveWriter` is documented as not
    /// thread-safe, and `close()` used to run on the caller's thread after a bare
    /// `sessionWriteQueue.sync {}` — which orders against blocks *already enqueued* and nothing
    /// more. A capture callback that had passed the `isRecording` check could still enqueue an
    /// encode after that sync returned, running `write()` on the same `OGGEncoder` and
    /// `FileHandle` the caller was closing. `stopRecording` mostly hid it behind a 200 ms drain;
    /// the three recovery paths close with no drain at all.
    ///
    /// There is deliberately **no off-queue `sessionWriterOpen` mirror** of this. One was tried,
    /// to let the capture callback skip the buffer copy when no session was open, and it was a
    /// straightforward data race: there is no single "control thread" here. `openSessionWriter`
    /// runs from `startRecordingInternal`, while `closeSessionWriter` runs from `stopRecording`,
    /// from `discardSessionAudio` (reached from `abortWedgedStartup` on the 20 s timeout task,
    /// which fires *while* `startRecordingInternal` is still running — that is its purpose), and
    /// from three sites in `recoverAudioEngine`, itself spawned as an unstructured `Task` from
    /// four places. Two unsynchronized writers and one reader on the CoreAudio tap thread.
    /// Publishing the flag and the writer as independent variables also admits both stale
    /// states, including an open writer nobody will close. The saving was one
    /// `AVAudioPCMBuffer` allocation per callback; `isRecording` (`isRecordingLock`) is a
    /// sufficient gate and the enqueued block re-checks the writer on the queue regardless.
    private var sessionAudioWriter: AudioArchiveWriter?
    private(set) var sessionAudioURL: URL?
    /// The format the capture callback delivers, reused for `AVAudioPCMBuffer` reconstruction.
    private let whisperFormat: AVAudioFormat = AudioArchiveFormat.pcmFormat
    private let sessionWriteQueue = DispatchQueue(label: "whisperer.sessionWrite", qos: .utility)
    /// Frames encoded since the last forced flush. Touched only on `sessionWriteQueue`.
    private var framesSinceFlush = 0
    /// True once any audio has been encoded into the current session. Distinguishes "a start
    /// that never produced sound" (safe to unlink) from "a live recording whose engine died"
    /// (must be kept). Touched only on `sessionWriteQueue`.
    private var sessionHasAudio = false
    /// Flush every 5s so a crash costs the interval rather than the whole recording.
    private let flushIntervalFrames = Int(AudioArchiveFormat.sampleRate * 5)

    // MARK: - Device monitoring

    private var monitoredDeviceID: AudioDeviceID?
    private var deviceAliveListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultInputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var isMonitoringDefaultInputDevice = false

    /// Timestamp of the most recent default-input device change, regardless of whether
    /// recording was active at the time. A start within ~3 s of this timestamp may be racing
    /// a Bluetooth handoff that has not finished settling — preflight uses this to select a
    /// more conservative first-buffer deadline.
    private(set) var lastDefaultInputChangeAt: Date?

    // MARK: - Init / deinit

    override init() {
        super.init()
        startMonitoringDefaultInputDevice()
    }

    // No `closeSessionWriter()` here, deliberately. It does a `sessionWriteQueue.sync {}`, and
    // an encode block's `guard let self` can hold the last strong reference — so deinit can run
    // *on* `sessionWriteQueue`, and a `sync` back onto that serial queue would deadlock.
    // A recorder released mid-recording is covered instead by `AudioArchiveWriter.deinit`,
    // which finalizes the stream when the writer is dropped.
    deinit {
        stopAudioFlowWatchdog()
        stopMonitoringDevice()
        stopMonitoringDefaultInputDevice()
    }

    // MARK: - Permission

    static func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted {
            } else {
                Logger.event(.recFail, .audio, ["perm": .string("denied")], level: .warning)
            }
        }
    }

    static func checkMicrophonePermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                continuation.resume(returning: true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            case .denied, .restricted:
                continuation.resume(returning: false)
            @unknown default:
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Recording

    /// Three-attempt policy:
    ///   1. The requested route, after a preflight readiness check.
    ///   2. Same route (or `.systemDefault`) after a settle delay sized by the preflight verdict.
    ///   3. A *different* device — the best healthy non-default input found by `recoveryRoute`.
    ///      This is the critical change: if attempts 1 and 2 both fail on a cold AirPods that is
    ///      still the default input, attempt 3 picks up `MacBook Pro Microphone` instead of
    ///      trying the dead device a third time.
    ///
    /// `recovery` governs what happens *after* a successful start, if the device later stops
    /// producing audio: `.dictation` gives up quickly, `.longForm` never gives up while the
    /// session is open. Pass `.longForm` for meetings and in-app recording.
    func startRecording(route: ResolvedInputRoute, recovery: RecoveryPolicy = .dictation) async throws -> URL {
        recoveryAttemptCount = 0
        recoveryPolicy = recovery
        hasEverReceivedNonSilentAudio = false
        hasReportedSilenceEpisode = false

        guard !isRecording else {
            throw RecordingError.alreadyRecording
        }

        currentGeneration += 1
        let generation = currentGeneration
        recordingStartTime = Date()
        recorderState = .starting(generation: generation)
        markStartupInFlight(generation: generation)
        let attemptStart = Date()

        // Every exit resets the recorder. Generation-stamped so a start that began after ours
        // is never clobbered. Without this, a throw while .starting leaves the recorder wedged.
        defer {
            clearStartupInFlight(generation: generation)
            if case .starting(let g) = recorderState, g == generation {
                recorderState = .idle
                discardSessionAudio()
            }
        }

        // Last resort: if configure() hangs in buildGraph (engine.inputNode blocks on CoreAudio),
        // the continuation never resumes. Past the deadline the recorder resets for a retry.
        let timeoutGen = generation
        let deadline = startupHardDeadline
        let timeoutTask = Task { [weak self] in
            // NOT `try?` — that swallows CancellationError from the defer and runs the body
            // immediately, logging "timed out after 15s" at 4.4s into a start.
            do { try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000)) }
            catch { return }
            self?.abortWedgedStartup(generation: timeoutGen, after: deadline)
        }
        defer { timeoutTask.cancel() }

        // Pre-flight: check whether the resolved device is ready before we burn an attempt.
        // A cold Bluetooth device (e.g. AirPods that handed the link to an iPhone) reads alive
        // and has input streams but `isRunningSomewhere` is false. Binding it costs 1.5 s and
        // then fails with a sample-rate mismatch; it is better to know this up front.
        let preflight = InputRoutePreflight.preflight(route: route)
        let preflightFields = InputRoutePreflight.logFields(
            RoutePreflightFacts(uid: {
                if case .explicit(let uid, _) = route { return uid }
                return InputRoutePreflight.systemDefaultInputDeviceID()
                    .flatMap { InputRoutePreflight.deviceUID($0) }
            }(),
            transportType: {
                let devID: AudioDeviceID?
                switch route {
                case .systemDefault: devID = InputRoutePreflight.systemDefaultInputDeviceID()
                case .explicit(_, let d): devID = d
                }
                return devID.map { InputRoutePreflight.transportType($0) } ?? 0
            }(),
            isRunningSomewhere: {
                let devID: AudioDeviceID?
                switch route {
                case .systemDefault: devID = InputRoutePreflight.systemDefaultInputDeviceID()
                case .explicit(_, let d): devID = d
                }
                return devID.map { InputRoutePreflight.isRunningSomewhere($0) } ?? false
            }(),
            healthVerdict: .healthy),
            preflight
        )
        Logger.step(.engBuild, .audio, preflightFields)

        // Track which device attempt 1 used so attempt 3 can avoid it.
        var attempt1DeviceID: AudioDeviceID? = {
            switch route {
            case .systemDefault: return InputRoutePreflight.systemDefaultInputDeviceID()
            case .explicit(_, let d): return d
            }
        }()

        // Attempt 1: use the provided route (skip immediately if the preflight says not to).
        if preflight.shouldAttempt {
            do {
                return try await startRecordingInternal(route: route, generation: generation,
                                                        preflightReadiness: preflight)
            } catch {
                guard isGenerationCurrent(generation) else { throw RecordingError.engineCleanedUp }
                let elapsed = Int(Date().timeIntervalSince(attemptStart) * 1000)
                let reason: RecordingFailureReason = route == .systemDefault ? .audioUnitInitFailed : .explicitDeviceBindFailed
                Logger.event(.engRetry, .audio, ["attempt": .int(1), "err": .string(error.localizedDescription)], level: .warning)
                StartupFailure(stage: "full_startup", route: route, generation: generation, reason: reason, osStatus: nil, elapsedMs: elapsed).log()
            }
        } else {
            Logger.event(.engRetry, .audio, ["attempt": .int(1), "skip": .string("preflight_fail")], level: .warning)
        }

        // Attempt 2: same route after a settle delay sized to the readiness verdict.
        // For a cold BT link this is ~900 ms — the link is actually coming up by now.
        let settleDelay = preflight.suggestedSettleDelay
        if settleDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
        }
        guard isGenerationCurrent(generation) else { throw RecordingError.engineCleanedUp }
        recorderState = .starting(generation: generation)
        recordingStartTime = Date()

        do {
            return try await startRecordingInternal(route: .systemDefault, generation: generation,
                                                    preflightReadiness: nil)
        } catch {
            guard isGenerationCurrent(generation) else { throw RecordingError.engineCleanedUp }
            let elapsed = Int(Date().timeIntervalSince(recordingStartTime!) * 1000)
            Logger.event(.engRetry, .audio, ["attempt": .int(2), "err": .string(error.localizedDescription)], level: .warning)
            StartupFailure(stage: "full_startup", route: .systemDefault, generation: generation, reason: .restartOnDefaultFailed, osStatus: nil, elapsedMs: elapsed).log()
        }

        // Attempt 3: a *different* device.
        // This is the critical difference from the old "300ms + same default" structure.
        // If the default input is a cold AirPods, this path finds MacBook Pro Microphone instead.
        let fallbackRoute = recoveryRoute(attempt: 2, avoiding: attempt1DeviceID)
        guard isGenerationCurrent(generation) else { throw RecordingError.engineCleanedUp }
        recorderState = .starting(generation: generation)
        recordingStartTime = Date()

        do {
            return try await startRecordingInternal(route: fallbackRoute, generation: generation,
                                                    preflightReadiness: nil)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(recordingStartTime!) * 1000)
            Logger.event(.recFail, .audio, ["err": .string(error.localizedDescription)], level: .error)
            StartupFailure(stage: "full_startup", route: fallbackRoute, generation: generation, reason: .restartOnDefaultFailed, osStatus: nil, elapsedMs: elapsed).log()
            recorderState = .idle
            throw error
        }
    }

    private func isGenerationCurrent(_ generation: Int) -> Bool {
        return currentGeneration == generation
    }

    private func startRecordingInternal(route: ResolvedInputRoute, generation: Int,
                                         preflightReadiness: RouteReadiness? = nil) async throws -> URL {
        let hasPermission = await AudioRecorder.checkMicrophonePermission()
        guard hasPermission else {
            Logger.event(.recFail, .audio, ["perm": .string("denied")], level: .error)
            throw RecordingError.microphonePermissionDenied
        }

        guard isGenerationCurrent(generation) else { throw RecordingError.engineCleanedUp }

        // Prepare output URL
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "recording_\(Date().timeIntervalSince1970).wav"
        let audioURL = tempDir.appendingPathComponent(fileName)
        currentURL = audioURL

        // Open the session audio file for parallel disk write. It is written in the archive
        // format directly, so it *is* the archive — no transcode at stop.
        //
        // An already-open writer is kept, not replaced. `recoverAudioEngine` re-enters here to
        // rebuild the engine mid-recording, and overwriting the writer there orphaned the
        // pre-recovery file *unclosed* — so it lost its terminating page and its last flush
        // interval, while `StreamingTranscriber.sessionAudioURL` (captured at start) still
        // pointed at it. A successful device recovery silently truncated the recording and
        // leaked the remainder into an unreferenced file. One recording is one Opus stream;
        // the engine restarting underneath it is not a new session. Fresh starts and
        // retry-after-failure both reach here with a nil writer, because every abort path
        // funnels through `discardSessionAudio()`.
        //
        // Read on the queue: this is a strong class reference that `openSessionWriter` and
        // `closeSessionWriter` store to from the queue, and `recoverAudioEngine`'s Task can be
        // closing it while this runs. An unsynchronized read racing an ARC store can over-release.
        if sessionWriteQueue.sync(execute: { sessionAudioWriter == nil }) {
            let sessionURL = SessionStorage.makeSessionAudioURL()
            sessionAudioURL = sessionURL
            openSessionWriter(at: sessionURL)
        }

        lastAudioCallbackTime = nil
        consecutiveSilentCallbacks = 0

        let gracePeriod = startupGracePeriod
        let startTime = recordingStartTime ?? Date()

        // Capture weak self for config change handler (runs on main thread).
        // The 1.5 s grace period suppresses rebuilds on ordinary startup noise — but a genuine
        // input format change (e.g. Bluetooth rate flip completing mid-start) must still trigger
        // recovery even inside the grace period. We compare against the format `buildGraph`
        // settled on, which is exposed as `engineLifecycle.lastKnownInputFormat`.
        let configChangeHandler: () -> Void = { [weak self] in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(self.recordingStartTime ?? Date())
            if elapsed < gracePeriod {
                // Inside grace period: only act if the hardware format actually changed.
                Task { [weak self] in
                    guard let self else { return }
                    let settledFmt = await self.engineLifecycle.lastKnownInputFormat
                    let liveFmt = await self.engineLifecycle.phase == .running(generation: 0)
                        ? nil : settledFmt  // can't read inputNode format off-actor safely; proxy via settled
                    // Use a lightweight HAL probe instead: compare settled sample rate to the
                    // device's current nominal rate. If they differ by more than 1 Hz the link
                    // re-negotiated and we must recover.
                    let deviceID = await self.engineLifecycle.lastKnownDeviceID
                    var addr = AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyNominalSampleRate,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    var nowRate: Float64 = 0
                    var sz = UInt32(MemoryLayout<Float64>.size)
                    let readOk: Bool
                    if let devID = deviceID {
                        readOk = AudioObjectGetPropertyData(devID, &addr, 0, nil, &sz, &nowRate) == noErr
                    } else {
                        readOk = false
                    }
                    let settledRate = settledFmt?.sampleRate ?? 0
                    let formatChanged = readOk && abs(Double(nowRate) - settledRate) > 1.0

                    guard formatChanged else { return }
                    Logger.event(.engConfigChange, .audio, [
                        "action": .string("recovery"),
                        "reason": .string("format_changed_in_grace_period"),
                        "settled_sr": .double(settledRate),
                        "now_sr": .double(Double(nowRate))
                    ], level: .warning)
                    await self.recoverAudioEngine()
                }
                return
            }
            guard self.isRecording, case .recording = self.recorderState else { return }
            Logger.event(.engConfigChange, .audio, ["action": .string("recovery")], level: .warning)
            Task { [weak self] in await self?.recoverAudioEngine() }
        }

        // Delegate engine setup to actor
        do {
            try await engineLifecycle.configure(
                route: route,
                onBuffer: { [weak self] samples in self?.deliverSamples(samples) },
                onConfigChange: configChangeHandler
            )
        } catch {
            lastEngineStartError = error
            discardSessionAudio()
            throw error
        }

        // Every abort below discards the session file. The generation checks used to just drop
        // the reference, so a start cancelled mid-flight left an open encoder and a
        // fraction-of-a-second .opus in Sessions/ that no record pointed at, surviving until
        // the retention sweep.
        guard isGenerationCurrent(generation) else {
            await engineLifecycle.stopEngine()
            discardSessionAudio()
            throw RecordingError.engineCleanedUp
        }

        do {
            try await engineLifecycle.startEngine()
        } catch {
            lastEngineStartError = error
            await engineLifecycle.stopEngine()
            discardSessionAudio()
            throw error
        }

        guard isGenerationCurrent(generation) else {
            await engineLifecycle.stopEngine()
            discardSessionAudio()
            throw RecordingError.engineCleanedUp
        }

        // Cache device ID for sync diagnostics
        cachedEngineDeviceID = await engineLifecycle.lastKnownDeviceID
        let gen = await engineLifecycle.generation

        isRecording = true
        // `generation`, not `gen`. These are two unrelated counters: `generation` is
        // `AudioRecorder.currentGeneration` (bumped per start/stop), while `gen` is
        // `AudioEngineLifecycle.generation` (bumped by `configure`, `stopEngine` *and*
        // `replaceDeadEngine`). This state was stamped with the engine's, but the only consumer,
        // `recoverAudioEngine`, unpacks it and feeds it to `isGenerationCurrent()`, which
        // compares against `currentGeneration` — so the guard was only ever correct while the
        // two counters happened to coincide. `replaceDeadEngine` bumps one and not the other,
        // which means after a single successful recovery they are permanently skewed and every
        // later recovery fails the check unconditionally: `isRecording = false`, writer closed,
        // straight to `.idle` with no `onAudioFlowTimeout`. That silently defeated the
        // keep-the-partial-recording behaviour documented on `discardSessionAudio`.
        // `gen` stays in the log line below, where it is genuinely the engine's identity.
        recorderState = .recording(generation: generation)

        if let devID = cachedEngineDeviceID {
            startMonitoringDevice(devID)
        }
        startAudioFlowWatchdog()

        Logger.event(.recStart, .audio, ["route": .string("\(route)"), "gen": .int(gen)])

        // First-buffer gate: if the engine starts successfully but produces no audio within the
        // deadline, treat this attempt as failed and let the startup ladder try another device.
        // Without this, a tap that is installed but silent (e.g. a cold Bluetooth device whose
        // link didn't fully come up) returns a URL the user speaks into for nothing.
        let firstBufferDeadline: TimeInterval = (preflightReadiness ?? .ready).firstBufferDeadline
        if firstBufferDeadline > 0 {
            let deadline = firstBufferDeadline
            // Poll at 50 ms intervals up to the deadline.
            let pollIntervalNs: UInt64 = 50_000_000
            let iterations = Int(deadline / 0.05)
            for _ in 0..<iterations {
                if lastAudioCallbackTime != nil { break }
                guard isGenerationCurrent(generation) else { throw RecordingError.engineCleanedUp }
                try? await Task.sleep(nanoseconds: pollIntervalNs)
            }
            if lastAudioCallbackTime == nil {
                // Still no audio — probe and log the reason, then fail so the next attempt runs.
                let (facts, verdict) = InputHealthProbe.probe(deviceID: cachedEngineDeviceID)
                var fields = InputHealthProbe.logFields(facts, verdict)
                fields["warn"] = .string("no_first_buffer")
                fields["deadline_ms"] = .int(Int(deadline * 1000))
                Logger.event(.engBuild, .audio, fields, level: .warning)
                // Stop the engine cleanly before throwing — avoids a tap leak into the next start.
                await engineLifecycle.stopEngine()
                isRecording = false
                discardSessionAudio()
                throw RecordingError.audioUnitFailed
            }
        }

        return audioURL
    }

    // MARK: - Sample delivery (called from CoreAudio real-time thread via actor tap)

    private func deliverSamples(_ samples: [Float]) {
        guard isRecording else { return }  // skip callbacks after stop

        let isFirst = lastAudioCallbackTime == nil
        lastAudioCallbackTime = Date()
        audioProgressCounter &+= 1
        if isFirst { Logger.event(.audioFirst, .audio) }

        let rms = calculateRMS(samples: samples)
        DispatchQueue.main.async { [weak self] in self?.onAmplitudeUpdate?(rms) }

        // Silence detection — diagnose first, then auto-recover if a rebuild can actually help.
        if rms < 0.001 {
            consecutiveSilentCallbacks += 1
            let inGracePeriod = recordingStartTime.map { Date().timeIntervalSince($0) < 2.0 } ?? false
            if consecutiveSilentCallbacks >= silenceRecoveryThreshold,
               case .recording = recorderState,
               !inGracePeriod {
                // Ask the HAL *why* before reacting. Logging bare `reason=silence_1.5s` and
                // blindly rebuilding is what burned four engine builds on a muted device.
                let (facts, verdict) = InputHealthProbe.probe(deviceID: cachedEngineDeviceID)
                var fields = InputHealthProbe.logFields(facts, verdict)
                fields["reason"] = .string("silence_1.5s")
                Logger.event(.engRetry, .audio, fields, level: .warning)

                let shouldWarn = !hasReportedSilenceEpisode
                hasReportedSilenceEpisode = true

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if shouldWarn { self.onCaptureTrouble?(verdict) }
                    Task { await self.recoverAudioEngine(diagnosis: verdict) }
                }
            }
        } else {
            let wasSilent = hasReportedSilenceEpisode
            consecutiveSilentCallbacks = 0
            hasEverReceivedNonSilentAudio = true
            hasReportedSilenceEpisode = false
            if recoveryAttemptCount > 0 {
                recoveryAttemptCount = 0
            }
            if wasSilent {
                DispatchQueue.main.async { [weak self] in self?.onCaptureRecovered?() }
            }
        }

        autoreleasepool { onStreamingSamples?(samples) }

        // Disk write — reconstruct AVAudioPCMBuffer from [Float] for the Opus encoder.
        // Gated on `isRecording` (checked at the top of this function, under its own lock) rather
        // than on a writer flag; the enqueued block is what actually decides, on the queue.
        let frameCount = AVAudioFrameCount(samples.count)
        if let buf = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: frameCount) {
            buf.frameLength = frameCount
            samples.withUnsafeBufferPointer { ptr in
                buf.floatChannelData!.pointee.initialize(from: ptr.baseAddress!, count: samples.count)
            }
            let captured = buf
            sessionWriteQueue.async { [weak self] in
                guard let self, let writer = self.sessionAudioWriter else { return }
                do {
                    try writer.write(captured)
                } catch {
                    // Terminal, and reported exactly once. Retrying the next buffer used to be
                    // the behaviour here, which is wrong twice over: the failed buffer's Ogg
                    // pages are already out of the encoder, so a later success writes pages with
                    // a gap in their sequence and produces an *undecodable* file rather than a
                    // short one (see `AudioArchiveWriter.hasFailed`); and at ~12 buffers a second
                    // it emitted a log line per buffer, against a whole-app budget of <400 a day.
                    Logger.error("Session audio encode failed, session file abandoned: " +
                                 "\(error.localizedDescription)", subsystem: .audio)
                    // The writer is deliberately **kept**, not nil'd. `AudioArchiveWriter` has
                    // already latched `hasFailed`, so every later `write`/`flush` is a silent
                    // no-op and this branch cannot run twice — the log stays at one line.
                    // Nil'ing it instead re-armed the `sessionAudioWriter == nil` test in
                    // `startRecordingInternal`, so a device death after an encode failure sent
                    // `recoverAudioEngine` down the cold-start branch and minted a *second*
                    // session file. Nothing referenced the new one: `StreamingTranscriber`
                    // captured the original URL at start, so save copied the old partial and
                    // the delete-on-discard removed only the old path, leaving the new `.opus`
                    // orphaned until the retention sweep. Keeping the writer keeps
                    // "one recording is one Opus stream" true through recovery.
                    return
                }
                self.sessionHasAudio = true
                self.framesSinceFlush += Int(captured.frameLength)
                if self.framesSinceFlush >= self.flushIntervalFrames {
                    self.framesSinceFlush = 0
                    writer.flush()
                }
            }
        }
    }

    private func calculateRMS(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        vDSP_measqv(samples, 1, &sum, vDSP_Length(samples.count))
        return min(sqrt(sum) * 4.0, 1.0)
    }

    // MARK: - Stop

    func stopRecording() async {
        // Increment generation first — invalidates any in-flight startRecordingInternal attempts
        currentGeneration += 1

        guard isRecording else {
            // The generation bump above just cancelled a start that had not reached .recording.
            // That is correct for an explicit stop, and disastrous for a watchdog that fired only
            // because CoreAudio was slow — which is why the startup watchdog checks startupInFlightSince.
            if case .starting(let g) = recorderState {
                Logger.event(.recFail, .audio, ["warn": .string("cancelled_in_flight_start"), "gen": .int(g)], level: .warning)
            }
            return
        }

        let generation = currentGeneration
        recorderState = .stopping(generation: generation)

        // Wait for first audio data if engine hasn't produced any yet
        if lastAudioCallbackTime == nil {
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if lastAudioCallbackTime != nil { break }
            }
            if lastAudioCallbackTime == nil {
                Logger.event(.engBuild, .audio, ["warn": .string("no_data_500ms")], level: .warning)
            }
        }

        isRecording = false  // stops deliverSamples — no new disk write dispatches

        // Event-driven drain: poll `lastAudioCallbackTime` at 10ms intervals until the engine
        // hasn't produced a buffer for one 10ms window, or until 200ms elapse (same ceiling as
        // before). Typically resolves in ~30ms — the last CoreAudio callback arrives within
        // one buffer period of setting isRecording=false. The 200ms hard ceiling preserves the
        // previous worst-case behaviour for slow engines.
        let drainDeadline = Date().addingTimeInterval(0.200)
        while Date() < drainDeadline {
            let before = lastAudioCallbackTime
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            // No new callback in this window → engine is drained
            if lastAudioCallbackTime == before { break }
        }

        // Drain pending encodes, then finalize the Ogg stream. Dropping the reference is not
        // enough — `close()` writes the terminating page.
        closeSessionWriter()

        stopAudioFlowWatchdog()
        stopMonitoringDevice()

        // Stop engine — tap removed and engine stopped on lifecycleQueue
        await engineLifecycle.stopEngine()

        cachedEngineDeviceID = nil
        recordingStartTime = nil
        recorderState = .idle

        Logger.event(.recStop, .audio)
    }

    var recordingURL: URL? { currentURL }

    /// Close the session writer and unlink the file. Used only on failed-start paths: a start
    /// that never reached `.recording` produced at most a fraction of a second of Opus and no
    /// record refers to it, so leaving it behind is a leak the retention sweep has to mop up.
    ///
    /// Refuses to unlink once audio has actually been encoded. `recoverAudioEngine` restarts a
    /// live recording through `startRecordingInternal`, so its abort paths reach here holding a
    /// session that already contains everything captured before the device died — deleting it
    /// would turn a recoverable glitch into total loss of the recording. Finalize and keep.
    private func discardSessionAudio() {
        // One `sync`, not two. Reading `sessionHasAudio` in a separate earlier block let an
        // already-enqueued encode set it `true` in the gap, so `hadAudio` could come back stale
        // `false` and the unlink below would delete a file that does contain audio — the exact
        // total-loss outcome the doc comment above says this function refuses.
        let hadAudio = sessionWriteQueue.sync { () -> Bool in
            let had = sessionHasAudio
            sessionAudioWriter?.close()
            sessionAudioWriter = nil
            return had
        }
        guard !hadAudio else { return }
        if let url = sessionAudioURL {
            try? FileManager.default.removeItem(at: url)
            sessionAudioURL = nil
        }
    }

    /// Open the session writer. `framesSinceFlush` is reset on `sessionWriteQueue`, not here:
    /// the field is read-modify-written by the encode block, and a caller-thread reset would be
    /// an unsynchronized write racing it. In practice the queue is idle whenever this is called —
    /// the recovery restart re-enters `startRecordingInternal` with a live writer and so never
    /// reaches here — but the field's ownership rule is the queue and this honours it rather
    /// than depending on that reachability argument staying true.
    private func openSessionWriter(at url: URL) {
        let opened: Bool = sessionWriteQueue.sync {
            framesSinceFlush = 0
            sessionHasAudio = false
            do {
                sessionAudioWriter = try AudioArchiveFormat.makeWriter(at: url)
                Logger.step(.recStart, .audio, ["file": .string(url.lastPathComponent)])
                return true
            } catch {
                // Carry the reason. The `try?` this replaces reported only `fail=session_file`,
                // which is what made a 100%-reproducible failure look like ambient noise.
                Logger.event(.recFail, .audio,
                             ["fail": .string("session_file"),
                              "err": .string(error.localizedDescription)],
                             level: .warning)
                sessionAudioWriter = nil
                return false
            }
        }
        guard !opened else { return }
        // Leave nothing behind that the rest of the app can mistake for a recording. The URL is
        // the more damaging half: `StreamingTranscriber` captures it at start and history stores
        // it, so a non-nil URL with no writer is exactly the "row points at a file that was never
        // created" state this whole path was rewritten to eliminate. `AudioArchiveWriter.init`
        // unlinks after its own throws, so this is a backstop for the `createFile`-succeeded
        // cases it cannot reach.
        //
        // Clearing the URL does cost something, and it is deliberate: `AppState.beginRecordingSession`
        // bails on a nil `sessionAudioURL`, so no in-progress history row is opened and the
        // watchdog's text-preservation path has nothing to finalize. That is the right trade —
        // a row whose audio path does not exist corrupts playback and the library sweep for
        // good, whereas the text still reaches history through the ordinary `saveTranscription`
        // at stop. Only a crash mid-recording loses text, and only when the file could not be
        // opened at all, which is already a failed recording.
        try? FileManager.default.removeItem(at: url)
        if sessionAudioURL == url { sessionAudioURL = nil }
    }

    /// Drain queued encodes, then finalize the session file.
    ///
    /// One `sync`, and `close()` runs *inside* it. The finalize must be ordered against every
    /// `write()` on the same writer, and only being on the queue gives that — a drain followed
    /// by an off-queue `close()` leaves the window described on `sessionAudioWriter`.
    private func closeSessionWriter() {
        // No off-queue `guard sessionAudioWriter != nil` short-circuit. Two callers genuinely
        // race — `stopRecording` and a `recoverAudioEngine` Task can both reach here — and that
        // guard was an unsynchronized read of a reference the queue stores to. `close()` and the
        // nil assignment are both idempotent, so the loser of the race is a cheap no-op.
        sessionWriteQueue.sync {
            sessionAudioWriter?.close()
            sessionAudioWriter = nil
        }
    }

    // MARK: - Mid-Recording Recovery

    /// A recovery pass has run and is in flight; further triggers coalesce into it rather than
    /// stacking parallel rebuilds. Silence fires this from every buffer once the threshold is
    /// crossed, so without the guard an unrecoverable device spawns ~12 concurrent rebuilds a
    /// second.
    private var isRecoveryInFlight = false

    private func recoverAudioEngine(diagnosis: InputHealthVerdict = .healthy) async {
        guard case .recording(let generation) = recorderState else { return }
        guard !isRecoveryInFlight else { return }
        isRecoveryInFlight = true
        defer { isRecoveryInFlight = false }

        // Self-repair before anything else. A muted input or a zeroed gain cannot be fixed by
        // rebuilding a graph, but it *can* be fixed outright — and doing so beats telling the
        // user to go and find a slider.
        if diagnosis.isSelfRepairable, let deviceID = cachedEngineDeviceID {
            let repaired = diagnosis == .muted
                ? InputHealthProbe.unmuteInput(deviceID: deviceID)
                : InputHealthProbe.restoreInputLevel(deviceID: deviceID)
            if repaired {
                // The device is live and the tap is installed; the next buffer will carry signal
                // and `deliverSamples` will clear the episode. No rebuild needed.
                consecutiveSilentCallbacks = 0
                return
            }
        }

        recoveryAttemptCount += 1

        if let maxAttempts = recoveryPolicy.maxAttempts, recoveryAttemptCount > maxAttempts {
            var fields = InputHealthProbe.logFields(
                InputHealthProbe.probe(deviceID: cachedEngineDeviceID).facts, diagnosis
            )
            fields["attempts"] = .int(maxAttempts)
            fields["reason"] = .string("recovery_exhausted")
            Logger.event(.recFail, .audio, fields, level: .error)
            isRecording = false
            // Finalize whatever was captured before the engine died. This path used to return
            // without closing, and `AppState`'s watchdog then called `stopRecording()`, which
            // bails on `guard isRecording` — so nothing ever closed the writer. The partial
            // recording was left unterminated and its filename was still written to history.
            closeSessionWriter()
            recorderState = .idle
            cachedEngineDeviceID = nil
            DispatchQueue.main.async { [weak self] in self?.onAudioFlowTimeout?(diagnosis) }
            return
        }

        recorderState = .recovering(generation: generation)
        Logger.event(.engRetry, .audio, [
            "attempt": .int(recoveryAttemptCount),
            "max": .string(recoveryPolicy.maxAttempts.map(String.init) ?? "unbounded"),
            "verdict": .string(diagnosis.logCode),
            "gen": .int(generation)
        ], level: .warning)

        stopAudioFlowWatchdog()
        stopMonitoringDevice()

        // Replace dead engine — creates fresh queue, bypassing any hung old queue
        await engineLifecycle.replaceDeadEngine()
        let failedDeviceID = cachedEngineDeviceID
        cachedEngineDeviceID = nil

        // Settle delay — flat for dictation, backing off for long-form so an outage that lasts
        // minutes costs a handful of rebuilds instead of one every 300 ms forever.
        let settle = recoveryPolicy.settleDelay(attempt: recoveryAttemptCount)
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))

        guard isRecording, isGenerationCurrent(generation) else {
            isRecording = false
            closeSessionWriter()
            recorderState = .idle
            return
        }

        // Escalate the route rather than re-binding the device that just failed. All four
        // rebuilds on 2026-09-14 targeted the same built-in mic (id=96) while five other live
        // inputs sat unused.
        let route = recoveryRoute(attempt: recoveryAttemptCount, avoiding: diagnosis.otherDeviceCanHelp ? failedDeviceID : nil)

        recorderState = .starting(generation: generation)
        recordingStartTime = Date()
        do {
            _ = try await startRecordingInternal(route: route, generation: generation)
            Logger.event(.recStart, .audio, ["recovery": .bool(true), "route": .string("\(route)"), "gen": .int(generation)])
            DispatchQueue.main.async { [weak self] in
                self?.onDeviceRecovery?(.deviceLostDuringRecording)
            }
        } catch {
            Logger.event(.recFail, .audio, ["recovery": .bool(true), "err": .string(error.localizedDescription)], level: .error)

            // A failed rebuild is not the end for a long-form session — the device may come back.
            // The recorder keeps the session open and the next silent buffer (or the flow
            // watchdog) re-enters recovery, now with a longer backoff.
            if recoveryPolicy.maxAttempts == nil, isRecording, isGenerationCurrent(generation) {
                recorderState = .recording(generation: generation)
                startAudioFlowWatchdog()
                return
            }

            isRecording = false
            // Keep what was captured before the device died — the restart failed, but the
            // pre-recovery audio is still a valid recording and history will reference it.
            closeSessionWriter()
            recorderState = .idle
            cachedEngineDeviceID = nil
            DispatchQueue.main.async { [weak self] in self?.onAudioFlowTimeout?(diagnosis) }
        }
    }

    /// Picks the route for recovery attempt `attempt` (1-based).
    ///
    /// 1 → whatever the system default currently is (covers the common "device came back" case).
    /// 2+ → walk the other live input devices, skipping `avoiding` and skipping devices the
    /// probe says are muted, gain-zeroed or streamless. Wraps back to the default when the list
    /// is exhausted, so an unbounded long-form recovery keeps cycling instead of dead-ending.
    private func recoveryRoute(attempt: Int, avoiding: AudioDeviceID?) -> ResolvedInputRoute {
        guard attempt > 1 else { return .systemDefault }

        let candidates = AudioDeviceManager.usableInputDevicesForRecovery(excluding: avoiding)
        guard !candidates.isEmpty else { return .systemDefault }

        // attempt 2 → candidates[0], attempt 3 → candidates[1], … then wrap.
        let index = (attempt - 2) % (candidates.count + 1)
        guard index < candidates.count else { return .systemDefault }

        let device = candidates[index]
        Logger.event(.devSelect, .audio, [
            "id": .int(Int(device.id)),
            "name": .string(device.name),
            "action": .string("recovery_fallback")
        ])
        return .explicit(uid: device.uid, deviceID: device.id)
    }

    // MARK: - Device-Alive Monitoring

    private func getSystemDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        ) == noErr ? deviceID : nil
    }

    private func getEngineDeviceID() -> AudioDeviceID? { cachedEngineDeviceID }

    private func startMonitoringDevice(_ deviceID: AudioDeviceID) {
        stopMonitoringDevice()
        monitoredDeviceID = deviceID

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        deviceAliveListenerBlock = { [weak self] (_, _) in self?.handleDeviceDied() }

        let status = AudioObjectAddPropertyListenerBlock(
            deviceID, &propertyAddress, DispatchQueue.main, deviceAliveListenerBlock!
        )

        if status != noErr {
            Logger.event(.devFail, .audio, ["id": .int(Int(deviceID)), "fail": .string("monitor"), "status": .int(Int(status))], level: .warning)
            monitoredDeviceID = nil
            deviceAliveListenerBlock = nil
        } else {
            Logger.step(.devSelect, .audio, ["id": .int(Int(deviceID))])
        }
    }

    private func stopMonitoringDevice() {
        guard let deviceID = monitoredDeviceID, let listenerBlock = deviceAliveListenerBlock else { return }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(deviceID, &propertyAddress, DispatchQueue.main, listenerBlock)
        monitoredDeviceID = nil
        deviceAliveListenerBlock = nil
    }

    private func handleDeviceDied() {
        guard let deviceID = monitoredDeviceID else { return }

        var isAlive: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &isAlive)

        if status != noErr || isAlive == 0 {
            Logger.event(.devFail, .audio, ["id": .int(Int(deviceID)), "action": .string("recovery")], level: .warning)
            stopMonitoringDevice()
            if isRecording, case .recording = recorderState {
                Task { await self.recoverAudioEngine() }
            }
        }
    }

    // MARK: - System Default Input Device Monitoring

    private func startMonitoringDefaultInputDevice() {
        guard !isMonitoringDefaultInputDevice else { return }

        defaultInputDeviceListenerBlock = { [weak self] (_, _) in
            self?.handleDefaultInputDeviceChanged()
        }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            defaultInputDeviceListenerBlock!
        )

        if status == noErr {
            isMonitoringDefaultInputDevice = true
        } else {
            Logger.event(.devFail, .audio, ["fail": .string("monitor_default"), "status": .int(Int(status))], level: .warning)
            defaultInputDeviceListenerBlock = nil
        }
    }

    private func stopMonitoringDefaultInputDevice() {
        guard isMonitoringDefaultInputDevice, let listenerBlock = defaultInputDeviceListenerBlock else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            listenerBlock
        )

        isMonitoringDefaultInputDevice = false
        defaultInputDeviceListenerBlock = nil
    }

    private func handleDefaultInputDeviceChanged() {
        let newDefaultID = getSystemDefaultInputDeviceID()
        let engineDeviceID = cachedEngineDeviceID

        Logger.event(.devChange, .audio, [
            "new": .string(newDefaultID.map(String.init) ?? "nil"),
            "engine": .string(engineDeviceID.map(String.init) ?? "nil")
        ])

        // Always stamp the change time — even when idle. The startup path checks this to decide
        // whether the route may still be settling from a Bluetooth handoff.
        lastDefaultInputChangeAt = Date()

        guard isRecording, case .recording = recorderState else {
            return
        }

        if let startTime = recordingStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < startupGracePeriod {
                return
            }
        }

        guard let engineID = engineDeviceID, let newID = newDefaultID else {
            Logger.event(.devFail, .audio, ["warn": .string("id_compare_failed"), "action": .string("recovery")], level: .warning)
            Task { await self.recoverAudioEngine() }
            return
        }

        if engineID != newID {
            Logger.event(.engConfigChange, .audio, ["reason": .string("default_device_changed"), "from": .int(Int(engineID)), "to": .int(Int(newID)), "alive": .bool(isDeviceAlive(engineID))], level: .warning)
            stopMonitoringDevice()
            Task { await self.recoverAudioEngine() }
        } else {
            Logger.step(.devSelect, .audio, ["id": .int(Int(engineID)), "match": .bool(true)])
        }
    }

    private func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &isAlive) == noErr && isAlive != 0
    }

    // MARK: - Continuous Audio Flow Watchdog

    private func startAudioFlowWatchdog() {
        stopAudioFlowWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRecording, case .recording = self.recorderState else { return }

            if let lastTime = self.lastAudioCallbackTime {
                let elapsed = Date().timeIntervalSince(lastTime)
                if elapsed > self.audioFlowTimeout {
                    Logger.event(.recFail, .audio, ["reason": .string("no_audio_flow"), "elapsed": .double(elapsed)], level: .error)
                    self.stopAudioFlowWatchdog()
                    self.recoverWithDiagnosis()
                }
            } else {
                Logger.event(.recFail, .audio, ["reason": .string("no_audio_startup")], level: .error)
                self.stopAudioFlowWatchdog()
                self.recoverWithDiagnosis()
            }
        }
        timer.resume()
        audioFlowWatchdog = timer
    }

    /// Probe the device, warn the user once per episode, then recover. Used by the callers that
    /// detect "no buffers at all" — as opposed to `deliverSamples`, which detects "buffers full
    /// of zeros" and already has the probe result in hand.
    private func recoverWithDiagnosis() {
        let (facts, verdict) = InputHealthProbe.probe(deviceID: cachedEngineDeviceID)
        Logger.event(.engRetry, .audio, InputHealthProbe.logFields(facts, verdict), level: .warning)
        if !hasReportedSilenceEpisode {
            hasReportedSilenceEpisode = true
            DispatchQueue.main.async { [weak self] in self?.onCaptureTrouble?(verdict) }
        }
        Task { await self.recoverAudioEngine(diagnosis: verdict) }
    }

    private func stopAudioFlowWatchdog() {
        audioFlowWatchdog?.cancel()
        audioFlowWatchdog = nil
    }

    // MARK: - Device name helper

    private func deviceName(for deviceID: AudioDeviceID) -> String? {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        return status == noErr ? name as String : nil
    }
}

// MARK: - Error types

enum RecordingError: Error, LocalizedError {
    case alreadyRecording
    case invalidFormat
    case fileCreationFailed
    case microphonePermissionDenied
    case audioUnitFailed
    case engineCleanedUp

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording is already in progress."
        case .invalidFormat:
            return "Couldn't read the microphone format. Try unplugging and reconnecting your audio device."
        case .fileCreationFailed:
            return "Couldn't create the recording file. Check available disk space."
        case .microphonePermissionDenied:
            return "Whisperer doesn't have microphone access. Open System Settings ▸ Privacy & Security ▸ Microphone and enable Whisperer."
        case .audioUnitFailed:
            return "Couldn't start the microphone. If you're using a Bluetooth device, it may still be connecting — try again in a moment."
        case .engineCleanedUp:
            return "The audio session was cancelled before it could start."
        }
    }
}

// MARK: - HealthReportable

extension AudioRecorder: HealthReportable {

    var componentName: String { "AudioRecorder" }

    var healthState: ComponentHealth {
        let seq = audioProgressCounter
        let opName: String
        let status: ComponentStatus
        switch recorderState {
        case .idle:
            return ComponentHealth()
        case .starting:
            opName = "starting"
            status = .healthy
        case .recording:
            opName = "recording"
            status = .healthy
        case .recovering:
            opName = "recovering"
            status = .busy
        case .stopping:
            opName = "stopping"
            status = .healthy
        }

        let now = ContinuousClock.now
        let opStart = recordingStartTime.map { start in
            now - .seconds(Date().timeIntervalSince(start))
        } ?? now

        var op = OperationInfo(
            id: UInt64(currentGeneration),
            name: opName,
            started: opStart,
            deadline: opStart + .seconds(120),
            queueBacklog: 0
        )
        op.deadline = opStart + .seconds(120)

        var meta: [String: MetadataValue] = [
            "recoveryAttempts": .int(recoveryAttemptCount),
            "silentCallbacks": .int(consecutiveSilentCallbacks)
        ]
        if let devID = cachedEngineDeviceID {
            meta["deviceID"] = .int(Int(devID))
        }

        var health = ComponentHealth()
        health.status = status
        health.operation = op
        health.progress = ProgressInfo(sequence: seq, completedWork: 1.0, lastUpdate: now)
        health.metadata = meta
        return health
    }
}

// MARK: - Debug snapshot

extension AudioRecorder {
    var debugRecoveryAttemptCount: Int { recoveryAttemptCount }

    func debugSnapshot() -> [String: String] {
        var snap: [String: String] = [:]
        snap["isRecording"] = "\(isRecording)"
        snap["recorderState"] = "\(recorderState)"
        snap["currentGeneration"] = "\(currentGeneration)"
        snap["recoveryAttemptCount"] = "\(recoveryAttemptCount)"
        snap["consecutiveSilentCallbacks"] = "\(consecutiveSilentCallbacks)"
        if let last = lastAudioCallbackTime {
            snap["lastAudioCallback"] = "\(last) (Δ \(String(format: "%.2f", Date().timeIntervalSince(last)))s ago)"
        } else {
            snap["lastAudioCallback"] = "nil (no audio callback ever)"
        }
        if let start = recordingStartTime {
            snap["recordingStartTime"] = "\(start) (Δ \(String(format: "%.2f", Date().timeIntervalSince(start)))s ago)"
        } else {
            snap["recordingStartTime"] = "nil"
        }
        if let devID = cachedEngineDeviceID {
            snap["engineDeviceID"] = "\(devID)" + (deviceName(for: devID).map { " (\($0))" } ?? "")
        } else {
            snap["engineDeviceID"] = "nil"
        }
        snap["audioFlowWatchdog"] = audioFlowWatchdog == nil ? "nil" : "active"
        snap["onAudioFlowTimeout"] = onAudioFlowTimeout == nil ? "nil" : "wired"
        snap["onStreamingSamples"] = onStreamingSamples == nil ? "nil" : "wired"
        snap["onAmplitudeUpdate"] = onAmplitudeUpdate == nil ? "nil" : "wired"
        snap["lastEngineStartError"] = lastEngineStartError.map { "\($0)" } ?? "nil (no failure recorded)"
        return snap
    }
}
