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
    var onAudioFlowTimeout: (() -> Void)?

    // MARK: - Audio flow tracking

    private var lastAudioCallbackTime: Date?
    private(set) var audioProgressCounter: UInt64 = 0

    // MARK: - Watchdogs

    private var audioFlowWatchdog: DispatchSourceTimer?
    private let audioFlowTimeout: TimeInterval = 3.0

    // MARK: - Recovery

    private var recoveryAttemptCount: Int = 0
    private let maxRecoveryAttempts: Int = 3

    // MARK: - Silence detection

    private var consecutiveSilentCallbacks: Int = 0
    private let silenceRecoveryThreshold: Int = 18  // ~1.5s at 48kHz/4096 buffer

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

    // MARK: - Disk write (Int16 16kHz mono CAF, parallel with Float32 callback)

    private var sessionAudioFile: AVAudioFile?
    private(set) var sessionAudioURL: URL?
    private let int16Format: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    // Float32 format used for AVAudioPCMBuffer reconstruction in disk write
    private let whisperFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let sessionWriteQueue = DispatchQueue(label: "whisperer.sessionWrite", qos: .utility)

    // MARK: - Device monitoring

    private var monitoredDeviceID: AudioDeviceID?
    private var deviceAliveListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultInputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var isMonitoringDefaultInputDevice = false

    // MARK: - Init / deinit

    override init() {
        super.init()
        startMonitoringDefaultInputDevice()
    }

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

    /// Three-attempt policy: (1) requested route, (2) system default, (3) system default + 300ms settle.
    func startRecording(route: ResolvedInputRoute) async throws -> URL {
        recoveryAttemptCount = 0

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

        // Attempt 1: use the provided route
        do {
            return try await startRecordingInternal(route: route, generation: generation)
        } catch {
            guard isGenerationCurrent(generation) else { throw RecordingError.engineCleanedUp }
            let elapsed = Int(Date().timeIntervalSince(attemptStart) * 1000)
            let reason: RecordingFailureReason = route == .systemDefault ? .audioUnitInitFailed : .explicitDeviceBindFailed
            Logger.event(.engRetry, .audio, ["attempt": .int(1), "err": .string(error.localizedDescription)], level: .warning)
            StartupFailure(stage: "full_startup", route: route, generation: generation, reason: reason, osStatus: nil, elapsedMs: elapsed).log()
        }

        // Attempt 2: system default
        guard isGenerationCurrent(generation) else { throw RecordingError.engineCleanedUp }
        recorderState = .starting(generation: generation)
        recordingStartTime = Date()

        do {
            return try await startRecordingInternal(route: .systemDefault, generation: generation)
        } catch {
            guard isGenerationCurrent(generation) else { throw RecordingError.engineCleanedUp }
            let elapsed = Int(Date().timeIntervalSince(recordingStartTime!) * 1000)
            Logger.event(.engRetry, .audio, ["attempt": .int(2), "err": .string(error.localizedDescription)], level: .warning)
            StartupFailure(stage: "full_startup", route: .systemDefault, generation: generation, reason: .restartOnDefaultFailed, osStatus: nil, elapsedMs: elapsed).log()
        }

        // Attempt 3: 300ms settle + system default
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard isGenerationCurrent(generation) else { throw RecordingError.engineCleanedUp }
        recorderState = .starting(generation: generation)
        recordingStartTime = Date()

        do {
            return try await startRecordingInternal(route: .systemDefault, generation: generation)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(recordingStartTime!) * 1000)
            Logger.event(.recFail, .audio, ["err": .string(error.localizedDescription)], level: .error)
            StartupFailure(stage: "full_startup", route: .systemDefault, generation: generation, reason: .restartOnDefaultFailed, osStatus: nil, elapsedMs: elapsed).log()
            recorderState = .idle
            throw error
        }
    }

    private func isGenerationCurrent(_ generation: Int) -> Bool {
        return currentGeneration == generation
    }

    private func startRecordingInternal(route: ResolvedInputRoute, generation: Int) async throws -> URL {
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

        // Open session CAF file for parallel disk write
        let sessionURL = SessionStorage.makeSessionAudioURL()
        sessionAudioURL = sessionURL
        if let file = try? AVAudioFile(forWriting: sessionURL, settings: int16Format.settings) {
            sessionAudioFile = file
            Logger.step(.recStart, .audio, ["file": .string(sessionURL.lastPathComponent)])
        } else {
            Logger.event(.recFail, .audio, ["fail": .string("session_file")], level: .warning)
            sessionAudioFile = nil
        }

        lastAudioCallbackTime = nil
        consecutiveSilentCallbacks = 0

        let gracePeriod = startupGracePeriod
        let startTime = recordingStartTime ?? Date()

        // Capture weak self for config change handler (runs on main thread)
        let configChangeHandler: () -> Void = { [weak self] in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(self.recordingStartTime ?? Date())
            guard elapsed >= gracePeriod else {
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
            sessionAudioFile = nil
            throw error
        }

        guard isGenerationCurrent(generation) else {
            await engineLifecycle.stopEngine()
            throw RecordingError.engineCleanedUp
        }

        do {
            try await engineLifecycle.startEngine()
        } catch {
            lastEngineStartError = error
            await engineLifecycle.stopEngine()
            sessionAudioFile = nil
            throw error
        }

        guard isGenerationCurrent(generation) else {
            await engineLifecycle.stopEngine()
            throw RecordingError.engineCleanedUp
        }

        // Cache device ID for sync diagnostics
        cachedEngineDeviceID = await engineLifecycle.lastKnownDeviceID
        let gen = await engineLifecycle.generation

        isRecording = true
        recorderState = .recording(generation: gen)

        if let devID = cachedEngineDeviceID {
            startMonitoringDevice(devID)
        }
        startAudioFlowWatchdog()

        Logger.event(.recStart, .audio, ["route": .string("\(route)"), "gen": .int(gen)])
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

        // Silence detection — auto-recover if input device produces no audio
        if rms < 0.001 {
            consecutiveSilentCallbacks += 1
            let inGracePeriod = recordingStartTime.map { Date().timeIntervalSince($0) < 2.0 } ?? false
            if consecutiveSilentCallbacks >= silenceRecoveryThreshold,
               case .recording = recorderState,
               !inGracePeriod {
                Logger.event(.engRetry, .audio, ["reason": .string("silence_1.5s")], level: .warning)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    Task { await self.recoverAudioEngine() }
                }
            }
        } else {
            consecutiveSilentCallbacks = 0
            if recoveryAttemptCount > 0 {
                recoveryAttemptCount = 0
            }
        }

        autoreleasepool { onStreamingSamples?(samples) }

        // Disk write — reconstruct AVAudioPCMBuffer from [Float] for AVAudioFile
        if sessionAudioFile != nil {
            let frameCount = AVAudioFrameCount(samples.count)
            if let buf = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: frameCount) {
                buf.frameLength = frameCount
                samples.withUnsafeBufferPointer { ptr in
                    buf.floatChannelData!.pointee.initialize(from: ptr.baseAddress!, count: samples.count)
                }
                let captured = buf
                sessionWriteQueue.async { [weak self] in
                    guard let self, let file = self.sessionAudioFile else { return }
                    try? file.write(from: captured)
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

        // Short drain to let in-flight callbacks deliver last buffers
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Drain pending disk writes before closing the file
        sessionWriteQueue.sync {}
        sessionAudioFile = nil

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

    /// Discard an in-progress session file — called on failed/cancelled starts to prevent orphaned audio.
    private func discardSessionAudio() {
        sessionWriteQueue.sync {}
        sessionAudioFile = nil
        if let url = sessionAudioURL {
            try? FileManager.default.removeItem(at: url)
            sessionAudioURL = nil
        }
    }

    // MARK: - Mid-Recording Recovery

    private func recoverAudioEngine() async {
        guard case .recording(let generation) = recorderState else { return }

        recoveryAttemptCount += 1

        if recoveryAttemptCount > maxRecoveryAttempts {
            Logger.event(.recFail, .audio, ["attempts": .int(maxRecoveryAttempts), "reason": .string("recovery_exhausted")], level: .error)
            isRecording = false
            recorderState = .idle
            cachedEngineDeviceID = nil
            DispatchQueue.main.async { [weak self] in self?.onAudioFlowTimeout?() }
            return
        }

        recorderState = .recovering(generation: generation)
        Logger.event(.engRetry, .audio, ["attempt": .int(recoveryAttemptCount), "max": .int(maxRecoveryAttempts), "gen": .int(generation)], level: .warning)

        stopAudioFlowWatchdog()
        stopMonitoringDevice()

        // Replace dead engine — creates fresh queue, bypassing any hung old queue
        await engineLifecycle.replaceDeadEngine()
        cachedEngineDeviceID = nil

        // Settle delay
        try? await Task.sleep(nanoseconds: 300_000_000)

        guard isRecording, isGenerationCurrent(generation) else {
            isRecording = false
            recorderState = .idle
            return
        }

        // Rebuild on system default
        recorderState = .starting(generation: generation)
        recordingStartTime = Date()
        do {
            _ = try await startRecordingInternal(route: .systemDefault, generation: generation)
            Logger.event(.recStart, .audio, ["recovery": .bool(true), "gen": .int(generation)])
            DispatchQueue.main.async { [weak self] in
                self?.onDeviceRecovery?(.deviceLostDuringRecording)
            }
        } catch {
            Logger.event(.recFail, .audio, ["recovery": .bool(true), "err": .string(error.localizedDescription)], level: .error)
            isRecording = false
            recorderState = .idle
            cachedEngineDeviceID = nil
            DispatchQueue.main.async { [weak self] in self?.onAudioFlowTimeout?() }
        }
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
                    Task { await self.recoverAudioEngine() }
                }
            } else {
                Logger.event(.recFail, .audio, ["reason": .string("no_audio_startup")], level: .error)
                self.stopAudioFlowWatchdog()
                Task { await self.recoverAudioEngine() }
            }
        }
        timer.resume()
        audioFlowWatchdog = timer
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

enum RecordingError: Error {
    case alreadyRecording
    case invalidFormat
    case fileCreationFailed
    case microphonePermissionDenied
    case audioUnitFailed
    case engineCleanedUp
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
