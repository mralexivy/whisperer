//
//  AppState.swift
//  Whisperer
//
//  Global application state machine for recording workflow
//

import Foundation
import Combine

enum RecordingState: Equatable {
    case idle
    case recording(startTime: Date)
    case stopping
    case transcribing(audioPath: URL)
    case inserting(text: String)
    case downloadingModel(progress: Double)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .idle:
            return "Ready"
        case .recording:
            return "Listening..."
        case .stopping:
            return "Stopping..."
        case .transcribing:
            return "Transcribing..."
        case .inserting:
            return "Inserting..."
        case .downloadingModel(let progress):
            return "Downloading model... \(Int(progress * 100))%"
        }
    }
}

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var state: RecordingState = .idle {
        didSet {
            // Notify observers when state changes
            NotificationCenter.default.post(name: NSNotification.Name("AppStateChanged"), object: nil)
        }
    }
    @Published var waveformAmplitudes: [Float] = Array(repeating: 0, count: 20)
    @Published var errorMessage: String?
    @Published var saveRecordings: Bool = true  // Save recordings by default
    @Published var liveTranscription: String = ""  // Live transcription during recording
    @Published var muteOtherAudioDuringRecording: Bool = true {  // Mute other audio sources during recording
        didSet {
            UserDefaults.standard.set(muteOtherAudioDuringRecording, forKey: "muteOtherAudioDuringRecording")
        }
    }

    // Language selection for transcription
    @Published var selectedLanguage: TranscriptionLanguage = .english {
        didSet {
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: "selectedLanguage")
        }
    }

    // Model selection
    @Published var selectedModel: WhisperModel = .largeTurboQ5
    @Published var downloadingModel: WhisperModel? = nil
    @Published var downloadProgress: Double = 0

    // Component references
    var audioRecorder: AudioRecorder?
    var keyListener: GlobalKeyListener?
    var whisperRunner: WhisperRunner?
    var textInjector: TextInjector?
    var audioMuter: AudioMuter?
    var soundPlayer: SoundPlayer?

    // Audio device management
    let audioDeviceManager = AudioDeviceManager.shared
    private var deviceSubscription: AnyCancellable?

    // Pre-loaded WhisperBridge - keeps model in memory for instant recording start
    private var whisperBridge: WhisperBridge?
    private var loadedModel: WhisperModel? = nil
    @Published var isModelLoaded: Bool = false

    // Pre-loaded Silero VAD for voice activity detection
    private var sileroVAD: SileroVAD?
    @Published var isVADLoaded: Bool = false

    // Streaming transcription
    private var streamingTranscriber: StreamingTranscriber?

    private var currentAudioURL: URL?

    // Model path for selected model
    private var modelPath: URL {
        ModelDownloader.shared.modelPath(for: selectedModel)
    }

    // Recordings directory
    private var recordingsDir: URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let recordingsDir = appSupport.appendingPathComponent("Whisperer/Recordings")
        try? fileManager.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        return recordingsDir
    }

    private init() {
        // Load saved model selection
        if let savedModel = UserDefaults.standard.string(forKey: "selectedModel"),
           let model = WhisperModel(filename: savedModel) {
            selectedModel = model
        }

        // Load mute preference (default true if not set)
        if UserDefaults.standard.object(forKey: "muteOtherAudioDuringRecording") != nil {
            muteOtherAudioDuringRecording = UserDefaults.standard.bool(forKey: "muteOtherAudioDuringRecording")
        }

        // Load language preference (default English)
        if let savedLang = UserDefaults.standard.string(forKey: "selectedLanguage"),
           let lang = TranscriptionLanguage(rawValue: savedLang) {
            selectedLanguage = lang
        }

        // Start monitoring audio device changes
        audioDeviceManager.startMonitoring()

        // Subscribe to device changes to update audioRecorder
        // Only set device ID if user explicitly selected a non-default device
        deviceSubscription = audioDeviceManager.$selectedDevice
            .sink { [weak self] device in
                guard let self = self else { return }
                // Only set custom device if user explicitly selected one (preferredDeviceUID is not nil)
                // If preferredDeviceUID is nil, use system default (don't set any device)
                if self.audioDeviceManager.preferredDeviceUID != nil {
                    self.audioRecorder?.selectedDeviceID = device?.id
                } else {
                    self.audioRecorder?.selectedDeviceID = nil
                }
            }
    }

    // MARK: - Model Selection

    /// Check if a model is downloaded
    func isModelDownloaded(_ model: WhisperModel) -> Bool {
        ModelDownloader.shared.isModelDownloaded(model)
    }

    /// Select a model (must be downloaded first)
    func selectModel(_ model: WhisperModel) {
        guard isModelDownloaded(model) else {
            print("⚠️ Cannot select model \(model.displayName) - not downloaded")
            return
        }

        guard model != selectedModel || loadedModel != model else {
            print("✅ Model \(model.displayName) already selected")
            return
        }

        selectedModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "selectedModel")
        print("🔄 Switched to model: \(model.displayName)")

        // Reload the model
        isModelLoaded = false
        whisperBridge = nil
        loadedModel = nil
        preloadModel()
    }

    /// Download a model
    func downloadModel(_ model: WhisperModel) async {
        guard downloadingModel == nil else {
            print("⚠️ Already downloading a model")
            return
        }

        guard !isModelDownloaded(model) else {
            print("✅ Model \(model.displayName) already downloaded")
            selectModel(model)
            return
        }

        downloadingModel = model
        downloadProgress = 0
        state = .downloadingModel(progress: 0)

        do {
            try await ModelDownloader.shared.downloadModel(model) { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                    self?.state = .downloadingModel(progress: progress)
                }
            }

            print("✅ Downloaded \(model.displayName)")
            downloadingModel = nil
            downloadProgress = 0
            state = .idle

            // Auto-select the newly downloaded model
            selectModel(model)
        } catch {
            print("❌ Failed to download \(model.displayName): \(error)")
            errorMessage = "Failed to download \(model.displayName): \(error.localizedDescription)"
            downloadingModel = nil
            downloadProgress = 0
            state = .idle
        }
    }

    // MARK: - Model Loading

    /// Pre-load the Whisper model into memory for instant recording start
    /// Call this once after model download completes
    func preloadModel() {
        let model = selectedModel
        let path = modelPath

        guard FileManager.default.fileExists(atPath: path.path) else {
            print("⚠️ Model file not found, cannot preload: \(path.path)")
            return
        }

        guard whisperBridge == nil || loadedModel != model else {
            print("✅ Model \(model.displayName) already loaded")
            isModelLoaded = true
            // Also preload VAD if not loaded
            preloadVAD()
            return
        }

        let modelDisplayName = model.displayName
        print("🔄 Pre-loading \(modelDisplayName)...")
        let startTime = Date()

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let bridge = try WhisperBridge(modelPath: path)
                let loadTime = Date().timeIntervalSince(startTime)
                print("✅ \(modelDisplayName) pre-loaded in \(String(format: "%.2f", loadTime))s")

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.whisperBridge = bridge
                    self.loadedModel = model
                    self.isModelLoaded = true
                    // Also preload VAD after whisper model is loaded
                    self.preloadVAD()
                }
            } catch {
                print("❌ Failed to pre-load \(modelDisplayName): \(error)")
            }
        }
    }

    /// Pre-load the Silero VAD model for voice activity detection
    /// VAD is completely optional - the app works fine without it
    func preloadVAD() {
        guard sileroVAD == nil else {
            print("✅ Silero VAD already loaded")
            isVADLoaded = true
            return
        }

        let vadPath = ModelDownloader.shared.vadModelPath()

        // First ensure the VAD model is downloaded
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                print("📥 Checking for Silero VAD model...")

                // Download VAD model if needed (small ~2MB download)
                try await ModelDownloader.shared.ensureVADModelDownloaded()

                // Double-check file exists and has reasonable size
                guard FileManager.default.fileExists(atPath: vadPath.path) else {
                    print("⚠️ VAD model file not found at: \(vadPath.path)")
                    print("   App will continue without VAD (no speech detection)")
                    return
                }

                // Verify file size
                if let attrs = try? FileManager.default.attributesOfItem(atPath: vadPath.path),
                   let size = attrs[.size] as? Int64 {
                    print("📦 VAD model found: \(String(format: "%.2f", Double(size) / 1024.0 / 1024.0)) MB")
                }

                print("🔄 Pre-loading Silero VAD...")
                let startTime = Date()

                // Load VAD model (now calls ggml_backend_load_all first)
                let vad = try SileroVAD(modelPath: vadPath)
                let loadTime = Date().timeIntervalSince(startTime)
                print("✅ Silero VAD pre-loaded in \(String(format: "%.2f", loadTime))s")

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.sileroVAD = vad
                    self.isVADLoaded = true
                }
            } catch {
                print("⚠️ Failed to load Silero VAD: \(error.localizedDescription)")
                print("   This is OK - VAD is optional for better performance")
                print("   App will work fine without speech detection")
                // VAD is completely optional, continue without it
                await MainActor.run { [weak self] in
                    self?.isVADLoaded = false
                }
            }
        }
    }

    // MARK: - State Transitions

    func startRecording() {
        guard state == .idle else { return }

        // Check if model is loaded first
        guard let bridge = whisperBridge else {
            errorMessage = "Model not loaded yet. Please wait..."
            print("⚠️ Cannot start recording - model not pre-loaded")
            return
        }

        // Capture the frontmost app BEFORE our overlay steals focus
        textInjector?.captureTargetApp()

        // INSTANT: Set state immediately so overlay appears right away
        state = .recording(startTime: Date())
        liveTranscription = ""

        // Play sound immediately (non-blocking)
        soundPlayer?.playStartSound()

        // Mute other audio sources if enabled (after sound plays)
        Task {
            // Small delay to let sound play before muting
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

            if muteOtherAudioDuringRecording {
                audioMuter?.muteSystemAudio()
            }
        }

        // Start recording immediately
        Task {
            do {
                // Create streaming transcriber with pre-loaded bridge, optional VAD, and language
                streamingTranscriber = StreamingTranscriber(whisperBridge: bridge, vad: sileroVAD, language: selectedLanguage)
                streamingTranscriber?.start { [weak self] text in
                    Task { @MainActor in
                        self?.liveTranscription = text
                    }
                }
                print("✅ Streaming transcriber initialized (VAD: \(sileroVAD != nil ? "enabled" : "disabled"))")

                // Connect audio samples to streaming transcriber
                audioRecorder?.onStreamingSamples = { [weak self] samples in
                    self?.streamingTranscriber?.addSamples(samples)
                }

                let audioURL = try await audioRecorder?.startRecording()
                currentAudioURL = audioURL
            } catch {
                errorMessage = "Failed to start recording: \(error.localizedDescription)"
                state = .idle
                // Unmute on error since we're not recording
                if muteOtherAudioDuringRecording {
                    audioMuter?.unmuteSystemAudio()
                }
            }
        }
    }

    func stopRecording() {
        guard case .recording = state else { return }

        state = .stopping

        Task {
            await audioRecorder?.stopRecording()

            // Unmute other audio sources now that recording is done
            if muteOtherAudioDuringRecording {
                audioMuter?.unmuteSystemAudio()
            }

            // Play stop sound AFTER unmuting (so user hears it)
            soundPlayer?.playStopSound()

            // Get final transcription from streaming transcriber
            var finalText = ""
            if let transcriber = streamingTranscriber {
                finalText = transcriber.stop()
                print("🎤 Final transcription: '\(finalText)'")

                // Save recording if enabled (use in-memory samples, not file)
                if saveRecordings {
                    saveRecordingFromTranscriber(transcriber, transcription: finalText)
                }
            }
            streamingTranscriber = nil

            if !finalText.isEmpty {
                print("📝 Inserting text: '\(finalText)'")
                state = .inserting(text: finalText)
                await insertText(finalText)
            } else {
                // No speech detected
                print("⚠️ No speech detected in recording")
                errorMessage = "No speech detected"
                state = .idle
            }
        }
    }

    /// Cancel recording without transcribing (e.g., Fn+key combo detected)
    /// Immediately stops recording, unmutes audio, and returns to idle state
    func cancelRecording() {
        guard case .recording = state else { return }

        Logger.debug("Recording cancelled (Fn+key combo)", subsystem: .app)

        Task {
            // Stop audio recording immediately
            await audioRecorder?.stopRecording()

            // Unmute audio
            if muteOtherAudioDuringRecording {
                audioMuter?.unmuteSystemAudio()
            }

            // Clear streaming transcriber without doing final pass
            streamingTranscriber = nil

            // Reset state
            state = .idle
            liveTranscription = ""
        }
    }

    private func saveRecordingFromTranscriber(_ transcriber: StreamingTranscriber, transcription: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = dateFormatter.string(from: Date())

        // Create safe filename from transcription (first 30 chars)
        let safeText = transcription
            .prefix(30)
            .replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")

        let fileName = safeText.isEmpty ? "\(timestamp).wav" : "\(timestamp)_\(safeText).wav"
        let destURL = recordingsDir.appendingPathComponent(fileName)

        // Save recording from in-memory samples
        if transcriber.saveRecording(to: destURL) {
            print("✅ Recording saved to: \(destURL.path)")

            // Save to history database
            Task {
                do {
                    let record = TranscriptionRecord(
                        transcription: transcription,
                        audioFileURL: fileName,
                        duration: transcriber.recordedDuration,
                        language: selectedLanguage.rawValue,
                        modelUsed: selectedModel.rawValue,
                        corrections: DictionaryManager.shared.lastCorrections
                    )
                    try await HistoryManager.shared.saveTranscription(record)
                    Logger.debug("Transcription saved to history database", subsystem: .app)
                } catch {
                    Logger.error("Failed to save transcription to history: \(error)", subsystem: .app)
                }
            }
        }
    }

    private func insertText(_ text: String) async {
        guard let textInjector = textInjector else {
            errorMessage = "Text injector not initialized"
            state = .idle
            return
        }

        // Dismiss HUD immediately — fade-out animation runs concurrently with text injection
        state = .idle
        liveTranscription = ""

        do {
            try await textInjector.insertText(text)
        } catch {
            errorMessage = "Failed to insert text: \(error.localizedDescription)"
        }
    }

    func updateWaveform(amplitude: Float) {
        // Shift array and add new amplitude
        waveformAmplitudes.removeFirst()
        waveformAmplitudes.append(amplitude)
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Cleanup for Graceful Shutdown

    /// Release all whisper-related resources before app termination
    /// This prevents crashes when C++ destructors run during exit()
    func releaseWhisperResources() {
        Logger.debug("Releasing whisper resources...", subsystem: .transcription)

        // Stop any streaming transcription
        streamingTranscriber = nil

        // Free VAD context first (smaller, faster)
        if sileroVAD != nil {
            Logger.debug("Freeing Silero VAD context", subsystem: .transcription)
            sileroVAD = nil
            isVADLoaded = false
        }

        // Free whisper context (this is the critical one that was crashing)
        if whisperBridge != nil {
            Logger.debug("Freeing WhisperBridge context", subsystem: .transcription)
            whisperBridge = nil
            loadedModel = nil
            isModelLoaded = false
        }

        Logger.debug("Whisper resources released", subsystem: .transcription)
    }
}
