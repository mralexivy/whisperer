//
//  AppState.swift
//  Whisperer
//
//  Global application state machine for recording workflow
//

import AppKit
import Combine
import FluidAudio
import Foundation

enum ActiveMode: Equatable {
    case dictation
    case rewrite
}

enum RecordingState: Equatable {
    case idle
    case recording(startTime: Date)
    case stopping
    case transcribing(audioPath: URL)
    case inserting(text: String)
    case downloadingModel(progress: Double)
    case rewriting

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
            return "Entering text..."
        case .downloadingModel(let progress):
            return "Downloading model... \(Int(progress * 100))%"
        case .rewriting:
            return "Rewriting..."
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
            if state == .idle {
                targetAppIcon = nil
                activeMode = .dictation
                activeAIModeName = nil
                capturedSelectedText = nil
                isHandsFreeRecording = false
                showHandsFreeToast = false
                isMicMuted = false
                isPaused = false
            }
        }
    }
    @Published var waveformAmplitudes: [Float] = Array(repeating: 0, count: 20)
    @Published var errorMessage: String?
    @Published var saveRecordings: Bool = true  // Save recordings by default
    @Published var liveTranscription: String = ""  // Live transcription during recording
    @Published var recordingSessionID: UUID = UUID()  // Forces SwiftUI state reset between recordings

    // Latest committed transcript for macOS Services provider
    private(set) var lastTranscribedText: String = ""
    private(set) var lastTranscriptionDate: Date?
    @Published var muteOtherAudioDuringRecording: Bool = true {  // Mute other audio sources during recording
        didSet {
            UserDefaults.standard.set(muteOtherAudioDuringRecording, forKey: "muteOtherAudioDuringRecording")
        }
    }
    @Published var liveTranscriptionEnabled: Bool = true {  // Show live transcription preview during recording
        didSet {
            UserDefaults.standard.set(liveTranscriptionEnabled, forKey: "liveTranscriptionEnabled")
        }
    }

    // Prompt words — biases recognition toward specific vocabulary
    // Whisper: passed as initial_prompt. Parakeet: fed into CTC vocabulary boosting.
    @Published var promptWords: [String] = [] {
        didSet {
            UserDefaults.standard.set(promptWords, forKey: "promptWords")
            reconfigureVocabularyBoosting()
        }
    }
    @Published var promptWordsEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(promptWordsEnabled, forKey: "promptWordsEnabled")
            reconfigureVocabularyBoosting()
        }
    }

    /// Assembled prompt words string for whisper.cpp initial_prompt.
    /// Formatted as a simple comma-separated list — whisper treats this as "previous context"
    /// and biases recognition toward these words.
    var promptWordsString: String? {
        guard promptWordsEnabled, !promptWords.isEmpty else { return nil }
        return promptWords.joined(separator: ", ")
    }

    /// Approximate token count for prompt words (~4 characters per token, including ", " separators)
    var promptWordsTokenCount: Int {
        guard !promptWords.isEmpty else { return 0 }
        let totalChars = promptWords.joined(separator: ", ").count
        return max(1, (totalChars + 3) / 4)  // ceil(totalChars / 4)
    }

    /// Whisper initial_prompt hard limit: 224 tokens (model architecture constraint)
    static let maxPromptWordsTokens = 224

    // System-wide dictation opt-in (default OFF for App Store compliance)
    @Published var systemWideDictationEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(systemWideDictationEnabled, forKey: "systemWideDictationEnabled")
            if systemWideDictationEnabled {
                startGlobalDictation()
            } else {
                stopGlobalDictation()
            }
        }
    }

    #if !APP_STORE
    // Auto-paste opt-in — when enabled, uses Accessibility to simulate Cmd+V.
    // When disabled, transcribed text is copied to clipboard only.
    @Published var autoPasteEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(autoPasteEnabled, forKey: "autoPasteEnabled")
            if autoPasteEnabled {
                PermissionManager.shared.enableAccessibilityTracking()
            } else {
                PermissionManager.shared.disableAccessibilityTracking()
            }
        }
    }
    #endif

    // In-app transcription mode (no Accessibility required)
    @Published var isInAppMode: Bool = false
    @Published var lastInAppTranscription: String = ""

    // Onboarding
    @Published var hasCompletedOnboarding: Bool = false {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
        }
    }

    // Language selection for transcription
    @Published var selectedLanguage: TranscriptionLanguage = .english {
        didSet {
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: "selectedLanguage")

            // SpeechAnalyzer needs re-prepare for new locale (model download may be required)
            if selectedBackendType == .speechAnalyzer && isModelLoaded && oldValue != selectedLanguage {
                Logger.info("Language changed to \(selectedLanguage.displayName), re-preparing SpeechAnalyzer", subsystem: .model)
                releaseCurrentBridge()
                preloadSpeechAnalyzer()
            }
        }
    }

    // Model selection
    @Published var selectedModel: WhisperModel = .largeTurboQ5
    @Published var downloadingModel: WhisperModel? = nil
    @Published var downloadProgress: Double = 0
    @Published var downloadRetryInfo: String?

    // Component references
    var audioRecorder: AudioRecorder?
    var keyListener: GlobalKeyListener?
    var whisperRunner: WhisperRunner?
    var textInjector: TextInjector?
    var audioMuter: AudioMuter?
    var soundPlayer: SoundPlayer?

    // Audio device management
    let audioDeviceManager = AudioDeviceManager.shared

    // Main-thread watchdog: forces state to .idle if stuck in .recording/.stopping.
    // Uses DispatchSourceTimer on the main RunLoop — independent of Swift cooperative thread pool.
    private var stateWatchdog: DispatchSourceTimer?
    private var lastStopActivityTime: Date?
    private var stopWatchdogStartTime: Date?

    // Pre-loaded transcription backend - keeps model in memory for instant recording start
    private var whisperBridge: TranscriptionBackend?

    /// Read-only access to the pre-loaded backend for file transcription
    var fileTranscriptionBridge: TranscriptionBackend? { whisperBridge }

    /// Selected transcription backend engine
    @Published var selectedBackendType: BackendType = .whisperCpp
    @Published var selectedParakeetModel: ParakeetModelVariant = .v3

    /// Cached Apple Speech supported language codes (populated after SpeechAnalyzer prepares)
    @Published private(set) var speechAnalyzerSupportedLanguageCodes: Set<String> = []

    /// User-facing hint when the selected language isn't supported by the current backend
    var languageCompatibilityHint: String? {
        guard selectedLanguage != .auto else { return nil }
        guard !selectedBackendType.supportsLanguage(
            selectedLanguage,
            parakeetVariant: selectedParakeetModel,
            speechAnalyzerLanguageCodes: speechAnalyzerSupportedLanguageCodes
        ) else { return nil }

        switch selectedBackendType {
        case .whisperCpp: return nil
        case .parakeet:
            return selectedParakeetModel == .v2
                ? "Parakeet v2 supports English only — language will be ignored"
                : "\(selectedLanguage.displayName) isn't supported by Parakeet — language will be auto-detected"
        case .speechAnalyzer:
            return "\(selectedLanguage.displayName) isn't available in Apple Speech — will use system language"
        }
    }

    /// Display name of the model actively used for transcription (for history records)
    var activeModelDisplayName: String {
        switch loadedBackendType ?? selectedBackendType {
        case .whisperCpp: return selectedModel.displayName
        case .parakeet: return selectedParakeetModel.displayName
        case .speechAnalyzer: return "Apple Speech"
        }
    }
    private var loadedModel: WhisperModel? = nil
    private var loadedParakeetModel: ParakeetModelVariant? = nil
    @Published var isModelLoaded: Bool = false {
        didSet {
            if isModelLoaded { showModelLoadingToast = false }
        }
    }
    @Published var showModelLoadingToast: Bool = false {
        didSet {
            NotificationCenter.default.post(name: NSNotification.Name("AppStateChanged"), object: nil)
        }
    }
    @Published var showClipboardToast: Bool = false {
        didSet {
            NotificationCenter.default.post(name: NSNotification.Name("AppStateChanged"), object: nil)
        }
    }
    @Published var isHandsFreeRecording: Bool = false
    @Published var isMicMuted: Bool = false
    @Published var isPaused: Bool = false  // Pause recording (soft pause — engine runs, samples discarded)
    @Published var isOutputAudioMuted: Bool = true  // Runtime toggle for system audio mute during recording
    @Published var showHandsFreeToast: Bool = false {
        didSet {
            NotificationCenter.default.post(name: NSNotification.Name("AppStateChanged"), object: nil)
        }
    }
    /// Which backend type is currently loaded (may differ from selectedBackendType while browsing tabs)
    @Published var loadedBackendType: BackendType? = nil

    // Whisper model load state
    @Published var isLoadingWhisper: Bool = false
    private var whisperLoadTask: Task<Void, Never>?

    // Parakeet model download/load state
    @Published var isDownloadingParakeet: Bool = false
    @Published var isLoadingParakeet: Bool = false
    @Published var parakeetDownloadStatus: String = ""
    private var parakeetLoadTask: Task<Void, Never>?

    // Parakeet EOU (streaming live preview) download/load state
    @Published var isDownloadingEou: Bool = false
    @Published var eouDownloadProgress: Double = 0
    @Published var eouDownloadStatus: String = ""
    // LivePreviewEngine removed — StreamingTranscriber.onTranscription provides live preview directly

    // SpeechAnalyzer (macOS 26+) load state
    @Published var isLoadingSpeechAnalyzer: Bool = false
    @Published var speechAnalyzerStatus: String = ""
    private var speechAnalyzerLoadTask: Task<Void, Never>?

    /// True when any model download or load is in progress — blocks model selection UI
    var isModelBusy: Bool {
        downloadingModel != nil ||
        isLoadingWhisper ||
        isDownloadingParakeet ||
        isLoadingParakeet ||
        isDownloadingEou ||
        isLoadingSpeechAnalyzer
    }

    // LLM post-processing
    @Published var llmEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(llmEnabled, forKey: "llmEnabled")
            if llmEnabled {
                preloadLLM()
            } else {
                let memBefore = BenchmarkUtilities.currentMemoryMB()
                llmPostProcessor?.unloadModel()
                llmPostProcessor = nil
                rewriteModeService = nil
                Logger.info("LLM disabled, unloaded (process memory: \(String(format: "%.0f", memBefore))MB)", subsystem: .model)
            }
        }
    }
    @Published var selectedLLMModel: LLMModelVariant = .qwen3_5_4B {
        didSet {
            UserDefaults.standard.set(selectedLLMModel.rawValue, forKey: "selectedLLMModel")
            if llmEnabled {
                // Unload old model — delay before loading new one to let ARC release GPU buffers
                let memBefore = BenchmarkUtilities.currentMemoryMB()
                Logger.info("Switching LLM: unloading old model (\(String(format: "%.0f", memBefore))MB)", subsystem: .model)
                llmPostProcessor?.unloadModel()
                llmPostProcessor = nil
                rewriteModeService = nil

                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms for ARC to release GPU buffers
                    guard let self, self.llmEnabled else { return }
                    let memAfter = BenchmarkUtilities.currentMemoryMB()
                    Logger.info("LLM unload freed \(String(format: "%.0f", memBefore - memAfter))MB, loading new model", subsystem: .model)
                    self.preloadLLM()
                }
            }
        }
    }
    @Published var llmPostProcessor: LLMPostProcessor?
    @Published var activeAIModeName: String?

    // Filler word removal (strips "um", "uh", "er" from final output)
    @Published var fillerWordRemovalEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(fillerWordRemovalEnabled, forKey: "fillerWordRemovalEnabled")
        }
    }

    // List formatting (detects and formats spoken numbered/bulleted lists)
    @Published var listFormattingEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(listFormattingEnabled, forKey: "listFormattingEnabled")
        }
    }
    @Published var listFormattingAIEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(listFormattingAIEnabled, forKey: "listFormattingAIEnabled")
        }
    }

    // Add a trailing space after inserted transcription so the cursor is ready for the next word
    @Published var appendTrailingSpace: Bool = false {
        didSet {
            UserDefaults.standard.set(appendTrailingSpace, forKey: "appendTrailingSpace")
        }
    }

    private var dictionaryRebuildObserver: Any?
    private var appActivationObserver: Any?
    private var clipboardNotificationObserver: Any?

    // Pre-loaded Silero VAD for voice activity detection
    private var sileroVAD: SileroVAD?
    @Published var isVADLoaded: Bool = false

    // Streaming transcription
    private var streamingTranscriber: StreamingTranscriber?

    // Language routing
    private var modelPool: ModelPool?
    @Published var routingConfig: LanguageRoutingConfig = .load() {
        didSet {
            // Re-initialize routing infrastructure when config changes
            if routingConfig.isRoutingEnabled != oldValue.isRoutingEnabled ||
               routingConfig.allowedLanguages != oldValue.allowedLanguages {
                if routingConfig.isRoutingEnabled {
                    Logger.info("Routing config changed, re-initializing language routing", subsystem: .model)
                    preloadLanguageRouting()
                } else {
                    Logger.info("Routing disabled, releasing model pool", subsystem: .model)
                    modelPool?.releaseAll()
                    modelPool = nil
                }
            }
        }
    }
    @Published var activeRouteInfo: String?
    @Published var isLiveTranscriptionRTL: Bool = false

    private var currentAudioURL: URL?
    private var lastTargetAppName: String?
    @Published var targetAppIcon: NSImage?

    // Rewrite mode
    @Published var activeMode: ActiveMode = .dictation
    #if !APP_STORE
    var textSelectionService: TextSelectionService?
    #endif
    var rewriteModeService: RewriteModeService?
    private var capturedSelectedText: String?

    // Model path for selected whisper.cpp model
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

        // Load live transcription preference (default true if not set)
        if UserDefaults.standard.object(forKey: "liveTranscriptionEnabled") != nil {
            liveTranscriptionEnabled = UserDefaults.standard.bool(forKey: "liveTranscriptionEnabled")
        }

        // Load language preference (default English)
        if let savedLang = UserDefaults.standard.string(forKey: "selectedLanguage"),
           let lang = TranscriptionLanguage(rawValue: savedLang) {
            selectedLanguage = lang
        }

        // Load system-wide dictation preference (default OFF)
        if UserDefaults.standard.object(forKey: "systemWideDictationEnabled") != nil {
            // Use _systemWideDictationEnabled to avoid triggering didSet during init
            _systemWideDictationEnabled = Published(wrappedValue: UserDefaults.standard.bool(forKey: "systemWideDictationEnabled"))
        }

        #if !APP_STORE
        // Load auto-paste preference (default OFF)
        if UserDefaults.standard.object(forKey: "autoPasteEnabled") != nil {
            _autoPasteEnabled = Published(wrappedValue: UserDefaults.standard.bool(forKey: "autoPasteEnabled"))
        }

        // Enable accessibility tracking if auto-paste was previously enabled
        if autoPasteEnabled {
            PermissionManager.shared.enableAccessibilityTracking()
        }
        #endif

        // Load onboarding state
        if UserDefaults.standard.object(forKey: "hasCompletedOnboarding") != nil {
            _hasCompletedOnboarding = Published(wrappedValue: UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"))
        }

        // Load backend type and Parakeet model selection
        if let savedBackend = UserDefaults.standard.string(forKey: "selectedBackendType"),
           let backend = BackendType(rawValue: savedBackend) {
            // Migrate old "MLX" backend to Parakeet
            selectedBackendType = backend
        } else if UserDefaults.standard.string(forKey: "selectedBackendType") == "MLX" {
            selectedBackendType = .parakeet
            UserDefaults.standard.set(BackendType.parakeet.rawValue, forKey: "selectedBackendType")
        }
        if let savedParakeet = UserDefaults.standard.string(forKey: "selectedParakeetModel"),
           let parakeetModel = ParakeetModelVariant(rawValue: savedParakeet) {
            selectedParakeetModel = parakeetModel
        }

        // Load LLM settings
        if UserDefaults.standard.object(forKey: "llmEnabled") != nil {
            _llmEnabled = Published(wrappedValue: UserDefaults.standard.bool(forKey: "llmEnabled"))
        }
        if let savedLLMModel = UserDefaults.standard.string(forKey: "selectedLLMModel"),
           let llmModel = LLMModelVariant(rawValue: savedLLMModel) {
            _selectedLLMModel = Published(wrappedValue: llmModel)
        }
        // Initialize AIModeManager (triggers migration from legacy LLMTask/PromptProfile)
        _ = AIModeManager.shared

        // Load prompt words
        if let savedPromptWords = UserDefaults.standard.stringArray(forKey: "promptWords") {
            _promptWords = Published(wrappedValue: savedPromptWords)
        }
        if UserDefaults.standard.object(forKey: "promptWordsEnabled") != nil {
            _promptWordsEnabled = Published(wrappedValue: UserDefaults.standard.bool(forKey: "promptWordsEnabled"))
        }

        // Load filler word, list formatting, and trailing space settings
        if UserDefaults.standard.object(forKey: "fillerWordRemovalEnabled") != nil {
            _fillerWordRemovalEnabled = Published(wrappedValue: UserDefaults.standard.bool(forKey: "fillerWordRemovalEnabled"))
        }
        if UserDefaults.standard.object(forKey: "listFormattingEnabled") != nil {
            _listFormattingEnabled = Published(wrappedValue: UserDefaults.standard.bool(forKey: "listFormattingEnabled"))
        }
        if UserDefaults.standard.object(forKey: "listFormattingAIEnabled") != nil {
            _listFormattingAIEnabled = Published(wrappedValue: UserDefaults.standard.bool(forKey: "listFormattingAIEnabled"))
        }
        if UserDefaults.standard.object(forKey: "appendTrailingSpace") != nil {
            _appendTrailingSpace = Published(wrappedValue: UserDefaults.standard.bool(forKey: "appendTrailingSpace"))
        }

        // Observe dictionary rebuilds to reconfigure CTC vocabulary boosting
        dictionaryRebuildObserver = NotificationCenter.default.addObserver(
            forName: .dictionaryDidRebuild, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reconfigureVocabularyBoosting()
        }

        #if !APP_STORE
        // Recheck accessibility when app becomes active (user returns from System Settings)
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard self != nil else { return }
            Task { @MainActor in
                PermissionManager.shared.recheckAccessibilityIfNeeded()
            }
        }
        #endif

        // Show clipboard toast when text is copied
        clipboardNotificationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TextCopiedToClipboard"), object: nil, queue: .main
        ) { [weak self] _ in
            guard self != nil else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.showClipboardToast = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.showClipboardToast = false
                }
            }
        }

        // Start monitoring audio device changes (for UI device picker only)
        audioDeviceManager.startMonitoring()
    }

    // MARK: - Prompt Words

    /// Add a prompt word if under the token limit. Returns false if rejected (duplicate, empty, or over limit).
    func addPromptWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Check for duplicates (case-insensitive)
        guard !promptWords.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            Logger.debug("Prompt word '\(trimmed)' already exists", subsystem: .transcription)
            return false
        }

        // Check token limit (~4 chars per token, account for ", " separator)
        let separatorChars = promptWords.isEmpty ? 0 : 2  // ", " before new word
        let newChars = trimmed.count + separatorChars
        let currentChars = promptWords.isEmpty ? 0 : promptWords.joined(separator: ", ").count
        let newTokenCount = max(1, (currentChars + newChars + 3) / 4)
        guard newTokenCount <= Self.maxPromptWordsTokens else {
            Logger.warning("Prompt word limit reached (\(promptWordsTokenCount)/\(Self.maxPromptWordsTokens) tokens)", subsystem: .transcription)
            return false
        }

        promptWords.append(trimmed)
        Logger.info("Added prompt word: '\(trimmed)' (\(promptWordsTokenCount)/\(Self.maxPromptWordsTokens) tokens)", subsystem: .transcription)
        return true
    }

    /// Remove a prompt word by value
    func removePromptWord(_ word: String) {
        promptWords.removeAll { $0 == word }
        Logger.debug("Removed prompt word: '\(word)'", subsystem: .transcription)
    }

    // MARK: - Model Selection

    /// Check if a model is downloaded
    func isModelDownloaded(_ model: WhisperModel) -> Bool {
        ModelDownloader.shared.isModelDownloaded(model)
    }

    /// Select a model (must be downloaded first)
    func selectModel(_ model: WhisperModel) {
        guard state == .idle else { return }

        guard isModelDownloaded(model) else {
            Logger.warning("Cannot select model \(model.displayName) - not downloaded", subsystem: .model)
            return
        }

        guard model != selectedModel || loadedModel != model else {
            Logger.debug("Model \(model.displayName) already selected", subsystem: .model)
            return
        }

        selectedModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "selectedModel")
        Logger.info("Switched to model: \(model.displayName)", subsystem: .model)

        // Auto-set language for language-restricted models
        if let requiredLanguage = model.supportedLanguage {
            selectedLanguage = requiredLanguage
        }

        // Release any existing bridge (may be from a different backend)
        releaseCurrentBridge()
        preloadModel()
    }

    /// Select a Parakeet model variant
    func selectParakeetModel(_ model: ParakeetModelVariant) {
        guard state == .idle else { return }

        guard model != selectedParakeetModel || loadedParakeetModel != model else {
            Logger.info("Parakeet \(model.displayName) already selected", subsystem: .model)
            return
        }

        selectedParakeetModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "selectedParakeetModel")
        Logger.info("Switched to Parakeet model: \(model.displayName)", subsystem: .model)

        // Cancel any in-flight Parakeet load
        parakeetLoadTask?.cancel()
        parakeetLoadTask = nil

        // Release any existing bridge (may be from a different backend)
        releaseCurrentBridge()
        preloadModel()
    }

    /// Switch the active transcription backend
    func selectBackend(_ backend: BackendType) {
        guard state == .idle else { return }
        guard backend != selectedBackendType else { return }

        // Release current bridge and all satellite resources BEFORE switching
        releaseCurrentBridge()

        selectedBackendType = backend
        UserDefaults.standard.set(backend.rawValue, forKey: "selectedBackendType")
        Logger.info("Switched backend to \(backend.displayName)", subsystem: .model)

        preloadModel()
    }

    /// Release the active transcription bridge and all satellite resources (EOU, VAD, CTC)
    private func releaseCurrentBridge() {
        let memBefore = BenchmarkUtilities.currentMemoryMB()

        // Cancel in-flight load tasks to prevent them from setting whisperBridge after we nil it
        whisperLoadTask?.cancel()
        whisperLoadTask = nil
        parakeetLoadTask?.cancel()
        parakeetLoadTask = nil
        speechAnalyzerLoadTask?.cancel()
        speechAnalyzerLoadTask = nil

        // DON'T release LivePreviewEngine here — it's backend-agnostic and
        // reloading CoreML models on every backend switch leaks compiled model cache.
        // EOU is only released in releaseWhisperResources() (app shutdown).

        // Release SileroVAD (~2MB)
        if sileroVAD != nil {
            sileroVAD = nil
            isVADLoaded = false
            Logger.debug("Released SileroVAD during bridge release", subsystem: .model)
        }

        guard let bridge = whisperBridge else { return }

        let backendName = loadedBackendType?.displayName ?? selectedBackendType.displayName
        bridge.prepareForShutdown()

        // Release SpeechAnalyzer reserved locales
        if #available(macOS 26.0, *), let saBridge = bridge as? SpeechAnalyzerBridge {
            Task.detached { [weak saBridge] in
                await saBridge?.clearCache()
            }
        }

        whisperBridge = nil
        loadedModel = nil
        loadedParakeetModel = nil
        isModelLoaded = false
        loadedBackendType = nil

        // Deferred measurement — ARC needs time to deallocate the bridge and free MLModel/Metal resources
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms for ARC
            let memAfter = BenchmarkUtilities.currentMemoryMB()
            Logger.info("Released \(backendName) bridge: \(String(format: "%.0f", memBefore))MB → \(String(format: "%.0f", memAfter))MB (freed \(String(format: "%.0f", memBefore - memAfter))MB)", subsystem: .model)
        }
    }

    /// Download a model
    func downloadModel(_ model: WhisperModel) async {
        guard downloadingModel == nil else {
            Logger.warning("Already downloading a model", subsystem: .model)
            return
        }

        guard !isModelDownloaded(model) else {
            Logger.debug("Model \(model.displayName) already downloaded", subsystem: .model)
            selectModel(model)
            return
        }

        downloadingModel = model
        downloadProgress = 0
        downloadRetryInfo = nil
        state = .downloadingModel(progress: 0)

        do {
            try await ModelDownloader.shared.downloadModel(model, progressCallback: { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                    self?.state = .downloadingModel(progress: progress)
                }
            }, retryStatusCallback: { [weak self] attempt, maxAttempts in
                Task { @MainActor in
                    self?.downloadRetryInfo = "Retrying download (\(attempt)/\(maxAttempts))..."
                }
            })

            Logger.info("Downloaded \(model.displayName)", subsystem: .model)
            downloadingModel = nil
            downloadProgress = 0
            downloadRetryInfo = nil
            state = .idle

            // Auto-select the newly downloaded model (only if still on Whisper backend)
            guard selectedBackendType == .whisperCpp else {
                Logger.info("Backend switched during download, skipping auto-select of \(model.displayName)", subsystem: .model)
                return
            }
            selectModel(model)
        } catch {
            // Check if this was a user cancellation (downloadingModel already cleared by cancelModelDownload)
            let wasCancelled = downloadingModel == nil ||
                (error as? URLError)?.code == .cancelled ||
                (error as NSError).code == NSURLErrorCancelled

            if wasCancelled {
                Logger.info("Download was cancelled, not showing error", subsystem: .model)
            } else {
                Logger.error("Failed to download \(model.displayName): \(error)", subsystem: .model)
                errorMessage = "Failed to download \(model.displayName): \(error.localizedDescription)"
            }

            downloadingModel = nil
            downloadProgress = 0
            downloadRetryInfo = nil
            state = .idle
        }
    }

    /// Cancel the current model download and return to idle state
    func cancelModelDownload() {
        guard downloadingModel != nil else { return }
        Logger.info("Model download cancelled by user", subsystem: .model)

        // Actually cancel the URLSession download task
        ModelDownloader.shared.cancelCurrentDownload()

        // Clean up partial file if exists
        if let model = downloadingModel {
            let partialPath = ModelDownloader.shared.modelPath(for: model)
            try? FileManager.default.removeItem(at: partialPath)
        }

        downloadingModel = nil
        downloadProgress = 0
        downloadRetryInfo = nil
        state = .idle
    }

    // MARK: - Model Loading

    /// Pre-load the Whisper model into memory for instant recording start
    /// Call this once after model download completes
    func preloadModel() {
        switch selectedBackendType {
        case .whisperCpp:
            preloadWhisperCppModel()
        case .parakeet:
            preloadParakeetModel()
        case .speechAnalyzer:
            preloadSpeechAnalyzer()
        }
    }

    private func preloadWhisperCppModel() {
        let model = selectedModel
        let path = modelPath

        guard FileManager.default.fileExists(atPath: path.path) else {
            Logger.warning("Model file not found, cannot preload: \(path.path)", subsystem: .model)
            return
        }

        // Memory safety check — warn if available memory is low for this model
        let availableGB = SystemMemory.availableGB()
        let requiredGB = model.requiredMemoryGB
        if availableGB < requiredGB {
            Logger.warning("Low memory for \(model.displayName): available \(String(format: "%.1f", availableGB)) GB, required \(String(format: "%.1f", requiredGB)) GB", subsystem: .model)
            errorMessage = "Low memory for \(model.displayName). Required: \(String(format: "%.1f", requiredGB)) GB, Available: \(String(format: "%.1f", availableGB)) GB. Consider a smaller model."
        }

        guard whisperBridge == nil || loadedModel != model else {
            Logger.info("Model \(model.displayName) already loaded", subsystem: .model)
            isModelLoaded = true
            loadedBackendType = .whisperCpp
            isLoadingWhisper = false
            preloadVAD()
            return
        }

        // Cancel any in-flight Whisper load
        whisperLoadTask?.cancel()

        let modelDisplayName = model.displayName
        Logger.info("Pre-loading \(modelDisplayName)...", subsystem: .model)
        isLoadingWhisper = true
        let startTime = Date()

        // Download Core ML encoder in background (for ANE acceleration)
        Task.detached(priority: .utility) {
            do {
                try await ModelDownloader.shared.ensureCoreMLEncoder(for: model)
            } catch {
                Logger.debug("Core ML encoder not available for \(modelDisplayName): \(error)", subsystem: .model)
            }
        }

        whisperLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let bridge = try WhisperBridge(modelPath: path)

                guard !Task.isCancelled else { return }

                // Warm up Metal GPU shaders
                let warmupSamples = [Float](repeating: 0, count: 16000)
                _ = bridge.transcribe(samples: warmupSamples)

                guard !Task.isCancelled else { return }

                let loadTime = Date().timeIntervalSince(startTime)
                Logger.info("\(modelDisplayName) pre-loaded in \(String(format: "%.2f", loadTime))s (includes GPU warm-up)", subsystem: .model)

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    guard self.selectedModel == model else { return }

                    // Safety: release any existing bridge that might still be loaded
                    if let old = self.whisperBridge {
                        old.prepareForShutdown()
                        self.whisperBridge = nil
                        Logger.warning("Safety release of existing bridge during Whisper preload", subsystem: .model)
                    }

                    self.whisperBridge = bridge
                    self.loadedModel = model
                    self.loadedParakeetModel = nil
                    self.isModelLoaded = true
                    self.loadedBackendType = .whisperCpp
                    self.isLoadingWhisper = false
                    self.preloadVAD()
                    self.preloadLanguageRouting()

                    Logger.info("Whisper model loaded. Process memory: \(String(format: "%.0f", BenchmarkUtilities.currentMemoryMB()))MB", subsystem: .model)
                }
            } catch {
                guard !Task.isCancelled else { return }
                Logger.error("Failed to pre-load \(modelDisplayName): \(error)", subsystem: .model)
                await MainActor.run { [weak self] in
                    self?.isLoadingWhisper = false
                    self?.errorMessage = "Failed to load \(modelDisplayName): \(error.localizedDescription)"
                }
            }
        }
    }

    /// Check if Parakeet model is already downloaded
    func isParakeetModelCached(_ variant: ParakeetModelVariant? = nil) -> Bool {
        FluidAudioBridge.isModelCached(variant: variant ?? selectedParakeetModel)
    }

    /// Download Parakeet model (separate from loading)
    func downloadParakeetModel(_ variant: ParakeetModelVariant? = nil) {
        let variant = variant ?? selectedParakeetModel
        guard !isDownloadingParakeet else { return }

        isDownloadingParakeet = true
        parakeetDownloadStatus = "Downloading \(variant.displayName)..."
        downloadProgress = 0
        state = .downloadingModel(progress: 0)

        // Poll the download directory to track file-level progress.
        // FluidAudio's DownloadUtils doesn't expose a progress callback,
        // so we count files appearing on disk vs the expected total.
        let cacheDir = FluidAudioBridge.cacheDirectory(for: variant)
        let progressTask = Task.detached(priority: .utility) { [weak self] in
            // Expected file count for Parakeet models (4 .mlmodelc dirs + vocab + metadata)
            // Each .mlmodelc dir contains ~4-5 files. The HF API reports ~23 total files.
            let expectedFileCount = 23
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                let fileCount = Self.countFilesRecursively(at: cacheDir)
                let progress = min(Double(fileCount) / Double(expectedFileCount), 0.95)
                await MainActor.run { [weak self] in
                    guard let self, self.isDownloadingParakeet else { return }
                    self.downloadProgress = progress
                    self.state = .downloadingModel(progress: progress)
                }
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await FluidAudioBridge.downloadModel(variant: variant)
                progressTask.cancel()
                Logger.info("Parakeet \(variant.displayName) downloaded", subsystem: .model)

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.isDownloadingParakeet = false
                    self.parakeetDownloadStatus = ""
                    self.downloadProgress = 0
                    self.state = .idle

                    // Auto-load after download if this is the active backend
                    if self.selectedBackendType == .parakeet && self.selectedParakeetModel == variant {
                        self.preloadParakeetModel()
                    }
                }
            } catch {
                progressTask.cancel()
                Logger.error("Failed to download Parakeet \(variant.displayName): \(error)", subsystem: .model)
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.isDownloadingParakeet = false
                    self.parakeetDownloadStatus = ""
                    self.downloadProgress = 0
                    self.state = .idle
                    self.errorMessage = "Failed to download Parakeet: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Count files recursively in a directory (for download progress tracking)
    private nonisolated static func countFilesRecursively(at url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let fileURL as URL in enumerator {
            if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                count += 1
            }
        }
        return count
    }

    // LivePreviewEngine + Parakeet EOU removed — live preview comes from StreamingTranscriber.onTranscription

    private func preloadParakeetModel() {
        let variant = selectedParakeetModel

        guard whisperBridge == nil || loadedParakeetModel != variant else {
            Logger.info("Parakeet \(variant.displayName) already loaded", subsystem: .model)
            isModelLoaded = true
            loadedBackendType = .parakeet
            isLoadingParakeet = false
            preloadVAD()
            return
        }

        // Check if model is cached — if not, download first
        guard isParakeetModelCached(variant) else {
            Logger.info("Parakeet \(variant.displayName) not cached, starting download...", subsystem: .model)
            downloadParakeetModel(variant)
            return
        }

        // Cancel any previous load task
        parakeetLoadTask?.cancel()

        Logger.info("Pre-loading Parakeet \(variant.displayName)...", subsystem: .model)
        isLoadingParakeet = true
        parakeetDownloadStatus = "Loading \(variant.displayName)..."
        let startTime = Date()

        parakeetLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let bridge = try await FluidAudioBridge.loadFromCache(variant: variant)

                guard !Task.isCancelled else { return }

                // Warm up both ANE/CoreML managers (streaming + final pass)
                let warmupSamples = [Float](repeating: 0, count: 16000)

                // Warm up streaming manager
                bridge.setMode(.streaming)
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    bridge.transcribeAsync(
                        samples: warmupSamples,
                        initialPrompt: nil,
                        language: .auto,
                        singleSegment: false,
                        maxTokens: 0
                    ) { _ in
                        continuation.resume()
                    }
                }

                guard !Task.isCancelled else { return }

                // Warm up final-pass manager
                bridge.setMode(.finalPass)
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    bridge.transcribeAsync(
                        samples: warmupSamples,
                        initialPrompt: nil,
                        language: .auto,
                        singleSegment: false,
                        maxTokens: 0
                    ) { _ in
                        continuation.resume()
                    }
                }
                bridge.setMode(.streaming)

                guard !Task.isCancelled else { return }

                let loadTime = Date().timeIntervalSince(startTime)
                Logger.info("Parakeet \(variant.displayName) pre-loaded in \(String(format: "%.2f", loadTime))s (dual manager, ANE warm-up)", subsystem: .model)

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    // Verify this is still the selected model (user may have switched)
                    guard self.selectedParakeetModel == variant else { return }

                    // Safety: release any existing bridge that might still be loaded
                    if let old = self.whisperBridge {
                        old.prepareForShutdown()
                        self.whisperBridge = nil
                        Logger.warning("Safety release of existing bridge during Parakeet preload", subsystem: .model)
                    }

                    self.whisperBridge = bridge
                    self.loadedModel = nil
                    self.loadedParakeetModel = variant
                    self.isModelLoaded = true
                    self.loadedBackendType = .parakeet
                    self.isLoadingParakeet = false
                    self.parakeetDownloadStatus = ""
                    self.preloadVAD()

                    Logger.info("Parakeet model loaded. Process memory: \(String(format: "%.0f", BenchmarkUtilities.currentMemoryMB()))MB", subsystem: .model)

                    // Configure CTC vocabulary boosting on the final-pass manager
                    self.configureVocabularyBoostingOnBridge(bridge, variant: variant)
                }
            } catch {
                guard !Task.isCancelled else { return }
                Logger.error("Failed to pre-load Parakeet \(variant.displayName): \(error)", subsystem: .model)
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.isLoadingParakeet = false
                    self.parakeetDownloadStatus = ""
                    self.errorMessage = "Failed to load Parakeet: \(error.localizedDescription)"
                }
            }
        }
    }

    private func preloadSpeechAnalyzer() {
        guard #available(macOS 26.0, *) else {
            Logger.warning("SpeechAnalyzer requires macOS 26+", subsystem: .model)
            return
        }

        guard whisperBridge == nil else {
            Logger.info("SpeechAnalyzer already loaded", subsystem: .model)
            isModelLoaded = true
            loadedBackendType = .speechAnalyzer
            preloadVAD()
            return
        }

        // Cancel any previous load task
        speechAnalyzerLoadTask?.cancel()

        Logger.info("Pre-loading Apple SpeechAnalyzer...", subsystem: .model)
        isLoadingSpeechAnalyzer = true
        speechAnalyzerStatus = "Preparing Apple Speech..."
        let startTime = Date()
        let language = selectedLanguage

        speechAnalyzerLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let locale = language.locale ?? Locale.current
                let bridge = try await SpeechAnalyzerBridge.prepare(locale: locale) { progress in
                    Task { @MainActor [weak self] in
                        self?.speechAnalyzerStatus = "Downloading model... \(Int(progress * 100))%"
                    }
                }

                guard !Task.isCancelled else { return }

                let loadTime = Date().timeIntervalSince(startTime)
                Logger.info("SpeechAnalyzer pre-loaded in \(String(format: "%.2f", loadTime))s", subsystem: .model)

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    guard self.selectedBackendType == .speechAnalyzer else { return }

                    // Safety: release any existing bridge that might still be loaded
                    if let old = self.whisperBridge {
                        old.prepareForShutdown()
                        self.whisperBridge = nil
                        Logger.warning("Safety release of existing bridge during SpeechAnalyzer preload", subsystem: .model)
                    }

                    self.whisperBridge = bridge
                    self.speechAnalyzerSupportedLanguageCodes = bridge.supportedLanguageCodes
                    self.loadedModel = nil
                    self.loadedParakeetModel = nil
                    self.isModelLoaded = true
                    self.loadedBackendType = .speechAnalyzer
                    self.isLoadingSpeechAnalyzer = false
                    self.speechAnalyzerStatus = ""
                    self.preloadVAD()

                    Logger.info("SpeechAnalyzer loaded. Process memory: \(String(format: "%.0f", BenchmarkUtilities.currentMemoryMB()))MB", subsystem: .model)
                }
            } catch {
                guard !Task.isCancelled else { return }
                Logger.error("Failed to pre-load SpeechAnalyzer: \(error)", subsystem: .model)
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.isLoadingSpeechAnalyzer = false
                    self.speechAnalyzerStatus = ""
                    self.errorMessage = "Failed to load Apple Speech: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Pre-load the LLM model if enabled
    func preloadLLM() {
        guard llmEnabled else { return }

        let processor = llmPostProcessor ?? LLMPostProcessor()
        llmPostProcessor = processor

        // Skip if already loading or the correct model is loaded
        if processor.isLoading { return }

        let variant = selectedLLMModel

        let memBefore = BenchmarkUtilities.currentMemoryMB()
        Task {
            do {
                try await processor.loadModel(variant)
                let memAfter = BenchmarkUtilities.currentMemoryMB()
                Logger.info("LLM \(variant.displayName) pre-loaded. Process memory: \(String(format: "%.0f", memBefore))MB → \(String(format: "%.0f", memAfter))MB (+\(String(format: "%.0f", memAfter - memBefore))MB)", subsystem: .model)
            } catch {
                Logger.error("Failed to pre-load LLM \(variant.displayName): \(error)", subsystem: .model)
                let msg = "Failed to load model"
                processor.errorMessage = msg
                processor.loadPhase = .error(msg)
                processor.isLoading = false
            }
        }
    }

    /// Apply LLM post-processing to transcribed text if enabled
    private func applyLLMPostProcessing(_ text: String) async -> String {
        guard llmEnabled, let processor = llmPostProcessor, processor.isModelLoaded else {
            return text
        }

        // Skip AI post-processing if text has no real word content (silence/hallucination leak)
        guard text.contains(where: { $0.isLetter }) else {
            return text
        }

        let mode = AIModeManager.shared.activeMode
        guard !mode.systemPrompt.isEmpty else { return text }

        activeAIModeName = mode.name
        defer { activeAIModeName = nil }

        do {
            Logger.debug("LLM processing with mode '\(mode.name)' (temp=\(mode.temperature), topP=\(mode.topP))", subsystem: .transcription)
            Logger.debug("LLM system prompt: \(mode.systemPrompt.prefix(100))", subsystem: .transcription)
            Logger.debug("LLM input: \(text)", subsystem: .transcription)

            let processed = try await processor.process(
                text: text,
                systemPrompt: mode.systemPrompt,
                targetLanguage: mode.targetLanguage,
                temperature: mode.temperature,
                topP: mode.topP
            )
            Logger.info("LLM post-processed (\(mode.name)): \(text.prefix(60))... → \(processed.prefix(60))...", subsystem: .transcription)
            Logger.debug("LLM output: \(processed)", subsystem: .transcription)
            return processed
        } catch {
            Logger.error("LLM post-processing failed: \(error)", subsystem: .transcription)
            return text
        }
    }

    /// Process transcription through rewrite mode LLM
    private func processRewriteMode(transcription: String) async -> String {
        // Initialize rewrite service lazily
        if rewriteModeService == nil, let processor = llmPostProcessor {
            rewriteModeService = RewriteModeService(llmProcessor: processor)
        }

        guard let service = rewriteModeService else {
            Logger.warning("Rewrite mode: no LLM available, returning raw transcription", subsystem: .transcription)
            return transcription
        }

        let mode = AIModeManager.shared.activeMode
        let rewritePrompt = mode.rewritePrompt.isEmpty ? nil : mode.rewritePrompt
        do {
            let result = try await service.process(
                instruction: transcription,
                selectedText: capturedSelectedText,
                rewritePrompt: rewritePrompt
            )
            Logger.info("Rewrite mode (\(mode.name)) processed: \(transcription.prefix(30))... → \(result.prefix(30))...", subsystem: .transcription)
            return result
        } catch {
            Logger.error("Rewrite mode failed: \(error)", subsystem: .transcription)
            return transcription
        }
    }

    /// Apply list formatting to transcribed text (deterministic engine + optional LLM fallback)
    private func applyListFormatting(_ text: String) async -> String {
        guard listFormattingEnabled else { return text }

        // Skip list formatting if text has no real word content
        guard text.contains(where: { $0.isLetter }) else { return text }

        let result = ListFormatter.format(text)

        // LLM fallback: if deterministic found nothing and AI mode enabled
        if listFormattingAIEnabled, result == text,
           let processor = llmPostProcessor, processor.isModelLoaded {
            do {
                let listFormatPrompt = AIMode.builtInModes.first { $0.name == "List Format" }?.systemPrompt ?? ""
                let llmResult = try await processor.process(text: text, systemPrompt: listFormatPrompt)
                Logger.info("LLM list formatting: \(text.prefix(30))... → \(llmResult.prefix(30))...", subsystem: .transcription)
                return llmResult
            } catch {
                Logger.error("LLM list formatting failed: \(error)", subsystem: .transcription)
                return text
            }
        }

        if result != text {
            Logger.info("List formatted: \(text.prefix(30))... → \(result.prefix(30))...", subsystem: .transcription)
        }

        return result
    }

    /// Pre-load the Silero VAD model for voice activity detection
    /// VAD is completely optional - the app works fine without it
    func preloadVAD() {
        guard sileroVAD == nil else {
            Logger.debug("Silero VAD already loaded", subsystem: .model)
            isVADLoaded = true
            return
        }

        let vadPath = ModelDownloader.shared.vadModelPath()

        // First ensure the VAD model is downloaded
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                Logger.debug("Checking for Silero VAD model...", subsystem: .model)

                // Download VAD model if needed (small ~2MB download)
                try await ModelDownloader.shared.ensureVADModelDownloaded()

                // Double-check file exists and has reasonable size
                guard FileManager.default.fileExists(atPath: vadPath.path) else {
                    Logger.warning("VAD model file not found — app will continue without speech detection", subsystem: .model)
                    return
                }

                // Verify file size
                if let attrs = try? FileManager.default.attributesOfItem(atPath: vadPath.path),
                   let size = attrs[.size] as? Int64 {
                    Logger.debug("VAD model found: \(String(format: "%.2f", Double(size) / 1024.0 / 1024.0)) MB", subsystem: .model)
                }

                Logger.info("Pre-loading Silero VAD...", subsystem: .model)
                let startTime = Date()

                // Load VAD model (now calls ggml_backend_load_all first)
                let vad = try SileroVAD(modelPath: vadPath)
                let loadTime = Date().timeIntervalSince(startTime)
                Logger.info("Silero VAD pre-loaded in \(String(format: "%.2f", loadTime))s", subsystem: .model)

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.sileroVAD = vad
                    self.isVADLoaded = true
                }
            } catch {
                Logger.warning("Failed to load Silero VAD: \(error.localizedDescription) — app will work without speech detection", subsystem: .model)
                // VAD is completely optional, continue without it
                await MainActor.run { [weak self] in
                    self?.isVADLoaded = false
                }
            }
        }
    }

    // MARK: - Language Routing

    /// Pre-load the language routing infrastructure (detector + model pool)
    func preloadLanguageRouting() {
        guard routingConfig.isRoutingEnabled else {
            Logger.debug("Language routing disabled (single language)", subsystem: .model)
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            do {
                // Validate multilingual fallback availability
                let fallbackModel = await MainActor.run { self.buildFallbackModel() }
                if !ModelDownloader.shared.isModelDownloaded(fallbackModel) {
                    Logger.warning("Multilingual fallback model \(fallbackModel.displayName) not downloaded, attempting download", subsystem: .model)
                    do {
                        try await ModelDownloader.shared.downloadModel(fallbackModel, progressCallback: { _ in })
                    } catch {
                        Logger.warning("Failed to download fallback model, disabling routing: \(error)", subsystem: .model)
                        return
                    }
                }

                // Download tiny model for preview/detection
                try await ModelDownloader.shared.ensureDetectorModelDownloaded()

                // Create ModelPool and load shared preview/detector bridge (CPU-only)
                let pool = ModelPool()
                let tinyModelPath = ModelDownloader.shared.modelPath(for: .tiny)
                try pool.loadPreviewBridge(modelPath: tinyModelPath)

                // Register the current whisperBridge as fallback
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let fallbackProfile = self.buildFallbackProfile()

                    if let bridge = self.whisperBridge {
                        try? pool.loadFallback(profile: fallbackProfile, backend: bridge)
                    }

                    self.modelPool = pool
                    Logger.info("Language routing initialized (\(self.routingConfig.allowedLanguages.count) languages)", subsystem: .model)

                    // Optionally preload standby for primary language
                    if let primary = self.routingConfig.primaryLanguage {
                        let downloaded = ModelDownloader.shared.downloadedModelSet()
                        if let specializedModel = WhisperModel.recommendedModel(for: primary, downloaded: downloaded),
                           specializedModel != self.selectedModel {
                            let standbyProfile = ModelProfile(
                                model: specializedModel,
                                backend: .whisperCpp,
                                language: primary,
                                isSpecialized: true
                            )
                            pool.preloadStandby(profile: standbyProfile)
                        }
                    }
                }
            } catch {
                Logger.warning("Failed to initialize language routing: \(error)", subsystem: .model)
            }
        }
    }

    /// Build the fallback model — must be multilingual
    private func buildFallbackModel() -> WhisperModel {
        if selectedModel.isMultilingual {
            return selectedModel
        }
        // English-only model selected — upgrade to largeTurboQ5
        Logger.info("Fallback upgraded from \(selectedModel.displayName) to \(WhisperModel.largeTurboQ5.displayName) (multilingual required)", subsystem: .model)
        return .largeTurboQ5
    }

    /// Build fallback ModelProfile from current state
    private func buildFallbackProfile() -> ModelProfile {
        let model = buildFallbackModel()
        return ModelProfile(
            model: model,
            backend: .whisperCpp,
            language: .auto,
            isSpecialized: false
        )
    }

    /// Build language → model mapping from downloaded models and config
    private func buildLanguageModelMap() -> [TranscriptionLanguage: ModelProfile] {
        let downloaded = ModelDownloader.shared.downloadedModelSet()
        var map: [TranscriptionLanguage: ModelProfile] = [:]

        for lang in routingConfig.allowedLanguages {
            // Check user overrides first
            if let overrideRaw = routingConfig.languageModelOverrides[lang.rawValue],
               let overrideModel = WhisperModel(filename: overrideRaw),
               downloaded.contains(overrideModel) {
                map[lang] = ModelProfile(
                    model: overrideModel,
                    backend: .whisperCpp,
                    language: lang,
                    isSpecialized: true
                )
                continue
            }

            // Use recommended model if available
            if let recommended = WhisperModel.recommendedModel(for: lang, downloaded: downloaded) {
                map[lang] = ModelProfile(
                    model: recommended,
                    backend: .whisperCpp,
                    language: lang,
                    isSpecialized: true
                )
            } else {
                // Use the selected model (multilingual)
                map[lang] = ModelProfile(
                    model: selectedModel.isMultilingual ? selectedModel : .largeTurboQ5,
                    backend: .whisperCpp,
                    language: lang,
                    isSpecialized: false
                )
            }
        }

        return map
    }

    // MARK: - Vocabulary Boosting

    /// Configure CTC vocabulary boosting on a FluidAudioBridge's final-pass manager
    private func configureVocabularyBoostingOnBridge(_ bridge: FluidAudioBridge, variant: ParakeetModelVariant) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            do {
                let entries = await DictionaryManager.shared.entries
                let words = await MainActor.run { self.promptWordsEnabled ? self.promptWords : [] }
                guard let vocabBundle = try await VocabularyStore.buildVocabulary(entries: entries, promptWords: words) else {
                    Logger.debug("No vocabulary terms for CTC boosting", subsystem: .transcription)
                    return
                }
                try await bridge.configureVocabularyBoosting(
                    vocabulary: vocabBundle.vocabulary,
                    ctcModels: vocabBundle.ctcModels
                )
            } catch {
                Logger.warning("Failed to configure vocabulary boosting: \(error.localizedDescription)", subsystem: .transcription)
                // Non-fatal — transcription still works without boosting
            }
        }
    }

    /// Reconfigure vocabulary boosting after dictionary or prompt word changes
    private func reconfigureVocabularyBoosting() {
        guard selectedBackendType == .parakeet,
              let bridge = whisperBridge as? FluidAudioBridge else { return }

        let variant = selectedParakeetModel
        configureVocabularyBoostingOnBridge(bridge, variant: variant)
    }

    // MARK: - Global Dictation Lifecycle

    /// Start global dictation — creates and starts the key listener
    func startGlobalDictation() {
        guard keyListener == nil else {
            keyListener?.start()
            return
        }
        let listener = GlobalKeyListener()
        keyListener = listener
        configureKeyListenerCallbacks(listener)
        listener.start()
        Logger.info("System-wide dictation enabled", subsystem: .app)
    }

    /// Stop global dictation — stops and removes the key listener
    func stopGlobalDictation() {
        keyListener?.stop()
        keyListener = nil
        Logger.info("System-wide dictation disabled", subsystem: .app)
    }

    /// Configure key listener callbacks (reusable for both init and toggle)
    func configureKeyListenerCallbacks(_ listener: GlobalKeyListener) {
        listener.onFnPressed = { [weak self] in
            Task { @MainActor in
                self?.startRecording()
            }
        }
        listener.onFnReleased = { [weak self] in
            Task { @MainActor in
                self?.stopRecording()
            }
        }
        listener.onShortcutCancelled = { [weak self] in
            Task { @MainActor in
                self?.cancelRecording()
            }
        }
        listener.onHandsFreeActivated = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                self.isHandsFreeRecording = true
                self.showHandsFreeToast = true
                Logger.info("Hands-free recording activated", subsystem: .app)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.showHandsFreeToast = false
                }
            }
        }

        #if !APP_STORE
        // Rewrite mode callback — single keypress rewrites selected text directly (no recording)
        listener.onRewriteShortcutPressed = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                guard self.llmEnabled else {
                    Logger.warning("Rewrite shortcut: AI post-processing not enabled", subsystem: .app)
                    return
                }
                guard self.llmPostProcessor?.isModelLoaded == true else {
                    Logger.warning("Rewrite shortcut: LLM model not loaded", subsystem: .app)
                    return
                }
                await self.rewriteSelectedText()
            }
        }
        #endif

        // Transcription picker callbacks (Option+V)
        listener.onPickerActivated = { [weak self] in
            Task { @MainActor in
                guard self?.state == .idle else { return }
                TranscriptionPickerState.shared.show()
            }
        }
        listener.onPickerCycled = {
            Task { @MainActor in
                TranscriptionPickerState.shared.cycleNext()
            }
        }
        listener.onPickerConfirmed = {
            Task { @MainActor in
                TranscriptionPickerState.shared.confirmSelection()
            }
        }
    }

    // MARK: - In-App Transcription

    /// Start recording in in-app mode (no text entry into other apps, no Accessibility required)
    func startInAppRecording() {
        // Show loading indicator if model isn't ready (works even during download)
        guard whisperBridge != nil else {
            showModelLoadingToast = true
            // Safety timeout — dismiss if model never loads (e.g., no model downloaded)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                self?.showModelLoadingToast = false
            }
            Logger.warning("Cannot start recording - model not pre-loaded", subsystem: .app)
            return
        }

        guard state == .idle else { return }

        let bridge = whisperBridge!

        isInAppMode = true
        lastInAppTranscription = ""

        // Set state immediately so UI updates
        state = .recording(startTime: Date())
        liveTranscription = ""
        recordingSessionID = UUID()  // Force SwiftUI state reset
        isLiveTranscriptionRTL = selectedLanguage.isRTL
        isOutputAudioMuted = muteOtherAudioDuringRecording  // Initialize runtime toggle from setting
        startStateWatchdog()  // 4s startup watchdog — cancelled when audio starts

        soundPlayer?.playStartSound()

        Task {
            do {
                streamingTranscriber = StreamingTranscriber(backend: bridge, vad: sileroVAD, language: selectedLanguage, initialPrompt: promptWordsString, fillerWordRemovalEnabled: fillerWordRemovalEnabled, modelPool: modelPool, languageRouter: routingConfig.isRoutingEnabled ? LanguageRouter(allowed: routingConfig.allowedLanguages, primary: routingConfig.primaryLanguage) : nil, modelRouter: routingConfig.isRoutingEnabled ? ModelRouter(languageModelMap: buildLanguageModelMap(), fallbackProfile: buildFallbackProfile()) : nil, previewBridge: modelPool?.previewBridge)

                // Wire language detection → UI update
                streamingTranscriber?.onLanguageDetected = { [weak self] lang in
                    self?.activeRouteInfo = "Detected: \(lang.displayName)"
                    self?.isLiveTranscriptionRTL = lang.isRTL
                }

                // StreamingTranscriber provides live preview via onNewSegment + onTranscription
                streamingTranscriber?.start { [weak self] text in
                    Task { @MainActor in
                        if self?.liveTranscriptionEnabled == true {
                            self?.liveTranscription = text
                        }
                    }
                }

                audioRecorder?.onStreamingSamples = { [weak self] samples in
                    guard let self = self, !self.isMicMuted, !self.isPaused else { return }
                    self.streamingTranscriber?.addSamples(samples)
                }

                // Resolve input route fresh at recording time
                let route = audioDeviceManager.resolveInputRouteForRecording()
                Logger.info("In-app recording with route: \(route)", subsystem: .audio)

                let audioURL = try await audioRecorder?.startRecording(route: route)
                currentAudioURL = audioURL
                cancelStateWatchdog()  // Startup succeeded, audio is flowing
                startRecordingWatchdog()  // Long-running watchdog for stuck .recording state

                // Mute AFTER engine is running and audio HAL has stabilized
                if muteOtherAudioDuringRecording {
                    try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms post-engine stabilization
                    audioMuter?.muteSystemAudio()
                }
            } catch {
                cancelStateWatchdog()
                errorMessage = "Failed to start recording: \(error.localizedDescription)"
                streamingTranscriber = nil
                liveTranscription = ""
                state = .idle
                isInAppMode = false
                if muteOtherAudioDuringRecording {
                    audioMuter?.unmuteSystemAudio()
                }
            }
        }
    }

    /// Stop in-app recording — stores result in lastInAppTranscription, no text entry into other apps
    func stopInAppRecording() {
        guard case .recording = state else { return }
        guard isInAppMode else {
            stopRecording()
            return
        }

        state = .stopping
        startStopWatchdog()

        Task {
            await audioRecorder?.stopRecording()

            if muteOtherAudioDuringRecording {
                audioMuter?.unmuteSystemAudio()
            }

            soundPlayer?.playStopSound()

            var finalText = ""
            var savedRecordId: UUID?
            if let transcriber = streamingTranscriber {
                finalText = await withTimeoutResult(seconds: 3.0) {
                    await transcriber.stopAsync()
                } ?? ""

                if saveRecordings && !finalText.isEmpty {
                    savedRecordId = saveRecordingFromTranscriber(transcriber, transcription: finalText)
                }
            }
            streamingTranscriber = nil

            // Bail out if watchdog already forced idle
            guard case .stopping = state else { return }

            if !finalText.isEmpty {
                // Apply list formatting then LLM post-processing
                let listFormatted = await applyListFormatting(finalText)
                let processedText = await applyLLMPostProcessing(listFormatted)
                lastInAppTranscription = processedText

                // Save AI enhancement if text was modified by post-processing
                if processedText != finalText, let recordId = savedRecordId {
                    let modeName = llmEnabled ? AIModeManager.shared.activeMode.name : "List Format"
                    Task {
                        try? await HistoryManager.shared.updateAIEnhancementById(recordId, aiText: processedText, modeName: modeName)
                    }
                }
            }

            cancelStateWatchdog()
            state = .idle
            isInAppMode = false
            liveTranscription = ""
        }
    }

    // MARK: - State Transitions

    func startRecording() {
        // Show loading indicator if model isn't ready (works even during download)
        guard whisperBridge != nil else {
            showModelLoadingToast = true
            // Safety timeout — dismiss if model never loads (e.g., no model downloaded)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                self?.showModelLoadingToast = false
            }
            Logger.warning("Cannot start recording - model not pre-loaded", subsystem: .app)
            return
        }

        guard state == .idle else { return }

        #if !APP_STORE
        // Recheck accessibility status before recording (event-based check)
        PermissionManager.shared.recheckAccessibilityIfNeeded()
        #endif

        // Dismiss transcription picker if visible
        if TranscriptionPickerState.shared.isVisible {
            TranscriptionPickerState.shared.dismiss()
        }

        let bridge = whisperBridge!

        // Capture the frontmost app BEFORE our overlay steals focus
        textInjector?.captureTargetApp()
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastTargetAppName = frontApp.localizedName
            targetAppIcon = frontApp.icon
        } else {
            lastTargetAppName = nil
            targetAppIcon = nil
        }

        // INSTANT: Set state immediately so overlay appears right away
        let recordingStart = Date()
        state = .recording(startTime: recordingStart)
        liveTranscription = ""
        recordingSessionID = UUID()
        isOutputAudioMuted = muteOtherAudioDuringRecording  // Initialize runtime toggle from setting
        startStateWatchdog()  // 4s startup watchdog — cancelled when audio starts

        // Play sound immediately (non-blocking)
        soundPlayer?.playStartSound()

        // Start recording immediately
        Task {
            do {
                // Create streaming transcriber with pre-loaded bridge, optional VAD, and language
                streamingTranscriber = StreamingTranscriber(backend: bridge, vad: sileroVAD, language: selectedLanguage, initialPrompt: promptWordsString, fillerWordRemovalEnabled: fillerWordRemovalEnabled, modelPool: modelPool, languageRouter: routingConfig.isRoutingEnabled ? LanguageRouter(allowed: routingConfig.allowedLanguages, primary: routingConfig.primaryLanguage) : nil, modelRouter: routingConfig.isRoutingEnabled ? ModelRouter(languageModelMap: buildLanguageModelMap(), fallbackProfile: buildFallbackProfile()) : nil, previewBridge: modelPool?.previewBridge)

                // Wire language detection → UI update
                streamingTranscriber?.onLanguageDetected = { [weak self] lang in
                    self?.activeRouteInfo = "Detected: \(lang.displayName)"
                    self?.isLiveTranscriptionRTL = lang.isRTL
                }

                streamingTranscriber?.start { [weak self] text in
                    Task { @MainActor in
                        if self?.liveTranscriptionEnabled == true {
                            self?.liveTranscription = text
                        }
                    }
                }
                Logger.info("Streaming transcriber initialized (VAD: \(sileroVAD != nil ? "enabled" : "disabled"))", subsystem: .transcription)

                audioRecorder?.onStreamingSamples = { [weak self] samples in
                    guard let self = self, !self.isMicMuted, !self.isPaused else { return }
                    self.streamingTranscriber?.addSamples(samples)
                }

                // Guard: if stopRecording() was called before we got here, bail out
                guard case .recording = state else {
                    Logger.debug("startRecording Task: state changed before audio start, aborting", subsystem: .app)
                    streamingTranscriber = nil
                    liveTranscription = ""
                    return
                }

                // Resolve input route fresh at recording time — no cached device IDs
                let route = audioDeviceManager.resolveInputRouteForRecording()
                Logger.info("Recording with route: \(route)", subsystem: .audio)

                let audioURL = try await audioRecorder?.startRecording(route: route)
                currentAudioURL = audioURL
                cancelStateWatchdog()  // Startup succeeded, audio is flowing
                startRecordingWatchdog()  // Long-running watchdog for stuck .recording state

                // Guard: if stopRecording() was called while audio was starting, stop the recorder
                guard case .recording = state else {
                    Logger.debug("startRecording Task: state changed during audio start, cleaning up", subsystem: .app)
                    await audioRecorder?.stopRecording()
                    streamingTranscriber = nil
                    liveTranscription = ""
                    if muteOtherAudioDuringRecording {
                        audioMuter?.unmuteSystemAudio()
                    }
                    return
                }

                // Mute AFTER engine is running and audio HAL has stabilized.
                // Muting before engine.start() gets undone by HAL reconfiguration,
                // causing audio to unmute ~1s into recording (especially with headphones).
                if muteOtherAudioDuringRecording {
                    try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms post-engine stabilization
                    audioMuter?.muteSystemAudio()
                }
            } catch {
                // Only handle the error if THIS recording is still the active one.
                // A stale Task (from a timed-out queryInputNodeFormat) can arrive after
                // a new recording has already started — setting state = .idle would kill it.
                guard case .recording(let startTime) = state, startTime == recordingStart else {
                    Logger.debug("Stale startRecording error ignored (state already changed): \(error.localizedDescription)", subsystem: .app)
                    return
                }
                cancelStateWatchdog()
                Logger.error("Failed to start recording: \(error.localizedDescription)", subsystem: .app)
                streamingTranscriber = nil
                liveTranscription = ""
                state = .idle
                // Silent reset — no error message. Next Fn press starts fresh.
                if muteOtherAudioDuringRecording {
                    audioMuter?.unmuteSystemAudio()
                }
            }
        }
    }

    /// Called when audio engine exhausts all recovery attempts.
    /// Silently resets to idle so the next Fn press starts a clean recording.
    func handleAudioFlowTimeout() {
        Logger.error("Audio flow timeout — all recovery attempts exhausted, resetting to idle", subsystem: .audio)
        guard case .recording = state else { return }
        cancelStateWatchdog()
        streamingTranscriber = nil
        liveTranscription = ""
        state = .idle
        errorMessage = "Microphone not responding. Try recording again."
        if muteOtherAudioDuringRecording {
            audioMuter?.unmuteSystemAudio()
        }
    }

    func stopRecording() {
        guard case .recording = state else {
            Logger.warning("stopRecording() called but state is \(state), ignoring", subsystem: .app)
            return
        }

        state = .stopping

        startStopWatchdog()

        Task {
            await audioRecorder?.stopRecording()

            // No separate live preview engine to stop — StreamingTranscriber handles everything

            // Unmute other audio sources now that recording is done
            if muteOtherAudioDuringRecording {
                audioMuter?.unmuteSystemAudio()
            }

            // Play stop sound AFTER unmuting (so user hears it)
            soundPlayer?.playStopSound()

            // Bail out if watchdog already forced idle
            guard case .stopping = state else {
                streamingTranscriber = nil
                return
            }

            // Get final transcription — tail transcription has a 4s timeout
            // in FluidAudioBridge, so 5s here is plenty of margin.
            var finalText = ""
            let transcriber = streamingTranscriber
            if let transcriber {
                finalText = await withTimeoutResult(seconds: 5.0) {
                    await transcriber.stopAsync()
                } ?? ""

                // Fallback: if final pass timed out, use the live streaming result.
                if finalText.isEmpty {
                    let streamingResult = transcriber.currentTranscription
                    if !streamingResult.isEmpty {
                        finalText = DictionaryManager.shared.correctText(streamingResult)
                        if fillerWordRemovalEnabled {
                            finalText = FillerWordFilter.removeFillers(from: finalText)
                        }
                        Logger.debug("Final pass timed out, using streaming result (\(finalText.count) chars)", subsystem: .transcription)
                    } else {
                        Logger.debug("Final transcription empty or timed out", subsystem: .transcription)
                    }
                } else {
                    Logger.debug("Final transcription: '\(finalText)'", subsystem: .transcription)
                }
            }
            streamingTranscriber = nil

            // Bail out if watchdog already forced idle while we were transcribing
            guard case .stopping = state else { return }

            if !finalText.isEmpty {
                // Save recording if enabled (only when there are actual words)
                var savedRecordId: UUID?
                if saveRecordings, let transcriber {
                    savedRecordId = saveRecordingFromTranscriber(transcriber, transcription: finalText)
                }

                // Standard dictation post-processing
                let listFormatted = await applyListFormatting(finalText)
                let processedText = await applyLLMPostProcessing(listFormatted)
                let textToInsert = appendTrailingSpace ? processedText + " " : processedText

                // Save AI enhancement if text was modified by post-processing
                if processedText != finalText, let recordId = savedRecordId {
                    let modeName = llmEnabled ? AIModeManager.shared.activeMode.name : "List Format"
                    Task {
                        try? await HistoryManager.shared.updateAIEnhancementById(recordId, aiText: processedText, modeName: modeName)
                    }
                }

                Logger.debug("Entering dictated text: '\(textToInsert)'", subsystem: .app)
                cancelStateWatchdog()
                state = .inserting(text: textToInsert)
                await insertText(textToInsert)
            } else {
                Logger.debug("No speech detected in recording", subsystem: .app)
                cancelStateWatchdog()
                state = .idle
            }
        }
    }

    /// Run an async operation with a timeout. Returns nil if the operation times out.
    private func withTimeoutResult<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Cancel recording without transcribing (e.g., Fn+key combo detected)
    /// Immediately stops recording, unmutes audio, and returns to idle state
    // MARK: - State Watchdog

    /// Start a main-thread watchdog that forces .idle if stuck in .recording/.stopping.
    /// Uses DispatchSourceTimer on the main RunLoop — completely independent of the Swift
    /// cooperative thread pool. Even if all cooperative threads are exhausted, this fires.
    /// - Parameter timeout: Seconds before forcing idle. 4s for startup, 5s for stop/transcription.
    private func startStateWatchdog(timeout: TimeInterval = 4.0) {
        stateWatchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            switch self.state {
            case .recording, .stopping:
                Logger.error("State watchdog: stuck in \(self.state) for \(timeout)s, forcing idle", subsystem: .app)
                self.forceIdleFromWatchdog()
            default:
                break
            }
        }
        timer.resume()
        stateWatchdog = timer
    }

    private func cancelStateWatchdog() {
        stateWatchdog?.cancel()
        stateWatchdog = nil
    }

    /// Lightweight watchdog for the recording phase. Fires every 5s and checks
    /// whether we're still in .recording state. Catches the case where the Fn
    /// release event fires but stopRecording() never executes (main actor busy,
    /// callback dropped, etc.). The 5-minute recording limit is enforced by
    /// AudioRecorder, but this watchdog catches state-machine stuck scenarios.
    /// Also acts as a fallback if the key listener's release event is lost.
    private func startRecordingWatchdog() {
        // Don't replace an existing stop watchdog — only install if no watchdog is active
        guard stateWatchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Check every 10s — recording can legitimately last up to 5 minutes
        timer.schedule(deadline: .now() + 10, repeating: 10.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard case .recording(let startTime) = self.state else {
                // State changed (to .stopping, .idle, etc.) — watchdog no longer needed
                self.stateWatchdog?.cancel()
                self.stateWatchdog = nil
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)
            // 5.5 minutes = 5 min recording limit + 30s margin
            if elapsed > 330 {
                Logger.error("Recording watchdog: stuck in .recording for \(String(format: "%.0f", elapsed))s, forcing idle", subsystem: .app)
                self.forceIdleFromWatchdog()
            }
        }
        timer.resume()
        stateWatchdog = timer
    }

    /// Activity-aware watchdog for the stop phase. Repeats every 2s and checks
    /// whether transcription or LLM post-processing is still actively working.
    /// Forces idle after 5s of zero activity OR after 20s absolute (even if
    /// isProcessing stays true — e.g., whisper hung after encode failure).
    private func startStopWatchdog() {
        stateWatchdog?.cancel()
        let now = Date()
        lastStopActivityTime = now
        stopWatchdogStartTime = now
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard case .stopping = self.state else {
                self.stateWatchdog?.cancel()
                self.stateWatchdog = nil
                return
            }

            // Absolute timeout: force idle after 20s regardless of activity.
            // Catches cases where isProcessing stays true (e.g., whisper hung
            // after Metal encode failure, SafeLock held indefinitely).
            let elapsed = Date().timeIntervalSince(self.stopWatchdogStartTime ?? Date())
            if elapsed > 20.0 {
                Logger.error("Stop watchdog: absolute timeout after \(String(format: "%.1f", elapsed))s, forcing idle", subsystem: .app)
                self.forceIdleFromWatchdog()
                return
            }

            let transcribing = self.streamingTranscriber?.isProcessing == true
            let llmProcessing = self.llmPostProcessor?.isProcessing == true

            if transcribing || llmProcessing {
                self.lastStopActivityTime = Date()
                return
            }

            let inactivity = Date().timeIntervalSince(self.lastStopActivityTime ?? Date())
            if inactivity > 5.0 {
                Logger.error("Stop watchdog: no activity for \(String(format: "%.1f", inactivity))s, forcing idle", subsystem: .app)
                self.forceIdleFromWatchdog()
            }
        }
        timer.resume()
        stateWatchdog = timer
    }

    /// Force state to idle from a watchdog — shared cleanup for all watchdog paths.
    private func forceIdleFromWatchdog() {
        stateWatchdog?.cancel()
        stateWatchdog = nil
        streamingTranscriber = nil
        liveTranscription = ""
        state = .idle
        if muteOtherAudioDuringRecording {
            audioMuter?.unmuteSystemAudio()
        }
        if let recorder = audioRecorder {
            DispatchQueue.global(qos: .utility).async {
                Task { await recorder.stopRecording() }
            }
        }
    }

    // MARK: - Rewrite Selected Text

    /// Directly rewrites selected text through LLM — no recording, no voice input.
    /// Triggered by rewrite shortcut (Option+Shift+Tab by default).
    func rewriteSelectedText() async {
        guard state == .idle else { return }
        guard let processor = llmPostProcessor, processor.isModelLoaded else { return }

        #if !APP_STORE
        // Read text from clipboard
        guard let clipboardText = NSPasteboard.general.string(forType: .string), !clipboardText.isEmpty else {
            Logger.warning("Rewrite: clipboard is empty", subsystem: .app)
            return
        }
        let selectedText = clipboardText

        let mode = AIModeManager.shared.activeMode
        activeMode = .rewrite
        activeAIModeName = mode.name
        state = .rewriting

        Logger.info("Rewriting \(selectedText.count) chars with \(mode.name) mode", subsystem: .app)

        do {
            let result = try await processor.process(
                text: selectedText,
                systemPrompt: mode.systemPrompt,
                targetLanguage: mode.targetLanguage
            )
            Logger.info("Rewrite (\(mode.name)): \(selectedText.prefix(30))... → \(result.prefix(30))...", subsystem: .app)
            state = .idle
            await insertText(result)
        } catch {
            Logger.error("Rewrite failed: \(error)", subsystem: .transcription)
            state = .idle
        }
        #endif
    }

    func cancelRecording() {
        guard case .recording = state else { return }

        Logger.debug("Recording cancelled (Fn+key combo)", subsystem: .app)
        cancelStateWatchdog()

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

    @discardableResult
    private func saveRecordingFromTranscriber(_ transcriber: StreamingTranscriber, transcription: String) -> UUID {
        let recordId = UUID()
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
            Logger.info("Recording saved to: \(destURL.path)", subsystem: .app)

            // Save to history database
            Task {
                do {
                    // Use detected language when auto-detect is active, otherwise use user selection
                    let recordedLanguage: String
                    if self.selectedLanguage == .auto, let detected = self.whisperBridge?.lastDetectedLanguage {
                        recordedLanguage = detected
                    } else {
                        recordedLanguage = self.selectedLanguage.rawValue
                    }

                    let record = TranscriptionRecord(
                        id: recordId,
                        transcription: transcription,
                        audioFileURL: fileName,
                        duration: transcriber.recordedDuration,
                        language: recordedLanguage,
                        modelUsed: activeModelDisplayName,
                        corrections: DictionaryManager.shared.lastCorrections,
                        targetAppName: self.lastTargetAppName
                    )
                    try await HistoryManager.shared.saveTranscription(record)
                    Logger.debug("Transcription saved to history database", subsystem: .app)
                } catch {
                    Logger.error("Failed to save transcription to history: \(error)", subsystem: .app)
                }
            }
        }

        return recordId
    }

    private func insertText(_ text: String) async {
        guard let textInjector = textInjector else {
            errorMessage = "Text entry not initialized"
            state = .idle
            return
        }

        // Store transcript for macOS Services provider
        lastTranscribedText = text
        lastTranscriptionDate = Date()

        // Dismiss HUD immediately — fade-out animation runs concurrently with text entry
        state = .idle
        liveTranscription = ""

        do {
            try await textInjector.insertText(text)
        } catch {
            errorMessage = "Failed to enter text: \(error.localizedDescription)"
        }
    }

    // MARK: - Pause/Resume Recording

    /// Toggle pause state during recording (soft pause — engine keeps running, samples discarded)
    func togglePause() {
        guard state.isRecording else { return }
        isPaused.toggle()

        if isPaused {
            Logger.info("Recording paused", subsystem: .app)
        } else {
            Logger.info("Recording resumed", subsystem: .app)
        }
    }

    /// Toggle system output audio mute during recording
    func toggleOutputAudioMute() {
        guard state.isRecording else { return }
        isOutputAudioMuted.toggle()

        if isOutputAudioMuted {
            audioMuter?.muteSystemAudio()
            Logger.info("Output audio muted", subsystem: .audio)
        } else {
            audioMuter?.unmuteSystemAudio()
            Logger.info("Output audio unmuted (meeting capture mode)", subsystem: .audio)
        }
    }

    func updateWaveform(amplitude: Float) {
        // Show flat waveform when mic is muted or recording is paused
        waveformAmplitudes.removeFirst()
        waveformAmplitudes.append((isMicMuted || isPaused) ? 0 : amplitude)
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Cleanup for Graceful Shutdown

    /// Release all whisper-related resources before app termination
    /// This prevents crashes when C++ destructors run during exit()
    func releaseWhisperResources() {
        Logger.debug("Releasing whisper resources...", subsystem: .transcription)

        // Remove notification observers
        if let observer = dictionaryRebuildObserver {
            NotificationCenter.default.removeObserver(observer)
            dictionaryRebuildObserver = nil
        }
        if let observer = appActivationObserver {
            NotificationCenter.default.removeObserver(observer)
            appActivationObserver = nil
        }
        if let observer = clipboardNotificationObserver {
            NotificationCenter.default.removeObserver(observer)
            clipboardNotificationObserver = nil
        }

        // Stop any streaming transcription
        streamingTranscriber = nil

        // Release language routing model pool (detector + standby backends)
        modelPool?.releaseAll()
        modelPool = nil

        // Free VAD context first (smaller, faster)
        if sileroVAD != nil {
            Logger.debug("Freeing Silero VAD context", subsystem: .transcription)
            sileroVAD = nil
            isVADLoaded = false
        }

        // Free active transcription bridge
        if let bridge = whisperBridge {
            Logger.debug("Freeing transcription backend context", subsystem: .transcription)
            bridge.prepareForShutdown()
            if #available(macOS 26.0, *), let saBridge = bridge as? SpeechAnalyzerBridge {
                Task.detached { [weak saBridge] in
                    await saBridge?.clearCache()
                }
            }
            whisperBridge = nil
            loadedModel = nil
            loadedParakeetModel = nil
            isModelLoaded = false
        }

        // Cancel SpeechAnalyzer load task
        speechAnalyzerLoadTask?.cancel()
        speechAnalyzerLoadTask = nil

        // Free LLM resources
        if llmPostProcessor != nil {
            Logger.debug("Freeing LLM resources", subsystem: .transcription)
            llmPostProcessor?.unloadModel()
            llmPostProcessor = nil
        }

        // Free cached CTC models
        #if arch(arm64)
        VocabularyStore.releaseCachedModels()
        #endif

        Logger.debug("Transcription resources released", subsystem: .transcription)
    }
}
