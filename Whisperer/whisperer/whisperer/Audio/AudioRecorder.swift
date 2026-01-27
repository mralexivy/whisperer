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
    private var isRecording = false
    private var currentURL: URL?

    // Callback for waveform updates
    var onAmplitudeUpdate: ((Float) -> Void)?

    // Callback for streaming samples (16kHz mono float32)
    var onStreamingSamples: (([Float]) -> Void)?

    // Target format for whisper: 16kHz mono
    private let targetSampleRate: Double = 16000.0

    // Selected input device (nil = use system default)
    var selectedDeviceID: AudioDeviceID?

    // MARK: - Permission

    static func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted {
                print("Microphone permission granted")
            } else {
                print("Microphone permission denied")
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
            throw RecordingError.alreadyRecording
        }

        // Check microphone permission first
        let hasPermission = await AudioRecorder.checkMicrophonePermission()
        guard hasPermission else {
            print("Microphone permission denied - cannot record")
            throw RecordingError.microphonePermissionDenied
        }
        print("Microphone permission confirmed")

        // Create temporary file for recording
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "recording_\(Date().timeIntervalSince1970).wav"
        let audioURL = tempDir.appendingPathComponent(fileName)
        currentURL = audioURL

        // Setup audio engine
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw RecordingError.fileCreationFailed
        }

        let inputNode = audioEngine.inputNode

        // Only set custom device if explicitly selected (not system default)
        // selectedDeviceID is only set when user picks a specific device in settings
        if let deviceID = selectedDeviceID {
            if setInputDevice(deviceID, on: inputNode) {
                print("✅ Using selected input device: \(deviceID)")
            } else {
                // Device selection failed - clear it and use default
                print("⚠️ Selected device unavailable, using system default")
                selectedDeviceID = nil
            }
        } else {
            print("🎤 Using system default input device")
        }

        // Voice processing disabled - it causes ~500ms+ startup delay due to
        // KeystrokeSuppressor initialization and stream setup timeouts.
        // This delay cuts off the first words of speech.
        // Whisper handles raw audio well enough without preprocessing.
        print("🎤 Voice processing disabled for instant startup")

        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Validate format - must have valid sample rate and channels
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            print("❌ Invalid input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels")
            throw RecordingError.invalidFormat
        }

        print("Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels")

        // Create output format (16kHz mono PCM for whisper)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecordingError.invalidFormat
        }

        // Create converter
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecordingError.invalidFormat
        }

        // Configure converter for proper downmixing from multi-channel to mono
        // Map first input channel to mono output (channel 0)
        converter.channelMap = [0]
        print("🔧 Converter: \(inputFormat.channelCount) channels → 1 channel, channel map: \(converter.channelMap)")

        // Install tap on input node
        let bufferSize: AVAudioFrameCount = 4096
        print("📌 Installing tap on input node (buffer size: \(bufferSize))")
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, time in
            // Wrap in do-catch to prevent crashes in audio callback
            do {
                try self?.processAudioBufferSafe(buffer: buffer, converter: converter, outputFormat: outputFormat)
            } catch {
                print("❌ Error in audio callback: \(error)")
            }
        }
        print("✅ Tap installed successfully")

        // Start engine (use self.audioEngine in case we recreated it)
        do {
            print("🎬 Starting audio engine...")
            guard let engine = self.audioEngine else {
                throw RecordingError.fileCreationFailed
            }
            try engine.start()
            isRecording = true
            print("✅ Started recording with AVAudioEngine to: \(audioURL.path)")
            return audioURL
        } catch {
            print("❌ Failed to start audio engine: \(error)")
            throw RecordingError.fileCreationFailed
        }
    }

    private func processAudioBufferSafe(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) throws {
        // Calculate output buffer size
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            print("❌ Failed to create output buffer")
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
            print("❌ Conversion error: \(error.localizedDescription)")
            throw error
        }

        guard status != .error else {
            print("❌ Conversion failed with status: \(status.rawValue)")
            throw RecordingError.invalidFormat
        }

        // Extract float samples
        guard let channelData = outputBuffer.floatChannelData else {
            print("❌ No channel data in output buffer")
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
        return min(rms * 3.0, 1.0)
    }

    func stopRecording() async {
        guard isRecording else { return }

        isRecording = false

        // Stop audio engine
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        print("Stopped recording")
    }

    var recordingURL: URL? {
        return currentURL
    }

    // MARK: - Device Selection

    /// Attempt to set a specific input device. Returns true if successful.
    /// If this fails, the system default device will be used automatically.
    @discardableResult
    private func setInputDevice(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) -> Bool {
        // Verify device exists and has input capability first
        guard isValidInputDevice(deviceID) else {
            print("⚠️ Device \(deviceID) is not a valid input device, using default")
            return false
        }

        // Get the audio unit from the input node
        guard let au = inputNode.audioUnit else {
            print("⚠️ Failed to get audio unit from input node, using default device")
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
            print("✅ Set input device ID: \(deviceID)")
            return true
        } else {
            print("⚠️ Failed to set input device (error: \(status)), using default")
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
}
