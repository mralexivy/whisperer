//
//  AppState.swift
//  Whisperer
//
//  Global application state machine for recording workflow
//

import Foundation
import Combine
import AppKit

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
                capturedSelectedText = nil
            }
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
    @Published var liveTranscriptionEnabled: Bool = true {  // Show live transcription preview during recording
        didSet {
            UserDefaults.standard.set(liveTranscriptionEnabled, forKey: "liveTranscriptionEnabled")
        }
    }

    // Prompt words — biases whisper toward recognizing specific vocabulary during transcription
    @Published var promptWords: [String] = [] {
        didSet {
            UserDefaults.standard.set(promptWords, forKey: "promptWords")
        }
    }
    @Published var promptWordsEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(promptWordsEnabled, forKey: "promptWordsEnabled")
        }
    }

    /// Assembled prompt words string for whisper.cpp initial_prompt.
    /// Formatted as a simple comma-separated list — whisper treats this as "previous context"
    /// and biases recognition toward these words.
    var promptWordsString: String? {
        guard promptWordsEnabled, !promptWords.isEmpty else { return nil }
        return promptWords.joined(separator: ", ")
    }

    /// Approximate token count for prompt words (word count as rough estimate)
    var promptWordsTokenCount: Int {
        promptWords.reduce(0) { $0 + $1.split(separator: " ").count }
    }

    /// Maximum recommended word count (conservative limit under 244 tokens)
    static let maxPromptWordsTokens = 200

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
                isModelLoaded = false
                whisperBridge = nil
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
    private var deviceSubscription: AnyCancellable?

    // Main-thread watchdog: forces state to .idle if stuck in .recording/.stopping for >8s.
    // Uses DispatchSourceTimer on the main RunLoop — independent of Swift cooperative thread pool.
    private var stateWatchdog: DispatchSourceTimer?

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
        isLoadingSpeechAnalyzer
    }

    // LLM post-processing
    @Published var llmEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(llmEnabled, forKey: "llmEnabled")
        }
    }
    @Published var selectedLLMModel: LLMModelVariant = .qwen3_4B {
        didSet {
            UserDefaults.standard.set(selectedLLMModel.rawValue, forKey: "selectedLLMModel")
        }
    }
    @Published var selectedLLMTask: LLMTask = .rewrite {
        didSet {
            UserDefaults.standard.set(selectedLLMTask.rawValue, forKey: "selectedLLMTask")
        }
    }
    @Published var llmCustomPrompt: String = "" {
        didSet {
            UserDefaults.standard.set(llmCustomPrompt, forKey: "llmCustomPrompt")
        }
    }
    @Published var llmTranslateLanguage: String = "English" {
        didSet {
            UserDefaults.standard.set(llmTranslateLanguage, forKey: "llmTranslateLanguage")
        }
    }
    var llmPostProcessor: LLMPostProcessor?

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

    // CTC vocabulary boosting for Parakeet (boosts dictionary terms in final pass)
    @Published var vocabularyBoostingEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(vocabularyBoostingEnabled, forKey: "vocabularyBoostingEnabled")
            if vocabularyBoostingEnabled && selectedBackendType == .parakeet {
                reconfigureVocabularyBoosting()
            }
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

    private var currentAudioURL: URL?
    private var lastTargetAppName: String?
    @Published var targetAppIcon: NSImage?

    // Rewrite mode
    @Published var activeMode: ActiveMode = .dictation
    var textSelectionService: TextSelectionService?
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

        // Load auto-paste preference (default OFF)
        if UserDefaults.standard.object(forKey: "autoPasteEnabled") != nil {
            _autoPasteEnabled = Published(wrappedValue: UserDefaults.standard.bool(forKey: "autoPasteEnabled"))
        }

        // Enable accessibility tracking if auto-paste was previously enabled
        if autoPasteEnabled {
            PermissionManager.shared.enableAccessibilityTracking()
        }

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
        if let savedLLMTask = UserDefaults.standard.string(forKey: "selectedLLMTask"),
           let llmTask = LLMTask(rawValue: savedLLMTask) {
            _selectedLLMTask = Published(wrappedValue: llmTask)
        }
        if let savedCustomPrompt = UserDefaults.standard.string(forKey: "llmCustomPrompt") {
            _llmCustomPrompt = Published(wrappedValue: savedCustomPrompt)
        }
        if let savedTranslateLang = UserDefaults.standard.string(forKey: "llmTranslateLanguage") {
            _llmTranslateLanguage = Published(wrappedValue: savedTranslateLang)
        }

        // Load prompt words
        if let savedPromptWords = UserDefaults.standard.stringArray(forKey: "promptWords") {
            _promptWords = Published(wrappedValue: savedPromptWords)
        }
        if UserDefaults.standard.object(forKey: "promptWordsEnabled") != nil {
            _promptWordsEnabled = Published(wrappedValue: UserDefaults.standard.bool(forKey: "promptWordsEnabled"))
        }

        // Load filler word, list formatting, vocabulary boosting, and trailing space settings
        if UserDefaults.standard.object(forKey: "fillerWordRemovalEnabled") != nil {
            _fillerWordRemovalEnabled = Published(wrappedValue: UserDefaults.standard.bool(forKey: "fillerWordRemovalEnabled"))
        }
        if UserDefaults.standard.object(forKey: "listFormattingEnabled") != nil {
            _listFormattingEnabled = Published(wrappedValue: UserDefaults.standard.bool(forKey: "listFormattingEnabled"))
        }
        if UserDefaults.standard.object(forKey: "listFormattingAIEnabled") != nil {
            _listFormattingAIEnabled = Published(wrappedValue: UserDefaults.standard.bool(forKey: "listFormattingAIEnabled"))
        }
        if UserDefaults.standard.object(forKey: "vocabularyBoostingEnabled") != nil {
            _vocabularyBoostingEnabled = Published(wrappedValue: UserDefaults.standard.bool(forKey: "vocabularyBoostingEnabled"))
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

        // Recheck accessibility when app becomes active (user returns from System Settings)
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard self != nil else { return }
            Task { @MainActor in
                PermissionManager.shared.recheckAccessibilityIfNeeded()
            }
        }

        // Show feedback when text is copied to clipboard (accessibility fallback)
        clipboardNotificationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TextCopiedToClipboard"), object: nil, queue: .main
        ) { [weak self] _ in
            guard self != nil else { return }
            Task { @MainActor [weak self] in
                self?.errorMessage = "Text copied to clipboard — press ⌘V to paste"
            }
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

        // Check token limit
        let newTokenCount = promptWordsTokenCount + trimmed.split(separator: " ").count
        guard newTokenCount <= Self.maxPromptWordsTokens else {
            Logger.warning("Prompt word limit reached (\(promptWordsTokenCount)/\(Self.maxPromptWordsTokens))", subsystem: .transcription)
            return false
        }

        promptWords.append(trimmed)
        Logger.info("Added prompt word: '\(trimmed)' (\(promptWordsTokenCount)/\(Self.maxPromptWordsTokens) words)", subsystem: .transcription)
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

        selectedBackendType = backend
        UserDefaults.standard.set(backend.rawValue, forKey: "selectedBackendType")
        Logger.info("Switched backend to \(backend.displayName)", subsystem: .model)
    }

    /// Release the active transcription bridge and free its memory
    private func releaseCurrentBridge() {
        guard let bridge = whisperBridge else { return }

        let backendName = selectedBackendType.displayName
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

        Logger.info("Released \(backendName) bridge (freeing memory)", subsystem: .model)
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
            Logger.error("Failed to download \(model.displayName): \(error)", subsystem: .model)
            errorMessage = "Failed to download \(model.displayName): \(error.localizedDescription)"
            downloadingModel = nil
            downloadProgress = 0
            downloadRetryInfo = nil
            state = .idle
        }
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
                    self.whisperBridge = bridge
                    self.loadedModel = model
                    self.loadedParakeetModel = nil
                    self.isModelLoaded = true
                    self.loadedBackendType = .whisperCpp
                    self.isLoadingWhisper = false
                    self.preloadVAD()
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
                    self.whisperBridge = bridge
                    self.loadedModel = nil
                    self.loadedParakeetModel = variant
                    self.isModelLoaded = true
                    self.loadedBackendType = .parakeet
                    self.isLoadingParakeet = false
                    self.parakeetDownloadStatus = ""
                    self.preloadVAD()

                    // Configure CTC vocabulary boosting on the final-pass manager
                    if self.vocabularyBoostingEnabled {
                        self.configureVocabularyBoostingOnBridge(bridge, variant: variant)
                    }
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
                    self.whisperBridge = bridge
                    self.speechAnalyzerSupportedLanguageCodes = bridge.supportedLanguageCodes
                    self.loadedModel = nil
                    self.loadedParakeetModel = nil
                    self.isModelLoaded = true
                    self.loadedBackendType = .speechAnalyzer
                    self.isLoadingSpeechAnalyzer = false
                    self.speechAnalyzerStatus = ""
                    self.preloadVAD()
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
        guard llmPostProcessor == nil || llmPostProcessor?.isModelLoaded != true else { return }

        let processor = LLMPostProcessor()
        llmPostProcessor = processor
        let variant = selectedLLMModel

        Task {
            do {
                try await processor.loadModel(variant)
                Logger.info("LLM \(variant.displayName) pre-loaded", subsystem: .model)
            } catch {
                Logger.error("Failed to pre-load LLM \(variant.displayName): \(error)", subsystem: .model)
            }
        }
    }

    /// Apply LLM post-processing to transcribed text if enabled
    private func applyLLMPostProcessing(_ text: String) async -> String {
        guard llmEnabled, let processor = llmPostProcessor, processor.isModelLoaded else {
            return text
        }

        do {
            let processed = try await processor.process(
                text: text,
                task: selectedLLMTask,
                customPrompt: selectedLLMTask == .custom ? llmCustomPrompt : nil,
                targetLanguage: selectedLLMTask == .translate ? llmTranslateLanguage : nil
            )
            Logger.info("LLM post-processed: \(text.prefix(30))... → \(processed.prefix(30))...", subsystem: .transcription)
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

        let profile = PromptProfileManager.shared.activeProfile
        do {
            let result = try await service.process(
                instruction: transcription,
                selectedText: capturedSelectedText,
                rewritePrompt: profile?.rewritePrompt
            )
            Logger.info("Rewrite mode processed: \(transcription.prefix(30))... → \(result.prefix(30))...", subsystem: .transcription)
            return result
        } catch {
            Logger.error("Rewrite mode failed: \(error)", subsystem: .transcription)
            return transcription
        }
    }

    /// Apply list formatting to transcribed text (deterministic engine + optional LLM fallback)
    private func applyListFormatting(_ text: String) async -> String {
        guard listFormattingEnabled else { return text }

        let result = ListFormatter.format(text)

        // LLM fallback: if deterministic found nothing and AI mode enabled
        if listFormattingAIEnabled, result == text,
           let processor = llmPostProcessor, processor.isModelLoaded {
            do {
                let llmResult = try await processor.process(text: text, task: .listFormat)
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

    // MARK: - Vocabulary Boosting

    /// Configure CTC vocabulary boosting on a FluidAudioBridge's final-pass manager
    private func configureVocabularyBoostingOnBridge(_ bridge: FluidAudioBridge, variant: ParakeetModelVariant) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            do {
                let entries = await DictionaryManager.shared.entries
                guard let vocabBundle = try await VocabularyStore.buildVocabulary(entries: entries) else {
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

    /// Reconfigure vocabulary boosting after dictionary changes
    private func reconfigureVocabularyBoosting() {
        guard vocabularyBoostingEnabled,
              selectedBackendType == .parakeet,
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

        // Rewrite mode callbacks
        listener.onRewriteShortcutPressed = { [weak self] in
            Task { @MainActor in
                self?.startRewriteRecording()
            }
        }
        listener.onRewriteShortcutReleased = { [weak self] in
            Task { @MainActor in
                self?.stopRecording()
            }
        }

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
        startStateWatchdog()  // 4s startup watchdog — cancelled when audio starts

        soundPlayer?.playStartSound()

        Task {
            do {
                streamingTranscriber = StreamingTranscriber(backend: bridge, vad: sileroVAD, language: selectedLanguage, initialPrompt: promptWordsString, fillerWordRemovalEnabled: fillerWordRemovalEnabled)
                streamingTranscriber?.start { [weak self] text in
                    Task { @MainActor in
                        if self?.liveTranscriptionEnabled == true {
                            self?.liveTranscription = text
                        }
                    }
                }

                audioRecorder?.onStreamingSamples = { [weak self] samples in
                    self?.streamingTranscriber?.addSamples(samples)
                }

                // AudioRecorder handles its own timeouts internally (1s per CoreAudio
                // call on GCD, with retry). No TaskGroup race needed here.
                let audioURL = try await audioRecorder?.startRecording()
                currentAudioURL = audioURL
                cancelStateWatchdog()  // Startup succeeded, audio is flowing

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
        startStateWatchdog(timeout: 5.0)

        Task {
            await audioRecorder?.stopRecording()

            if muteOtherAudioDuringRecording {
                audioMuter?.unmuteSystemAudio()
            }

            soundPlayer?.playStopSound()

            var finalText = ""
            if let transcriber = streamingTranscriber {
                finalText = await withTimeoutResult(seconds: 3.0) {
                    await transcriber.stopAsync()
                } ?? ""

                if saveRecordings && !finalText.isEmpty {
                    saveRecordingFromTranscriber(transcriber, transcription: finalText)
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
            } else {
                errorMessage = "No speech detected"
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

        // Recheck accessibility status before recording (event-based check)
        PermissionManager.shared.recheckAccessibilityIfNeeded()

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
        startStateWatchdog()  // 4s startup watchdog — cancelled when audio starts

        // Play sound immediately (non-blocking)
        soundPlayer?.playStartSound()

        // Start recording immediately
        Task {
            do {
                // Create streaming transcriber with pre-loaded bridge, optional VAD, and language
                streamingTranscriber = StreamingTranscriber(backend: bridge, vad: sileroVAD, language: selectedLanguage, initialPrompt: promptWordsString, fillerWordRemovalEnabled: fillerWordRemovalEnabled)
                streamingTranscriber?.start { [weak self] text in
                    Task { @MainActor in
                        if self?.liveTranscriptionEnabled == true {
                            self?.liveTranscription = text
                        }
                    }
                }
                Logger.info("Streaming transcriber initialized (VAD: \(sileroVAD != nil ? "enabled" : "disabled"))", subsystem: .transcription)

                // Connect audio samples to streaming transcriber
                audioRecorder?.onStreamingSamples = { [weak self] samples in
                    self?.streamingTranscriber?.addSamples(samples)
                }

                // Guard: if stopRecording() was called before we got here, bail out
                guard case .recording = state else {
                    Logger.debug("startRecording Task: state changed before audio start, aborting", subsystem: .app)
                    streamingTranscriber = nil
                    liveTranscription = ""
                    return
                }

                // AudioRecorder handles its own timeouts internally (1s per CoreAudio
                // call on GCD, with retry). No TaskGroup race needed here.
                let audioURL = try await audioRecorder?.startRecording()
                currentAudioURL = audioURL
                cancelStateWatchdog()  // Startup succeeded, audio is flowing

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
                errorMessage = "Failed to start recording: \(error.localizedDescription)"
                streamingTranscriber = nil
                liveTranscription = ""
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

        // Fixed watchdog — chunked pipeline processes bounded chunks (~20s max),
        // so stop time is predictable regardless of total recording duration.
        startStateWatchdog(timeout: 15.0)

        Task {
            await audioRecorder?.stopRecording()

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

            // Get final transcription — chunked pipeline only transcribes the tail
            // (bounded ~5s), so a fixed 10s timeout is sufficient.
            var finalText = ""
            let transcriber = streamingTranscriber
            if let transcriber {
                finalText = await withTimeoutResult(seconds: 10.0) {
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
                if saveRecordings, let transcriber {
                    saveRecordingFromTranscriber(transcriber, transcription: finalText)
                }

                // Route through rewrite mode or standard dictation
                let textToInsert: String
                if self.activeMode == .rewrite {
                    textToInsert = await processRewriteMode(transcription: finalText)
                } else {
                    let listFormatted = await applyListFormatting(finalText)
                    let processedText = await applyLLMPostProcessing(listFormatted)
                    textToInsert = appendTrailingSpace ? processedText + " " : processedText
                }

                Logger.debug("Entering dictated text: '\(textToInsert)'", subsystem: .app)
                cancelStateWatchdog()
                state = .inserting(text: textToInsert)
                await insertText(textToInsert)
            } else {
                Logger.debug("No speech detected in recording", subsystem: .app)
                errorMessage = "No speech detected"
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
                self.streamingTranscriber = nil
                self.liveTranscription = ""
                self.state = .idle
                self.errorMessage = "Recording failed — audio device error. Please try again."
                if self.muteOtherAudioDuringRecording {
                    self.audioMuter?.unmuteSystemAudio()
                }
                // Fire-and-forget stop on GCD to avoid blocking main thread
                if let recorder = self.audioRecorder {
                    DispatchQueue.global(qos: .utility).async {
                        Task { await recorder.stopRecording() }
                    }
                }
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

    // MARK: - Rewrite Mode Recording

    func startRewriteRecording() {
        guard whisperBridge != nil else {
            showModelLoadingToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                self?.showModelLoadingToast = false
            }
            return
        }
        guard state == .idle else { return }

        // Capture selected text BEFORE recording starts (before overlay steals focus)
        capturedSelectedText = textSelectionService?.getSelectedText()
        activeMode = .rewrite

        Logger.info("Rewrite mode started (selected \(capturedSelectedText?.count ?? 0) chars)", subsystem: .app)

        // Use the standard startRecording flow
        startRecording()
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
    }

    private func insertText(_ text: String) async {
        guard let textInjector = textInjector else {
            errorMessage = "Text entry not initialized"
            state = .idle
            return
        }

        // Dismiss HUD immediately — fade-out animation runs concurrently with text entry
        state = .idle
        liveTranscription = ""

        do {
            try await textInjector.insertText(text)
        } catch {
            errorMessage = "Failed to enter text: \(error.localizedDescription)"
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

        Logger.debug("Transcription resources released", subsystem: .transcription)
    }
}
