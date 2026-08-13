//
//  MeetingSpeakerCoordinator.swift
//  Whisperer
//
//  Attributes Nemotron's growing transcript to Sortformer speaker slots on a
//  shared audio-sample clock.
//

#if canImport(FluidAudio)
import Foundation
import FluidAudio

/// Runs the streaming diarizer alongside the ASR and hands back speaker-labelled text.
///
/// `SortformerDiarizer` is a `public final class` documented as not thread-safe. This actor
/// is the containment boundary — the instance is created here and never escapes (same
/// precedent as `MeetingRAGEngine` owning Wax `Memory` handles).
///
/// ### Why an audio-sample clock
/// The coordinator is fed the same buffers as the ASR, so `samplesFed / 16000` is the exact
/// audio position. Nemotron partials *arrive* later than the audio they describe, while
/// Sortformer timestamps are audio time — counting samples puts both on one axis with no
/// fudge factor.
///
/// ### Why deltas are held back
/// Sortformer finalizes its timeline ~1s behind the audio. Text is queued until the finalized
/// timeline covers its span, so labels are right the first time. The delay is invisible: the
/// not-yet-attributed remainder is exactly what the UI already draws as the grey live tail.
actor MeetingSpeakerCoordinator {

    // MARK: - Callbacks

    /// Text whose speaker is now known. `(text, speakerIndex, startSeconds, endSeconds)`.
    private var onAttributed: (@Sendable (String, Int, TimeInterval, TimeInterval) -> Void)?
    /// Everything still waiting on the diarizer — rendered as the grey live tail.
    private var onPendingTail: (@Sendable (String) -> Void)?
    /// Speaker the diarizer *thinks* is talking right now, from tentative segments.
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

    private var diarizer: SortformerDiarizer?

    private let sampleRate: Double = 16000
    private var samplesFed: Int = 0
    private var audioSeconds: TimeInterval { Double(samplesFed) / sampleRate }

    /// Speaker turns the diarizer has committed to, and how far that timeline reaches.
    private var finalized: [(start: TimeInterval, end: TimeInterval, speaker: Int)] = []
    private var finalizedUntil: TimeInterval = 0
    private var tentativeSpeaker: Int?
    private var lastEmittedSpeaker: Int?

    /// Text waiting for the finalized timeline to catch up, in transcript order.
    private var pending: [(words: [String], start: TimeInterval, end: TimeInterval)] = []

    /// Last accumulated transcript seen, split into words, and the audio position it reached.
    private var lastWords: [String] = []
    private var lastPartialAudioSeconds: TimeInterval = 0

    /// Word count already handed to `onAttributed` — the floor below which a Nemotron
    /// revision cannot rewrite history.
    private var emittedWordCount: Int = 0

    /// `process()` drains one chunk per call. Bounded so a misbehaving model can't spin here.
    private let maxDrainIterations = 64

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
            Logger.info("Diarization: Sortformer model not on disk — meeting records without speaker labels", subsystem: .model)
            return
        }

        let config = MeetingDiarizerService.config
        do {
            let models: SortformerModels
            if let warm = await MeetingDiarizerService.shared.models {
                models = warm
            } else {
                let started = Date()
                models = try await SortformerModels.loadFromHuggingFace(
                    config: config,
                    cacheDirectory: MeetingDiarizerService.modelsRoot()
                )
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                Logger.warning("Diarization: Sortformer was not warm — loaded on the recording path in \(ms)ms", subsystem: .model)
                await MeetingDiarizerService.shared.adopt(models)
            }
            let instance = SortformerDiarizer(config: config)
            instance.initialize(models: models)
            diarizer = instance
            Logger.info("Diarization: Sortformer ready (\(config.numSpeakers) speaker slots)", subsystem: .model)
        } catch {
            Logger.error("Diarization: Sortformer load failed — \(error.localizedDescription)", subsystem: .model)
            diarizer = nil
        }
    }

    private func reset() {
        diarizer?.reset()
        samplesFed = 0
        finalized = []
        finalizedUntil = 0
        tentativeSpeaker = nil
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
    func feed(_ samples: [Float]) {
        samplesFed += samples.count
        guard let diarizer else { return }

        diarizer.addAudio(samples)
        // addAudio buffers internally; process() returns nil until a chunk's worth of mel
        // features exists, and may have several chunks queued after a burst.
        var iterations = 0
        while iterations < maxDrainIterations,
              let update = ((try? diarizer.process()) ?? nil) {
            integrate(update)
            iterations += 1
        }
        drainPending()
    }

    // MARK: - Text

    /// A Nemotron partial. The callback delivers the **full accumulated transcript** every
    /// ~1120 ms, not a delta, so the new text has to be diffed out.
    func onPartial(_ accumulated: String) {
        ingest(accumulated)
    }

    /// Nemotron's final pass. Same diff, higher-quality text — the tail benefits from the
    /// final decode rather than being frozen at the last partial.
    func onFinalText(_ text: String) {
        ingest(text)
    }

    /// Closes the stream: drain the diarizer, then commit whatever text is left with the
    /// best speaker guess available.
    func finish() {
        if let diarizer, let update = ((try? diarizer.finalizeSession()) ?? nil) {
            integrate(update)
        }
        drainPending()
        flushRemaining()
    }

    // MARK: - Diffing

    /// Word-level longest-common-prefix diff. Word granularity rather than character
    /// granularity because Nemotron routinely re-cases or re-punctuates its tail words —
    /// a character diff would treat "hello" → "Hello," as a full rewrite of the tail.
    private func ingest(_ accumulated: String) {
        let words = accumulated.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let now = audioSeconds

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
            finalized.append((start: start, end: end, speaker: segment.speakerIndex))
            finalizedUntil = max(finalizedUntil, end)
        }

        // The latest tentative segment is who the model currently believes is talking.
        if let latest = update.tentativeSegments.max(by: { $0.endTime < $1.endTime }),
           latest.speakerIndex != tentativeSpeaker {
            tentativeSpeaker = latest.speakerIndex
            onLiveSpeaker?(latest.speakerIndex)
        }
    }

    // MARK: - Draining

    /// Emits every queued item the finalized timeline now covers. Strictly in order — an item
    /// that isn't ready blocks the ones behind it so the transcript never reorders.
    private func drainPending() {
        while let first = pending.first, first.end <= finalizedUntil {
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
        let runs = voicedRuns(from: item.start, to: item.end)

        // One run — nothing to apportion. No runs means the diarizer never armed (or the
        // window is pure silence); fall back to the raw span rather than dropping the text.
        guard runs.count > 1, runs.count <= item.words.count else {
            let span = runs.first ?? (start: item.start, end: item.end)
            deliver(words: item.words, start: span.start, end: span.end)
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
            deliver(words: Array(item.words[cursor..<(cursor + count)]), start: run.start, end: run.end)
            cursor += count
        }
    }

    private func deliver(words: [String], start: TimeInterval, end: TimeInterval) {
        guard !words.isEmpty else { return }
        let speaker = dominantSpeaker(from: start, to: end)
        lastEmittedSpeaker = speaker
        onAttributed?(words.joined(separator: " "), speaker, start, end)
    }

    /// Merged voiced intervals inside the span, in order, per the finalized timeline.
    ///
    /// Overlapping turns collapse into one interval — this answers *where there is sound*, not
    /// who made it. No threshold is applied: the gaps are reported as they are and
    /// `MeetingSession.silenceSplitGap` decides which of them is long enough to break a card.
    private func voicedRuns(from start: TimeInterval, to end: TimeInterval) -> [(start: TimeInterval, end: TimeInterval)] {
        var clipped: [(start: TimeInterval, end: TimeInterval)] = []
        for turn in finalized {
            let lo = max(turn.start, start)
            let hi = min(turn.end, end)
            if hi > lo { clipped.append((start: lo, end: hi)) }
        }
        guard !clipped.isEmpty else { return [] }
        clipped.sort { $0.start < $1.start }

        var merged: [(start: TimeInterval, end: TimeInterval)] = [clipped[0]]
        for interval in clipped.dropFirst() {
            if interval.start <= merged[merged.count - 1].end {
                merged[merged.count - 1].end = max(merged[merged.count - 1].end, interval.end)
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// The speaker holding the most audio time across the span. Overlapping speech resolves to
    /// whoever dominates rather than whoever happened to start first.
    private func dominantSpeaker(from start: TimeInterval, to end: TimeInterval) -> Int {
        var totals: [Int: TimeInterval] = [:]
        for turn in finalized {
            let overlap = min(turn.end, end) - max(turn.start, start)
            if overlap > 0 { totals[turn.speaker, default: 0] += overlap }
        }
        if let best = totals.max(by: { $0.value < $1.value })?.key { return best }
        // No finalized coverage (silence-only span, or the diarizer never armed).
        return tentativeSpeaker ?? lastEmittedSpeaker ?? 0
    }
}
#endif
