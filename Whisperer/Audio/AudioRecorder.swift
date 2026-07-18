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
        Logger.error(
            "StartupFailure [gen=\(generation)] stage=\(stage) route=\(route) reason=\(reason.rawValue) osStatus=\(osStatus.map(String.init) ?? "nil") elapsed=\(elapsedMs)ms",
            subsystem: .audio
        )
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

    // MARK: - Timing

    private var recordingStartTime: Date?
    private let startupGracePeriod: TimeInterval = 1.5

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
                Logger.debug("Microphone permission granted", subsystem: .audio)
            } else {
                Logger.warning("Microphone permission denied", subsystem: .audio)
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
            Logger.warning("startRecording called but already recording", subsystem: .audio)
            throw RecordingError.alreadyRecording
        }

        currentGeneration += 1
        let generation = currentGeneration
        recordingStartTime = Date()
        recorderState = .starting(generation: generation)
        let attemptStart = Date()

        // Attempt 1: use the provided route
        do {
            return try await startRecordingInternal(route: route, generation: generation)
        } catch {
            guard isGenerationCurrent(generation) else { throw RecordingError.engineCleanedUp }
            let elapsed = Int(Date().timeIntervalSince(attemptStart) * 1000)
            let reason: RecordingFailureReason = route == .systemDefault ? .audioUnitInitFailed : .explicitDeviceBindFailed
            Logger.warning("Attempt 1 failed: \(error.localizedDescription)", subsystem: .audio)
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
            Logger.warning("Attempt 2 failed: \(error.localizedDescription)", subsystem: .audio)
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
            Logger.error("All attempts failed: \(error.localizedDescription)", subsystem: .audio)
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
            Logger.error("Microphone permission denied - cannot record", subsystem: .audio)
            throw RecordingError.microphonePermissionDenied
        }
        Logger.debug("Microphone permission confirmed", subsystem: .audio)

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
            Logger.debug("Session audio file opened: \(sessionURL.lastPathComponent)", subsystem: .audio)
        } else {
            Logger.warning("Failed to open session audio file — disk write disabled", subsystem: .audio)
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
                Logger.debug("Ignoring config change during startup grace period (\(String(format: "%.2f", elapsed))s)", subsystem: .audio)
                return
            }
            guard self.isRecording, case .recording = self.recorderState else { return }
            Logger.warning("Audio engine configuration changed — triggering recovery", subsystem: .audio)
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

        Logger.debug("Started recording (route: \(route), gen: \(gen))", subsystem: .audio)
        return audioURL
    }

    // MARK: - Sample delivery (called from CoreAudio real-time thread via actor tap)

    private func deliverSamples(_ samples: [Float]) {
        guard isRecording else { return }  // skip callbacks after stop

        let isFirst = lastAudioCallbackTime == nil
        lastAudioCallbackTime = Date()
        audioProgressCounter &+= 1
        if isFirst { Logger.debug("First audio data received", subsystem: .audio) }

        let rms = calculateRMS(samples: samples)
        DispatchQueue.main.async { [weak self] in self?.onAmplitudeUpdate?(rms) }

        // Silence detection — auto-recover if input device produces no audio
        if rms < 0.001 {
            consecutiveSilentCallbacks += 1
            let inGracePeriod = recordingStartTime.map { Date().timeIntervalSince($0) < 2.0 } ?? false
            if consecutiveSilentCallbacks >= silenceRecoveryThreshold,
               case .recording = recorderState,
               !inGracePeriod {
                Logger.warning("Audio silent for ~1.5s, triggering recovery to default route", subsystem: .audio)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    Task { await self.recoverAudioEngine() }
                }
            }
        } else {
            consecutiveSilentCallbacks = 0
            if recoveryAttemptCount > 0 {
                Logger.debug("Non-silent audio confirmed, resetting recovery counter (was \(recoveryAttemptCount))", subsystem: .audio)
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
            Logger.debug("stopRecording called but not recording", subsystem: .audio)
            return
        }

        let generation = currentGeneration
        recorderState = .stopping(generation: generation)
        Logger.debug("Stopping audio recording...", subsystem: .audio)

        // Wait for first audio data if engine hasn't produced any yet
        if lastAudioCallbackTime == nil {
            Logger.debug("No audio data yet, waiting for engine warmup...", subsystem: .audio)
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if lastAudioCallbackTime != nil { break }
            }
            if lastAudioCallbackTime == nil {
                Logger.warning("Audio engine produced no data after 500ms wait", subsystem: .audio)
            }
        }

        isRecording = false  // stops deliverSamples — no new disk write dispatches

        // Short drain to let in-flight callbacks deliver last buffers
        try? await Task.sleep(nanoseconds: 200_000_000)
        Logger.debug("Drain period complete", subsystem: .audio)

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

        Logger.debug("Audio recording stopped", subsystem: .audio)
    }

    var recordingURL: URL? { currentURL }

    // MARK: - Mid-Recording Recovery

    private func recoverAudioEngine() async {
        guard case .recording(let generation) = recorderState else { return }

        recoveryAttemptCount += 1

        if recoveryAttemptCount > maxRecoveryAttempts {
            Logger.error("Audio recovery exhausted (\(maxRecoveryAttempts) attempts) — giving up", subsystem: .audio)
            isRecording = false
            recorderState = .idle
            cachedEngineDeviceID = nil
            DispatchQueue.main.async { [weak self] in self?.onAudioFlowTimeout?() }
            return
        }

        recorderState = .recovering(generation: generation)
        Logger.warning("Mid-recording recovery attempt \(recoveryAttemptCount)/\(maxRecoveryAttempts) (gen: \(generation))", subsystem: .audio)

        stopAudioFlowWatchdog()
        stopMonitoringDevice()

        // Replace dead engine — creates fresh queue, bypassing any hung old queue
        await engineLifecycle.replaceDeadEngine()
        cachedEngineDeviceID = nil

        // Settle delay
        try? await Task.sleep(nanoseconds: 300_000_000)

        guard isRecording, isGenerationCurrent(generation) else {
            Logger.debug("Recovery cancelled (recording stopped)", subsystem: .audio)
            isRecording = false
            recorderState = .idle
            return
        }

        // Rebuild on system default
        recorderState = .starting(generation: generation)
        recordingStartTime = Date()
        do {
            _ = try await startRecordingInternal(route: .systemDefault, generation: generation)
            Logger.info("Mid-recording recovery succeeded on default route (gen: \(generation))", subsystem: .audio)
            DispatchQueue.main.async { [weak self] in
                self?.onDeviceRecovery?(.deviceLostDuringRecording)
            }
        } catch {
            Logger.error("Mid-recording recovery failed: \(error.localizedDescription)", subsystem: .audio)
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
            Logger.warning("Failed to monitor device \(deviceID) alive status: \(status)", subsystem: .audio)
            monitoredDeviceID = nil
            deviceAliveListenerBlock = nil
        } else {
            Logger.debug("Monitoring device \(deviceID) (\(deviceName(for: deviceID) ?? "unknown")) alive status", subsystem: .audio)
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
        Logger.debug("Stopped monitoring device \(deviceID) alive status", subsystem: .audio)
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
            Logger.warning("Device \(deviceID) died — triggering full recovery", subsystem: .audio)
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
            Logger.debug("Monitoring system default input device changes", subsystem: .audio)
        } else {
            Logger.warning("Failed to monitor default input device changes: \(status)", subsystem: .audio)
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
        Logger.debug("Stopped monitoring system default input device changes", subsystem: .audio)
    }

    private func handleDefaultInputDeviceChanged() {
        let newDefaultID = getSystemDefaultInputDeviceID()
        let engineDeviceID = cachedEngineDeviceID

        Logger.info(
            "System default input device changed: new=\(newDefaultID.map(String.init) ?? "nil") (\(newDefaultID.flatMap { deviceName(for: $0) } ?? "unknown")), engine=\(engineDeviceID.map(String.init) ?? "nil") (\(engineDeviceID.flatMap { deviceName(for: $0) } ?? "unknown"))",
            subsystem: .audio
        )

        guard isRecording, case .recording = recorderState else {
            Logger.debug("Default input device changed while not recording — no action needed", subsystem: .audio)
            return
        }

        if let startTime = recordingStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < startupGracePeriod {
                Logger.debug("Ignoring default device change during startup grace period (\(String(format: "%.2f", elapsed))s)", subsystem: .audio)
                return
            }
        }

        guard let engineID = engineDeviceID, let newID = newDefaultID else {
            Logger.warning("Could not compare device IDs — triggering recovery as precaution", subsystem: .audio)
            Task { await self.recoverAudioEngine() }
            return
        }

        if engineID != newID {
            let engineDeviceAlive = isDeviceAlive(engineID)
            Logger.warning(
                "Engine device \(engineID) differs from new default \(newID) (engineAlive=\(engineDeviceAlive)) — triggering recovery",
                subsystem: .audio
            )
            stopMonitoringDevice()
            Task { await self.recoverAudioEngine() }
        } else {
            Logger.debug("Engine device matches new default (\(engineID)) — no recovery needed", subsystem: .audio)
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
                    Logger.error("Audio flow stopped — no data for \(String(format: "%.1f", elapsed))s, triggering recovery", subsystem: .audio)
                    self.stopAudioFlowWatchdog()
                    Task { await self.recoverAudioEngine() }
                }
            } else {
                Logger.error("Audio engine running but no data flowing after startup — triggering recovery", subsystem: .audio)
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
