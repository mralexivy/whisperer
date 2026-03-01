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

    // Target format for whisper: 16kHz mono
    private let targetSampleRate: Double = 16000.0

    // Selected input device (nil = use system default)
    var selectedDeviceID: AudioDeviceID?

    // Auto-recovery state
    private var autoRecoveryEnabled = true
    private var recoveryAttempts = 0
    private let maxRecoveryAttempts = 3
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var startupRetryCount = 0  // Prevent infinite retry loops
    private var recordingStartTime: Date?  // Track when recording started for grace period
    private let startupGracePeriod: TimeInterval = 1.5  // Ignore config changes for 1.5s after start

    // Notification observer for audio engine configuration changes
    private var configChangeObserver: NSObjectProtocol?

    override init() {
        super.init()
        // Observer setup moved to startRecordingInternal() to observe only our engine
    }

    deinit {
        // Safety net: clean up observer if stopRecording() was never called
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    // MARK: - Audio Engine Observers
    // Note: Observer is now registered per-recording session in startRecordingInternal()
    // and removed in stopRecording() to only monitor our specific engine instance

    /// Attempt to recover the audio engine after a failure
    private func recoverAudioEngine() async {
        guard autoRecoveryEnabled else {
            Logger.warning("Auto-recovery disabled, not attempting recovery", subsystem: .audio)
            return
        }

        guard recoveryAttempts < maxRecoveryAttempts else {
            Logger.error("Max recovery attempts (\(maxRecoveryAttempts)) reached, giving up", subsystem: .audio)
            DispatchQueue.main.async { [weak self] in
                self?.onDeviceRecovery?("Microphone connection lost. Please check your audio device.")
            }
            await stopRecording()
            return
        }

        recoveryAttempts += 1
        Logger.debug("Recovery attempt \(recoveryAttempts)/\(maxRecoveryAttempts)...", subsystem: .audio)

        // Notify user that we're recovering
        if recoveryAttempts == 1 {
            DispatchQueue.main.async { [weak self] in
                self?.onDeviceRecovery?("Audio device changed, reconnecting...")
            }
        }

        // Stop current engine completely
        cleanupEngineState()

        // Wait a bit before restarting
        try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms

        // Check if recording was stopped during the wait
        // (user may have released button during recovery)
        guard isRecording else {
            Logger.debug("Recording stopped during recovery, not restarting", subsystem: .audio)
            return
        }

        // Try to restart
        do {
            _ = try await startRecordingInternal()
            Logger.debug("Audio engine recovered successfully", subsystem: .audio)
            recoveryAttempts = 0  // Reset on success

            // Notify user of successful recovery
            DispatchQueue.main.async { [weak self] in
                self?.onDeviceRecovery?("Audio reconnected successfully")
            }
        } catch {
            Logger.error("Recovery failed: \(error.localizedDescription)", subsystem: .audio)

            // If we haven't maxed out, try again
            if recoveryAttempts < maxRecoveryAttempts {
                await recoverAudioEngine()
            } else {
                // Final failure notification
                DispatchQueue.main.async { [weak self] in
                    self?.onDeviceRecovery?("Could not reconnect audio. Please restart recording.")
                }
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

        recoveryAttempts = 0  // Reset recovery counter on new recording
        startupRetryCount = 0  // Reset startup retry counter
        recordingStartTime = Date()  // Set grace period start time

        do {
            return try await startRecordingInternal()
        } catch {
            // First attempt failed — clean up completely and retry once with a fresh
            // engine and system default device. This handles cases where the audio unit
            // is left in a bad state by a previous session or device change.
            guard startupRetryCount == 0 else {
                // Already retried, give up
                throw error
            }
            startupRetryCount += 1
            Logger.warning("Recording setup failed (\(error.localizedDescription)), retrying with fresh engine and default device...", subsystem: .audio)

            cleanupEngineState()
            selectedDeviceID = nil

            // Let the audio subsystem settle before retrying
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

            recordingStartTime = Date()
            return try await startRecordingInternal()
        }
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

        let inputNode = audioEngine.inputNode

        // Voice processing disabled - it causes ~500ms+ startup delay due to
        // KeystrokeSuppressor initialization and stream setup timeouts.
        // This delay cuts off the first words of speech.
        // Whisper handles raw audio well enough without preprocessing.
        Logger.debug("Voice processing disabled for instant startup", subsystem: .audio)

        // CRITICAL: Force audio unit creation by querying format BEFORE setting device
        // The audio unit is only created when we access outputFormat(forBus:)
        // Without this, setInputDevice() fails because inputNode.audioUnit is nil
        let initialFormat = inputNode.outputFormat(forBus: 0)

        // Validate audio unit was created successfully — the outputFormat call can
        // fail internally (AVAudioIONodeImpl error) leaving the audio unit in a bad state
        guard initialFormat.sampleRate > 0 && initialFormat.channelCount > 0 else {
            Logger.error("Audio unit initialization failed (format: \(initialFormat.sampleRate)Hz, \(initialFormat.channelCount)ch)", subsystem: .audio)
            throw RecordingError.audioUnitFailed
        }

        // Only set custom device if explicitly selected (not system default)
        // selectedDeviceID is only set when user picks a specific device in settings
        if let deviceID = selectedDeviceID {
            if setInputDevice(deviceID, on: inputNode) {
                Logger.debug("Using selected input device: \(deviceID)", subsystem: .audio)
            } else {
                // Device selection failed - clear it and use default
                Logger.warning("Selected device unavailable, using system default", subsystem: .audio)
                selectedDeviceID = nil
            }
        } else {
            Logger.debug("Using system default input device", subsystem: .audio)
        }

        // Re-query format after device change (format may be different for selected device)
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Validate format - must have valid sample rate and channels
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            Logger.error("Invalid input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels", subsystem: .audio)
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
        do {
            Logger.debug("Starting audio engine...", subsystem: .audio)
            guard let engine = self.audioEngine else {
                Logger.error("Audio engine is nil, cannot start", subsystem: .audio)
                throw RecordingError.fileCreationFailed
            }
            try engine.start()
            isRecording = true
            Logger.debug("Started recording", subsystem: .audio)
            return audioURL
        } catch {
            Logger.error("Failed to start audio engine: \(error.localizedDescription)", subsystem: .audio)
            throw error
        }
    }

    private func processAudioBufferSafe(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) throws {
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

    // MARK: - Engine Cleanup

    /// Fully tear down the audio engine and all associated state.
    /// Safe to call even if the engine is nil or partially initialized.
    private func cleanupEngineState() {
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
            Logger.debug("Set input device ID: \(deviceID)", subsystem: .audio)
            return true
        } else {
            Logger.warning("Failed to set input device (error: \(status)), using default", subsystem: .audio)
            return false
        }
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
