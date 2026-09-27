//
//  MeetingSpeakerCoordinator.swift
//  Whisperer
//
//  Attributes Nemotron's growing transcript to Nemotron-3 Diarization speaker slots on a
//  shared audio-sample clock.
//

#if canImport(FluidAudio)
import Foundation
import FluidAudio

/// Runs the streaming diarizer alongside the ASR and hands back speaker-labelled text.
///
/// `Nemotron3Diarizer` is not thread-safe. This actor is the containment boundary —
/// the instance is created here and never escapes (same precedent as `MeetingRAGEngine`
/// owning Wax `Memory` handles).
///
/// ### Why an audio-sample clock
/// The coordinator is fed the same buffers as the ASR, so `samplesFed / 16000` is the exact
/// audio position. Nemotron ASR partials *arrive* later than the audio they describe, while
/// diarizer timestamps are audio time — counting samples puts both on one axis with no
/// fudge factor.
///
/// ### Why deltas are held back
/// The diarizer finalizes its timeline ~1s behind the audio. Text is queued until the finalized
/// timeline covers its span, so labels are right the first time. The delay is invisible: the
/// not-yet-attributed remainder is exactly what the UI already draws as the grey live tail.
actor MeetingSpeakerCoordinator {

    // MARK: - Callbacks

    /// Text whose speaker is now known. `(text, speakerIndex, startSeconds, endSeconds)`.
    private var onAttributed: (@Sendable (String, Int, TimeInterval, TimeInterval) -> Void)?
    /// Everything still waiting on the diarizer — rendered as the grey live tail.
    private var onPendingTail: (@Sendable (String) -> Void)?
    /// Speaker the diarizer *thinks* is talking right now, from the latest finalized segment.
    private var onLiveSpeaker: (@Sendable (Int) -> Void)?

    func setCallbacks(
        onAttributed: @escaping @Sendable (String, Int, TimeInterval, TimeInterval) -> Void,
        onPendingTail: @escaping @Sendable (String) -> Void,
        onLiveSpeaker: @escaping @Sendable (Int) -> Void
    ) {
        self.onAttributed = onAttributed
        self.onPendingTail = onPendingTail
        self.onLiveSpeaker = onLiveSpeaker
    }

    // MARK: - State

    private var diarizer: Nemotron3Diarizer?

    /// Owned timeline converts raw Nemotron3ChunkResult probabilities into DiarizerTimelineUpdate.
    private var diarizerTimeline: DiarizerTimeline?
    /// Running count of finalized frames fed into the timeline — used as startFrame for each chunk.
    private var diarizerFrameCount: Int = 0

    private let sampleRate: Double = 16000
    private var samplesFed: Int = 0
    private var audioSeconds: TimeInterval { Double(samplesFed) / sampleRate }

    /// Speaker turns the diarizer has committed to, and how far that timeline reaches.
    private var finalized: [SpeakerAttribution.Turn] = []
    private var finalizedUntil: TimeInterval = 0
    private var lastEmittedSpeaker: Int?

    /// Text waiting for the finalized timeline to catch up, in transcript order.
    private var pending: [(words: [String], start: TimeInterval, end: TimeInterval)] = []

    /// Last accumulated transcript seen, split into words, and the audio position it reached.
    private var lastWords: [String] = []
    private var lastPartialAudioSeconds: TimeInterval = 0

    /// Word count already handed to `onAttributed` — the floor below which a Nemotron
    /// revision cannot rewrite history.
    private var emittedWordCount: Int = 0

    /// Last tail string published. `drainPending()` runs on every audio buffer, but the tail
    /// only actually changes when a partial lands (~1/s) — without this the grey live text is
    /// republished ~12x/s, and each republish is a `@Published` write that re-renders the
    /// whole transcript view.
    private var lastPublishedTail: String?

    // MARK: - Lifecycle

    /// Arms the diarizer from the resident model bundle.
    ///
    /// Every failure path leaves `diarizer == nil`, which turns every other method into a
    /// no-op — the meeting then records exactly as it does today, all "Speaker 1".
    ///
    /// The load is only a fallback: `MeetingDiarizerService.warm()` normally holds the bundle
    /// from launch, and loading here costs 9+ seconds because it lands on an ANE already busy
    /// with streaming ASR. It deliberately does **not** go through `ModelWorkQueue` — the
    /// meeting gate is raised at this exact moment, so a queued load would wait for the meeting
    /// it is supposed to be diarizing.
    func start() async {
        reset()

        guard MeetingDiarizerService.isModelCached() else {
            Logger.info("Diarization: model not on disk — meeting records without speaker labels", subsystem: .model)
            return
        }

        let config = MeetingDiarizerService.config
        do {
            let models: Nemotron3Models
            if let warm = await MeetingDiarizerService.shared.models {
                models = warm
            } else {
                let started = Date()
                models = try await Nemotron3Models.loadFromHuggingFace(
                    config: config,
                    cacheDirectory: MeetingDiarizerService.modelsRoot()
                )
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                Logger.warning("Diarization: model was not warm — loaded on the recording path in \(ms)ms", subsystem: .model)
                await MeetingDiarizerService.shared.adopt(models)
            }
            let instance = Nemotron3Diarizer(config: config, models: models)
            diarizer = instance
            let timelineConfig = DiarizerTimelineConfig(
                numSpeakers: config.numSpeakers,
                frameDurationSeconds: config.outputFrameSeconds
            )
            diarizerTimeline = DiarizerTimeline(config: timelineConfig)
            Logger.info("Diarization: ready (\(config.numSpeakers) speaker slots)", subsystem: .model)
        } catch {
            Logger.error("Diarization: load failed — \(error.localizedDescription)", subsystem: .model)
            diarizer = nil
            diarizerTimeline = nil
        }
    }

    private func reset() {
        diarizer?.reset()
        diarizer = nil
        diarizerTimeline = nil
        diarizerFrameCount = 0
        samplesFed = 0
        finalized = []
        finalizedUntil = 0
        lastEmittedSpeaker = nil
        pending = []
        lastWords = []
        lastPartialAudioSeconds = 0
        emittedWordCount = 0
        lastPublishedTail = nil
    }

    // MARK: - Audio

    /// Feeds the same 16 kHz mono buffer the ASR receives. Advances the audio clock even when
    /// the diarizer is absent, so timestamps stay right in the degraded path.
    ///
    /// `drainPending()` is called unconditionally so the age-based deadline fires even when
    /// the diarizer is not loaded — without this, a meeting recorded without a model would keep
    /// the entire transcript in pending forever (finalizedUntil stays 0).
    func feed(_ samples: [Float]) {
        samplesFed += samples.count
        if let diarizer, let timeline = diarizerTimeline {
            diarizer.appendAudio(samples)
            let chunks = (try? diarizer.processBufferedAudio()) ?? []
            for chunk in chunks {
                ingest(chunk, into: timeline)
            }
        }
        drainPending()
    }

    // MARK: - Text

    /// A Nemotron partial. The callback delivers the **full accumulated transcript** every
    /// ~1120 ms, not a delta, so the new text has to be diffed out.
    func onPartial(_ accumulated: String) {
        ingestAccumulated(accumulated)
    }

    /// Nemotron's final pass. The argument MUST be the **full accumulated transcript**,
    /// never a per-commit delta from a different decoder. Same diff as `onPartial`, but with
    /// higher-quality text — the tail benefits from the final decode rather than being frozen
    /// at the last partial.
    ///
    /// **Do not call this with a whisper.cpp per-commit delta.** On the whisper.cpp + Nemotron
    /// preview-only meeting path, `onChunkCompleted` delivers disjoint deltas — feeding those
    /// here triggers the "Nemotron rewrote its tail" branch and destroys the pending queue.
    /// `AppState.startInAppRecording` guards this at the call site by not calling `onFinalText`
    /// when `inAppBackend == .whisperCpp`.
    func onFinalText(_ accumulated: String) {
        ingestAccumulated(accumulated)
    }

    /// Closes the stream: drain the diarizer, then commit whatever text is left with the
    /// best speaker guess available.
    func finish() {
        if let diarizer, let timeline = diarizerTimeline {
            let chunks = (try? diarizer.finishStream()) ?? []
            for chunk in chunks {
                ingest(chunk, into: timeline)
            }
        }
        drainPending()
        flushRemaining()
    }

    // MARK: - Chunk ingestion

    /// Converts a `Nemotron3ChunkResult` (raw probabilities) into a `DiarizerTimelineUpdate`
    /// via the owned `DiarizerTimeline`, then integrates the update into the speaker-turn state.
    ///
    /// Nemotron3 emits no tentative predictions — the right-context window finalizes every
    /// core frame before it is returned. The live-speaker dot therefore reads from the newest
    /// finalized segment instead of a tentative one; the lag is at most one chunk (~1.04 s),
    /// comparable to the prior ~1 s finalization lag.
    private func ingest(_ chunk: Nemotron3ChunkResult, into timeline: DiarizerTimeline) {
        let diarizerChunk = DiarizerChunkResult(
            startFrame: diarizerFrameCount,
            finalizedPredictions: chunk.probabilities,
            finalizedFrameCount: chunk.frameCount
        )
        diarizerFrameCount += chunk.frameCount
        guard let update = try? timeline.addChunk(diarizerChunk) else { return }
        integrate(update)
    }

    // MARK: - Diffing

    /// Word-level longest-common-prefix diff. Word granularity rather than character
    /// granularity because Nemotron routinely re-cases or re-punctuates its tail words —
    /// a character diff would treat "hello" → "Hello," as a full rewrite of the tail.
    ///
    /// **Contract:** `accumulated` MUST be the full transcript seen so far, not a delta.
    /// A delta has `words.count < emittedWordCount`; that case is rejected here with an error
    /// log rather than silently destroying the pending queue.
    private func ingestAccumulated(_ accumulated: String) {
        let words = accumulated.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let now = audioSeconds

        // Guard: a per-commit delta from a different decoder (whisper.cpp) has
        // `words.count < emittedWordCount` — it can never be a full accumulated transcript.
        // Feeding it would treat the mismatch as a Nemotron tail-rewrite and destroy pending.
        // The primary guard is in AppState (don't call onFinalText on the whisper.cpp path),
        // but this layer catches any future misrouting before it corrupts state.
        if words.count < emittedWordCount {
            Logger.error("Coordinator received text shorter than emittedWordCount (\(words.count) < \(emittedWordCount)) — rejecting as delta, not accumulated transcript",
                         subsystem: .transcription)
            return
        }

        var lcp = 0
        while lcp < words.count, lcp < lastWords.count, words[lcp] == lastWords[lcp] { lcp += 1 }

        // Text already handed downstream cannot be revoked, so a revision can only reach
        // back as far as the pending queue.
        let divergence = max(lcp, emittedWordCount)
        var queueStart = lastPartialAudioSeconds

        if divergence < emittedWordCount + pendingWordCount {
            // Nemotron rewrote part of its tail: drop the affected pending items and re-queue
            // from the earliest point they covered so the audio span isn't lost.
            var kept: [(words: [String], start: TimeInterval, end: TimeInterval)] = []
            var index = emittedWordCount
            var droppedStart: TimeInterval?
            for item in pending {
                let itemEnd = index + item.words.count
                if itemEnd <= divergence {
                    kept.append(item)
                } else if index >= divergence {
                    droppedStart = droppedStart ?? item.start
                } else {
                    // Split point falls inside this item — keep the surviving prefix.
                    let keepCount = divergence - index
                    let ratio = Double(keepCount) / Double(item.words.count)
                    let cut = item.start + (item.end - item.start) * ratio
                    kept.append((words: Array(item.words.prefix(keepCount)), start: item.start, end: cut))
                    droppedStart = droppedStart ?? cut
                }
                index = itemEnd
            }
            pending = kept
            if let droppedStart { queueStart = droppedStart }
        }

        let suffix = divergence < words.count ? Array(words[divergence...]) : []
        if !suffix.isEmpty {
            pending.append((words: suffix, start: min(queueStart, now), end: now))
        }

        lastWords = words
        lastPartialAudioSeconds = now
        drainPending()
    }

    private var pendingWordCount: Int {
        pending.reduce(0) { $0 + $1.words.count }
    }

    // MARK: - Timeline

    private func integrate(_ update: DiarizerTimelineUpdate) {
        for segment in update.finalizedSegments {
            let start = TimeInterval(segment.startTime)
            let end = TimeInterval(segment.endTime)
            guard end > start else { continue }
            finalized.append(SpeakerAttribution.Turn(start: start, end: end, speaker: segment.speakerIndex))
            finalizedUntil = max(finalizedUntil, end)
        }

        // The latest finalized segment is who the model most recently confirmed as talking.
        // Nemotron3 emits no tentative predictions, so we read the live speaker from finalized.
        if let latest = update.finalizedSegments.max(by: { $0.endTime < $1.endTime }) {
            onLiveSpeaker?(latest.speakerIndex)
        }
    }

    // MARK: - Draining

    /// Emits every queued item the finalized timeline now covers. Strictly in order — an item
    /// that isn't ready blocks the ones behind it so the transcript never reorders.
    ///
    /// Additionally enforces a 3 s audio-age deadline: an item older than `drainDeadlineSeconds`
    /// behind the current audio clock is emitted with the best available speaker guess rather
    /// than waiting for the diarizer to finalize. This prevents unbounded tail growth during long
    /// monologues and bounds the main-actor work done by `MeetingSession.livePreviewText`'s
    /// synchronous polish setter.
    private static let drainDeadlineSeconds: TimeInterval = 3.0

    private func drainPending() {
        let deadline = audioSeconds - Self.drainDeadlineSeconds
        while let first = pending.first,
              first.end <= finalizedUntil || first.end <= deadline {
            pending.removeFirst()
            emit(first)
        }
        publishTail(pending.flatMap { $0.words }.joined(separator: " "))
    }

    /// Stop-time flush: nothing more is coming, so commit the queue with the best guess.
    private func flushRemaining() {
        while !pending.isEmpty {
            emit(pending.removeFirst())
        }
        publishTail("")
    }

    private func publishTail(_ tail: String) {
        guard tail != lastPublishedTail else { return }
        lastPublishedTail = tail
        onPendingTail?(tail)
    }

    /// Hands an item downstream on the **voiced** clock rather than the partial-arrival clock.
    ///
    /// Consecutive queue items abut exactly by construction — `ingest` starts each one where the
    /// last ended — so the raw window can never expose a pause however long the speaker stopped.
    /// Clipping to the finalized turns puts the silence back on the audio clock, which is the
    /// only thing `MeetingSession` can split a paragraph on.
    private func emit(_ item: (words: [String], start: TimeInterval, end: TimeInterval)) {
        emittedWordCount += item.words.count

        // The speaker is resolved **once, over the whole item**. An item is one Nemotron
        // partial — roughly a second of continuous speech from one person — so the runs below
        // say where the pauses are, not who is talking. Resolving per run let a single delta
        // change hands mid-sentence, which is how a card boundary landed inside a word.
        let speaker = dominantSpeaker(from: item.start, to: item.end)
        // Placement is clipped to **that speaker's** finalized turns and nobody else's — see
        // `SpeakerAttribution.voicedRuns(in:by:from:to:)`. A foreign slot's blip says nothing
        // about where these words sit, and treating it as if it did is what manufactured the
        // sub-second gaps that `MeetingSession.silenceSplitGap` then broke cards on.
        let runs = SpeakerAttribution.voicedRuns(in: finalized, by: speaker,
                                                 from: item.start, to: item.end)

        // One run — nothing to apportion. No runs means the diarizer never armed (or the
        // window is pure silence); fall back to the raw span rather than dropping the text.
        guard runs.count > 1, runs.count <= item.words.count else {
            let span = runs.first ?? (start: item.start, end: item.end)
            deliver(words: item.words, speaker: speaker, start: span.start, end: span.end)
            return
        }

        // The window straddles a pause: Nemotron stays quiet through silence, so the partial
        // that follows one carries a window spanning it. Emitting a single envelope here would
        // average the gap away and the paragraph would never break. Apportion the words across
        // the runs by voiced duration instead — the same proportional split `ingest` uses when
        // Nemotron rewrites part of its tail.
        let voiced = runs.reduce(0.0) { $0 + ($1.end - $1.start) }
        var cursor = 0
        for (index, run) in runs.enumerated() {
            let runsLeft = runs.count - index - 1
            let count: Int
            if runsLeft == 0 {
                count = item.words.count - cursor
            } else {
                // Leave at least one word for every run still to come, so no run is emitted empty.
                let available = item.words.count - cursor - runsLeft
                let share = voiced > 0 ? Double(item.words.count) * ((run.end - run.start) / voiced) : 0
                count = min(available, max(1, Int(share.rounded())))
            }
            deliver(words: Array(item.words[cursor..<(cursor + count)]), speaker: speaker,
                    start: run.start, end: run.end)
            cursor += count
        }
    }

    private func deliver(words: [String], speaker: Int, start: TimeInterval, end: TimeInterval) {
        guard !words.isEmpty else { return }
        // A switch closes a transcript card, so it is worth a line. Logged here rather than at
        // the session, which only sees the ones that survive its floors — the absence of any
        // speaker logging is what made per-second relabelling invisible in the log.
        if let previous = lastEmittedSpeaker, previous != speaker {
            Logger.info("Diarization: speaker \(previous + 1) → \(speaker + 1) at \(String(format: "%.1f", start))s",
                        subsystem: .model)
        }
        lastEmittedSpeaker = speaker
        onAttributed?(words.joined(separator: " "), speaker, start, end)
    }

    /// The speaker the finalized timeline puts in the span, or the current one when it has no
    /// real opinion — see `SpeakerAttribution.dominantSpeaker`, which holds both the floors and
    /// the reason "no opinion" is the normal state of affairs in the middle of a turn.
    ///
    /// Carrying the current speaker is the right prior: speech continues far more often than it
    /// changes hands, and a real handover shows up as finalized coverage on the next window.
    private func dominantSpeaker(from start: TimeInterval, to end: TimeInterval) -> Int {
        SpeakerAttribution.dominantSpeaker(in: finalized, from: start, to: end)
            ?? lastEmittedSpeaker ?? 0
    }
}
#endif
