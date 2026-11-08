//
//  SystemLivePreviewBridge.swift
//  Whisperer
//
//  The built-in engine: Apple's on-device Dictation model (`DictationTranscriber`, macOS 26)
//  streaming live text into the dictation HUD and the meeting live transcript. The user's own
//  engine (Qwen3, Whisper V3) still produces the final text.
//
//  Why `DictationTranscriber` and not `SpeechTranscriber` (which `SpeechAnalyzerBridge` uses):
//  on 2026-11-04 `SpeechTranscriber.supportedLocales` had 45 locales and no Hebrew or Russian;
//  `DictationTranscriber` had 54, including both. Its language assets are the ones System
//  Settings › Keyboard › Dictation installs, shared with every app and updated by the OS — so
//  there is no model of ours to download, load or keep resident.
//

#if canImport(Speech)
import Foundation
import Speech
import AVFoundation

/// Whether Apple's dictation model can stream a language on this Mac, as the UI shows it.
nonisolated enum SystemLanguageStatus: Equatable, Sendable {
    case ready
    case notInstalled
    case downloading(Double)
    case unsupported
}

@available(macOS 26.0, *)
actor SystemLivePreviewBridge: LivePreviewEngine {

    /// Volatile results for word-by-word live text, punctuation, and no one-minute short-form cap
    /// (meetings run for an hour). Measured on 2026-11-04 at real time: first word 0.75–1.3 s,
    /// then a word every 0.2–0.5 s, final text 40–50 ms after the audio ends.
    nonisolated static let preset = DictationTranscriber.Preset.progressiveLongDictation

    /// Bound on `finalizeAndFinishThroughEndOfInput` at stop and on a language restart. Measured
    /// finalize lag is ~50 ms; anything near this is a wedged analyzer, not a busy one.
    nonisolated private static let finalizeTimeout: Duration = .seconds(2)

    /// Languages the user dictates in, in priority order. In auto mode the session starts in the
    /// language it ended in last time (`lastLanguageKey`), else the first installed one, and the
    /// language probe corrects it within 1–3 s of speech.
    private var preferredLanguages: [TranscriptionLanguage]

    // MARK: Language probe (auto mode)

    /// Apple's model cannot detect language, so a session that starts in the wrong one shows
    /// that language's guess at the words — fluent nonsense — until something tells it. The
    /// main engine's verdict took 9–10 s (2026-11-04 log), longer than most dictations.
    private var probe: LanguageProbe?
    nonisolated static let lastLanguageKey = "builtinEngineLastLanguage"
    /// Commit at the early checkpoint only when this sure; otherwise wait for the late one and take
    /// its answer. See `LanguageProbeBenchmarkTests` for the measured accuracy.
    nonisolated static let earlyProbeSeconds = 1.0
    /// An unsure 1.0 s answer is re-asked here before waiting for the late one: the user's 9.6 s
    /// Russian read ru 0.64 at 1.0 s, and waiting for 3.0 s put Russian on screen at 4.3 s.
    nonisolated static let midProbeSeconds = 2.0
    nonisolated static let lateProbeSeconds = 3.0
    nonisolated static let confidentProbability: Float = 0.8
    /// Audio kept for replay into a restarted analyzer. Past it, a restart carries text over.
    nonisolated static let replayLimitSamples = 16_000 * 30
    /// After the start-of-session decision, the language is re-checked on the most recent
    /// `reprobeWindowSamples` every `reprobeIntervalSamples` of audio, so a session that started
    /// in the wrong language (or genuinely switched) follows the speech. See
    /// `LanguageReprobeTracker` for the switching rule.
    nonisolated static let reprobeIntervalSamples = 16_000 * 15
    nonisolated static let reprobeWindowSamples = 16_000 * 8
    /// RMS below which a re-probe window is treated as silence and skipped.
    nonisolated static let reprobeMinimumRMS: Float = 0.005

    private var sessionID = 0
    private var sessionLanguage: TranscriptionLanguage?
    /// The language this session could not stream in (see `unavailableLanguage()`).
    private var missingLanguage: TranscriptionLanguage?
    /// Installed languages the probe may choose among; empty when there is nothing to choose.
    private var probeCandidates: [TranscriptionLanguage] = []
    private var sessionAudio: [Float] = []
    private var sessionAudioOverflowed = false
    /// Index in `sessionAudio` where speech starts; the probe only sees voiced audio.
    private var voicedStart: Int?
    private var frameRMS: [Float] = []
    private var pendingFrame: [Float] = []
    /// `confirming`: committed early, re-checked at the late checkpoint. A confident 1 s answer is
    /// still wrong about once in 90 (FLEURS, V3: ru → he at p 0.91); replay makes the fix cheap.
    private enum ProbeStage { case waitingEarly, waitingMid, waitingLate, confirming, decided }
    private var probeStage: ProbeStage = .decided
    private var probeInFlight = false
    /// Checkpoints already probed this session; each runs at most once (a 1.0 s probe was seen
    /// running twice back to back, costing a second V3 encode).
    private var probedCheckpoints: Set<Double> = []
    /// This session's first checkpoint (`LanguageProbe.Source.earliestSeconds`).
    private var probeEarlySeconds = SystemLivePreviewBridge.earlyProbeSeconds
    /// The last `reprobeWindowSamples` of audio, kept for the whole session (unlike `sessionAudio`,
    /// which stops at the replay limit).
    private var recentAudio: [Float] = []
    private var samplesSinceReprobe = 0
    private var reprobe = LanguageReprobeTracker()

    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var sessionLocale: Locale?
    /// Bumped for every analyzer; results from a retired one are ignored.
    private var generation = 0

    /// Text from analyzers retired by a language restart.
    private var carried = ""
    private var finalized = ""
    private var volatile = ""
    private var lastEmitted = ""
    private var callback: (@Sendable (String) -> Void)?

    // MARK: Stable text (meetings)

    /// Words that will never change again, for consumers that need a transcript which only grows
    /// (`MeetingSpeakerCoordinator` rejects anything else). Apple revises its volatile words —
    /// "micro" → "microphone", "it let's" → "it. Let's" — and with continuous speech finalizes
    /// only at a pause (34 s of read Russian produced one final, at the end), so neither its
    /// volatile nor its final text works on its own. A word is committed once it has held its
    /// place across `agreementUpdates` consecutive updates and is not among the last
    /// `uncommittedTailWords`: the same local-agreement idea as the whisper eager stream.
    nonisolated static let agreementUpdates = 3
    nonisolated static let uncommittedTailWords = 3
    private var stableCallback: (@Sendable (String) -> Void)?
    private var committedWords: [String] = []
    private var recentUpdates: [[String]] = []

    /// Locales whose assets this process has already allocated. `assetInstallationRequest` must
    /// run once per locale before use ("Cannot use modules with unallocated locales").
    private var allocatedLocales: Set<String> = []

    init(preferredLanguages: [TranscriptionLanguage]) {
        self.preferredLanguages = preferredLanguages
    }

    func setPreferredLanguages(_ languages: [TranscriptionLanguage]) {
        preferredLanguages = languages
    }

    func setLanguageProbe(_ probe: LanguageProbe?) {
        self.probe = probe
    }

    /// Receives the committed (never-changing) transcript whenever it grows. Cleared at
    /// `endSession`, so set it for each session that wants it.
    func setStableTextCallback(_ callback: (@Sendable (String) -> Void)?) {
        stableCallback = callback
    }

    // MARK: - Availability and assets

    nonisolated static func locale(for language: TranscriptionLanguage) async -> Locale? {
        guard let base = language.locale else { return nil }
        return await DictationTranscriber.supportedLocale(equivalentTo: base)
    }

    /// Whether live text can stream `language`, from `DictationAssets` — the same answer a session
    /// gets when it opens. Waits up to `statusBudget` for an install Apple hands out, which covers
    /// the allocation-only case; a real download is reported as `.downloading` and finishes in the
    /// background. Once ready, Apple is not asked again in this process.
    nonisolated static func status(for language: TranscriptionLanguage) async -> SystemLanguageStatus {
        guard let locale = await locale(for: language) else { return .unsupported }
        switch await DictationAssets.shared.prepare(locale, within: statusBudget) {
        case .ready: return .ready
        case .installing(let fraction): return .downloading(fraction)
        case .failed: return .notInstalled
        }
    }

    nonisolated static let statusBudget: Double = 1.5

    /// Languages Apple dictation is already installed for on this Mac — the ones the user turned
    /// on in System Settings › Keyboard › Dictation.
    nonisolated static func installedLanguages() async -> [TranscriptionLanguage] {
        await DictationTranscriber.installedLocales.compactMap {
            TranscriptionLanguage.from(languageTag: $0.identifier(.bcp47))
        }
    }

    /// Download and install Apple's dictation assets for `language`. The OS fetches them from
    /// Apple, shares them with every app and keeps them updated.
    nonisolated static func install(
        _ language: TranscriptionLanguage,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let locale = await locale(for: language) else {
            throw SystemLivePreviewError.unsupported(language.displayName)
        }
        try await DictationAssets.shared.install(locale, progress: progress)
    }

    /// How long a session start waits for Apple to finish an install it hands out: enough for the
    /// allocation-only case (0.4 s measured), far short of a real download (~25 s measured).
    nonisolated static let sessionInstallBudget: Double = 3

    // MARK: - LivePreviewEngine

    func forcedLanguageSupport(for language: TranscriptionLanguage) async -> (code: String, isSupported: Bool)? {
        guard language != .auto else { return nil }
        let supported = await Self.status(for: language) == .ready
        return (language.rawValue, supported)
    }

    func beginSession(language: TranscriptionLanguage) async {
        resetText()
        resetSessionAudio()
        sessionID &+= 1
        probeCandidates = []
        probeStage = .decided
        missingLanguage = nil

        let start: TranscriptionLanguage?
        if language == .auto {
            var ready: [TranscriptionLanguage] = []
            for candidate in preferredLanguages where candidate != .auto {
                if await Self.status(for: candidate) == .ready { ready.append(candidate) }
            }
            let last = UserDefaults.standard.string(forKey: Self.lastLanguageKey)
                .flatMap { TranscriptionLanguage(rawValue: $0) }
            start = last.flatMap { ready.contains($0) ? $0 : nil } ?? ready.first
            if ready.count > 1, let probe {
                // The first checkpoint depends on the engine the probe runs on.
                let session = sessionID
                let earliest = await probe.earliestSeconds() ?? Self.earlyProbeSeconds
                guard session == sessionID else { return }
                probeEarlySeconds = earliest
                probeCandidates = ready
                probeStage = .waitingEarly
            }
        } else {
            start = await Self.status(for: language) == .ready ? language : nil
        }
        guard let start, let locale = await Self.locale(for: start) else {
            missingLanguage = language != .auto ? language : preferredLanguages.first { $0 != .auto }
            Logger.warning("System dictation: no installed locale for \(language.rawValue) — the engine's own preview shows live text this session", subsystem: .transcription)
            return
        }
        sessionLanguage = start
        await startAnalyzer(locale: locale)
        if probeStage != .decided {
            // Normally done by `prepare()` already; here in case the main engine loaded after it ran.
            Task { [weak self] in await self?.prepare() }
        }
    }

    /// Pay the one-time costs of a language switch before any session needs it: Apple's asset
    /// allocation for every preferred language, and the probe's calibration. Measured on the
    /// user's 9.6 s Russian dictation: paid inside the session, they pushed the first Russian
    /// text from ~3 s to 4.8 s.
    func prepare() async {
        await preallocate(preferredLanguages.filter { $0 != .auto })
        await probe?.prepare(for: preferredLanguages)
    }

    func setPreviewCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        self.callback = callback
    }

    func feed(samples: [Float]) async {
        recordSessionAudio(samples)
        recordRecentAudio(samples)
        if let input, let format = analyzerFormat, let buffer = makeBuffer(samples, format: format) {
            input.yield(AnalyzerInput(buffer: buffer))
        }
        scheduleProbeIfDue()
        scheduleReprobeIfDue()
    }

    func endSession() async -> String {
        await retireAnalyzer()
        let text = composed()
        // The session is over: everything Apple produced is final, so commit all of it before
        // the consumer closes its stream.
        let words = Self.words(text)
        if words.count > committedWords.count {
            committedWords.append(contentsOf: words[committedWords.count...])
            stableCallback?(committedWords.joined(separator: " "))
        }
        callback = nil
        stableCallback = nil
        committedWords = []
        recentUpdates = []
        resetText()
        resetSessionAudio()
        sessionID &+= 1
        sessionLocale = nil
        sessionLanguage = nil
        probeStage = .decided
        return text
    }

    /// Apple's model cannot detect language; the arbiter pins it through `pinLanguage`.
    func detectedLanguageCode() async -> String? { nil }

    /// Restart the analyzer in `code`'s locale. A nil code (unpin) keeps the current locale —
    /// there is no "auto" to fall back to. Once the probe has decided, its answer stands for the
    /// first `replayLimitSamples`; later pins (a meeting changing language) still apply.
    func isStreaming() async -> Bool { input != nil }

    func unavailableLanguage() async -> TranscriptionLanguage? { missingLanguage }

    func pinLanguage(_ code: String?) async {
        guard let code, let language = TranscriptionLanguage.from(languageTag: code) else { return }
        if probeStage != .decided { return }  // the probe is about to answer, sooner and better
        // A later pin means the language changed, not that the start was wrong: keep the text.
        await switchLanguage(to: language, reason: "pinned", replay: false)
    }

    // MARK: - Language probe

    private func resetSessionAudio() {
        sessionAudio = []
        sessionAudioOverflowed = false
        voicedStart = nil
        frameRMS = []
        pendingFrame = []
        probeInFlight = false
        probedCheckpoints = []
        recentAudio = []
        samplesSinceReprobe = 0
        reprobe.reset()
    }

    // MARK: - Re-probe (whole session)

    private func recordRecentAudio(_ samples: [Float]) {
        recentAudio.append(contentsOf: samples)
        // Trimmed in bulk, not per feed: a per-feed trim copied the whole 8 s window every 20 ms.
        if recentAudio.count > Self.reprobeWindowSamples * 2 {
            recentAudio.removeFirst(recentAudio.count - Self.reprobeWindowSamples)
        }
        samplesSinceReprobe += samples.count
    }

    /// Re-check the language on recent speech once the start decision is made. Only in auto mode
    /// with a real choice (`probeCandidates`), never while another probe runs, never on silence.
    private func scheduleReprobeIfDue() {
        guard probeStage == .decided, !probeInFlight, let probe, probeCandidates.count > 1,
              sessionLanguage != nil, samplesSinceReprobe >= Self.reprobeIntervalSamples,
              recentAudio.count >= Self.reprobeWindowSamples else { return }
        samplesSinceReprobe = 0
        let window = Array(recentAudio.suffix(Self.reprobeWindowSamples))
        var sum: Float = 0
        for value in window { sum += value * value }
        guard (sum / Float(window.count)).squareRoot() >= Self.reprobeMinimumRMS else { return }
        probeInFlight = true
        let candidates = probeCandidates
        let id = sessionID
        Task { [weak self] in
            let result = await probe.identify(samples: window, allowed: candidates)
            await self?.reprobeFinished(result, session: id)
        }
    }

    private func reprobeFinished(
        _ result: (language: TranscriptionLanguage, probability: Float, probabilities: [TranscriptionLanguage: Float])?,
        session: Int
    ) async {
        guard session == sessionID else { return }
        probeInFlight = false
        guard let result, let current = sessionLanguage else { return }
        let scores = result.probabilities.sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue)=\(String(format: "%.2f", $0.value))" }.joined(separator: " ")
        guard let target = reprobe.observe(language: result.language, probability: result.probability,
                                           current: current) else {
            if result.language != current, result.probability >= LanguageReprobeTracker.confidentProbability {
                Logger.info("Language re-probe: \(result.language.rawValue) (\(scores)) against \(current.rawValue) — waiting for agreement", subsystem: .transcription)
            }
            return
        }
        Logger.info("Language re-probe: switching \(current.rawValue) → \(target.rawValue) (\(scores))", subsystem: .transcription)
        UserDefaults.standard.set(target.rawValue, forKey: Self.lastLanguageKey)
        await switchLanguage(to: target, reason: "re-probe", replay: false)
    }

    /// Keep the session's audio for the probe and for replay, and find where speech starts:
    /// 20 ms frames against a noise floor taken from the first 200 ms (the key press usually
    /// precedes speech), capped so a recording that starts mid-word still finds its onset.
    private func recordSessionAudio(_ samples: [Float]) {
        let room = Self.replayLimitSamples - sessionAudio.count
        if room <= 0 { sessionAudioOverflowed = true; return }
        let kept = samples.count <= room ? samples : Array(samples.prefix(room))
        let base = sessionAudio.count
        sessionAudio.append(contentsOf: kept)
        guard voicedStart == nil else { return }

        let frame = 320
        pendingFrame.append(contentsOf: kept)
        var consumed = 0
        while pendingFrame.count - consumed >= frame {
            var sum: Float = 0
            for value in pendingFrame[consumed..<consumed + frame] { sum += value * value }
            let rms = (sum / Float(frame)).squareRoot()
            frameRMS.append(rms)
            consumed += frame
            let sorted = frameRMS.prefix(10).sorted()
            let floor = min(sorted[sorted.count / 2], 0.01)
            if frameRMS.count > 3, rms > max(0.004, floor * 3) {
                // Back off 100 ms so the onset consonant is inside the window.
                let frameStart = (frameRMS.count - 1) * frame
                voicedStart = max(0, min(frameStart, base + kept.count) - 1_600)
                pendingFrame = []
                return
            }
        }
        pendingFrame.removeFirst(consumed)
    }

    private func scheduleProbeIfDue() {
        guard probeStage != .decided, !probeInFlight, let probe else { return }
        // A quiet mic may never cross the onset threshold; probe from the top rather than never.
        guard let start = voicedStart ?? (sessionAudio.count >= 40_000 ? 0 : nil) else { return }
        let seconds: Double
        switch probeStage {
        case .waitingEarly: seconds = probeEarlySeconds
        case .waitingMid: seconds = Self.midProbeSeconds
        default: seconds = Self.lateProbeSeconds
        }
        let needed = Int(seconds * 16_000)
        guard sessionAudio.count - start >= needed, !probedCheckpoints.contains(seconds) else { return }
        probeInFlight = true
        probedCheckpoints.insert(seconds)
        let window = Array(sessionAudio[start..<start + needed])
        let candidates = probeCandidates
        let id = sessionID
        let stage = probeStage
        Logger.debug("Language probe: \(seconds)s window from \(start) (stage \(stage), session \(id))", subsystem: .transcription)
        Task { [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            let result = await probe.identify(samples: window, allowed: candidates)
            let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
            let engine = await probe.currentSourceName() ?? "no engine"
            await self?.probeFinished(result, engine: engine, stage: stage, seconds: seconds, elapsedMs: elapsed, session: id)
        }
    }

    private func probeFinished(
        _ result: (language: TranscriptionLanguage, probability: Float, probabilities: [TranscriptionLanguage: Float])?,
        engine: String, stage: ProbeStage, seconds: Double, elapsedMs: Double, session: Int
    ) async {
        guard session == sessionID else { return }
        probeInFlight = false
        guard let result else {
            // No main engine loaded yet: the session keeps its start language and follows the
            // engine's own pin. Logged, because this silently left Russian in Hebrew once.
            Logger.info("Language probe: no answer (\(engine)) — keeping the start language", subsystem: .transcription)
            probeStage = .decided
            return
        }
        let scores = result.probabilities.sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue)=\(String(format: "%.2f", $0.value))" }.joined(separator: " ")
        if (stage == .waitingEarly || stage == .waitingMid) && result.probability < Self.confidentProbability {
            // From a 2 s first checkpoint there is no mid one left; go to the late one.
            let next: ProbeStage = stage == .waitingEarly && probeEarlySeconds < Self.midProbeSeconds ? .waitingMid : .waitingLate
            let nextSeconds = next == .waitingMid ? Self.midProbeSeconds : Self.lateProbeSeconds
            Logger.info("Language probe (\(engine)) \(String(format: "%.1f", seconds))s: unsure (\(scores)) in \(String(format: "%.0f", elapsedMs))ms — waiting for \(nextSeconds)s", subsystem: .transcription)
            probeStage = next
            scheduleProbeIfDue()
            return
        }
        Logger.info("Language probe (\(engine)) \(String(format: "%.1f", seconds))s: \(result.language.rawValue) (\(scores)) in \(String(format: "%.0f", elapsedMs))ms", subsystem: .transcription)
        if stage == .confirming && result.probability < Self.confidentProbability {
            probeStage = .decided  // an unsure re-check does not overturn a confident answer
            return
        }
        probeStage = (stage == .waitingEarly || stage == .waitingMid) ? .confirming : .decided
        UserDefaults.standard.set(result.language.rawValue, forKey: Self.lastLanguageKey)
        await switchLanguage(to: result.language, reason: "probe", replay: true)
        if probeStage == .confirming { scheduleProbeIfDue() }
    }

    /// Restart in `language`. With `replay` (the probe correcting the session's starting
    /// language) and the session's audio all still held, the new analyzer is fed it from the
    /// start and the wrong-language text is dropped, so the live text reads as if the right
    /// language had been chosen up front. Otherwise the text so far is carried over.
    private func switchLanguage(to language: TranscriptionLanguage, reason: String, replay wantsReplay: Bool) async {
        // Claim the language before the first await: the actor is reentrant, and a probe or pin
        // arriving while this one awaits Apple must see the switch as taken, not start a second.
        guard language != sessionLanguage else { return }
        let previous = sessionLanguage
        sessionLanguage = language
        let session = sessionID
        guard await Self.status(for: language) == .ready,
              let locale = await Self.locale(for: language) else {
            if session == sessionID {
                sessionLanguage = previous
                // Keeps streaming in the old language (a meeting must not lose its live text);
                // reported so the caller can tell the user and install it for next time.
                missingLanguage = language
                Logger.warning("System dictation: cannot switch to \(language.rawValue) (\(reason)) — not installed", subsystem: .transcription)
            }
            return
        }
        guard session == sessionID else { return }
        // Replay from the top drops the wrong-language text; carrying keeps it and replays only
        // what arrives while the old analyzer finishes, which no analyzer would hear otherwise.
        let replay = wantsReplay && !sessionAudioOverflowed
        Logger.info("System dictation: restarting in \(locale.identifier(.bcp47)) (\(reason), \(replay ? String(format: "replaying %.1fs", Double(sessionAudio.count) / 16_000) : "carrying text"))", subsystem: .transcription)
        let replayFrom: Int?
        if replay {
            replayFrom = 0
            await discardAnalyzer()
            resetText()
        } else {
            replayFrom = sessionAudioOverflowed ? nil : sessionAudio.count
            await retireAnalyzer()
            carried = composed()
            finalized = ""
            volatile = ""
        }
        guard session == sessionID else { return }
        await startAnalyzer(locale: locale, replayFrom: replayFrom)
    }

    /// Allocate Apple's assets for the languages a session may switch to, ahead of the switch:
    /// the first `assetInstallationRequest` for a locale in this process is what made the first
    /// switch to Russian land ~2.5 s after the probe answered.
    private func preallocate(_ languages: [TranscriptionLanguage]) async {
        for language in languages {
            guard let locale = await Self.locale(for: language) else { continue }
            let id = locale.identifier(.bcp47)
            guard !allocatedLocales.contains(id) else { continue }
            // Starts whatever install is needed without waiting for it.
            if await DictationAssets.shared.prepare(locale, within: Self.sessionInstallBudget) == .ready {
                allocatedLocales.insert(id)
            }
        }
    }

    /// Drop the current analyzer without waiting for its last results — they are in the wrong
    /// language and about to be replaced.
    private func discardAnalyzer() async {
        guard let analyzer else { return }
        input?.finish()
        input = nil
        self.analyzer = nil
        generation &+= 1
        resultsTask?.cancel()
        resultsTask = nil
        await analyzer.cancelAndFinishNow()
    }

    // MARK: - Analyzer lifecycle

    /// Session audio from `replayFrom` on is fed before any live audio, read inside the same
    /// actor turn that publishes `input`, so nothing from `feed` can be lost or doubled.
    private func startAnalyzer(locale: Locale, replayFrom: Int? = nil) async {
        let module = DictationTranscriber(locale: locale, preset: Self.preset)
        let id = locale.identifier(.bcp47)
        do {
            if !allocatedLocales.contains(id) {
                // A request from Apple is completed, not refused: it comes back even for installed
                // assets on some Macs, and refusing meant live text never streamed there.
                switch await DictationAssets.shared.prepare(locale, within: Self.sessionInstallBudget) {
                case .ready:
                    allocatedLocales.insert(id)
                case .installing:
                    Logger.warning("System dictation: \(id) still installing — the engine's own preview shows live text this session", subsystem: .transcription)
                    missingLanguage = sessionLanguage
                    return
                case .failed:
                    missingLanguage = sessionLanguage
                    return
                }
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                Logger.warning("System dictation: no audio format for \(id)", subsystem: .transcription)
                return
            }
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(modules: [module])
            generation &+= 1
            let gen = generation
            resultsTask = Task { [weak self] in
                do {
                    for try await result in module.results {
                        await self?.handle(text: String(result.text.characters), isFinal: result.isFinal, generation: gen)
                    }
                } catch {
                    Logger.warning("System dictation results ended: \(error.localizedDescription)", subsystem: .transcription)
                }
            }
            try await analyzer.start(inputSequence: stream)
            self.analyzer = analyzer
            self.input = continuation
            self.analyzerFormat = format
            self.converter = nil
            self.sessionLocale = locale
            if let replayFrom, replayFrom < sessionAudio.count {
                let replay = sessionAudio
                var offset = replayFrom
                while offset < replay.count {
                    let end = min(offset + 8_000, replay.count)
                    if let buffer = makeBuffer(Array(replay[offset..<end]), format: format) {
                        continuation.yield(AnalyzerInput(buffer: buffer))
                    }
                    offset = end
                }
            }
            Logger.info("System dictation: streaming in \(id)", subsystem: .transcription)
        } catch {
            Logger.error("System dictation: failed to start \(id): \(error.localizedDescription)", subsystem: .transcription)
        }
    }

    /// Finish the current analyzer and wait (bounded) for its last results.
    private func retireAnalyzer() async {
        guard let analyzer else { return }
        input?.finish()
        input = nil
        self.analyzer = nil
        let results = resultsTask
        resultsTask = nil
        let finished = await Self.withTimeout(Self.finalizeTimeout) {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            await results?.value
        }
        if !finished {
            Logger.warning("System dictation: finalize timed out — cancelling", subsystem: .transcription)
            await analyzer.cancelAndFinishNow()
            results?.cancel()
        }
    }

    // MARK: - Results

    private func handle(text raw: String, isFinal: Bool, generation gen: Int) {
        guard gen == generation else { return }
        let text = Self.clean(raw)
        if isFinal {
            finalized = Self.join(finalized, text)
            volatile = ""
        } else {
            volatile = text
        }
        let full = composed()
        guard !full.isEmpty, full != lastEmitted else { return }
        lastEmitted = full
        callback?(full)
        commitStableWords(full)
    }

    private func commitStableWords(_ full: String) {
        guard stableCallback != nil else { return }
        let words = Self.words(full)
        recentUpdates.append(words)
        if recentUpdates.count > Self.agreementUpdates { recentUpdates.removeFirst() }
        // Until the probe has settled the language the text may be thrown away by a replay.
        guard probeStage == .decided, recentUpdates.count == Self.agreementUpdates else { return }
        var agreed = recentUpdates.map(\.count).min() ?? 0
        for update in recentUpdates.dropLast() {
            var index = 0
            while index < agreed && update[index] == words[index] { index += 1 }
            agreed = index
        }
        let finalizedCount = Self.words(Self.join(carried, finalized)).count
        let target = max(min(agreed, words.count - Self.uncommittedTailWords), finalizedCount)
        guard target > committedWords.count, target <= words.count else { return }
        committedWords.append(contentsOf: words[committedWords.count..<target])
        stableCallback?(committedWords.joined(separator: " "))
    }

    nonisolated static func words(_ text: String) -> [String] {
        text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    private func composed() -> String {
        Self.join(Self.join(carried, finalized), volatile)
    }

    private func resetText() {
        carried = ""
        finalized = ""
        volatile = ""
        lastEmitted = ""
    }

    /// Apple prefixes RTL results with U+200F (and can emit U+200E); the HUD sets paragraph
    /// direction itself, and stray marks would break the transcriber's text diffing.
    nonisolated static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{200F}", with: "")
            .replacingOccurrences(of: "\u{200E}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    // MARK: - Audio

    private func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = source.floatChannelData else { return nil }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress { channel[0].update(from: base, count: samples.count) }
        }
        if format == sourceFormat { return source }

        if converter == nil || converter?.outputFormat != format {
            converter = AVAudioConverter(from: sourceFormat, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount((Double(samples.count) * format.sampleRate / sourceFormat.sampleRate).rounded(.up))
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error else {
            Logger.warning("System dictation: audio conversion failed: \(error?.localizedDescription ?? "unknown")", subsystem: .transcription)
            return nil
        }
        return output
    }

    /// Runs `work`; returns false if `timeout` elapsed first. Unstructured on purpose: a task group
    /// would wait for `work` before returning, and a wedged finalize never returns.
    nonisolated private static func withTimeout(_ timeout: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            Task {
                await work()
                if once.claim() { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }
}

/// First caller wins; for racing two tasks onto one continuation.
private nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

nonisolated enum SystemLivePreviewError: Error, LocalizedError {
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let language): return "\(language) is not available in Apple dictation"
        }
    }
}
#endif
