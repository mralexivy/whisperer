//
//  AudioRecorder.swift
//  Whisperer
//
//  Microphone capture using AVAudioEngine for real-time streaming
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
    let stage: String          // "device_bind", "engine_prepare", "engine_start", "flow_verify"
    let route: ResolvedInputRoute
    let generation: Int
    let reason: RecordingFailureReason
    let osStatus: OSStatus?    // underlying CoreAudio error code
    let elapsedMs: Int         // time from attempt start to failure

    func log() {
        Logger.error("StartupFailure [gen=\(generation)] stage=\(stage) route=\(route) reason=\(reason.rawValue) osStatus=\(osStatus.map(String.init) ?? "nil") elapsed=\(elapsedMs)ms", subsystem: .audio)
    }
}

class AudioRecorder: NSObject {
    private var audioEngine: AVAudioEngine?
    private let isRecordingLock = NSLock()
    private var _isRecording = false
    private var isRecording: Bool {
        get { isRecordingLock.lock(); defer { isRecordingLock.unlock() }; return _isRecording }
        set { isRecordingLock.lock(); _isRecording = newValue; isRecordingLock.unlock() }
    }
    private var currentURL: URL?

    // Callback for waveform updates
    var onAmplitudeUpdate: ((Float) -> Void)?

    // Callback for streaming samples (16kHz mono float32)
    var onStreamingSamples: (([Float]) -> Void)?

    // Callback for device recovery events (reason describing what happened)
    var onDeviceRecovery: ((RecordingFailureReason) -> Void)?

    // Callback when audio engine is running but no data flows (silent recording)
    var onAudioFlowTimeout: (() -> Void)?

    // Tracks when the most recent audio callback fired (for continuous flow monitoring)
    private var lastAudioCallbackTime: Date?

    // Continuous audio flow watchdog — detects when audio stops flowing mid-recording
    private var audioFlowWatchdog: DispatchSourceTimer?
    private let audioFlowTimeout: TimeInterval = 3.0  // Trigger recovery if no data for 3s

    // Target format for whisper: 16kHz mono
    private let targetSampleRate: Double = 16000.0

    // Silence detection — auto-recover if audio is dead
    private var consecutiveSilentCallbacks: Int = 0
    private let silenceRecoveryThreshold: Int = 18  // ~1.5s at 48kHz/4096 buffer

    // State machine — only the active generation may mutate terminal state
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
            case .idle: return "idle"
            case .starting(let g): return "starting(gen=\(g))"
            case .recording(let g): return "recording(gen=\(g))"
            case .stopping(let g): return "stopping(gen=\(g))"
            case .recovering(let g): return "recovering(gen=\(g))"
            }
        }
    }

    private var recorderState: RecorderState = .idle
    private var currentGeneration = 0

    // Recovery state
    private var recoveryTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var recordingStartTime: Date?  // Track when recording started for grace period
    private let startupGracePeriod: TimeInterval = 1.5  // Ignore config changes for 1.5s after start

    // Notification observer for audio engine configuration changes
    private var configChangeObserver: NSObjectProtocol?

    // Device-alive monitoring: detect when the recording device dies
    private var monitoredDeviceID: AudioDeviceID?
    private var deviceAliveListenerBlock: AudioObjectPropertyListenerBlock?

    override init() {
        super.init()
    }

    deinit {
        stopAudioFlowWatchdog()
        stopMonitoringDevice()
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
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

    /// Start recording with a resolved input route.
    /// Three-attempt policy:
    ///   1. Use requested route (explicit or default)
    ///   2. Full teardown, system default
    ///   3. Full teardown + 300ms settle, system default
    func startRecording(route: ResolvedInputRoute) async throws -> URL {
        guard !isRecording else {
            Logger.warning("startRecording called but already recording", subsystem: .audio)
            throw RecordingError.alreadyRecording
        }

        currentGeneration += 1
        let generation = currentGeneration
        recordingStartTime = Date()

        // Attempt 1: use the provided route
        recorderState = .starting(generation: generation)
        let attemptStart = Date()

        do {
            return try await startRecordingInternal(route: route, generation: generation)
        } catch {
            guard isGenerationCurrent(generation) else {
                throw RecordingError.engineCleanedUp
            }

            let elapsed = Int(Date().timeIntervalSince(attemptStart) * 1000)
            let reason: RecordingFailureReason
            switch route {
            case .explicit(let uid, let deviceID):
                reason = .explicitDeviceBindFailed
                Logger.warning("Attempt 1 failed: explicit route uid=\(uid) id=\(deviceID) error=\(error.localizedDescription)", subsystem: .audio)
            case .systemDefault:
                reason = .audioUnitInitFailed
                Logger.warning("Attempt 1 failed: default route error=\(error.localizedDescription)", subsystem: .audio)
            }
            StartupFailure(stage: "full_startup", route: route, generation: generation, reason: reason, osStatus: nil, elapsedMs: elapsed).log()
        }

        // Attempt 2: full teardown, system default
        cleanupEngineState()
        guard isGenerationCurrent(generation) else { throw RecordingError.engineCleanedUp }
        recorderState = .starting(generation: generation)
        recordingStartTime = Date()

        do {
            return try await startRecordingInternal(route: .systemDefault, generation: generation)
        } catch {
            guard isGenerationCurrent(generation) else { throw RecordingError.engineCleanedUp }
            let elapsed = Int(Date().timeIntervalSince(recordingStartTime!) * 1000)
            StartupFailure(stage: "full_startup", route: .systemDefault, generation: generation, reason: .restartOnDefaultFailed, osStatus: nil, elapsedMs: elapsed).log()
        }

        // Attempt 3: full teardown + 300ms settle, system default
        cleanupEngineState()
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard isGenerationCurrent(generation) else { throw RecordingError.engineCleanedUp }
        recorderState = .starting(generation: generation)
        recordingStartTime = Date()

        do {
            return try await startRecordingInternal(route: .systemDefault, generation: generation)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(recordingStartTime!) * 1000)
            StartupFailure(stage: "full_startup", route: .systemDefault, generation: generation, reason: .restartOnDefaultFailed, osStatus: nil, elapsedMs: elapsed).log()
            recorderState = .idle
            throw error
        }
    }

    private func isGenerationCurrent(_ generation: Int) -> Bool {
        return currentGeneration == generation
    }

    private func startRecordingInternal(route: ResolvedInputRoute, generation: Int) async throws -> URL {
        // Check microphone permission first
        let hasPermission = await AudioRecorder.checkMicrophonePermission()
        guard hasPermission else {
            Logger.error("Microphone permission denied - cannot record", subsystem: .audio)
            throw RecordingError.microphonePermissionDenied
        }
        Logger.debug("Microphone permission confirmed", subsystem: .audio)

        guard !Task.isCancelled, isGenerationCurrent(generation) else {
            throw RecordingError.engineCleanedUp
        }

        // Create temporary file for recording
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "recording_\(Date().timeIntervalSince1970).wav"
        let audioURL = tempDir.appendingPathComponent(fileName)
        currentURL = audioURL

        // Setup audio engine — fresh instance every time
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            Logger.error("Failed to create AVAudioEngine", subsystem: .audio)
            throw RecordingError.fileCreationFailed
        }

        // Setup observer for THIS engine only
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            Logger.warning("Audio engine configuration changed", subsystem: .audio)

            // Ignore config changes during startup grace period
            if let startTime = self.recordingStartTime {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed < self.startupGracePeriod {
                    Logger.debug("Ignoring config change during startup grace period (\(String(format: "%.2f", elapsed))s < \(self.startupGracePeriod)s)", subsystem: .audio)
                    return
                }
            }

            if self.isRecording, case .recording = self.recorderState {
                Logger.debug("Config change during recording — triggering full recovery", subsystem: .audio)
                self.recoveryTask = Task {
                    await self.recoverAudioEngine()
                }
            }
        }

        Logger.debug("Voice processing disabled for instant startup", subsystem: .audio)

        // Force inputNode instantiation (creates the underlying AUHAL AudioUnit)
        let inputNode = audioEngine.inputNode

        // Bind device based on route
        switch route {
        case .explicit(let uid, let deviceID):
            if setInputDevice(deviceID, on: inputNode) {
                Logger.debug("Bound explicit device: uid=\(uid) id=\(deviceID) (\(deviceName(for: deviceID) ?? "unknown"))", subsystem: .audio)
            } else {
                Logger.warning("Explicit device bind failed: uid=\(uid) id=\(deviceID), throwing to trigger default fallback", subsystem: .audio)
                throw RecordingError.audioUnitFailed
            }
        case .systemDefault:
            Logger.debug("Using system default input device", subsystem: .audio)
        }

        guard !Task.isCancelled, self.audioEngine != nil, isGenerationCurrent(generation) else {
            throw RecordingError.engineCleanedUp
        }

        // Prepare the engine — allocates resources for the bound device
        audioEngine.prepare()

        // Query format AFTER prepare. Retry if 0Hz/0ch (HAL still initializing after sleep/wake).
        var inputFormat = inputNode.outputFormat(forBus: 0)
        if inputFormat.sampleRate == 0 || inputFormat.channelCount == 0 {
            Logger.warning("Initial format invalid (\(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch), retrying...", subsystem: .audio)
            for attempt in 1...5 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                inputFormat = inputNode.outputFormat(forBus: 0)
                if inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 {
                    Logger.info("Format valid after retry \(attempt): \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch", subsystem: .audio)
                    break
                }
            }
        }

        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            Logger.error("Invalid input format after retries: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels", subsystem: .audio)
            throw RecordingError.invalidFormat
        }

        Logger.debug("Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels", subsystem: .audio)

        // Create output format (16kHz mono PCM for whisper)
        guard let newOutputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            Logger.error("Failed to create output format", subsystem: .audio)
            throw RecordingError.invalidFormat
        }
        outputFormat = newOutputFormat

        // Create converter
        guard let newConverter = AVAudioConverter(from: inputFormat, to: newOutputFormat) else {
            Logger.error("Failed to create audio converter", subsystem: .audio)
            throw RecordingError.invalidFormat
        }
        converter = newConverter
        newConverter.channelMap = [0]
        Logger.debug("Converter: \(inputFormat.channelCount) channels → 1 channel, channel map: \(newConverter.channelMap)", subsystem: .audio)

        // Install tap on input node
        let bufferSize: AVAudioFrameCount = 4096
        Logger.debug("Installing tap on input node (buffer size: \(bufferSize))", subsystem: .audio)
        var tapErr: NSError?
        let tapInstalled = ObjCTry({
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, time in
                do {
                    guard let self = self, let converter = self.converter, let outputFormat = self.outputFormat else {
                        return
                    }
                    try self.processAudioBufferSafe(buffer: buffer, converter: converter, outputFormat: outputFormat)
                } catch {
                    Logger.error("Error in audio callback: \(error.localizedDescription)", subsystem: .audio)
                }
            }
        }, &tapErr)
        guard tapInstalled else {
            Logger.error("Failed to install tap (NSException): \(tapErr?.localizedDescription ?? "unknown")", subsystem: .audio)
            throw RecordingError.audioUnitFailed
        }
        Logger.debug("Tap installed successfully", subsystem: .audio)

        // Start engine
        lastAudioCallbackTime = nil
        consecutiveSilentCallbacks = 0
        do {
            Logger.debug("Starting audio engine...", subsystem: .audio)
            guard let engine = self.audioEngine else {
                throw RecordingError.fileCreationFailed
            }
            var startException: NSError?
            var startSwiftError: Error?
            let started = ObjCTry({
                do {
                    try engine.start()
                } catch {
                    startSwiftError = error
                }
            }, &startException)
            if let startSwiftError = startSwiftError {
                throw startSwiftError
            }
            guard started else {
                Logger.error("Engine start caught NSException: \(startException?.localizedDescription ?? "unknown")", subsystem: .audio)
                throw RecordingError.audioUnitFailed
            }
            isRecording = true
            recorderState = .recording(generation: generation)

            // Monitor the actual device the engine is using for disconnect detection
            if let engineDeviceID = getEngineDeviceID() {
                startMonitoringDevice(engineDeviceID)
            }

            startAudioFlowWatchdog()

            Logger.debug("Started recording (route: \(route), gen: \(generation))", subsystem: .audio)
            return audioURL
        } catch {
            Logger.error("Failed to start audio engine: \(error.localizedDescription)", subsystem: .audio)
            throw error
        }
    }

    private func processAudioBufferSafe(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) throws {
        // Track audio data arrival
        let isFirst = lastAudioCallbackTime == nil
        lastAudioCallbackTime = Date()
        if isFirst {
            Logger.debug("First audio data received", subsystem: .audio)
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            Logger.error("Failed to create output buffer", subsystem: .audio)
            throw RecordingError.invalidFormat
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            Logger.error("Conversion error: \(error.localizedDescription)", subsystem: .audio)
            throw error
        }

        guard status != .error else {
            Logger.error("Conversion failed with status: \(status.rawValue)", subsystem: .audio)
            throw RecordingError.invalidFormat
        }

        guard let channelData = outputBuffer.floatChannelData else {
            Logger.error("No channel data in output buffer", subsystem: .audio)
            throw RecordingError.invalidFormat
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

        // Calculate amplitude for waveform
        let rms = calculateRMS(samples: samples)
        DispatchQueue.main.async { [weak self] in
            self?.onAmplitudeUpdate?(rms)
        }

        // Silence detection — auto-recover if input device produces no audio
        // Skip during grace period (covers muting disruption) and active recovery
        if rms < 0.001 {
            consecutiveSilentCallbacks += 1
            let inGracePeriod = recordingStartTime.map { Date().timeIntervalSince($0) < 2.0 } ?? false
            if consecutiveSilentCallbacks >= silenceRecoveryThreshold,
               case .recording = recorderState,
               !inGracePeriod {
                Logger.warning("Audio silent for ~1.5s, triggering recovery to default route", subsystem: .audio)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.recoveryTask = Task { await self.recoverAudioEngine() }
                }
            }
        } else {
            consecutiveSilentCallbacks = 0
        }

        // Send samples to streaming transcriber
        autoreleasepool {
            onStreamingSamples?(samples)
        }
    }

    private func calculateRMS(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        vDSP_measqv(samples, 1, &sum, vDSP_Length(samples.count))
        let rms = sqrt(sum)
        return min(rms * 4.0, 1.0)
    }

    func stopRecording() async {
        // Cancel any in-progress recovery before tearing down
        recoveryTask?.cancel()
        recoveryTask = nil

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

        isRecording = false

        // Drain delay: wait for pending audio buffers
        try? await Task.sleep(nanoseconds: 200_000_000)
        Logger.debug("Drain period complete, removing tap", subsystem: .audio)

        cleanupEngineState()
        recordingStartTime = nil
        recorderState = .idle

        Logger.debug("Audio recording stopped", subsystem: .audio)
    }

    var recordingURL: URL? {
        return currentURL
    }

    // MARK: - Mid-Recording Recovery

    /// Full teardown + rebuild on system default route.
    /// Called when device dies, audio stalls, or config changes mid-recording.
    private func recoverAudioEngine() async {
        guard case .recording(let generation) = recorderState else { return }

        recorderState = .recovering(generation: generation)
        Logger.info("Mid-recording recovery: full teardown + rebuild on default route (gen: \(generation))", subsystem: .audio)

        // Full teardown
        cleanupEngineState()

        // Short settle delay
        try? await Task.sleep(nanoseconds: 300_000_000)

        guard isGenerationCurrent(generation), !Task.isCancelled else {
            Logger.debug("Recovery cancelled (recording stopped or generation changed)", subsystem: .audio)
            recorderState = .idle
            return
        }

        // Check if recording was stopped during the wait
        guard isRecording else {
            Logger.debug("Recording stopped during recovery, not restarting", subsystem: .audio)
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
            recorderState = .idle
            isRecording = false
            DispatchQueue.main.async { [weak self] in
                self?.onAudioFlowTimeout?()
            }
        }
    }

    // MARK: - Device-Alive Monitoring

    private func getEngineDeviceID() -> AudioDeviceID? {
        guard let au = audioEngine?.inputNode.audioUnit else { return nil }
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        return status == noErr ? deviceID : nil
    }

    private func startMonitoringDevice(_ deviceID: AudioDeviceID) {
        stopMonitoringDevice()

        monitoredDeviceID = deviceID

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        deviceAliveListenerBlock = { [weak self] (_, _) in
            self?.handleDeviceDied()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &propertyAddress,
            DispatchQueue.main,
            deviceAliveListenerBlock!
        )

        if status != noErr {
            Logger.warning("Failed to monitor device \(deviceID) alive status: \(status)", subsystem: .audio)
            monitoredDeviceID = nil
            deviceAliveListenerBlock = nil
        } else {
            Logger.debug("Monitoring device \(deviceID) alive status", subsystem: .audio)
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
                recoveryTask = Task {
                    await recoverAudioEngine()
                }
            }
        }
    }

    // MARK: - Continuous Audio Flow Watchdog

    private func startAudioFlowWatchdog() {
        stopAudioFlowWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isRecording, case .recording = self.recorderState else { return }

            if let lastTime = self.lastAudioCallbackTime {
                let elapsed = Date().timeIntervalSince(lastTime)
                if elapsed > self.audioFlowTimeout {
                    Logger.error("Audio flow stopped — no data for \(String(format: "%.1f", elapsed))s, triggering recovery", subsystem: .audio)
                    self.stopAudioFlowWatchdog()
                    self.recoveryTask = Task { await self.recoverAudioEngine() }
                }
            } else {
                Logger.error("Audio engine running but no data flowing after startup — triggering recovery", subsystem: .audio)
                self.stopAudioFlowWatchdog()
                self.recoveryTask = Task { await self.recoverAudioEngine() }
            }
        }
        timer.resume()
        audioFlowWatchdog = timer
    }

    private func stopAudioFlowWatchdog() {
        audioFlowWatchdog?.cancel()
        audioFlowWatchdog = nil
    }

    // MARK: - Engine Cleanup

    /// Fully tear down the audio engine and all associated state.
    private func cleanupEngineState() {
        stopAudioFlowWatchdog()
        stopMonitoringDevice()
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if let engine = audioEngine {
            var tapErr: NSError?
            ObjCTry({
                engine.inputNode.removeTap(onBus: 0)
            }, &tapErr)
            if let tapErr = tapErr {
                Logger.warning("removeTap caught exception: \(tapErr.localizedDescription)", subsystem: .audio)
            }

            var stopErr: NSError?
            ObjCTry({
                engine.stop()
            }, &stopErr)
            if let stopErr = stopErr {
                Logger.warning("engine.stop caught exception: \(stopErr.localizedDescription)", subsystem: .audio)
            }
        }
        audioEngine = nil
        converter = nil
        outputFormat = nil
    }

    // MARK: - Device Selection

    @discardableResult
    private func setInputDevice(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) -> Bool {
        guard isValidInputDevice(deviceID) else {
            Logger.warning("Device \(deviceID) is not a valid input device", subsystem: .audio)
            return false
        }

        guard let au = inputNode.audioUnit else {
            Logger.warning("Failed to get audio unit from input node", subsystem: .audio)
            return false
        }

        var deviceIDVar = deviceID
        let status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIDVar,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status == noErr {
            Logger.debug("Set input device ID: \(deviceID) (\(deviceName(for: deviceID) ?? "unknown"))", subsystem: .audio)
            return true
        } else {
            Logger.warning("Failed to set input device \(deviceID) (error: \(status))", subsystem: .audio)
            return false
        }
    }

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

    private func isValidInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        return status == noErr && dataSize > 0
    }
}

enum RecordingError: Error {
    case alreadyRecording
    case invalidFormat
    case fileCreationFailed
    case microphonePermissionDenied
    case audioUnitFailed
    case engineCleanedUp
}
