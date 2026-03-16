//
//  AudioRecorder.swift
//  Whisperer
//
//  Microphone capture using AVAudioEngine for real-time streaming
//  Also saves to WAV file for backup/replay
//

import AVFoundation
import Accelerate
import CoreAudio
import AudioToolbox

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

    // Callback for device recovery events (message describing what happened)
    var onDeviceRecovery: ((String) -> Void)?

    // Callback when audio engine is running but no data flows (silent recording)
    var onAudioFlowTimeout: (() -> Void)?

    // Tracks when the most recent audio callback fired (for continuous flow monitoring)
    private var lastAudioCallbackTime: Date?

    // Continuous audio flow watchdog — detects when audio stops flowing mid-recording
    private var audioFlowWatchdog: DispatchSourceTimer?
    private let audioFlowTimeout: TimeInterval = 3.0  // Trigger recovery if no data for 3s

    // Target format for whisper: 16kHz mono
    private let targetSampleRate: Double = 16000.0

    // Selected input device (nil = use system default)
    var selectedDeviceID: AudioDeviceID?

    // Silence detection — auto-recover if audio is dead
    private var consecutiveSilentCallbacks: Int = 0
    private let silenceRecoveryThreshold: Int = 18  // ~1.5s at 48kHz/4096 buffer

    // Auto-recovery state
    private var autoRecoveryEnabled = true
    private var recoveryAttempts = 0
    private let maxRecoveryAttempts = 5
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var recordingStartTime: Date?  // Track when recording started for grace period
    private let startupGracePeriod: TimeInterval = 1.5  // Ignore config changes for 1.5s after start
    private var recordingGeneration = 0  // Incremented each startRecording call; stale retries bail out

    // Notification observer for audio engine configuration changes
    private var configChangeObserver: NSObjectProtocol?

    // Device-alive monitoring: detect when the recording device dies (e.g. monitor unplugged)
    // This fires immediately when the device vanishes, unlike AVAudioEngineConfigurationChange
    // which may be delayed or not fire at all.
    private var monitoredDeviceID: AudioDeviceID?
    private var deviceAliveListenerBlock: AudioObjectPropertyListenerBlock?

    override init() {
        super.init()
        // Observer setup moved to startRecordingInternal() to observe only our engine
    }

    deinit {
        // Safety net: clean up observers if stopRecording() was never called
        stopAudioFlowWatchdog()
        stopMonitoringDevice()
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    // MARK: - Audio Engine Observers
    // Note: Observer is now registered per-recording session in startRecordingInternal()
    // and removed in stopRecording() to only monitor our specific engine instance

    /// Silently recover the audio engine. No user-facing messages — just fix it.
    /// Keeps retrying with increasing backoff until it works or recording is stopped.
    private func recoverAudioEngine() async {
        guard autoRecoveryEnabled else { return }

        recoveryAttempts += 1
        Logger.debug("Silent recovery attempt \(recoveryAttempts)...", subsystem: .audio)

        // Stop current engine completely — engine released on background thread
        cleanupEngineState()

        // Fall back to built-in mic — the system default may be the same broken
        // device that caused the failure (e.g., stale aggregate device after sleep)
        selectedDeviceID = await findBuiltInMicID()
        if selectedDeviceID == nil {
            Logger.debug("No built-in mic found, will use system default", subsystem: .audio)
        }

        // Backoff: 300ms first attempt, 500ms second, 1s third+
        let backoffNs: UInt64 = recoveryAttempts <= 1 ? 300_000_000 :
                                recoveryAttempts <= 2 ? 500_000_000 : 1_000_000_000
        try? await Task.sleep(nanoseconds: backoffNs)

        // Check if recording was stopped during the wait
        // (user may have released button during recovery)
        guard isRecording else {
            Logger.debug("Recording stopped during recovery, not restarting", subsystem: .audio)
            return
        }

        // Try to restart
        do {
            _ = try await startRecordingInternal()
            Logger.info("Audio engine recovered silently (attempt \(recoveryAttempts))", subsystem: .audio)
            recoveryAttempts = 0  // Reset on success
        } catch {
            Logger.error("Recovery attempt \(recoveryAttempts) failed: \(error.localizedDescription)", subsystem: .audio)

            // Keep retrying until maxRecoveryAttempts, then notify AppState to
            // stop and reset so the NEXT recording attempt starts clean
            if recoveryAttempts < maxRecoveryAttempts {
                await recoverAudioEngine()
            } else {
                Logger.error("All \(maxRecoveryAttempts) recovery attempts failed, resetting for next recording", subsystem: .audio)
                // Signal AppState so it resets to idle — next Fn press starts fresh
                DispatchQueue.main.async { [weak self] in
                    self?.onAudioFlowTimeout?()
                }
                await stopRecording()
            }
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

    func startRecording() async throws -> URL {
        guard !isRecording else {
            Logger.warning("startRecording called but already recording", subsystem: .audio)
            throw RecordingError.alreadyRecording
        }

        recoveryAttempts = 0
        recordingStartTime = Date()
        recordingGeneration += 1
        let myGeneration = recordingGeneration

        var lastError: Error?

        for attempt in 1...3 {
            do {
                return try await startRecordingInternal()
            } catch {
                lastError = error

                // A newer startRecording() call has taken over — don't retry
                guard recordingGeneration == myGeneration else {
                    Logger.debug("Stale recording attempt (gen \(myGeneration) vs \(recordingGeneration)), not retrying", subsystem: .audio)
                    throw error
                }

                Logger.warning("Recording start failed (attempt \(attempt)/3): \(error.localizedDescription)", subsystem: .audio)

                // Don't retry after the last attempt
                guard attempt < 3 else { break }

                cleanupEngineState()

                // On retry 2+, use built-in mic explicitly — the system default
                // may be a stale/dead device after sleep/wake
                if attempt >= 2 {
                    selectedDeviceID = await findBuiltInMicID()
                }

                // Let CoreAudio settle before retrying
                try? await Task.sleep(nanoseconds: 300_000_000)

                guard recordingGeneration == myGeneration else {
                    Logger.debug("Stale recording attempt after sleep (gen \(myGeneration) vs \(recordingGeneration)), not retrying", subsystem: .audio)
                    throw error
                }

                recordingStartTime = Date()
            }
        }

        throw lastError ?? RecordingError.audioUnitFailed
    }

    private func startRecordingInternal() async throws -> URL {

        // Check microphone permission first
        let hasPermission = await AudioRecorder.checkMicrophonePermission()
        guard hasPermission else {
            Logger.error("Microphone permission denied - cannot record", subsystem: .audio)
            throw RecordingError.microphonePermissionDenied
        }
        Logger.debug("Microphone permission confirmed", subsystem: .audio)

        // Create temporary file for recording
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "recording_\(Date().timeIntervalSince1970).wav"
        let audioURL = tempDir.appendingPathComponent(fileName)
        currentURL = audioURL

        // Setup audio engine
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            Logger.error("Failed to create AVAudioEngine", subsystem: .audio)
            throw RecordingError.fileCreationFailed
        }

        // Setup observer for THIS engine only (not all engines on the system)
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,  // Only observe our engine, not all engines
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            Logger.warning("Audio engine configuration changed", subsystem: .audio)

            // Ignore config changes during startup grace period
            // (audio muting and other system changes can trigger this right after start)
            if let startTime = self.recordingStartTime {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed < self.startupGracePeriod {
                    Logger.debug("Ignoring config change during startup grace period (\(String(format: "%.2f", elapsed))s < \(self.startupGracePeriod)s)", subsystem: .audio)
                    return
                }
            }

            if self.isRecording && self.autoRecoveryEnabled {
                Logger.debug("Attempting to recover from configuration change...", subsystem: .audio)
                Task {
                    await self.recoverAudioEngine()
                }
            }
        }

        // Voice processing disabled — it causes ~500ms+ startup delay due to
        // KeystrokeSuppressor initialization and stream setup timeouts.
        // Whisper handles raw audio well enough without preprocessing.
        Logger.debug("Voice processing disabled for instant startup", subsystem: .audio)

        // Force inputNode instantiation (creates the underlying AUHAL AudioUnit)
        let inputNode = audioEngine.inputNode

        // Resolve and bind device BEFORE engine.prepare() — CoreAudio requires
        // the device to be set before AudioUnit initialization. After sleep/wake,
        // the system default device ID may be stale, so we re-resolve from AudioDeviceManager.
        if let deviceID = selectedDeviceID {
            let currentDevice = await AudioDeviceManager.shared.selectedDevice
            if let current = currentDevice, current.id != deviceID {
                Logger.info("Device ID changed (\(deviceID) -> \(current.id)), using current ID", subsystem: .audio)
                selectedDeviceID = current.id
            }
            if setInputDevice(selectedDeviceID!, on: inputNode) {
                Logger.debug("Using selected input device: \(selectedDeviceID!) (\(deviceName(for: selectedDeviceID!) ?? "unknown"))", subsystem: .audio)
            } else {
                Logger.warning("Selected device unavailable, falling back to built-in mic", subsystem: .audio)
                selectedDeviceID = nil
                // Try built-in mic as fallback
                if let builtInID = await findBuiltInMicID() {
                    setInputDevice(builtInID, on: inputNode)
                }
            }
        } else {
            Logger.debug("Using system default input device", subsystem: .audio)
        }

        // Prepare the engine — allocates resources and establishes the audio format
        // for the bound device. Must happen after device binding, before format query.
        audioEngine.prepare()

        // Query the node's output format AFTER prepare.
        // The tap reads from the node's output, so the tap format must match outputFormat.
        // Retry if format is 0Hz/0ch (HAL still initializing after sleep/wake).
        var inputFormat = inputNode.outputFormat(forBus: 0)
        if inputFormat.sampleRate == 0 || inputFormat.channelCount == 0 {
            Logger.warning("Initial format invalid (\(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch), retrying...", subsystem: .audio)
            for attempt in 1...5 {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
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

        // Configure converter for proper downmixing from multi-channel to mono
        // Map first input channel to mono output (channel 0)
        newConverter.channelMap = [0]
        Logger.debug("Converter: \(inputFormat.channelCount) channels → 1 channel, channel map: \(newConverter.channelMap)", subsystem: .audio)

        // Install tap on input node
        let bufferSize: AVAudioFrameCount = 4096
        Logger.debug("Installing tap on input node (buffer size: \(bufferSize))", subsystem: .audio)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, time in
            // Wrap in do-catch to prevent crashes in audio callback
            do {
                guard let self = self, let converter = self.converter, let outputFormat = self.outputFormat else {
                    return
                }
                try self.processAudioBufferSafe(buffer: buffer, converter: converter, outputFormat: outputFormat)
            } catch {
                Logger.error("Error in audio callback: \(error.localizedDescription)", subsystem: .audio)
            }
        }
        Logger.debug("Tap installed successfully", subsystem: .audio)

        // Start engine (use self.audioEngine in case we recreated it)
        lastAudioCallbackTime = nil  // Reset for flow watchdog
        consecutiveSilentCallbacks = 0  // Reset silence detection
        do {
            Logger.debug("Starting audio engine...", subsystem: .audio)
            guard let engine = self.audioEngine else {
                Logger.error("Audio engine is nil, cannot start", subsystem: .audio)
                throw RecordingError.fileCreationFailed
            }
            try engine.start()
            isRecording = true

            // Monitor the actual device the engine is using for disconnect detection.
            // May differ from selectedDeviceID if fallback to system default occurred.
            if let engineDeviceID = getEngineDeviceID() {
                startMonitoringDevice(engineDeviceID)
            }

            // Continuous audio flow watchdog: checks every 2s that audio data is still
            // arriving. Catches both initial startup failures AND mid-recording audio death
            // (e.g., aggregate device disappears, audio unit silently stops producing data).
            startAudioFlowWatchdog()

            Logger.debug("Started recording", subsystem: .audio)
            return audioURL
        } catch {
            Logger.error("Failed to start audio engine: \(error.localizedDescription)", subsystem: .audio)
            throw error
        }
    }

    private func processAudioBufferSafe(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) throws {
        // Track audio data arrival — used by continuous flow watchdog
        let isFirst = lastAudioCallbackTime == nil
        lastAudioCallbackTime = Date()
        if isFirst {
            Logger.debug("First audio data received", subsystem: .audio)
        }

        // Calculate output buffer size
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            Logger.error("Failed to create output buffer", subsystem: .audio)
            throw RecordingError.invalidFormat
        }

        // Convert to 16kHz mono
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

        // Extract float samples
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
        if rms < 0.001 {
            consecutiveSilentCallbacks += 1
            if consecutiveSilentCallbacks == silenceRecoveryThreshold {
                Logger.warning("Audio silent for ~1.5s (device: \(selectedDeviceID.map(String.init) ?? "default")), recovering", subsystem: .audio)
                selectedDeviceID = nil
                DispatchQueue.main.async { [weak self] in
                    Task { await self?.recoverAudioEngine() }
                }
            }
        } else {
            consecutiveSilentCallbacks = 0
        }

        // Send samples to streaming transcriber (wrap in autoreleasepool to prevent memory buildup)
        autoreleasepool {
            onStreamingSamples?(samples)
        }

        // Don't write to file during recording - it causes crashes on the real-time audio thread
        // The streaming transcriber handles the audio directly
    }

    private func calculateRMS(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        var sum: Float = 0
        vDSP_measqv(samples, 1, &sum, vDSP_Length(samples.count))
        let rms = sqrt(sum)

        // Normalize (typical speech is around 0.1-0.3 RMS)
        return min(rms * 4.0, 1.0)
    }

    func stopRecording() async {
        guard isRecording else {
            Logger.debug("stopRecording called but not recording", subsystem: .audio)
            return
        }

        Logger.debug("Stopping audio recording...", subsystem: .audio)

        // Wait for first audio data if engine hasn't produced any yet.
        // After sleep/wake, the audio HAL needs extra time to initialize.
        // Without this, a quick Fn tap after wake records 0 samples.
        if lastAudioCallbackTime == nil {
            Logger.debug("No audio data yet, waiting for engine warmup...", subsystem: .audio)
            for _ in 0..<10 {  // Up to 500ms
                try? await Task.sleep(nanoseconds: 50_000_000)
                if lastAudioCallbackTime != nil { break }
            }
            if lastAudioCallbackTime == nil {
                Logger.warning("Audio engine produced no data after 500ms wait", subsystem: .audio)
            }
        }

        isRecording = false

        // Drain delay: wait for pending audio buffers to be delivered
        // The tap callback continues running until we remove the tap.
        // Buffer is 4096 frames at ~48kHz = ~85ms per buffer.
        // Wait 200ms to cover ~2-3 buffer cycles, ensuring last words are captured.
        try? await Task.sleep(nanoseconds: 200_000_000)

        Logger.debug("Drain period complete, removing tap", subsystem: .audio)

        // Tear down the engine and all associated state
        cleanupEngineState()
        recordingStartTime = nil

        Logger.debug("Audio recording stopped", subsystem: .audio)
    }

    var recordingURL: URL? {
        return currentURL
    }

    // MARK: - Timeout-Protected CoreAudio Queries

    /// Find the built-in microphone device ID from AudioDeviceManager.
    /// Used as a reliable fallback when the system default device is broken after sleep/wake.
    private func findBuiltInMicID() async -> AudioDeviceID? {
        let devices = await AudioDeviceManager.shared.availableInputDevices
        if let builtIn = devices.first(where: { $0.name.contains("MacBook") || $0.name.contains("Built-in") }) {
            Logger.debug("Found built-in mic: \(builtIn.name) (ID: \(builtIn.id))", subsystem: .audio)
            return builtIn.id
        }
        return nil
    }

    // MARK: - Device-Alive Monitoring

    /// Query the AudioDeviceID currently bound to the engine's input audio unit.
    /// Returns the actual device the engine is recording from (may differ from
    /// selectedDeviceID if fallback to system default occurred).
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

    /// Register a kAudioDevicePropertyDeviceIsAlive listener on the given device.
    /// When the device dies (e.g. monitor unplugged), triggers recovery immediately —
    /// faster and more reliable than AVAudioEngineConfigurationChange.
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

    /// Unregister the device-alive listener. Safe to call when no listener is active.
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

    /// Called when the monitored device's isAlive property changes.
    /// Verifies the device is actually dead before triggering recovery.
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
            Logger.warning("Device \(deviceID) died — triggering immediate recovery", subsystem: .audio)
            stopMonitoringDevice()

            if isRecording && autoRecoveryEnabled {
                Task {
                    await recoverAudioEngine()
                }
            }
        }
    }

    // MARK: - Continuous Audio Flow Watchdog

    /// Start a repeating timer that verifies audio data is still flowing.
    /// Fires every 2s; if no audio callback has arrived in the last 3s, triggers recovery.
    private func startAudioFlowWatchdog() {
        stopAudioFlowWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // First check after 2s (initial startup), then every 2s thereafter
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isRecording else { return }

            if let lastTime = self.lastAudioCallbackTime {
                let elapsed = Date().timeIntervalSince(lastTime)
                if elapsed > self.audioFlowTimeout {
                    Logger.error("Audio flow stopped — no data for \(String(format: "%.1f", elapsed))s, triggering recovery", subsystem: .audio)
                    self.stopAudioFlowWatchdog()  // Prevent re-entry during recovery
                    Task { await self.recoverAudioEngine() }
                }
            } else {
                // No audio data has arrived since engine started
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

    // MARK: - Engine Cleanup

    /// Fully tear down the audio engine and all associated state.
    /// Safe to call even if the engine is nil or partially initialized.
    private func cleanupEngineState() {
        stopAudioFlowWatchdog()
        stopMonitoringDevice()
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        converter = nil
        outputFormat = nil
    }

    // MARK: - Device Selection

    /// Attempt to set a specific input device. Returns true if successful.
    /// If this fails, the system default device will be used automatically.
    @discardableResult
    private func setInputDevice(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) -> Bool {
        // Verify device exists and has input capability first
        guard isValidInputDevice(deviceID) else {
            Logger.warning("Device \(deviceID) is not a valid input device, using default", subsystem: .audio)
            return false
        }

        // Get the audio unit from the input node
        guard let au = inputNode.audioUnit else {
            Logger.warning("Failed to get audio unit from input node, using default device", subsystem: .audio)
            return false
        }

        // Set the device on the audio unit
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
            Logger.warning("Failed to set input device (error: \(status)), using default", subsystem: .audio)
            return false
        }
    }

    /// Resolve a device ID to its human-readable name
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

    /// Check if a device ID is valid and has input capability
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

        // Device is valid if it has input streams (dataSize > 0)
        return status == noErr && dataSize > 0
    }
}

enum RecordingError: Error {
    case alreadyRecording
    case invalidFormat
    case fileCreationFailed
    case microphonePermissionDenied
    case audioUnitFailed
}
