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
import IOKit.pwr_mgt

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
            if case .recording = state {
                waveformState.startDisplayLink()
            }
            if state == .idle {
                waveformState.stopDisplayLink()
                targetAppIcon = nil
                activeMode = .dictation
                activeAIModeName = nil
                capturedSelectedText = nil
                isHandsFreeRecording = false
                showHandsFreeToast = false
                isMicMuted = false
                isPaused = false
                PermissionManager.shared.resumePolling()
                // Reset key listener state so hands-free flags don't get stuck when
                // recording ends naturally (time limit, watchdog) rather than via key press.
                keyListener?.resetToggleState()
            }
        }
    }
    let waveformState = WaveformState()
    @Published var errorMessage: String?

    /// Languages already reported as unsupported by the active ASR model, so the notice is shown
    /// once per app session instead of on every recording.
    private var reportedUnforceableLanguages: Set<TranscriptionLanguage> = []

    /// The selected language has no prompt in the loaded model, so it transcribes unconditioned.
    /// Surfaced through `errorMessage` — the same banner every other transcription degradation uses.
    private func reportLanguageForcingUnavailable(_ language: TranscriptionLanguage) {
        guard reportedUnforceableLanguages.insert(language).inserted else { return }
        errorMessage = "\(language.displayName) isn't supported by the current speech model — transcription will be less accurate."
    }
    @Published var liveTranscription: String = ""  // Live transcription during recording
    @Published var recordingSessionID: UUID = UUID()  // Forces SwiftUI state reset between recordings

    /// The committed VAD chunks of the recording in progress, kept so the polisher can read the
    /// silence between them.
    ///
    /// A string cannot carry where the speaker stopped, and that is the one signal that says where
    /// a sentence ended. The chunks are already produced for history persistence; this only retains
    /// them until the endpoint. Cleared at every recording start — see `committedChunks(matching:)`
    /// for why a stale or divergent set is discarded rather than used.
    private var committedChunks: [DeterministicPolisher.Chunk] = []

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
    /// Set when a Whisper model finishes downloading but hasn't been activated yet.
    /// Allows the user to keep recording on the current model and activate when ready.
    @Published var readyToActivateModel: WhisperModel? = nil

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

    // Audio-progress watchdog: independent of AudioRecorder's internal state machine.
    // Bumped by every onAmplitudeUpdate callback. If 15s elapses with no bump while
    // state == .recording, we know the recording is stuck — dump state (DEBUG) and force idle.
    private var lastAmplitudeUpdateTime: Date?
    private let audioProgressStallTimeout: TimeInterval = 15.0

    // Audio quality watchdog: tracks when non-silent audio was last observed.
    // Distinct from lastAmplitudeUpdateTime — callbacks can arrive with rms=0 (broken pipeline).
    // When callbacks flow but amplitude is always zero for 5s+, dump state (DEBUG).
    private var lastNonSilentAmplitudeTime: Date?
    private var hasTriggeredSilentAudioDump: Bool = false

    /// Called from the onAmplitudeUpdate callback chain. Cheap; runs ~100x/sec.
    func noteAudioActivity(amplitude: Float) {
        lastAmplitudeUpdateTime = Date()
        if amplitude >= 0.001 {
            lastNonSilentAmplitudeTime = Date()
        }
    }

    /// Read-only accessors for StuckStateDumper.
    var lastAmplitudeUpdateTimeForDebug: Date? { lastAmplitudeUpdateTime }
    var lastNonSilentAmplitudeTimeForDebug: Date? { lastNonSilentAmplitudeTime }
    var hasTriggeredSilentAudioDumpForDebug: Bool { hasTriggeredSilentAudioDump }
    var streamingTranscriberIsNil: Bool { streamingTranscriber == nil }
    var loadedModelForDebug: WhisperModel? { loadedModel }
    var sileroVADIsNilForDebug: Bool { sileroVAD == nil }
    var modelPoolForDebug: ModelPool? { modelPool }
    var llmEnabledForDebug: Bool { llmEnabled }
    var selectedLLMModelForDebug: LLMModelVariant { selectedLLMModel }
    var llmPostProcessorForDebug: LLMPostProcessor? { llmPostProcessor }

    // Pre-loaded transcription backend - keeps model in memory for instant recording start
    var whisperBridge: TranscriptionBackend?

    /// Read-only access to the pre-loaded backend for file transcription
    var fileTranscriptionBridge: TranscriptionBackend? { whisperBridge }

    /// Singleton manager for file-based transcription — owned here so state survives tab navigation
    let fileTranscriptionManager = FileTranscriptionManager()

    /// Shown when Fn/hotkey is pressed while file transcription is occupying the model
    @Published var showFileTranscribingToast: Bool = false {
        didSet {
            NotificationCenter.default.post(name: NSNotification.Name("AppStateChanged"), object: nil)
        }
    }

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
        case .whisperCpp, .nemotron, .nemotronHebrew, .whisperKit: return nil
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
        case .nemotron: return "Nemotron Multilingual"
        case .nemotronHebrew: return "Nemotron Hebrew"
        case .speechAnalyzer: return "Apple Speech"
        case .whisperKit: return "WhisperKit Turbo"
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

    // Meeting detection notification — shown when a conference app is detected while idle.
    #if !APP_STORE
    @Published var showMeetingDetectedToast: Bool = false {
        didSet {
            NotificationCenter.default.post(name: NSNotification.Name("AppStateChanged"), object: nil)
        }
    }
    @Published var detectedMeetingApp: MeetingDetector.DetectedMeetingApp? = nil

    func showMeetingNotification(app: MeetingDetector.DetectedMeetingApp) {
        detectedMeetingApp = app
        showMeetingDetectedToast = true
        #if canImport(FluidAudio)
        // Kick off engine warm passes as soon as a meeting is detected — before the user
        // taps Start Recording — so the ANE compile costs are already paid.
        MeetingEngines.shared.prefetch()
        #endif
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, self.showMeetingDetectedToast else { return }
            self.dismissMeetingNotification()
        }
    }

    func dismissMeetingNotification() {
        showMeetingDetectedToast = false
        detectedMeetingApp = nil
    }
    #else
    // Stubs so OverlayPanel can reference this property unconditionally.
    var showMeetingDetectedToast: Bool { false }
    #endif

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

    // Nemotron multilingual streaming model state
    @Published var isDownloadingNemotron: Bool = false
    @Published var isLoadingNemotron: Bool = false
    @Published var nemotronDownloadStatus: String = ""
    var nemotronLoadTask: Task<Void, Never>?
    #if canImport(FluidAudio)
    var nemotronBridgeInstance: NemotronBridge?
    #endif

    // Nemotron Hebrew streaming model state
    @Published var isDownloadingNemotronHebrew: Bool = false
    @Published var isLoadingNemotronHebrew: Bool = false
    @Published var nemotronHebrewDownloadStatus: String = ""
    var nemotronHebrewLoadTask: Task<Void, Never>?
    #if canImport(FluidAudio)
    var nemotronHebrewBridgeInstance: NemotronHebrewBridge?
    #endif

    // WhisperKit CoreML backend state
    @Published var isDownloadingWhisperKit: Bool = false
    @Published var isLoadingWhisperKit: Bool = false
    @Published var whisperKitDownloadStatus: String = ""
    var whisperKitDownloadTask: Task<Void, Never>?
    var whisperKitLoadTask: Task<Void, Never>?

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
        isDownloadingNemotron ||
        isLoadingNemotron ||
        isDownloadingNemotronHebrew ||
        isLoadingNemotronHebrew ||
        isDownloadingEou ||
        isLoadingSpeechAnalyzer ||
        isDownloadingWhisperKit ||
        isLoadingWhisperKit
    }

    // LLM post-processing
    @Published var llmEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(llmEnabled, forKey: "llmEnabled")
            if llmEnabled {
                preloadLLM()
            } else {
                // Cancel any in-flight load before unloading
                llmLoadTask?.cancel()
                llmLoadTask = nil
                llmModelSwitchTask?.cancel()
                llmModelSwitchTask = nil

                let memBefore = BenchmarkUtilities.currentMemoryMB()
                let processorToUnload = llmPostProcessor
                llmPostProcessor = nil
                rewriteModeService = nil
                Logger.info("LLM disabled, unloaded (process memory: \(String(format: "%.0f", memBefore))MB)", subsystem: .model)
                Task { await processorToUnload?.unloadModel() }
            }
        }
    }
    @Published var selectedLLMModel: LLMModelVariant = .qwen3_5_4B_mtp {
        didSet {
            UserDefaults.standard.set(selectedLLMModel.rawValue, forKey: "selectedLLMModel")
            if llmEnabled {
                // Cancel any in-flight LLM load and pending model switch to prevent duplicates
                llmLoadTask?.cancel()
                llmLoadTask = nil
                llmModelSwitchTask?.cancel()

                // Unload old model — delay before loading new one to let ARC release GPU buffers
                let memBefore = BenchmarkUtilities.currentMemoryMB()
                Logger.info("Switching LLM: unloading old model (\(String(format: "%.0f", memBefore))MB)", subsystem: .model)
                let processorToSwitch = llmPostProcessor
                llmPostProcessor = nil
                rewriteModeService = nil
                Task { await processorToSwitch?.unloadModel() }

                llmModelSwitchTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms for ARC to release GPU buffers
                    guard let self, self.llmEnabled, !Task.isCancelled else { return }
                    let memAfter = BenchmarkUtilities.currentMemoryMB()
                    Logger.info("LLM unload freed \(String(format: "%.0f", memBefore - memAfter))MB, loading new model", subsystem: .model)
                    self.preloadLLM()
                }
            }
        }
    }
    @Published var llmPostProcessor: LLMPostProcessor?
    @Published var activeAIModeName: String?
    private var llmLoadTask: Task<Void, Never>?
    private var llmModelSwitchTask: Task<Void, Never>?

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

    // Per-chunk LLM correction coordinator
    private let chunkLLMCoordinator = ChunkLLMCoordinator()

    // Long-record session state
    private var currentSessionID: UUID?
    private var idleSleepAssertion: IOPMAssertionID = 0

    // Meeting mode
    @Published private(set) var activeMeetingSession: MeetingSession?
    private(set) var meetingAudioFileURL: String?
    var isMeetingMode: Bool { activeMeetingSession != nil }
    /// A meeting records silently on both edges. The feature exists to make starting one cost
    /// nothing socially — a Tink mid-call announces it, and the Pop at the end announces it to
    /// everyone still on the line. Deliberately independent of the Sound Effects picker, which
    /// governs dictation: "Default" there must not put a sound into a meeting.
    var suppressesFeedbackSound: Bool { isMeetingMode }
    private var isMeetingStopInFlight = false
    #if canImport(FluidAudio)
    /// Live speaker diarization for the current meeting. Nil on non-Nemotron backends
    /// or when the Sortformer model isn't on disk — the meeting then records exactly as
    /// it did before, everything under "Speaker 1".
    private var meetingSpeakerCoordinator: MeetingSpeakerCoordinator?
    /// Serializes `coordinator.feed()` calls. Feeding an actor from the audio callback
    /// without chaining lets re-entrancy across the ANE `await` interleave buffers.
    private var diarizerFeedTask: Task<Void, Never>?
    /// True while a meeting holds its own Nemotron bridge.
    ///
    /// Meetings need Nemotron (it is the only backend whose partial callback delivers the
    /// growing accumulated transcript that speaker attribution diffs against), but they no
    /// longer take it by switching `selectedBackendType`. That switch cost a teardown plus a
    /// reload on the way in and again on the way out — ~62s per meeting for anyone whose
    /// dictation backend isn't Nemotron, with the return leg landing on top of the
    /// post-meeting AI work. The bridge is now loaded alongside the user's backend and
    /// released through `ModelWorkQueue` once the AI tail has drained.
    private var meetingOwnsNemotron = false
    /// Set when free memory was too tight to hold the user's backend and Nemotron at once,
    /// so the user's bridge was evicted for the duration of the meeting and must be reloaded
    /// afterwards. `selectedBackendType` is still never written.
    private var meetingEvictedUserBackend = false
    #endif

    /// The backend the in-app recording path (meetings, workspace recorder) should drive.
    ///
    /// A meeting borrows Nemotron through its own bridge instead of switching
    /// `selectedBackendType`, so while one is running this reports `.nemotron` and the
    /// user's dictation backend stays exactly as they left it.
    var effectiveInAppBackend: BackendType {
        #if canImport(FluidAudio)
        if meetingOwnsNemotron, nemotronBridgeInstance != nil { return .nemotron }
        #endif
        return selectedBackendType
    }

    @Published var meetingWindowIsVisible: Bool = false {
        didSet { NotificationCenter.default.post(name: NSNotification.Name("AppStateChanged"), object: nil) }
    }

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

    // MCP server
    @Published var mcpEnabled: Bool = true {
        didSet { UserDefaults.standard.set(mcpEnabled, forKey: "mcpEnabled") }
    }
    @Published var mcpPort: Int = 8080 {
        didSet { UserDefaults.standard.set(mcpPort, forKey: "mcpPort") }
    }
    @Published var mcpServerRunning: Bool = false
    @Published var mcpBonjourReady: Bool = false
    @Published var mcpBonjourHostname: String? = nil  // machine's .local hostname, set at launch

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
        // Load auto-paste preference. Default ON for direct distribution — clipboard-only is App Store compliance, not the preferred UX.
        if UserDefaults.standard.object(forKey: "autoPasteEnabled") != nil {
            _autoPasteEnabled = Published(wrappedValue: UserDefaults.standard.bool(forKey: "autoPasteEnabled"))
        } else {
            _autoPasteEnabled = Published(wrappedValue: true)
            UserDefaults.standard.set(true, forKey: "autoPasteEnabled")
        }

        // Enable accessibility tracking if auto-paste was previously enabled
        if autoPasteEnabled {
            PermissionManager.shared.enableAccessibilityTracking()
            if !AXIsProcessTrusted() {
                let recoveryKey = "accessibilityAutoRecoveryAttempted"
                if !UserDefaults.standard.bool(forKey: recoveryKey) {
                    // First time we detect a lost/stale permission: do a one-shot
                    // auto-recovery. Mark immediately so repeated crashes don't loop.
                    UserDefaults.standard.set(true, forKey: recoveryKey)
                    let bundleID = Bundle.main.bundleIdentifier ?? "com.ivy.whisperer"
                    DispatchQueue.global(qos: .userInitiated).async {
                        // Best-effort: remove our own stale TCC entry before re-requesting.
                        // tccutil can reset an app's own accessibility entry without sudo.
                        // If it fails (permission denied or unavailable), we proceed anyway —
                        // the onboarding requestAccessibilityPermission call still works.
                        let task = Process()
                        task.launchPath = "/usr/bin/tccutil"
                        task.arguments = ["reset", "Accessibility", bundleID]
                        do {
                            try task.run()
                            task.waitUntilExit()
                            Logger.debug("tccutil reset Accessibility exited \(task.terminationStatus)", subsystem: .permissions)
                        } catch {
                            Logger.debug("tccutil reset skipped: \(error.localizedDescription)", subsystem: .permissions)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            // Only re-open onboarding if user hasn't completed it.
                            // For completed users, the menu bar permission badge handles recovery UX.
                            guard !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return }
                            OnboardingWindowManager.shared.show(startingAtPage: 4)
                        }
                    }
                }
                // If recovery was already attempted, the main UI warning is shown;
                // don't re-open onboarding on every launch.
            } else {
                // Permission valid — clear recovery flag so future permission-loss
                // events (e.g. next macOS upgrade) get the same seamless auto-recovery.
                UserDefaults.standard.removeObject(forKey: "accessibilityAutoRecoveryAttempted")
            }
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
        } else if UserDefaults.standard.object(forKey: "selectedBackendType") == nil,
                  BackendType.parakeet.isAvailable,
                  BackendType.parakeet.supportsLanguage(selectedLanguage, parakeetVariant: .v3) {
            // First launch on Apple Silicon with a Parakeet-supported language → default to Parakeet TDT
            selectedBackendType = .parakeet
        }
        if let savedParakeet = UserDefaults.standard.string(forKey: "selectedParakeetModel"),
           let parakeetModel = ParakeetModelVariant(rawValue: savedParakeet) {
            selectedParakeetModel = parakeetModel
        }

        // Load LLM settings
        if UserDefaults.standard.object(forKey: "llmEnabled") != nil {
            _llmEnabled = Published(wrappedValue: UserDefaults.standard.bool(forKey: "llmEnabled"))
        }
        // The key is written only in selectedLLMModel's didSet, so its absence means the user never
        // touched the picker — they fall through to the current default (Qwen3.5-4B MTP, the model
        // the Correct prompt is measured against). A stored
        // value is a deliberate choice and is preserved, including "Whisperer V3": silently pulling
        // 1.6GB onto someone who picked the 0.3GB model is a surprise, not a migration.
        if let savedLLMModel = UserDefaults.standard.string(forKey: "selectedLLMModel"),
           let llmModel = LLMModelVariant(rawValue: savedLLMModel) {
            // Migrate old default 4B to the faster MTP variant
            let migrated: LLMModelVariant = llmModel == .qwen3_5_4B ? .qwen3_5_4B_mtp : llmModel
            _selectedLLMModel = Published(wrappedValue: migrated)
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

        // Load MCP server settings
        if UserDefaults.standard.object(forKey: "mcpEnabled") != nil {
            _mcpEnabled = Published(wrappedValue: UserDefaults.standard.bool(forKey: "mcpEnabled"))
        }
        if UserDefaults.standard.object(forKey: "mcpPort") != nil {
            _mcpPort = Published(wrappedValue: UserDefaults.standard.integer(forKey: "mcpPort"))
        }

        // Start monitoring audio device changes (for UI device picker only)
        audioDeviceManager.startMonitoring()

        // Wire per-chunk LLM corrector. Uses applyLLMPostProcessing which guards on
        // llmEnabled, model loaded, and mode.supportsChunkProcessing before invoking the LLM.
        chunkLLMCoordinator.corrector = { [weak self] text, contextTail in
            guard let self else { return text }
            return await self.applyLLMPostProcessing(text, contextTail: contextTail)
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

        // Parakeet/Nemotron don't use the WhisperCpp routing pipeline
        if (backend == .parakeet || backend == .nemotron || backend == .nemotronHebrew) && modelPool != nil {
            modelPool?.releaseAll()
            modelPool = nil
        }

        preloadModel()
    }

    /// Release the active transcription bridge and all satellite resources (EOU, VAD, CTC)
    func releaseCurrentBridge() {
        let memBefore = BenchmarkUtilities.currentMemoryMB()

        // Cancel in-flight load tasks to prevent them from setting the bridge after we nil it
        whisperLoadTask?.cancel()
        whisperLoadTask = nil
        parakeetLoadTask?.cancel()
        parakeetLoadTask = nil
        speechAnalyzerLoadTask?.cancel()
        speechAnalyzerLoadTask = nil
        #if canImport(FluidAudio)
        // A meeting-initiated Nemotron load must survive a backend switch — see meetingOwnsNemotron.
        if !meetingOwnsNemotron {
            nemotronLoadTask?.cancel()
            nemotronLoadTask = nil
        }
        #else
        nemotronLoadTask?.cancel()
        nemotronLoadTask = nil
        #endif
        nemotronHebrewLoadTask?.cancel()
        nemotronHebrewLoadTask = nil
        whisperKitDownloadTask?.cancel()
        whisperKitDownloadTask = nil
        whisperKitLoadTask?.cancel()
        whisperKitLoadTask = nil
        isLoadingWhisperKit = false
        isDownloadingWhisperKit = false

        // Release Nemotron bridge if loaded
        #if canImport(FluidAudio)
        // A meeting-owned bridge survives backend switches — the meeting is recording through
        // it right now, and it is not the user's selected backend to begin with.
        if let nemotron = nemotronBridgeInstance, !meetingOwnsNemotron {
            Task { await nemotron.prepareForShutdown() }
            nemotronBridgeInstance = nil
            isLoadingNemotron = false
        }
        if let hebrew = nemotronHebrewBridgeInstance {
            Task { await hebrew.prepareForShutdown() }
            nemotronHebrewBridgeInstance = nil
            isLoadingNemotronHebrew = false
        }
        #endif

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
        // Do NOT set state = .downloadingModel — recording must remain available while downloading

        do {
            try await ModelDownloader.shared.downloadModel(model, progressCallback: { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
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

            // Don't auto-activate — let the user decide when to switch.
            // If no model is currently loaded (e.g. first download), activate immediately.
            guard selectedBackendType == .whisperCpp else {
                Logger.info("Backend switched during download, skipping activation of \(model.displayName)", subsystem: .model)
                return
            }
            if isModelLoaded {
                readyToActivateModel = model
            } else {
                selectModel(model)
            }
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
    }

    /// Activate a model that finished downloading. No-op while recording is in progress.
    func activateReadyModel() {
        guard state == .idle, let model = readyToActivateModel else { return }
        Logger.info("Activating ready model: \(model.displayName)", subsystem: .model)
        readyToActivateModel = nil
        selectModel(model)
    }

    // MARK: - Model Loading

    /// Pre-load the Whisper model into memory for instant recording start
    /// Call this once after model download completes
    func preloadModel() {
        // Skip heavy model loading during unit tests
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            Logger.info("Skipping Whisper preload in test environment", subsystem: .model)
            return
        }

        switch selectedBackendType {
        case .whisperCpp:
            preloadWhisperCppModel()
        case .parakeet:
            preloadParakeetModel()
        case .nemotron:
            preloadNemotronModel()
        case .nemotronHebrew:
            preloadNemotronHebrewModel()
        case .speechAnalyzer:
            preloadSpeechAnalyzer()
        case .whisperKit:
            preloadWhisperKitModel()
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

        // No Core ML encoder download. whisper.cpp's ANE encoder costs a 19s main-thread block at
        // load and is up to 3.1× slower per streaming pass than Metal with a sized `audio_ctx` —
        // see `WhisperBridge.purgeCoreMLEncoder(besideModelAt:)`, which also deletes any encoder a
        // previous build already installed. This sweeps the download leftovers that never reach a
        // load path (the `.mlmodelc.zip`, `__MACOSX`), reclaiming a few hundred MB.
        Task.detached(priority: .background) {
            ModelDownloader.shared.purgeCoreMLEncoderArtifacts(for: model)
            ModelDownloader.shared.purgeCoreMLEncoderArtifacts(for: .tiny)
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
                    guard !Task.isCancelled else { return }
                    guard self.selectedModel == model else { return }

                    // Safety: release any existing bridge that might still be loaded
                    if let old = self.whisperBridge {
                        old.prepareForShutdown()
                        self.whisperBridge = nil
                        Logger.warning("Safety release of existing bridge during Whisper preload", subsystem: .model)
                    }

                    self.whisperBridge = bridge
                    HealthManager.shared.register(bridge)
                    self.loadedModel = model
                    self.loadedParakeetModel = nil
                    self.isModelLoaded = true
                    self.loadedBackendType = .whisperCpp
                    self.isLoadingWhisper = false
                    self.preloadVAD()
                    self.preloadLanguageRouting()
                    self.preloadLLM()

                    Logger.info("Whisper model loaded. Process memory: \(String(format: "%.0f", BenchmarkUtilities.currentMemoryMB()))MB", subsystem: .model)
                }
            } catch WhisperError.modelCorrupted {
                guard !Task.isCancelled else { return }
                Logger.error("Model corrupted, deleting and re-queuing download: \(modelDisplayName)", subsystem: .model)
                // Delete corrupted file and clear cached hash so next load stores a fresh one
                try? FileManager.default.removeItem(at: path)
                let hashKey = "modelSHA256_\(path.lastPathComponent)"
                UserDefaults.standard.removeObject(forKey: hashKey)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isLoadingWhisper = false
                    self.errorMessage = "\(modelDisplayName) was corrupted and has been removed. Please re-download it."
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
                    self.preloadLLM()

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

    // MARK: - Nemotron

    #if canImport(FluidAudio)
    func isNemotronModelCached() -> Bool { NemotronBridge.isModelCached() }

    func downloadNemotronModel() {
        guard !isDownloadingNemotron else { return }
        isDownloadingNemotron = true
        nemotronDownloadStatus = "Downloading Nemotron Multilingual..."
        downloadProgress = 0
        state = .downloadingModel(progress: 0)

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await NemotronBridge.download { [weak self] downloadProgress in
                    let fraction = downloadProgress.fractionCompleted
                    Task { @MainActor [weak self] in
                        guard let self, self.isDownloadingNemotron else { return }
                        self.downloadProgress = fraction
                        self.state = .downloadingModel(progress: fraction)
                    }
                }
                Logger.info("Nemotron multilingual downloaded", subsystem: .model)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isDownloadingNemotron = false
                    self.nemotronDownloadStatus = ""
                    self.downloadProgress = 0
                    self.state = .idle
                    if self.selectedBackendType == .nemotron {
                        self.preloadNemotronModel()
                    }
                }
            } catch {
                Logger.error("Failed to download Nemotron: \(error)", subsystem: .model)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isDownloadingNemotron = false
                    self.nemotronDownloadStatus = ""
                    self.downloadProgress = 0
                    self.state = .idle
                    self.errorMessage = "Failed to download Nemotron: \(error.localizedDescription)"
                }
            }
        }
    }

    func preloadNemotronModel() {
        guard isNemotronModelCached() else {
            Logger.info("Nemotron not cached — download first", subsystem: .model)
            return
        }

        isLoadingNemotron = true
        nemotronDownloadStatus = "Loading Nemotron..."

        nemotronLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let bridge = try await ModelWorkQueue.shared.run("nemotron-load") {
                    try await NemotronBridge.loadFromCache()
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Meetings load this bridge for themselves without touching the user's
                    // backend selection, so always keep the instance. Only the user-visible
                    // "this is the loaded backend" state is gated on their actual choice.
                    self.nemotronBridgeInstance = bridge
                    self.isLoadingNemotron = false
                    self.nemotronDownloadStatus = ""
                    guard self.selectedBackendType == .nemotron else {
                        Logger.info("Nemotron multilingual ready (meeting-owned)", subsystem: .model)
                        return
                    }
                    self.isModelLoaded = true
                    self.loadedBackendType = .nemotron
                    self.preloadLLM()
                    Logger.info("Nemotron multilingual ready", subsystem: .model)
                }
            } catch {
                Logger.error("Failed to load Nemotron: \(error)", subsystem: .model)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isLoadingNemotron = false
                    self.nemotronDownloadStatus = ""
                    self.errorMessage = "Failed to load Nemotron: \(error.localizedDescription)"
                }
            }
        }
    }
    // MARK: - Nemotron Hebrew

    func isNemotronHebrewModelCached() -> Bool { NemotronHebrewBridge.isModelCached() }

    func downloadNemotronHebrewModel() {
        guard !isDownloadingNemotronHebrew else { return }
        isDownloadingNemotronHebrew = true
        nemotronHebrewDownloadStatus = "Downloading Nemotron Hebrew..."
        downloadProgress = 0
        state = .downloadingModel(progress: 0)

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await NemotronHebrewBridge.download { [weak self] downloadProgress in
                    let fraction = downloadProgress.fractionCompleted
                    Task { @MainActor [weak self] in
                        guard let self, self.isDownloadingNemotronHebrew else { return }
                        self.downloadProgress = fraction
                        self.state = .downloadingModel(progress: fraction)
                    }
                }
                Logger.info("Nemotron Hebrew downloaded", subsystem: .model)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isDownloadingNemotronHebrew = false
                    self.nemotronHebrewDownloadStatus = ""
                    self.downloadProgress = 0
                    self.state = .idle
                    if self.selectedBackendType == .nemotronHebrew {
                        self.preloadNemotronHebrewModel()
                    }
                }
            } catch {
                Logger.error("Failed to download Nemotron Hebrew: \(error)", subsystem: .model)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isDownloadingNemotronHebrew = false
                    self.nemotronHebrewDownloadStatus = ""
                    self.downloadProgress = 0
                    self.state = .idle
                    self.errorMessage = "Failed to download Nemotron Hebrew: \(error.localizedDescription)"
                }
            }
        }
    }

    func preloadNemotronHebrewModel() {
        guard isNemotronHebrewModelCached() else {
            Logger.info("Nemotron Hebrew not cached — download first", subsystem: .model)
            return
        }

        isLoadingNemotronHebrew = true
        nemotronHebrewDownloadStatus = "Loading Nemotron Hebrew..."

        nemotronHebrewLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let bridge = try await ModelWorkQueue.shared.run("nemotron-hebrew-load") {
                    try await NemotronHebrewBridge.loadFromCache()
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard self.selectedBackendType == .nemotronHebrew else { return }
                    self.nemotronHebrewBridgeInstance = bridge
                    self.isModelLoaded = true
                    self.loadedBackendType = .nemotronHebrew
                    self.isLoadingNemotronHebrew = false
                    self.nemotronHebrewDownloadStatus = ""
                    self.preloadLLM()
                    Logger.info("Nemotron Hebrew ready", subsystem: .model)
                }
            } catch {
                Logger.error("Failed to load Nemotron Hebrew: \(error)", subsystem: .model)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isLoadingNemotronHebrew = false
                    self.nemotronHebrewDownloadStatus = ""
                    self.errorMessage = "Failed to load Nemotron Hebrew: \(error.localizedDescription)"
                }
            }
        }
    }
    #else
    func isNemotronModelCached() -> Bool { false }
    func downloadNemotronModel() { }
    func preloadNemotronModel() { }
    func isNemotronHebrewModelCached() -> Bool { false }
    func downloadNemotronHebrewModel() { }
    func preloadNemotronHebrewModel() { }
    #endif

    // MARK: - WhisperKit

    func isWhisperKitModelCached() -> Bool {
        #if canImport(WhisperKit)
        return WhisperKitBridge.isModelCached()
        #else
        return false
        #endif
    }

    func downloadWhisperKitModel() {
        #if canImport(WhisperKit)
        guard !isDownloadingWhisperKit else { return }
        isDownloadingWhisperKit = true
        whisperKitDownloadStatus = "Downloading WhisperKit…"
        downloadProgress = 0
        state = .downloadingModel(progress: 0)

        whisperKitDownloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await WhisperKitBridge.download { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.isDownloadingWhisperKit else { return }
                        self.downloadProgress = fraction
                        self.state = .downloadingModel(progress: fraction)
                    }
                }
                Logger.info("WhisperKit model downloaded", subsystem: .model)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isDownloadingWhisperKit = false
                    self.whisperKitDownloadStatus = ""
                    self.downloadProgress = 0
                    self.state = .idle
                    if self.selectedBackendType == .whisperKit {
                        self.preloadWhisperKitModel()
                    }
                }
            } catch {
                Logger.error("Failed to download WhisperKit: \(error)", subsystem: .model)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isDownloadingWhisperKit = false
                    self.whisperKitDownloadStatus = ""
                    self.downloadProgress = 0
                    self.state = .idle
                    self.errorMessage = "Failed to download WhisperKit: \(error.localizedDescription)"
                }
            }
        }
        #endif
    }

    func preloadWhisperKitModel() {
        #if canImport(WhisperKit)
        guard isWhisperKitModelCached(), !isLoadingWhisperKit else { return }
        isLoadingWhisperKit = true
        whisperKitDownloadStatus = "Loading WhisperKit…"

        whisperKitLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let bridge = try await WhisperKitBridge.loadFromCache()
                Logger.info("[AppState] WhisperKit model loaded, checking warmup state", subsystem: .model)
                // Warm-up pass: force CoreML decoder JIT before the first user recording.
                // IMPORTANT: silence triggers noSpeechThreshold (0.6) early-exit BEFORE the
                // decoder runs — so silence warmup never JITs the decoder. Use a 440Hz sine wave
                // (speech-like energy) to force the full encoder+decoder pipeline.
                // Uses async path (not transcribe()) to avoid blocking a thread pool thread
                // and triggering HealthManager's "main thread unresponsive" false positive.
                // Skipped on subsequent launches if CoreML is already compiled for this OS version.
                let warmupKey = "whisperKitWarmupVersion"
                let warmupTag = "\(WhisperKitBridge.modelVariant)_\(ProcessInfo.processInfo.operatingSystemVersionString)"
                let alreadyWarmed = UserDefaults.standard.string(forKey: warmupKey) == warmupTag
                if !alreadyWarmed {
                    let sampleRate: Float = 16000
                    let warmupSamples: [Float] = (0..<32000).map { i in
                        0.3 * sin(2 * Float.pi * 440 * Float(i) / sampleRate)
                    }
                    let wt = CFAbsoluteTimeGetCurrent()
                    await withCheckedContinuation { cont in
                        bridge.transcribeAsync(samples: warmupSamples, initialPrompt: nil, language: .auto, singleSegment: false, maxTokens: 0) { _ in cont.resume() }
                    }
                    Logger.info("[AppState] WhisperKit warmup complete in \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - wt) * 1000))ms", subsystem: .model)
                    UserDefaults.standard.set(warmupTag, forKey: warmupKey)
                } else {
                    Logger.info("[AppState] WhisperKit decoder already warmed for this OS version, skipping", subsystem: .model)
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Transactional swap: shut down old backend AFTER new one is live
                    let old = self.whisperBridge
                    self.whisperBridge = bridge
                    self.isModelLoaded = true
                    self.loadedBackendType = .whisperKit
                    self.isLoadingWhisperKit = false
                    self.whisperKitDownloadStatus = ""
                    Logger.info("[AppState] WhisperKit active (transactional swap)", subsystem: .model)
                    old?.prepareForShutdown()
                    self.preloadLLM()
                }
                await self?.preloadVAD()
            } catch {
                Logger.error("Failed to load WhisperKit: \(error)", subsystem: .model)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isLoadingWhisperKit = false
                    self.whisperKitDownloadStatus = ""
                    // Prior backend remains active as fallback — do NOT clear whisperBridge
                    self.errorMessage = "WhisperKit load failed — previous backend still active. \(error.localizedDescription)"
                }
            }
        }
        #endif
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
                    self.preloadLLM()

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
        // Skip in test environment - tests load LLM directly
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        guard llmEnabled else { return }

        // Cancel any in-flight load to prevent duplicate model instances
        llmLoadTask?.cancel()

        let processor = llmPostProcessor ?? LLMPostProcessor()
        llmPostProcessor = processor

        // Skip if already loading or already loaded
        if processor.isLoading || processor.isModelLoaded { return }

        let variant = selectedLLMModel

        let memBefore = BenchmarkUtilities.currentMemoryMB()
        // Detached so this task does not inherit @MainActor — the heavy MLX weight loading and
        // ChatSession inference must not run on the main thread. @MainActor async methods
        // (loadModel, warmupPrompt) auto-hop to the main actor when awaited; non-async @MainActor
        // access (AIModeManager, splitPrompt) is wrapped in MainActor.run { }.
        llmLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // Weights + warmup are one queue slot: a warmup that lands on top of another
                // family's ANE load is exactly the contention this queue exists to remove.
                try await ModelWorkQueue.shared.run("llm-load") {
                    try await processor.loadModel(variant)
                    let memAfter = BenchmarkUtilities.currentMemoryMB()
                    Logger.info("LLM \(variant.displayName) pre-loaded. Process memory: \(String(format: "%.0f", memBefore))MB → \(String(format: "%.0f", memAfter))MB (+\(String(format: "%.0f", memAfter - memBefore))MB)", subsystem: .model)
                    // Warm up the system prompt KV cache now — absorbs the cold-start prefill penalty
                    // (897ms–24s) into the model load phase rather than the first user transcription.
                    if let self = self {
                        // Gather prompt on main actor (AIModeManager + splitPrompt are @MainActor
                        // non-async, so they need an explicit MainActor.run hop).
                        let sysPrompt: String = await MainActor.run {
                            let mode = AIModeManager.shared.postProcessMode
                            var (prompt, _) = self.splitPrompt(mode.prompt, text: ".")
                            if let lang = mode.targetLanguage, !lang.isEmpty {
                                prompt += " Translate to \(lang)."
                            }
                            return prompt
                        }
                        await processor.warmupPrompt(sysPrompt)
                    }
                }
            } catch {
                Logger.error("Failed to pre-load LLM \(variant.displayName): \(error)", subsystem: .model)
                let msg = "Failed to load model"
                // Write error state to the current processor, not a potentially stale capture
                await MainActor.run {
                    self?.llmPostProcessor?.errorMessage = msg
                    self?.llmPostProcessor?.loadPhase = .error(msg)
                    self?.llmPostProcessor?.isLoading = false
                }
            }
        }
    }

    /// Remove structural prompt tags that the LLM occasionally echoes in its output.
    private static func stripStructuralTags(_ text: String) -> String {
        var out = text
        // Remove complete [CONTEXT=previous]...[/CONTEXT] blocks (including multiline)
        if let regex = try? NSRegularExpression(pattern: #"\[CONTEXT=previous\][\s\S]*?\[/CONTEXT\]"#) {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "")
        }
        // Remove any remaining bare structural tags (including truncated [/INPUT without ])
        for tag in ["[CONTEXT=previous]", "[/CONTEXT]", "[INPUT]", "[/INPUT]", "[/INPUT"] {
            out = out.replacingOccurrences(of: tag, with: "")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split an AIMode prompt on {transcript} into system prompt + user message wrapper
    private func splitPrompt(_ prompt: String, text: String) -> (systemPrompt: String, userMessage: String) {
        let parts = prompt.components(separatedBy: "{transcript}")
        var systemPart = parts[0]
        // Strip trailing [INPUT]\n from system prompt (it belongs in user message)
        if let inputRange = systemPart.range(of: "[INPUT]", options: .backwards) {
            systemPart = String(systemPart[..<inputRange.lowerBound])
        }
        systemPart = systemPart.trimmingCharacters(in: .whitespacesAndNewlines)
        let userMessage = "[INPUT]\n\(text)\n[/INPUT]"
        return (systemPart, userMessage)
    }

    /// Keep a committed chunk for the endpoint polish.
    ///
    /// `start` and `end` come from `TranscriptChunk`, which derives them from sample counts, not
    /// from ASR word timings — so this signal exists identically behind every backend, including
    /// the ones that emit no per-word evidence at all.
    private func retainForPolish(_ chunk: TranscriptChunk) {
        committedChunks.append(DeterministicPolisher.Chunk(text: chunk.text,
                                                           start: chunk.start,
                                                           end: chunk.end))
    }

    /// The retained chunks, but only when they still describe `text`.
    ///
    /// `stopAsync` joins the committed chunks and *then* applies dictionary correction and filler
    /// removal, and `applyListFormatting` may reflow the result — so what reaches the polisher is
    /// not always the join. When the two diverge the pause map would be keyed to whitespace tokens
    /// that no longer sit where the joins were, and a mis-keyed pause is worse than no pause: it
    /// ends a sentence in the middle of one. So this returns nil and the caller polishes the plain
    /// string, losing the acoustic signal rather than misusing it.
    ///
    /// Sorted by start because the chunks are appended from a callback whose main-actor hops are
    /// not ordered against each other. If the sort disagrees with how the text was assembled, the
    /// equality check below rejects the set anyway.
    private func committedChunks(matching text: String) -> [DeterministicPolisher.Chunk]? {
        let ordered = committedChunks.sorted { $0.start < $1.start }
        let pieces = ordered.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
        guard pieces.count > 1 else { return nil }
        guard Self.whitespaceCollapsed(pieces.joined(separator: " "))
                == Self.whitespaceCollapsed(text) else { return nil }
        return ordered
    }

    private static func whitespaceCollapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Apply LLM post-processing to transcribed text if enabled.
    /// `contextTail`: non-nil signals this is a mid-stream chunk (fragment mode).
    /// The value itself is NOT injected into the user message — doing so causes the model
    /// to echo the context content into its output. Instead, a fragment-mode instruction
    /// is added to the system prompt telling the model to preserve boundary capitalization.
    private func applyLLMPostProcessing(_ text: String, contextTail: String? = nil) async -> String {
        guard llmEnabled, let processor = llmPostProcessor, processor.isModelLoaded else {
            return text
        }

        // Skip AI post-processing if text has no real word content (silence/hallucination leak)
        guard text.contains(where: { $0.isLetter }) else {
            return text
        }

        let mode = AIModeManager.shared.postProcessMode
        guard !mode.prompt.isEmpty else { return text }

        // Deterministic polish *instead of* the model, in strict correction modes only.
        //
        // Everything the Correct prompt does — fillers, duplicates, whitespace, aliases, casing,
        // and now sentence punctuation from the pauses in the speech itself — happens on the token
        // graph. So the strict path is non-generative end to end: no wording is invented, every
        // change is one gated edit, and the utterance is finished in single-digit milliseconds
        // rather than seconds. This also replaces the old `text.count <= 15` fast path; length was
        // never the question.
        //
        // Transformative modes (translate, summarize, rewrite) keep the previous path untouched —
        // their output is genuinely new wording, which is the one job that needs a generative
        // model. The 4B does not unload; it leaves the dictation latency path.
        //
        // List formatting is off here because both call sites already ran `applyListFormatting`.
        //
        // Behind `PolishFeatureFlags` while it is experimental. Off is not an approximation of the
        // shipped path — it *is* the shipped path, `text.count <= 15` fast path included, because
        // an A/B whose control drifted from what ships cannot attribute a bad result to an arm.
        let isStrict = (mode.id == AIMode.correctModeId || mode.id == AIMode.grammarModeId)
        let input = text
        if PolishFeatureFlags.isFastPolishEnabled {
            if isStrict {
                let polisher = DeterministicPolisher.forTranscript(
                    dictionaryEntries: DictionaryManager.shared.entries,
                    formatsLists: false)
                // Chunks when they are still an honest description of this text, the string
                // otherwise. The chunk form is what carries the silence between them, and silence
                // is the only evidence of a sentence boundary that survives every backend.
                let chunks = contextTail == nil ? committedChunks(matching: text) : nil
                let polished = chunks.map { polisher.polish(chunks: $0) }
                    ?? polisher.polish(text: text)
                Logger.debug("polish: \(PolishFeatureFlags.stateDescription), "
                             + "\(polished.appliedEdits.count) edits, "
                             + "\(chunks?.count ?? 0) chunks", subsystem: .transcription)

                // Arm B: the deterministic path is terminal in strict correction modes. The 4B is
                // not consulted at all, which is the whole point — a decode the user waits ~1.8s
                // for, to adjust punctuation the pipeline has already restored from the pauses in
                // their own speech, is a cost with no matching benefit.
                //
                // `needsGenerativePass` stays computed and logged rather than deleted. It was the
                // control flow; now it is the diagnostic that says how often the deterministic
                // output still looks unfinished, which is the number that would justify bringing
                // the fallback back. A predicate that stops being observable the moment it stops
                // being load-bearing is how a regression hides.
                Logger.debug("LLM skip: deterministic polish is terminal "
                             + "(\(polished.appliedEdits.count) edits, "
                             + "residual=\(polished.needsGenerativePass))", subsystem: .transcription)
                return polished.text
            }
        } else {
            // Fast-path: skip LLM for very short, already-clean text in strict correction modes.
            // Pre-cleaner handles filler removal and dedup; LLM adds no value for "OK." or "Yes."
            if text.count <= 15 {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let firstUpper = trimmed.first?.isUppercase ?? false
                let endsPunct = ".!?".contains(trimmed.last ?? Character(" "))
                if firstUpper && endsPunct && isStrict {
                    Logger.debug("LLM skip: short clean text (\(trimmed.count) chars)", subsystem: .transcription)
                    return text
                }
            }
        }

        activeAIModeName = mode.name
        defer { activeAIModeName = nil }

        do {
            // Pre-clean: normalize, dedup, protect tokens
            let precleanResult = TranscriptPreCleaner.preclean(input)

            // Split prompt into system prompt + user message with [INPUT] envelope.
            // When correcting a chunk, prepend the previous chunk's tail so the LLM
            // has sentence-boundary context and won't over-punctuate at the cut point.
            var (systemPrompt, baseUserMessage) = splitPrompt(mode.prompt, text: precleanResult.text)
            // Explicitly forbid echoing the user-message delimiters. Short streaming chunks are
            // out-of-distribution for the fine-tuned model and occasionally trigger [/INPUT echoing.
            systemPrompt += "\nDo not include [INPUT] or [/INPUT] in your response."
            let userMessage: String
            // contextTail non-nil signals "fragment mode" (mid-stream chunk, not full text).
            // Inject only into the system prompt — never into the user message.
            // Injecting context into the user message causes the model to echo its content.
            if contextTail != nil {
                systemPrompt += "\n\nThis is a speech fragment from a continuous dictation stream — it may begin or end mid-sentence. Do NOT capitalize the first word unless the source already capitalizes it or it is a proper noun/acronym. Do NOT add terminal punctuation (.!?) at the end unless the source already contains it."
            }
            userMessage = baseUserMessage

            Logger.step(.asrStart, .transcription, ["mode": .string(mode.name), "in": .string(Logger.redact(precleanResult.text))])

            var processed = try await processor.process(
                text: precleanResult.text,
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                targetLanguage: mode.targetLanguage,
                temperature: mode.temperature,
                topP: mode.topP,
                topK: mode.topK,
                repetitionPenalty: mode.repetitionPenalty,
                maxTokensCap: mode.maxTokensCap
            )

            // Strip any leaked structural tags — the LLM must never reproduce them
            // but occasionally does when context blocks are present.
            processed = Self.stripStructuralTags(processed)

            // Restore protected tokens
            processed = TranscriptPreCleaner.restorePlaceholders(processed, precleanResult.placeholders)

            // Post-validate output
            let profile = TranscriptPostValidator.profileFor(modeId: mode.id)
            let (valid, reason) = TranscriptPostValidator.validate(
                original: precleanResult.text,
                processed: processed,
                profile: profile
            )
            if !valid {
                Logger.warning("LLM output failed validation (\(reason ?? "unknown")), using pre-cleaned original", subsystem: .transcription)
                return TranscriptPreCleaner.restorePlaceholders(precleanResult.text, precleanResult.placeholders)
            }

            Logger.step(.asrDone, .transcription, ["mode": .string(mode.name), "in": .int(input.count), "out": .int(processed.count)])
            return processed
        } catch {
            // The deterministic result, not the raw one: every edit in it was gated, so it is
            // strictly closer to the intended output than what the ASR emitted.
            Logger.error("LLM post-processing failed: \(error)", subsystem: .transcription)
            return input
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

        let mode = AIModeManager.shared.rewriteMode
        let rewritePrompt = mode.prompt.isEmpty ? nil : mode.prompt.replacingOccurrences(of: "{transcript}", with: "")
        do {
            let result = try await service.process(
                instruction: transcription,
                selectedText: capturedSelectedText,
                rewritePrompt: rewritePrompt
            )
            Logger.step(.asrDone, .transcription, ["mode": .string(mode.name), "in": .int(transcription.count), "out": .int(result.count)])
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
                let listMode = AIMode.builtInDefault(for: AIMode.listFormatModeId) ?? AIMode.defaultMode()
                let (listSystemPrompt, listUserMessage) = splitPrompt(listMode.prompt, text: text)
                let llmResult = try await processor.process(
                    text: text,
                    systemPrompt: listSystemPrompt,
                    userMessage: listUserMessage,
                    temperature: listMode.temperature,
                    topP: listMode.topP,
                    topK: listMode.topK,
                    repetitionPenalty: listMode.repetitionPenalty,
                    maxTokensCap: listMode.maxTokensCap
                )
                Logger.step(.asrDone, .transcription, ["mode": .string("list-llm"), "in": .int(text.count), "out": .int(llmResult.count)])
                return llmResult
            } catch {
                Logger.error("LLM list formatting failed: \(error)", subsystem: .transcription)
                return text
            }
        }

        if result != text {
            Logger.step(.asrDone, .transcription, ["mode": .string("list"), "in": .int(text.count), "out": .int(result.count)])
        }

        return result
    }

    /// Pre-load the Silero VAD model for voice activity detection
    /// VAD is completely optional - the app works fine without it
    func preloadVAD() {
        // Skip in test environment
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
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
        // Skip in test environment
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        guard routingConfig.isRoutingEnabled else {
            Logger.debug("Language routing disabled (single language)", subsystem: .model)
            return
        }

        // Parakeet/Nemotron detect language natively — skip WhisperBridge detection + ModelPool.
        guard selectedBackendType != .parakeet && selectedBackendType != .nemotron && selectedBackendType != .nemotronHebrew else {
            Logger.info("Language routing skipped — \(selectedBackendType.displayName) detects language natively", subsystem: .model)
            // Release any stale pool left over from a previous WhisperCpp routing session
            modelPool?.releaseAll()
            modelPool = nil
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

    private func livePreviewBridge(for bridge: TranscriptionBackend) -> TranscriptionBackend? {
        #if canImport(WhisperKit)
        // WhisperKit can provide low-latency rolling previews with the already-loaded
        // Core ML model. StreamingTranscriber serializes these with committed chunks.
        if bridge is WhisperKitBridge { return bridge }
        #endif
        if bridge is FluidAudioBridge { return bridge }
        // WhisperBridge uses eager streaming — the main model's rolling decode IS the preview.
        // No separate tiny-model preview bridge needed; language detection still uses
        // modelPool.previewBridge directly.
        //
        // Unless the eager path is rolled back. Returning nil unconditionally made
        // `whisperCppEagerStreaming = false` mean "no live preview at all" rather than "the old
        // tiny-model preview": the flag disabled the new path without restoring the one it
        // replaced, so a rollback — or a stale flag left behind by a killed test run — silently
        // killed live text. Hand back the tiny bridge on that path, which is what it was.
        if bridge is WhisperBridge {
            let key = "whisperCppEagerStreaming"
            let eagerOn = UserDefaults.standard.object(forKey: key) == nil
                || UserDefaults.standard.bool(forKey: key)
            return eagerOn ? nil : modelPool?.previewBridge
        }
        return modelPool?.previewBridge
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
                guard self?.state == .idle else {
                    Logger.info("Picker show blocked — state not idle: \(self?.state.displayText ?? "nil")", subsystem: .app)
                    return
                }
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

        // Reset pickerVisible when the picker is dismissed without Option release
        // (e.g., user clicks away or presses Escape)
        TranscriptionPickerState.shared.onDismiss = { [weak listener] in
            listener?.resetPickerVisible()
        }
    }

    // MARK: - In-App Transcription

    /// Start recording in in-app mode (no text entry into other apps, no Accessibility required)
    func startInAppRecording() {
        // Show loading indicator if model isn't ready (works even during download)
        #if canImport(FluidAudio)
        let inAppBackend = effectiveInAppBackend
        let nemotronReadyInApp = (inAppBackend == .nemotron && nemotronBridgeInstance != nil)
            || (inAppBackend == .nemotronHebrew && nemotronHebrewBridgeInstance != nil)
        #else
        let nemotronReadyInApp = false
        #endif
        guard whisperBridge != nil || nemotronReadyInApp else {
            showModelLoadingToast = true
            // Safety timeout — dismiss if model never loads (e.g., no model downloaded)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                self?.showModelLoadingToast = false
            }
            Logger.warning("Cannot start recording - model not pre-loaded", subsystem: .app)
            return
        }

        // Block mic recording while file transcription is using the shared model
        guard !fileTranscriptionManager.isTranscribing else {
            showFileTranscribingToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.showFileTranscribingToast = false
            }
            Logger.info("Recording blocked — file transcription in progress", subsystem: .app)
            return
        }

        guard state == .idle else { return }

        let bridge: TranscriptionBackend = whisperBridge ?? NullTranscriptionBackend()

        isInAppMode = true
        lastInAppTranscription = ""

        // Set state immediately so UI updates
        state = .recording(startTime: Date())
        liveTranscription = ""
        recordingSessionID = UUID()  // Force SwiftUI state reset
        committedChunks = []
        isLiveTranscriptionRTL = selectedLanguage.isRTL
        isOutputAudioMuted = muteOtherAudioDuringRecording  // Initialize runtime toggle from setting
        lastAmplitudeUpdateTime = nil  // Reset audio-progress watchdog
        lastNonSilentAmplitudeTime = nil
        hasTriggeredSilentAudioDump = false
        chunkLLMCoordinator.reset()  // Clear any leftover state from previous recording
        startStartupWatchdog()  // cancelled when audio starts; waits on the recorder, not the clock

        // Play feedback sound first (user hears it) — except in a meeting, which starts silently.
        // startMeetingRecording() assigns activeMeetingSession before calling this, on the same
        // MainActor hop with no await between, so isMeetingMode is already true here.
        if !suppressesFeedbackSound {
            soundPlayer?.playStartSound()
        }

        Task {
            do {
                #if canImport(WhisperKit)
                // Reset gate before StreamingTranscriber is created — synchronous, no race
                if let wkBridge = bridge as? WhisperKitBridge {
                    wkBridge.beginSession()
                }
                #endif

                #if canImport(FluidAudio)
                let nemotronInApp: NemotronBridge? = inAppBackend == .nemotron ? nemotronBridgeInstance : nil
                let nemotronHebrewInApp: NemotronHebrewBridge? = inAppBackend == .nemotronHebrew ? nemotronHebrewBridgeInstance : nil
                let anyNemotronInApp: (any AnyObject)? = (nemotronInApp as AnyObject?) ?? (nemotronHebrewInApp as AnyObject?)
                #else
                let anyNemotronInApp: AnyObject? = nil
                #endif
                streamingTranscriber = StreamingTranscriber(backend: bridge, vad: sileroVAD, language: selectedLanguage, initialPrompt: promptWordsString, fillerWordRemovalEnabled: fillerWordRemovalEnabled, modelPool: modelPool, languageRouter: routingConfig.isRoutingEnabled ? LanguageRouter(allowed: routingConfig.allowedLanguages, primary: routingConfig.primaryLanguage) : nil, modelRouter: routingConfig.isRoutingEnabled ? ModelRouter(languageModelMap: buildLanguageModelMap(), fallbackProfile: buildFallbackProfile()) : nil, previewBridge: livePreviewBridge(for: bridge), nemotronBridge: anyNemotronInApp)

                // Wire language detection → UI update
                streamingTranscriber?.onLanguageDetected = { [weak self] lang in
                    self?.activeRouteInfo = "Detected: \(lang.displayName)"
                    self?.isLiveTranscriptionRTL = lang.isRTL
                }
                streamingTranscriber?.onLanguageForcingUnavailable = { [weak self] lang in
                    self?.reportLanguageForcingUnavailable(lang)
                }

                // Wire incremental CoreData persistence for crash recovery
                // and per-chunk LLM correction (runs during audio collection windows).
                // Capture session/startDate at wiring time — activeMeetingSession is nilled
                // inside stopInAppRecording()'s Task AFTER stopAsync() completes, so the tail
                // chunk fires while activeMeetingSession is still set. The captured refs are a
                // safety net in case of any ordering race between the async stop and the nil.
                let capturedMeetingSession = activeMeetingSession
                let capturedGeneration = activeMeetingSession?.chunkGeneration ?? 0

                #if canImport(FluidAudio)
                // Speaker diarization runs only on the Nemotron path: it is the backend whose
                // partial callback delivers a growing accumulated transcript, which is what the
                // coordinator diffs into per-speaker deltas. whisper.cpp meetings keep their
                // VAD-chunk behaviour with no speaker labels.
                if let meetingSession = capturedMeetingSession, anyNemotronInApp != nil {
                    let coordinator = MeetingSpeakerCoordinator()
                    meetingSpeakerCoordinator = coordinator
                    Task {
                        await coordinator.setCallbacks(
                            onAttributed: { text, speakerIndex, start, end in
                                Task { @MainActor in
                                    guard meetingSession.chunkGeneration == capturedGeneration else { return }
                                    meetingSession.onAttributedText(
                                        text: text,
                                        speakerIndex: speakerIndex,
                                        startTimestamp: start,
                                        endTimestamp: end
                                    )
                                }
                            },
                            onPendingTail: { tail in
                                Task { @MainActor in
                                    guard meetingSession.chunkGeneration == capturedGeneration else { return }
                                    meetingSession.livePreviewText = tail
                                }
                            },
                            onLiveSpeaker: { index in
                                Task { @MainActor in
                                    guard meetingSession.chunkGeneration == capturedGeneration else { return }
                                    meetingSession.noteLiveSpeaker(index)
                                }
                            }
                        )
                        await coordinator.start()
                    }
                }
                #endif

                streamingTranscriber?.onChunkCompleted = { [weak self] chunk in
                    guard let self else { return }
                    // Meeting mode — route chunk to session instead of history.
                    // Prefer the live property; fall back to the capture for the tail chunk
                    // that arrives while stopInAppRecording()'s Task is still running.
                    let meetingSession = self.activeMeetingSession ?? capturedMeetingSession
                    if let meetingSession = meetingSession {
                        #if canImport(FluidAudio)
                        // With a coordinator active, this final text goes through the same diff
                        // as the partials — sending it to onNewChunk as well would append the
                        // whole meeting a second time.
                        if let coordinator = self.meetingSpeakerCoordinator {
                            let finalText = chunk.text
                            self.diarizerFeedTask = Task { [previous = self.diarizerFeedTask] in
                                await previous?.value
                                await coordinator.onFinalText(finalText)
                            }
                            return
                        }
                        #endif
                        Task { @MainActor in
                            // Reject stale chunks from a previous recording that completed
                            // before this session's startRecording() incremented chunkGeneration.
                            guard meetingSession.chunkGeneration == capturedGeneration else { return }
                            meetingSession.onNewChunk(text: chunk.text, start: chunk.start, end: chunk.end)
                        }
                        return
                    }
                    guard let id = self.currentSessionID else { return }
                    let chunkText = chunk.text
                    Task { await HistoryManager.shared.appendChunk(sessionID: id, chunkText: chunkText, totalDuration: chunk.recordedDuration) }
                    self.retainForPolish(chunk)
                    Task { @MainActor [weak self] in
                        guard let self, self.llmEnabled else { return }
                        let mode = AIModeManager.shared.postProcessMode
                        // Nemotron fires onChunkCompleted once with the full session text at stop time.
                        // Per-chunk LLM is redundant — full-text path runs in stopRecording() instead.
                        let chunkBackend = self.effectiveInAppBackend
                        guard mode.supportsChunkProcessing, chunkBackend != .nemotron, chunkBackend != .nemotronHebrew else { return }
                        self.chunkLLMCoordinator.enqueue(chunkText: chunkText)
                    }
                }

                // StreamingTranscriber provides live preview via onNewSegment + onTranscription
                streamingTranscriber?.start { [weak self] text in
                    Task { @MainActor in
                        if self?.liveTranscriptionEnabled == true {
                            self?.liveTranscription = text
                        }
                    }
                }

                // Meeting mode: only deliver the live preview tail (not full accumulated text)
                // to avoid echoing already-committed chunk text in the transcript bubble.
                streamingTranscriber?.onPreviewTail = { [weak self] tail in
                    Task { @MainActor in
                        guard let self else { return }
                        #if canImport(FluidAudio)
                        // On the Nemotron path this "tail" is the FULL accumulated transcript.
                        // The coordinator diffs it, attributes the new words to a speaker, and
                        // feeds back only the not-yet-attributed remainder as livePreviewText.
                        if let coordinator = self.meetingSpeakerCoordinator {
                            self.diarizerFeedTask = Task { [previous = self.diarizerFeedTask] in
                                await previous?.value
                                await coordinator.onPartial(tail)
                            }
                            return
                        }
                        #endif
                        self.activeMeetingSession?.livePreviewText = tail
                    }
                }

                #if canImport(FluidAudio)
                // Sortformer consumes 0.48s of audio per ANE inference, so handing it every
                // ~85ms capture buffer spawns ~12 Tasks/s that mostly no-op inside the diarizer.
                // Batching to 0.25s cuts that churn ~3x, and the added clock skew is an order of
                // magnitude inside the diarizer's own ~1s finalization lag.
                var diarizerBatch: [Float] = []
                let diarizerBatchSize = 4000
                #endif

                audioRecorder?.onStreamingSamples = { [weak self] samples in
                    guard let self = self, !self.isMicMuted, !self.isPaused else { return }
                    self.streamingTranscriber?.addSamples(samples)
                    #if canImport(FluidAudio)
                    // Same buffers the ASR sees, so the coordinator's sample counter is an exact
                    // audio clock. Chained rather than fire-and-forget: SortformerDiarizer is not
                    // thread-safe and actor re-entrancy across its ANE await would interleave.
                    if let coordinator = self.meetingSpeakerCoordinator {
                        diarizerBatch.append(contentsOf: samples)
                        if diarizerBatch.count >= diarizerBatchSize {
                            let batch = diarizerBatch
                            diarizerBatch.removeAll(keepingCapacity: true)
                            self.diarizerFeedTask = Task { [previous = self.diarizerFeedTask] in
                                await previous?.value
                                await coordinator.feed(batch)
                            }
                        }
                    }
                    #endif
                }

                // Resolve input route fresh at recording time
                let route = audioDeviceManager.resolveInputRouteForRecording()
                Logger.info("In-app recording with route: \(route)", subsystem: .audio)

                HealthManager.shared.suppressForStartup(seconds: 3)
                let audioURL = try await audioRecorder?.startRecording(route: route)
                currentAudioURL = audioURL
                cancelStateWatchdog()  // Startup succeeded, audio is flowing
                HealthManager.shared.recordingStarted()
                if let transcriber = streamingTranscriber { HealthManager.shared.register(transcriber) }

                // Begin crash-recoverable CoreData session and prevent Mac sleep
                acquireIdleSleepAssertion()
                streamingTranscriber?.sessionAudioURL = audioRecorder?.sessionAudioURL
                beginRecordingSession(language: selectedLanguage.rawValue, modelUsed: selectedModel.rawValue)

                // Mute AFTER engine is running and aggregate device is stable.
                // Muting during engine startup can break the AUHAL bus connection (kAudioUnitErr_NoConnection
                // / -10877), causing the engine to produce zero-filled buffers silently.
                // Skip muting in meeting mode — meeting audio must keep playing for participants to be heard.
                if muteOtherAudioDuringRecording && !isMeetingMode {
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
                // The audio start failed, so a meeting started by startMeetingRecording() never
                // recorded anything. Without this it kept its session, its raised ModelWorkQueue
                // gate, its diarizer coordinator and a floating window showing LIVE — and the
                // user's eventual Stop produced "segments=0, transcript=0 chars".
                abandonMeetingMode(reason: "audio start failed: \(error.localizedDescription)")
            }
        }
    }

    /// Stop in-app recording — stores result in lastInAppTranscription, no text entry into other apps
    func stopInAppRecording() {
        guard case .recording = state else { return }
        // A live meeting must end through MeetingSession.stopRecording() — that is what flushes the
        // tail segment, moves the audio into Meetings/, finalizes the record and starts the AI pass.
        // The menu bar's in-app Stop button renders during a meeting and used to land here directly,
        // ending the meeting as if it were a dictation. isMeetingStopInFlight distinguishes the
        // legitimate re-entry from stopMeetingRecording().
        if isMeetingMode && !isMeetingStopInFlight {
            if let session = activeMeetingSession {
                Task { await session.stopRecording() }
            }
            return
        }
        guard isInAppMode else {
            stopRecording()
            return
        }

        state = .stopping
        startStopWatchdog()

        Task {
            // Capture meeting-stop flag synchronously before any await.
            // activeMeetingSession is still set at this point — it is nilled below after
            // stopAsync() completes so the tail chunk can route to the meeting session.
            let wasMeetingStop = isMeetingStopInFlight
            isMeetingStopInFlight = false

            // Captured here, before any await: activeMeetingSession is nilled further down this
            // same Task, so the sound decision must not depend on winning that race. Widened
            // beyond wasMeetingStop because isMeetingStopInFlight is set only by
            // stopMeetingRecording(); a meeting reaching this Task by any other route is still a
            // meeting and still ends silently. Kept separate from wasMeetingStop, which also gates
            // unmuting, the history save, and the ModelWorkQueue meeting gate.
            let wasSilentRecording = wasMeetingStop || suppressesFeedbackSound

            // Deferred, not placed at the end of the Task: the watchdog bail-out below
            // (`guard case .stopping`) returns early, and a stranded gate would suspend
            // every background model load for the rest of the app session.
            //
            // One ordered Task, not two: the gate must be DOWN before the release job is
            // submitted. As two independent Tasks the submission could win the race, land on a
            // still-raised gate, and — before the queue was reordered to wait on the gate ahead
            // of the slot — park there holding the only execution slot, wedging every job behind
            // it (transcript polish, overview, RAG index) for the rest of the session.
            defer {
                if wasMeetingStop {
                    Task { @MainActor in
                        await ModelWorkQueue.shared.setMeetingActive(false)
                        #if canImport(FluidAudio)
                        self.releaseMeetingNemotron()
                        #endif
                    }
                }
            }

            await audioRecorder?.stopRecording()

            // Meeting mode never muted audio, so nothing to unmute.
            if muteOtherAudioDuringRecording && !wasMeetingStop {
                audioMuter?.unmuteSystemAudio()
            }

            if !wasSilentRecording {
                soundPlayer?.playStopSound()
            }

            var finalText = ""
            var savedRecordId: UUID?
            if let transcriber = streamingTranscriber {
                // WhisperKit's final decoder already receives Prompt Words. Running
                // fuzzy dictionary correction afterward can corrupt ordinary phrases
                // (for example "And it" → "audit" and "so far" → "SOAR").
                let skipCorrections = llmEnabled ||
                    (loadedBackendType ?? selectedBackendType) == .whisperKit
                let stopTask = Task.detached(priority: .userInitiated) { [weak transcriber] in
                    await transcriber?.stopAsync(skipCorrections: skipCorrections) ?? ""
                }
                finalText = await withTimeoutResult(seconds: 10.0) {
                    await stopTask.value
                } ?? ""

                if !finalText.isEmpty && !wasMeetingStop {
                    savedRecordId = saveRecordingFromTranscriber(transcriber, transcription: finalText)
                }
            }
            // Discard the in-progress CoreData session — saveRecordingFromTranscriber wrote the clean final record
            discardCurrentSession()
            streamingTranscriber = nil

            #if canImport(FluidAudio)
            // Drain the diarizer and commit any still-unattributed text BEFORE the session
            // reference goes away — finish() emits through the callbacks captured above.
            if let coordinator = meetingSpeakerCoordinator {
                await diarizerFeedTask?.value
                diarizerFeedTask = nil
                await coordinator.finish()
                meetingSpeakerCoordinator = nil
                // Let the callbacks' MainActor hops land before activeMeetingSession is nilled.
                await Task.yield()
            }
            #endif

            // Tail transcription has now been delivered via onChunkCompleted — safe to nil meeting session.
            if wasMeetingStop {
                activeMeetingSession = nil
            }

            // Bail out if watchdog already forced idle
            guard case .stopping = state else { return }

            if !finalText.isEmpty && !wasMeetingStop {
                // Per-chunk path: drain coordinator (tail already queued via onChunkCompleted).
                // Transformative modes or no chunks collected → existing full-text path.
                let mode = AIModeManager.shared.postProcessMode
                let processedText: String
                if llmEnabled && mode.supportsChunkProcessing && !chunkLLMCoordinator.correctedChunks.isEmpty {
                    processedText = await chunkLLMCoordinator.drain()
                } else {
                    let listFormatted = await applyListFormatting(finalText)
                    processedText = await applyLLMPostProcessing(listFormatted)
                }
                lastInAppTranscription = processedText

                // Save AI enhancement if text was modified by post-processing
                if processedText != finalText, let recordId = savedRecordId {
                    let modeName = llmEnabled ? AIModeManager.shared.postProcessMode.name : "List Format"
                    Task {
                        try? await HistoryManager.shared.updateAIEnhancementById(recordId, aiText: processedText, modeName: modeName)
                    }
                }
            }

            cancelStateWatchdog()
            state = .idle
            HealthManager.shared.recordingStopped()
            isInAppMode = false
            liveTranscription = ""
            // Clear meeting suppression only after state is idle so the HUD never appears
            // during the .stopping/.transcribing transient states.
            if wasMeetingStop {
                meetingWindowIsVisible = false
            }
        }
    }

    // MARK: - State Transitions

    func startRecording() {
        // Show loading indicator if model isn't ready (works even during download)
        #if canImport(FluidAudio)
        let nemotronReady = (selectedBackendType == .nemotron && nemotronBridgeInstance != nil)
            || (selectedBackendType == .nemotronHebrew && nemotronHebrewBridgeInstance != nil)
        #else
        let nemotronReady = false
        #endif
        guard whisperBridge != nil || nemotronReady else {
            showModelLoadingToast = true
            // Safety timeout — dismiss if model never loads (e.g., no model downloaded)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                self?.showModelLoadingToast = false
            }
            Logger.warning("Cannot start recording - model not pre-loaded", subsystem: .app)
            return
        }

        // Block mic recording while file transcription is using the shared model
        guard !fileTranscriptionManager.isTranscribing else {
            showFileTranscribingToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.showFileTranscribingToast = false
            }
            Logger.info("Recording blocked — file transcription in progress", subsystem: .app)
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

        let bridge: TranscriptionBackend = whisperBridge ?? NullTranscriptionBackend()

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
        PermissionManager.shared.pausePolling()  // Permissions don't change mid-recording
        liveTranscription = ""
        chunkLLMCoordinator.reset()  // Clear any leftover state from previous recording
        recordingSessionID = UUID()
        committedChunks = []
        isOutputAudioMuted = muteOtherAudioDuringRecording  // Initialize runtime toggle from setting
        lastAmplitudeUpdateTime = nil  // Reset audio-progress watchdog
        lastNonSilentAmplitudeTime = nil
        hasTriggeredSilentAudioDump = false
        startStartupWatchdog()  // cancelled when audio starts; waits on the recorder, not the clock

        // Play feedback sound first (user hears it)
        soundPlayer?.playStartSound()

        // Start recording immediately
        Task {
            do {
                // Create streaming transcriber with pre-loaded bridge, optional VAD, and language.
                // Nemotron path: pass NullTranscriptionBackend + nemotronBridge (VAD chunking bypassed).
                #if canImport(WhisperKit)
                // Reset gate before StreamingTranscriber is created — synchronous, no race
                if let wkBridge = bridge as? WhisperKitBridge {
                    wkBridge.beginSession()
                }
                #endif

                #if canImport(FluidAudio)
                let nemotron: (any AnyObject)? = selectedBackendType == .nemotron ? nemotronBridgeInstance :
                    selectedBackendType == .nemotronHebrew ? nemotronHebrewBridgeInstance : nil
                #else
                let nemotron: AnyObject? = nil
                #endif
                streamingTranscriber = StreamingTranscriber(backend: bridge, vad: sileroVAD, language: selectedLanguage, initialPrompt: promptWordsString, fillerWordRemovalEnabled: fillerWordRemovalEnabled, modelPool: modelPool, languageRouter: routingConfig.isRoutingEnabled ? LanguageRouter(allowed: routingConfig.allowedLanguages, primary: routingConfig.primaryLanguage) : nil, modelRouter: routingConfig.isRoutingEnabled ? ModelRouter(languageModelMap: buildLanguageModelMap(), fallbackProfile: buildFallbackProfile()) : nil, previewBridge: livePreviewBridge(for: bridge), nemotronBridge: nemotron)

                // Wire language detection → UI update
                streamingTranscriber?.onLanguageDetected = { [weak self] lang in
                    self?.activeRouteInfo = "Detected: \(lang.displayName)"
                    self?.isLiveTranscriptionRTL = lang.isRTL
                }
                streamingTranscriber?.onLanguageForcingUnavailable = { [weak self] lang in
                    self?.reportLanguageForcingUnavailable(lang)
                }

                // Wire incremental CoreData persistence for crash recovery
                // and per-chunk LLM correction (runs during audio collection windows).
                streamingTranscriber?.onChunkCompleted = { [weak self] chunk in
                    guard let self else { return }
                    // Meeting mode — route chunk to session instead of history
                    if let meetingSession = self.activeMeetingSession {
                        Task { @MainActor in
                            meetingSession.onNewChunk(text: chunk.text, start: chunk.start, end: chunk.end)
                        }
                        return
                    }
                    guard let id = self.currentSessionID else { return }
                    let chunkText = chunk.text
                    Task { await HistoryManager.shared.appendChunk(sessionID: id, chunkText: chunkText, totalDuration: chunk.recordedDuration) }
                    self.retainForPolish(chunk)
                    Task { @MainActor [weak self] in
                        guard let self, self.llmEnabled else { return }
                        let mode = AIModeManager.shared.postProcessMode
                        // Nemotron fires onChunkCompleted once with the full session text at stop time.
                        // Per-chunk LLM is redundant — full-text path runs in stopRecording() instead.
                        guard mode.supportsChunkProcessing, self.selectedBackendType != .nemotron, self.selectedBackendType != .nemotronHebrew else { return }
                        self.chunkLLMCoordinator.enqueue(chunkText: chunkText)
                    }
                }

                streamingTranscriber?.start { [weak self] text in
                    Task { @MainActor in
                        if self?.liveTranscriptionEnabled == true {
                            self?.liveTranscription = text
                        }
                    }
                }

                // Meeting mode: only deliver the live preview tail (not full accumulated text)
                streamingTranscriber?.onPreviewTail = { [weak self] tail in
                    Task { @MainActor in
                        self?.activeMeetingSession?.livePreviewText = tail
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

                HealthManager.shared.suppressForStartup(seconds: 3)
                let audioURL = try await audioRecorder?.startRecording(route: route)
                currentAudioURL = audioURL
                cancelStateWatchdog()  // Startup succeeded, audio is flowing
                HealthManager.shared.recordingStarted()
                if let transcriber = streamingTranscriber { HealthManager.shared.register(transcriber) }

                // Begin crash-recoverable CoreData session and prevent Mac sleep
                acquireIdleSleepAssertion()
                streamingTranscriber?.sessionAudioURL = audioRecorder?.sessionAudioURL
                beginRecordingSession(language: selectedLanguage.rawValue, modelUsed: selectedModel.rawValue)

                // Mute AFTER engine is running and aggregate device is stable.
                // Muting during engine startup can break the AUHAL bus connection (kAudioUnitErr_NoConnection
                // / -10877), causing the engine to produce zero-filled buffers silently.
                if muteOtherAudioDuringRecording {
                    audioMuter?.muteSystemAudio()
                }

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
        #if DEBUG
        StuckStateDumper.dump(reason: "Audio recovery exhausted — engine rebuilt \(audioRecorder?.debugRecoveryAttemptCount ?? 0) times, all produced silent/no audio")
        #endif
        Logger.error("Audio flow timeout — all recovery attempts exhausted, resetting to idle", subsystem: .audio)
        guard case .recording = state else { return }
        cancelStateWatchdog()
        streamingTranscriber = nil
        liveTranscription = ""
        state = .idle
        errorMessage = "Microphone stopped responding. If recording keeps failing, open System Settings → Sound and re-select your microphone."
        if muteOtherAudioDuringRecording {
            audioMuter?.unmuteSystemAudio()
        }
        isOutputAudioMuted = false
    }

    func stopRecording() {
        // This is the dictation stop path: it writes a TranscriptionEntity and injects the text
        // into the focused app. A meeting or in-app recording must never end through it.
        //
        // GlobalKeyListener tracks its own `recordingInProgress` independently of AppState.state,
        // so a stray Fn press during a meeting is swallowed by startRecording()'s `state == .idle`
        // guard while the matching release still lands here with state == .recording. That saved
        // the whole meeting into transcription history and typed the transcript into whatever app
        // happened to be focused.
        if isMeetingMode {
            Logger.info("stopRecording() ignored — a meeting recording is active", subsystem: .app)
            return
        }
        if isInAppMode {
            Logger.info("stopRecording() routed to the in-app path — isInAppMode is set", subsystem: .app)
            stopInAppRecording()
            return
        }

        guard case .recording = state else {
            Logger.warning("stopRecording() called but state is \(state), ignoring", subsystem: .app)
            return
        }

        state = .stopping

        startStopWatchdog()

        Task {
            let transcriber = streamingTranscriber
            let stopPreparation = Task.detached(priority: .userInitiated) { [weak transcriber] in
                await transcriber?.prepareForStopAsync()
            }
            await audioRecorder?.stopRecording()
            await stopPreparation.value

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

            // Get final transcription.
            // stopAsync() worst case: 2s abort wait + 4s tail timeout in FluidAudioBridge = 6s.
            // 10s gives comfortable margin for all backends.
            var finalText = ""
            if let transcriber {
                // WhisperKit's final decoder already receives Prompt Words; avoid a
                // second fuzzy pass that can rewrite valid ordinary-language phrases.
                let skipCorrections = llmEnabled ||
                    (loadedBackendType ?? selectedBackendType) == .whisperKit
                // Run stopAsync() off the main actor so main thread stays free during tail transcription.
                let stopTask = Task.detached(priority: .userInitiated) { [weak transcriber] in
                    await transcriber?.stopAsync(skipCorrections: skipCorrections) ?? ""
                }
                finalText = await withTimeoutResult(seconds: 10.0) {
                    await stopTask.value
                } ?? ""

                // Fallback: if final pass timed out, use the live streaming result.
                if finalText.isEmpty {
                    let streamingResult = transcriber.currentTranscription
                    if !streamingResult.isEmpty {
                        finalText = DictionaryManager.shared.correctText(streamingResult)
                        if fillerWordRemovalEnabled {
                            finalText = FillerWordFilter.removeFillers(from: finalText)
                        }
                        Logger.event(.asrDone, .transcription, ["chars": .int(finalText.count), "fallback": .bool(true)])
                    } else {
                        Logger.event(.asrFail, .transcription, ["reason": .string("timeout_empty")], level: .warning)
                    }
                } else {
                    Logger.step(.asrDone, .transcription, ["chars": .int(finalText.count), "text": .string(Logger.redact(finalText))])
                }
            }
            // Discard the in-progress CoreData session — saveRecordingFromTranscriber writes the clean final record
            discardCurrentSession()
            streamingTranscriber = nil

            // Bail out if watchdog already forced idle while we were transcribing
            guard case .stopping = state else { return }

            if !finalText.isEmpty {
                // Archive the audio alongside the text — only when there are actual words.
                // Audio is always kept now; retention (AudioRetentionService) is the answer
                // to disk usage, not a switch that stops recordings from being saved.
                var savedRecordId: UUID?
                if let transcriber {
                    savedRecordId = saveRecordingFromTranscriber(transcriber, transcription: finalText)
                }

                // Per-chunk path: drain coordinator (tail already queued via onChunkCompleted).
                // Transformative modes or no chunks collected → existing full-text path.
                let mode = AIModeManager.shared.postProcessMode
                let processedText: String
                if llmEnabled && mode.supportsChunkProcessing && !chunkLLMCoordinator.correctedChunks.isEmpty {
                    processedText = await chunkLLMCoordinator.drain()
                } else {
                    let listFormatted = await applyListFormatting(finalText)
                    processedText = await applyLLMPostProcessing(listFormatted)
                }
                let textToInsert = appendTrailingSpace ? processedText + " " : processedText

                // Save AI enhancement if text was modified by post-processing
                if processedText != finalText, let recordId = savedRecordId {
                    let modeName = llmEnabled ? AIModeManager.shared.postProcessMode.name : "List Format"
                    Task {
                        try? await HistoryManager.shared.updateAIEnhancementById(recordId, aiText: processedText, modeName: modeName)
                    }
                }

                Logger.step(.asrDone, .transcription, ["chars": .int(textToInsert.count), "text": .string(Logger.redact(textToInsert))])
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
    private nonisolated func withTimeoutResult<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async -> T) async -> T? {
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

    /// Poll interval for the startup watchdog.
    private static let startupWatchdogInterval: TimeInterval = 1.0
    /// No audio start in flight and still not recording — the pre-audio setup is what is wedged.
    private static let startupSetupDeadline: TimeInterval = 4.0
    /// A start the recorder reports as genuinely in flight gets this long. Deliberately above
    /// `AudioRecorder.startupHardDeadline` (20s) so the recorder aborts first and the failure
    /// arrives as a thrown error on the clean path, rather than as a force-idle from out here.
    private static let startupHardCeiling: TimeInterval = 25.0
    /// When to say out loud that CoreAudio is taking its time.
    private static let startupSlowThreshold: TimeInterval = 3.0

    /// Activity-aware watchdog for the startup phase, mirroring `startStopWatchdog()`.
    ///
    /// The fixed 4s version force-idled on wall clock alone, and force-idling is not passive:
    /// `forceIdleFromWatchdog()` calls `AudioRecorder.stopRecording()`, which bumps the
    /// recorder's generation and so invalidates whatever start it was waiting on. Creating the
    /// AUHAL audio unit (`AVAudioEngine.inputNode`) is a CoreAudio round trip with no bounded
    /// latency — normally 30–250ms, measured at 4.30s with coreaudiod cleaning up after a
    /// killed process — so the 4s deadline destroyed a start that was 400ms from succeeding and
    /// the meeting recorded nothing. A slow start is not a stuck start: while the recorder
    /// reports one in flight we wait, up to a hard ceiling.
    ///
    /// DispatchSourceTimer on the main RunLoop — independent of the Swift cooperative thread
    /// pool, so it fires even when every cooperative thread is exhausted.
    private func startStartupWatchdog() {
        stateWatchdog?.cancel()
        let began = Date()
        var loggedSlowStart = false
        // Sticky, not sampled per tick. The recorder clears its in-flight marker in a `defer`,
        // and `cancelStateWatchdog()` runs one main-actor hop later — so a tick landing in
        // between would see "no start in flight" and apply the 4s setup deadline to a start
        // that had just succeeded after 5s, force-idling it. Once a start has been observed,
        // only the hard ceiling applies.
        var sawStartInFlight = false
        let interval = Self.startupWatchdogInterval
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard case .recording = self.state else {
                self.stateWatchdog?.cancel()
                self.stateWatchdog = nil
                return
            }

            let elapsed = Date().timeIntervalSince(began)
            let startupInFlight = self.audioRecorder?.startupInFlightSince != nil
            if startupInFlight { sawStartInFlight = true }
            let deadline = sawStartInFlight ? Self.startupHardCeiling : Self.startupSetupDeadline

            if startupInFlight, elapsed >= Self.startupSlowThreshold, !loggedSlowStart {
                loggedSlowStart = true
                Logger.warning(
                    "Audio startup slow: \(String(format: "%.1f", elapsed))s and still in flight — waiting up to \(Int(Self.startupHardCeiling))s",
                    subsystem: .app
                )
            }

            guard elapsed >= deadline else { return }
            Logger.error(
                "Startup watchdog: stuck in \(self.state) for \(String(format: "%.1f", elapsed))s (audio start in flight: \(startupInFlight)), forcing idle",
                subsystem: .app
            )
            self.forceIdleFromWatchdog()
        }
        timer.resume()
        stateWatchdog = timer
    }

    private func cancelStateWatchdog() {
        stateWatchdog?.cancel()
        stateWatchdog = nil
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

        // Preserve any accumulated transcription text before destroying the transcriber.
        // If we have a live session, finalize it so the user's words aren't lost.
        let accumulatedText = streamingTranscriber?.currentTranscription ?? ""
        let duration = streamingTranscriber?.recordedDuration ?? 0
        if !accumulatedText.isEmpty, currentSessionID != nil {
            Logger.info("Watchdog: finalizing session with \(accumulatedText.count) chars preserved", subsystem: .app)
            finalizeCurrentSession(text: accumulatedText, duration: duration, audioFileURL: audioRecorder?.sessionAudioURL?.lastPathComponent)
        } else {
            discardCurrentSession()
        }

        streamingTranscriber = nil
        chunkLLMCoordinator.reset()  // Discard in-flight per-chunk corrections on watchdog force-idle
        liveTranscription = ""
        state = .idle
        HealthManager.shared.recordingStopped()
        if muteOtherAudioDuringRecording {
            audioMuter?.unmuteSystemAudio()
        }
        isOutputAudioMuted = false
        // A meeting force-idled here used to keep every piece of its live state: the session, the
        // queue gate, the diarizer coordinator and a floating window still showing LIVE. The
        // recording was over; only the UI did not know, so the user stopped a meeting that had
        // not been running and got an empty transcript with no explanation.
        abandonMeetingMode(reason: "recording watchdog")
        if let recorder = audioRecorder {
            DispatchQueue.global(qos: .utility).async {
                Task { await recorder.stopRecording() }
            }
        }
    }

    /// Tear down meeting mode for a meeting that never really ran — a failed audio start or a
    /// watchdog force-idle. Not a substitute for `MeetingSession.stopRecording()`: there is no
    /// tail to flush, no title to generate and no overview to write, because nothing was
    /// captured. Ordered as in `stopInAppRecording()` — the queue gate comes down before the
    /// release job is submitted, or the release waits behind a gate nothing will lower.
    private func abandonMeetingMode(reason: String) {
        guard let session = activeMeetingSession else { return }
        // A meeting already stopping the normal way owns its own teardown: `stopInAppRecording()`
        // lowers the gate in its defer, the tail chunk is still being routed through
        // `activeMeetingSession`, and `MeetingSession.stopRecording()`'s Task is driving polish,
        // naming and summarizing. The stop watchdog reaches here too, and abandoning underneath
        // that pipeline would clear the processing banner and drop the tail.
        guard !isMeetingStopInFlight else {
            Logger.warning("Meeting teardown skipped (\(reason)) — a normal stop is already in flight", subsystem: .app)
            return
        }
        Logger.warning("Abandoning meeting mode: \(reason)", subsystem: .app)

        // Not left on screen: the window binds its session at construction and would keep
        // showing a LIVE badge over a recording that is not happening. Closing it also clears
        // `meetingWindowIsVisible` through the willClose observer, handing the HUD back.
        MeetingLiveWindowManager.shared.close()
        meetingWindowIsVisible = false

        Task { @MainActor in
            await session.abandonRecording()
            await ModelWorkQueue.shared.setMeetingActive(false)
            #if canImport(FluidAudio)
            self.releaseMeetingNemotron()
            if let coordinator = self.meetingSpeakerCoordinator {
                await self.diarizerFeedTask?.value
                self.diarizerFeedTask = nil
                await coordinator.finish()
                self.meetingSpeakerCoordinator = nil
                await Task.yield()
            }
            #endif
            // Outside the FluidAudio guard on purpose — a build without it still assigned
            // this in startMeetingRecording(), and leaving it set makes `isMeetingMode` true
            // forever, so every later dictation routes its chunks into a dead session.
            self.activeMeetingSession = nil
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

        let mode = AIModeManager.shared.rewriteMode
        activeMode = .rewrite
        activeAIModeName = mode.name
        state = .rewriting

        Logger.info("Rewriting \(selectedText.count) chars with \(mode.name) mode", subsystem: .app)

        do {
            let (systemPrompt, userMessage) = splitPrompt(mode.prompt, text: selectedText)
            let result = try await processor.process(
                text: selectedText,
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                targetLanguage: mode.targetLanguage,
                temperature: mode.temperature,
                topP: mode.topP,
                topK: mode.topK,
                repetitionPenalty: mode.repetitionPenalty,
                maxTokensCap: mode.maxTokensCap
            )
            Logger.debug("Rewrite (\(mode.name)): \(selectedText.prefix(30))... → \(result.prefix(30))...", subsystem: .app)
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

        // Cancelling out of a meeting never reaches stopInAppRecording(), so the queue gate
        // would stay raised for the rest of the session.
        abandonMeetingMode(reason: "recording cancelled")

        Task {
            // Cancel inference first so no stale progress callback can mutate the UI
            // while the recorder is shutting down.
            let transcriber = streamingTranscriber
            await transcriber?.cancelAsync()
            await audioRecorder?.stopRecording()

            // Unmute audio
            if muteOtherAudioDuringRecording {
                audioMuter?.unmuteSystemAudio()
            }

            // Clear streaming transcriber without doing final pass — discard incremental session (user cancelled)
            discardCurrentSession()
            streamingTranscriber = nil
            chunkLLMCoordinator.reset()  // Discard any in-flight per-chunk corrections

            // Reset state
            state = .idle
            liveTranscription = ""
        }
    }

    // MARK: - Long-Record Session Helpers

    private func acquireIdleSleepAssertion() {
        guard idleSleepAssertion == 0 else { return }
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Whisperer long-record session" as CFString,
            &idleSleepAssertion
        )
    }

    private func releaseIdleSleepAssertion() {
        guard idleSleepAssertion != 0 else { return }
        IOPMAssertionRelease(idleSleepAssertion)
        idleSleepAssertion = 0
    }

    private func beginRecordingSession(language: String, modelUsed: String) {
        guard !isMeetingMode else { return }
        guard let sessionURL = audioRecorder?.sessionAudioURL else { return }
        Task {
            let id = await HistoryManager.shared.beginSession(audioFileURL: sessionURL, language: language, modelUsed: modelUsed)
            await MainActor.run { self.currentSessionID = id }
        }
    }

    private func discardCurrentSession() {
        releaseIdleSleepAssertion()
        guard let id = currentSessionID else { return }
        currentSessionID = nil
        Task { await HistoryManager.shared.discardSession(sessionID: id) }
    }

    private func finalizeCurrentSession(text: String, duration: Double, audioFileURL: String?) {
        releaseIdleSleepAssertion()
        guard let id = currentSessionID else { return }
        currentSessionID = nil
        Task {
            try? await HistoryManager.shared.finalizeSession(
                sessionID: id,
                finalText: text,
                duration: duration,
                audioFileURL: audioFileURL
            )
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

        let ext = AudioArchiveFormat.fileExtension
        let fileName = safeText.isEmpty ? "\(timestamp).\(ext)" : "\(timestamp)_\(safeText).\(ext)"
        let destURL = recordingsDir.appendingPathComponent(fileName)

        // Save recording from in-memory samples
        if transcriber.saveRecording(to: destURL) {
            Logger.event(.recStop, .app, ["file": .string(recordId.uuidString)])

            // The archive is now a self-contained copy, so the session file is dead weight.
            // Without this it survived until a launch 7+ days later reaped it as an orphan,
            // doubling disk cost for every dictation in the meantime. Never in meeting mode —
            // MeetingSession.moveAudioToMeetingsDirectory consumes that same file.
            if activeMeetingSession == nil, let sessionURL = transcriber.sessionAudioURL {
                SessionStorage.deleteSessionFile(at: sessionURL)
            }

            // Save to history database
            Task {
                do {
                    // Use the language the transcriber actually used (routing detection or configured)
                    let effectiveLang = transcriber.effectiveLanguage
                    let recordedLanguage: String
                    if effectiveLang == .auto, let detected = self.whisperBridge?.lastDetectedLanguage {
                        recordedLanguage = detected
                    } else {
                        recordedLanguage = effectiveLang.rawValue
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

        // Cancel in-flight load tasks to prevent them from setting whisperBridge after we nil it
        whisperLoadTask?.cancel()
        whisperLoadTask = nil
        parakeetLoadTask?.cancel()
        parakeetLoadTask = nil

        // Shutdown Nemotron bridges
        #if canImport(FluidAudio)
        nemotronLoadTask?.cancel()
        nemotronLoadTask = nil
        nemotronHebrewLoadTask?.cancel()
        nemotronHebrewLoadTask = nil
        if let nemotron = nemotronBridgeInstance {
            Task { await nemotron.prepareForShutdown() }
            nemotronBridgeInstance = nil
        }
        if let nemotronHebrew = nemotronHebrewBridgeInstance {
            Task { await nemotronHebrew.prepareForShutdown() }
            nemotronHebrewBridgeInstance = nil
        }
        #endif

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
            let processorToFree = llmPostProcessor
            llmPostProcessor = nil
            Task { await processorToFree?.unloadModel() }
        }

        // Free cached CTC models
        #if arch(arm64)
        VocabularyStore.releaseCachedModels()
        #endif

        Logger.debug("Transcription resources released", subsystem: .transcription)
    }

    // MARK: - Meeting Mode

    #if canImport(FluidAudio)
    /// Minimum free memory required to hold Nemotron alongside a different dictation backend.
    /// Below this the user's bridge is evicted for the meeting and reloaded afterwards.
    private static let meetingDualBackendHeadroomGB: Double = 2.0

    /// Gets a Nemotron bridge ready for a meeting, without disturbing the user's backend.
    ///
    /// Nemotron is the only backend whose partial callback delivers a growing accumulated
    /// transcript, and that stream is what speaker attribution diffs against. Called before
    /// the meeting record is created so a failure leaves nothing half-started.
    ///
    /// The bridge is loaded *alongside* whatever the user dictates with rather than swapped in:
    /// `selectBackend()` tore the previous backend down and rebuilt it on the way out, ~62s of
    /// pure loading per meeting, with the return leg landing on top of the post-meeting AI work.
    ///
    /// Returns `false` when Nemotron cannot be made ready — the caller must not record.
    func prepareMeetingBackend() async -> Bool {
        if nemotronBridgeInstance != nil {
            meetingOwnsNemotron = selectedBackendType != .nemotron
            return true
        }

        guard isNemotronModelCached() else {
            errorMessage = "Meeting Notes needs the Nemotron model. Download it from the Models tab, then start the meeting."
            return false
        }

        meetingOwnsNemotron = selectedBackendType != .nemotron

        // Two ASR models resident at once is the trade that buys back the swap time, but only
        // when there is room for it. When there isn't, evict the user's bridge for the duration
        // and reload it at the end — the old behaviour, minus the write to selectedBackendType.
        if meetingOwnsNemotron, SystemMemory.availableGB() < Self.meetingDualBackendHeadroomGB {
            Logger.info("Meeting: low memory — evicting \(selectedBackendType.displayName) for the meeting", subsystem: .model)
            meetingEvictedUserBackend = true
            releaseCurrentBridge()
        }

        if nemotronLoadTask == nil {
            preloadNemotronModel()
        }
        // The load runs detached and is queued behind any other model work. Waiting beats
        // starting a meeting that records no words.
        await nemotronLoadTask?.value

        guard nemotronBridgeInstance != nil else {
            errorMessage = "Nemotron did not finish loading — try starting the meeting again."
            releaseMeetingNemotron()
            return false
        }
        return true
    }

    /// Hands back the Nemotron bridge a meeting borrowed.
    ///
    /// Submitted to `ModelWorkQueue` rather than torn down inline so the teardown cannot overlap
    /// another model load. It is the *first* job in line, not the last: title generation, the
    /// overview and the initial RAG index do not go through the queue at all, and transcript
    /// polish is submitted a second or two later. Callers must therefore lower the meeting gate
    /// before calling this — see the ordered Task in `stopInAppRecording()`.
    private func releaseMeetingNemotron() {
        guard meetingOwnsNemotron else { return }
        meetingOwnsNemotron = false

        if let bridge = nemotronBridgeInstance, selectedBackendType != .nemotron {
            nemotronBridgeInstance = nil
            nemotronLoadTask = nil
            isLoadingNemotron = false
            Task {
                // try? — run() now throws only on cancellation of this Task, in which case the
                // bridge is being torn down by app shutdown anyway.
                try? await ModelWorkQueue.shared.run("nemotron-meeting-release") {
                    await bridge.prepareForShutdown()
                }
            }
        }

        guard meetingEvictedUserBackend else { return }
        meetingEvictedUserBackend = false
        // preloadModel() dispatches on selectedBackendType, which the meeting never changed.
        preloadModel()
    }
    #endif

    func startMeetingRecording(session: MeetingSession, surface: MeetingLiveSurface) {
        guard state == .idle else {
            Logger.warning("Cannot start meeting recording — AppState not idle", subsystem: .app)
            return
        }

        activeMeetingSession = session
        meetingAudioFileURL = nil

        // Suppress HUD before recording starts so it never flashes. `meetingWindowIsVisible`
        // means "a meeting surface owns the recording UI", not "the floating window is up" —
        // the workspace is equally that surface, and `HistoryWindowManager`'s close observer
        // lowers this again if the workspace is closed with no floating window to take over.
        meetingWindowIsVisible = true

        // Raise the floating rail only for a detected call. Starting from Meeting Studio means
        // the user is already watching the transcript there; putting a second copy of it on top
        // of the window they pressed Start in is noise, and it covers what they came to read.
        if surface == .floatingWindow {
            MeetingLiveWindowManager.shared.show(session: session)
        }

        // Reuse in-app recording path (isInAppMode = true suppresses text injection)
        isInAppMode = true
        startInAppRecording()

        // Only once recording actually began: startInAppRecording() bails out early when no
        // backend is ready, and a gate raised then would never be lowered.
        if case .recording = state {
            Task { await ModelWorkQueue.shared.setMeetingActive(true) }
        }
    }

    func stopMeetingRecording() {
        guard isMeetingMode else { return }

        // Do NOT clear meetingWindowIsVisible here — the OverlayPanel uses it to suppress the HUD,
        // and we need that suppression to hold during the .stopping/.transcribing states.
        // It is cleared inside stopInAppRecording()'s Task once state reaches .idle.

        // Save audio file URL before tearing down
        meetingAudioFileURL = audioRecorder?.sessionAudioURL.map { $0.lastPathComponent }

        // NOTE: activeMeetingSession is NOT cleared here. The tail transcription fires
        // asynchronously inside stopInAppRecording()'s Task (after transcriber.stopAsync()
        // completes), and the onChunkCompleted closure routes via activeMeetingSession.
        // Clearing it here would drop the last ~10s of content. It is nilled inside the
        // stopInAppRecording Task after finalText is obtained.
        isMeetingStopInFlight = true
        // isInAppMode stays true so stopInAppRecording() takes the in-app path (not stopRecording())
        // and avoids both LLM post-processing and text insertion into other apps.

        stopInAppRecording()
    }

    /// Stops whichever recording mode is active. Used by the HUD stop button.
    func stopActiveRecording() {
        if let session = activeMeetingSession {
            Task { await session.stopRecording() }
        } else {
            stopRecording()
        }
    }
}
