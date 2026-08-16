//
//  EagerStreamHarness.swift
//  WhispererTests
//
//  Runs one real recording through the real `StreamingTranscriber` on the eager path and
//  measures it. Shared by `EagerStreamProfileTests` (one cap, broad corpus) and
//  `EagerStreamWindowSweepTests` (many caps, narrow corpus) so the two cannot disagree about
//  what "a pass" or "the lag" means.
//
//  Everything here is measurement of the shipping code path — nothing is simulated or
//  extrapolated. The comments record the several ways this harness was wrong before, because
//  each one produced confident numbers that were not true.
//

import Foundation
import XCTest
@testable import whisperer

// MARK: - Collectors

/// Thread-safe collector for the pass probe.
///
/// The probe fires on `WhisperBridge.queue`, not the test's thread, and an in-flight pass can
/// still land after `stop()` returns. Accumulating into a captured local `var` raced the main
/// thread's read and corrupted the heap — the first run of this harness died in `SafeLock.deinit`
/// with "pointer being freed was not allocated", which reads as a bug in the transcriber and is
/// not one.
final class EagerPassCollector {
    private let lock = NSLock()
    private var samples: [StreamingTranscriber.EagerPassSample] = []

    func record(_ sample: StreamingTranscriber.EagerPassSample) {
        lock.lock(); samples.append(sample); lock.unlock()
        // A pass that reports tens of seconds is almost never a slow decode — the corpus run that
        // added this reported a 197.7s pass on a 203.7s recording that also completed 128 other
        // passes, which does not fit in the wall clock and so has to be a mis-attributed sample.
        // `decodeMs` spans submit-to-callback, not decode, so it also counts time queued behind
        // another operation on the bridge's serial queue and time blocked on `ctxLock`. Print the
        // shape of the offender rather than only its duration, because the window and word count
        // say immediately which of those it was.
        if sample.decodeMs > 5000 {
            Logger.warning(String(format:
                "Eager pass outlier: %.0fms submit-to-callback, window %.2fs, lag %.2fs, %d words",
                sample.decodeMs, sample.windowSeconds, sample.lagSeconds, sample.wordCount),
                subsystem: .transcription)
        }
    }

    func snapshot() -> EagerPassStats {
        lock.lock(); defer { lock.unlock() }
        return EagerPassStats(latencies: samples.map(\.decodeMs),
                              windows: samples.map(\.windowSeconds),
                              lags: samples.map(\.lagSeconds),
                              // Drop the first, whose predecessor is the start of the recording
                              // rather than another pass, so it reports 0 and drags the mean down.
                              gaps: samples.dropFirst().map(\.sinceLastPassMs))
    }
}

/// Thread-safe collector for published live text. `onTranscription` is delivered via
/// `DispatchQueue.main.async`, which is not the thread this harness runs on.
final class EagerDisplayCollector {
    private let lock = NSLock()
    private var texts: [String] = []
    private var times: [CFAbsoluteTime] = []

    func record(_ text: String) {
        lock.lock(); texts.append(text); times.append(CFAbsoluteTimeGetCurrent()); lock.unlock()
    }

    func snapshot() -> (texts: [String], times: [CFAbsoluteTime]) {
        lock.lock(); defer { lock.unlock() }
        return (texts, times)
    }
}

/// Thread-safe collector for soft-committed chunks. Fires on the bridge queue like the others.
final class EagerChunkCollector {
    private let lock = NSLock()
    private var texts: [String] = []

    func record(_ text: String) {
        lock.lock(); texts.append(text); lock.unlock()
    }

    func snapshot() -> (count: Int, words: Int) {
        lock.lock(); defer { lock.unlock() }
        return (texts.count, texts.reduce(0) { $0 + $1.split(separator: " ").count })
    }
}

/// Thread-safe collector for passes the agreement guard discarded after decoding.
///
/// Kept apart from `EagerSkipCollector` because the two mean opposite things about where the time
/// went. A skip costs nothing; a hold costs a full decode *and* freezes the agreement boundary, so
/// the next pass repeats most of the same work. Split by reason because the two guards fail for
/// different causes and only one of them was a bug.
final class EagerHoldCollector {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ reason: EagerHoldReason) {
        lock.lock(); counts[reason.rawValue, default: 0] += 1; lock.unlock()
    }

    func snapshot() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return counts
    }
}

/// Thread-safe counter for a probe that carries no payload.
final class EagerCounter {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Thread-safe collector for the reasons scheduled passes declined to decode.
///
/// A fixture that produces one pass over a long recording has not "run slowly" — it has stalled,
/// and the only thing that distinguishes a stall from slowness is which guard is firing 150 ms
/// apart for the rest of the recording. Counting them is the difference between diagnosing that
/// and guessing at it.
final class EagerSkipCollector {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ reason: StreamingTranscriber.EagerPassSkip) {
        lock.lock(); counts[reason.rawValue, default: 0] += 1; lock.unlock()
    }

    func snapshot() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return counts
    }
}

// MARK: - Stats

struct EagerPassStats {
    var latencies: [Double] = []
    var windows: [Double] = []
    /// Per-pass distance from the decoded window's end to the live audio edge. The window cap
    /// trades this for bounded latency; a cap that lags badly is not an improvement.
    var lags: [Double] = []
    /// Wall-clock between one pass completing and the next. The decoder self-schedules, so this
    /// should sit just above the decode time; anything much larger means passes are not being
    /// launched, which is a different problem from passes being slow and has a different fix.
    var gaps: [Double] = []

    var count: Int { latencies.count }
    var meanGap: Double { gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count) }
    var maxLag: Double { lags.max() ?? 0 }
    var meanLag: Double { lags.isEmpty ? 0 : lags.reduce(0, +) / Double(lags.count) }
    var meanWindow: Double { windows.isEmpty ? 0 : windows.reduce(0, +) / Double(windows.count) }

    var p50: Double { percentile(0.50) }
    var p90: Double { percentile(0.90) }
    var maxLatency: Double { latencies.max() ?? 0 }

    func percentile(_ q: Double) -> Double {
        guard !latencies.isEmpty else { return 0 }
        let sorted = latencies.sorted()
        return sorted[Int((Double(sorted.count - 1) * q).rounded())]
    }
}

// MARK: - Result

struct EagerRunResult {
    let id: String
    let bucket: String
    let durationSec: Double
    let capSeconds: Double
    let passes: EagerPassStats
    let displayCount: Int
    let displayCadenceMs: Double
    /// Wall-clock from the first sample fed to the first published live text. What the user
    /// experiences as "did it notice I started talking".
    let firstDisplayMs: Double
    let monotonicityViolations: Int
    /// Characters of already-displayed text that a revision took back, summed over the run. A
    /// count of violations alone cannot distinguish one word being corrected from the whole
    /// screen being rewritten, and those are different bugs with different fixes.
    let retractedChars: Int
    /// The largest single retraction, in characters.
    let maxRetractedChars: Int
    let publishesSpeculativeTail: Bool
    /// Which arm of the anchor-guard A/B this run is. See
    /// `EagerStreamEngine.Config.skipsAnchorCheckAfterBoundaryMove`.
    let skipsAnchorCheckAfterBoundaryMove: Bool
    /// Which arm of the repetition-guard A/B this run is. See
    /// `EagerStreamEngine.Config.suppressesRepetitionLoops`.
    let suppressesRepetitionLoops: Bool
    /// Soft-commits that fired, and the total words in them.
    ///
    /// Separates the two ways a run can end up with almost no final text, which look identical
    /// from the outside and need opposite fixes: the engine never committed anything (the
    /// agreement boundary is not advancing), or it committed plenty and the stop path threw it
    /// away. `05011586` — 204s, 36 passes, 33 published displays, 9 words of final text — is the
    /// fixture this exists to classify.
    let chunkCount: Int
    let chunkWords: Int
    /// Passes discarded by the agreement guard, keyed by `EagerHoldReason`.
    let holds: [String: Int]
    /// Passes where the first unconfirmed word repeated the last confirmed one over the same
    /// audio — the suspected source of the adjacent duplicates in `duplicateRuns`. Reported
    /// beside `duplicateRuns` so the two can be checked against each other.
    let repeatedConfirmedTails: Int
    let duplicateRuns: [String]
    let wer: Double
    let stopLatencyMs: Double
    let skips: [String: Int]
    let finalText: String
    let reference: String

    /// True when the run stalled: a recording long enough to need several passes produced at
    /// most one. Scores no worse than a merely inaccurate run on WER, so it needs its own test.
    var stalled: Bool { durationSec > 20 && passes.count <= 1 }

    /// The guard that declined the most passes, as `reason:count`. `busy` dominating is healthy —
    /// it just means the decoder was saturated.
    var dominantSkip: String {
        guard let (reason, count) = skips.max(by: { $0.value < $1.value }) else { return "-" }
        return "\(reason):\(count)"
    }

    /// Held passes as a share of every pass that decoded. The headline number for wasted GPU time.
    var heldFraction: Double {
        let total = passes.count
        guard total > 0 else { return 0 }
        return Double(holds.values.reduce(0, +)) / Double(total)
    }
}

// MARK: - Corpus

/// One fixture, its audio, and its duration taken from the audio rather than the database.
typealias EagerFixture = (fixture: RecordingFixture, samples: [Float])

/// Loads a stratified corpus of real recordings with their audio, dropping any fixture whose
/// `.wav` does not actually contain the speech its stored transcript describes.
///
/// **Why the truncation check exists.** `05011586` scored WER 0.922 across every arm of every
/// profile run and was chased as a streaming bug for three runs. It is not one: the database says
/// 203.7s, the file on disk is 49.4s, and the stored transcript covers all 203.7s. Three quarters
/// of the reference is speech that is not in the audio, so no decoder could have scored better —
/// and because `durationSec` came from the database, the harness also bucketed a 49s recording as
/// "very-long" and reported its window lag against a timeline four times too long. (Its audio is
/// also 13 dB quieter than every other fixture, peak 0.093 against 0.19–0.40 — it is the recording
/// the user made *about* a capture bug, and it captured the bug.)
///
/// Quiet audio on its own is not grounds for exclusion — the app has to handle it. A reference
/// that describes audio the file does not contain is, because it makes WER meaningless rather than
/// merely bad.
///
/// - Parameter perBucket: how many fixtures to keep from each duration bucket.
func loadEagerCorpus(perBucket: [String: Int]) -> (fixtures: [EagerFixture], rejected: [String]) {
    // `EAGER_ONLY_FIXTURE=5f64f423` narrows a 20-minute corpus run to the one recording under
    // investigation. Matching on the id prefix is what the report already prints, so a suspect row
    // can be re-run by copying its first column. Unset in every normal run, including CI.
    let only = ProcessInfo.processInfo.environment["EAGER_ONLY_FIXTURE"]?.lowercased()
    let all = HistoryTestLoader.loadFixtures(maxCount: 3000)
        .filter { $0.audioURL != nil && !$0.transcript.trimmingCharacters(in: .whitespaces).isEmpty }
        .filter { only == nil || $0.id.lowercased().hasPrefix(only!) }

    var loaded: [EagerFixture] = []
    var rejected: [String] = []
    var counts: [String: Int] = [:]

    // Stable order so consecutive runs are comparable.
    for fixture in all.sorted(by: { $0.id < $1.id }) {
        guard let url = fixture.audioURL,
              let samples = try? loadAudioSamples(from: url), !samples.isEmpty else { continue }

        let audioSec = Double(samples.count) / 16000
        // Slack is the larger of 10% and 0.5s. The proportional term covers database rounding and
        // the last partial buffer dropped on stop; the absolute term keeps very short fixtures out
        // of the rejection list, where 0.2s of trailing buffer is 10% of the recording (two 2.0s
        // fixtures whose audio is 1.8s were rejected by a bare 90% rule, and neither is broken).
        guard audioSec >= min(fixture.durationSec * 0.9, fixture.durationSec - 0.5) else {
            rejected.append(String(format: "%@ db=%.1fs wav=%.1fs — reference covers audio that is not in the file",
                                   String(fixture.id.prefix(8)).lowercased(), fixture.durationSec, audioSec))
            continue
        }

        // Re-bucket on the audio, not the database row, so a fixture is judged against the
        // timeline it is actually fed.
        let corrected = RecordingFixture(
            id: fixture.id, durationSec: audioSec, transcript: fixture.transcript,
            aiEnhancedText: fixture.aiEnhancedText, aiModeName: fixture.aiModeName,
            language: fixture.language, audioURL: fixture.audioURL, wordCount: fixture.wordCount)

        let bucket = corrected.durationBucket
        // The per-bucket quota is what stratifies a normal run; a single-fixture run has already
        // said exactly what it wants, so honouring the quota would just discard it.
        guard only != nil || counts[bucket, default: 0] < (perBucket[bucket] ?? 0) else { continue }
        counts[bucket] = counts[bucket, default: 0] + 1
        loaded.append((corrected, samples))
    }

    let order = ["short": 0, "medium": 1, "long": 2, "very-long": 3]
    return (loaded.sorted { (order[$0.fixture.durationBucket] ?? 9, $0.fixture.id)
                         <  (order[$1.fixture.durationBucket] ?? 9, $1.fixture.id) }, rejected)
}

// MARK: - Runner

/// Feed one fixture through the eager path and measure it.
///
/// - Parameter capSeconds: value for `StreamingTranscriber.eagerMaxWindowSeconds`. Pass a huge
///   number to measure the uncapped behaviour.
/// - Parameter realTime: feed at wall-clock speed. Leave this on for anything that measures
///   keeping up. See the note on the feed loop below.
func runEagerFixture(
    _ fixture: RecordingFixture,
    samples: [Float],
    bridge: WhisperBridge,
    capSeconds: Double,
    publishesSpeculativeTail: Bool = true,
    skipsAnchorCheckAfterBoundaryMove: Bool = false,
    suppressesRepetitionLoops: Bool = true,
    realTime: Bool = true
) async -> EagerRunResult {
    let sampleRate: Double = 16000
    let passCollector = EagerPassCollector()
    let displayCollector = EagerDisplayCollector()
    let skipCollector = EagerSkipCollector()
    let chunkCollector = EagerChunkCollector()
    let holdCollector = EagerHoldCollector()
    let repeatCollector = EagerCounter()

    let transcriber = StreamingTranscriber(backend: bridge, vad: loadVAD(), language: .auto)
    transcriber.eagerMaxWindowSeconds = capSeconds
    transcriber.eagerPublishesSpeculativeTail = publishesSpeculativeTail
    transcriber.eagerSkipsAnchorCheckAfterBoundaryMove = skipsAnchorCheckAfterBoundaryMove
    transcriber.eagerSuppressesRepetitionLoops = suppressesRepetitionLoops
    transcriber.onEagerPassMeasured = { [passCollector] in passCollector.record($0) }
    transcriber.onEagerPassSkipped = { [skipCollector] in skipCollector.record($0) }
    transcriber.onChunkCompleted = { [chunkCollector] in chunkCollector.record($0.text) }
    transcriber.onEagerPassHeld = { [holdCollector] in holdCollector.record($0) }
    transcriber.onEagerRepeatedConfirmedTail = { [repeatCollector] in repeatCollector.increment() }

    bridge.resetAbort()
    let feedStart = CFAbsoluteTimeGetCurrent()
    transcriber.start { [displayCollector] text in displayCollector.record(text) }

    // Feed at the rate a microphone actually delivers.
    //
    // The first version of this loop slept 10 ms per 85 ms chunk — 8.5× real time. Pass
    // *latency* survives that (a given window costs what it costs), but every metric about
    // keeping up does not: the transcriber saw a 204s recording in 24s, so it was 180s behind
    // through no fault of its own, and the harness reported that as a 98.7s window lag.
    //
    // Deliberately NOT `feedAudioToTranscriber`, which paces with `Thread.sleep`: blocking a
    // thread outright starves the main queue that `onTranscription` is delivered on, so the
    // display sequence this harness measures never arrives while audio is being fed.
    // `Task.sleep` suspends instead of blocking.
    //
    // Paced against a fixed start time rather than by sleeping a constant per chunk, so the few
    // hundred µs of per-iteration overhead cannot accumulate into a slow feed over the ~3½
    // minutes a very-long fixture takes.
    let chunkSize = 1365  // ~85 ms at 16 kHz
    let chunkSeconds = Double(chunkSize) / sampleRate
    var chunkIndex = 0
    for offset in stride(from: 0, to: samples.count, by: chunkSize) {
        let end = min(offset + chunkSize, samples.count)
        transcriber.addSamples(Array(samples[offset..<end]))
        chunkIndex += 1
        if realTime {
            let remaining = feedStart + Double(chunkIndex) * chunkSeconds - CFAbsoluteTimeGetCurrent()
            if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        } else {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    // Let in-flight passes land before stopping.
    try? await Task.sleep(nanoseconds: 2_000_000_000)

    // `stopAsync`, never the synchronous `stop()`. The sync path returns while an eager pass is
    // still in flight on the bridge queue; that pass then calls back into a transcriber the test
    // has already released, and the run dies in `SafeLock.deinit` with "pointer being freed was
    // not allocated". This is the same race CLAUDE.md warns about, and it aborts the process
    // before a single row reaches the report.
    let stopStart = CFAbsoluteTimeGetCurrent()
    let finalText = await transcriber.stopAsync()
    let stopLatencyMs = (CFAbsoluteTimeGetCurrent() - stopStart) * 1000

    transcriber.onEagerPassMeasured = nil
    transcriber.onEagerPassSkipped = nil
    transcriber.onChunkCompleted = nil
    transcriber.onEagerPassHeld = nil
    transcriber.onEagerRepeatedConfirmedTail = nil

    let (displays, displayTimes) = displayCollector.snapshot()
    var cadence: Double = 0
    if displayTimes.count > 1 {
        let span = displayTimes[displayTimes.count - 1] - displayTimes[0]
        cadence = span / Double(displayTimes.count - 1) * 1000
    }

    return EagerRunResult(
        id: String(fixture.id.prefix(8)).lowercased(),
        bucket: fixture.durationBucket,
        durationSec: fixture.durationSec,
        capSeconds: capSeconds,
        passes: passCollector.snapshot(),
        displayCount: displays.count,
        displayCadenceMs: cadence,
        firstDisplayMs: displayTimes.first.map { ($0 - feedStart) * 1000 } ?? 0,
        monotonicityViolations: eagerMonotonicityViolations(displays),
        retractedChars: eagerRetractedCharacters(displays).total,
        maxRetractedChars: eagerRetractedCharacters(displays).max,
        publishesSpeculativeTail: publishesSpeculativeTail,
        skipsAnchorCheckAfterBoundaryMove: skipsAnchorCheckAfterBoundaryMove,
        suppressesRepetitionLoops: suppressesRepetitionLoops,
        chunkCount: chunkCollector.snapshot().count,
        chunkWords: chunkCollector.snapshot().words,
        holds: holdCollector.snapshot(),
        repeatedConfirmedTails: repeatCollector.value,
        duplicateRuns: eagerAdjacentDuplicateRuns(in: finalText),
        wer: wordErrorRate(finalText, reference: fixture.transcript),
        stopLatencyMs: stopLatencyMs,
        skips: skipCollector.snapshot(),
        finalText: finalText,
        reference: fixture.transcript
    )
}

// MARK: - Quality checks

/// Live text is supposed to be append-only. A display string that is not an extension of the one
/// before it is the flicker that made the eager preview read worse than the old tiny model.
/// Counted rather than asserted so the report shows how bad it is.
func eagerMonotonicityViolations(_ displays: [String]) -> Int {
    guard displays.count > 1 else { return 0 }
    return (1..<displays.count).reduce(0) { $0 + (displays[$1].hasPrefix(displays[$1 - 1]) ? 0 : 1) }
}

/// How much text each revision took back: for every display that is not an extension of its
/// predecessor, the number of the predecessor's characters that did not survive.
///
/// The violation count answers "did text get rewritten"; this answers "how much", which is the
/// question that decides whether the speculative tail is worth publishing. One corrected word at
/// the end of a paragraph and a wholesale rewrite both score 1 violation.
func eagerRetractedCharacters(_ displays: [String]) -> (total: Int, max: Int) {
    guard displays.count > 1 else { return (0, 0) }
    var total = 0, worst = 0
    for i in 1..<displays.count {
        let previous = Array(displays[i - 1]), current = Array(displays[i])
        guard !displays[i].hasPrefix(displays[i - 1]) else { continue }
        var shared = 0
        while shared < previous.count, shared < current.count, previous[shared] == current[shared] {
            shared += 1
        }
        let lost = previous.count - shared
        total += lost
        worst = max(worst, lost)
    }
    return (total, worst)
}

/// Adjacent repeated word runs — "one one", "Let Let me Let me". Checks runs of length 1–4 so it
/// catches both the single-word stutter and the phrase-level looping seen at low `audio_ctx`.
/// Case- and punctuation-insensitive.
func eagerAdjacentDuplicateRuns(in text: String) -> [String] {
    let words = text.lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
        .map(String.init)
    guard words.count > 1 else { return [] }

    var found: [String] = []
    var i = 0
    while i < words.count {
        var matchedLength = 0
        for runLength in stride(from: min(4, (words.count - i) / 2), through: 1, by: -1) {
            let a = words[i..<(i + runLength)]
            let b = words[(i + runLength)..<(i + 2 * runLength)]
            if Array(a) == Array(b) {
                found.append(a.joined(separator: " "))
                matchedLength = runLength * 2
                break
            }
        }
        i += matchedLength > 0 ? matchedLength : 1
    }
    return found
}

// MARK: - Report formatting

/// `String(format:)` with `%@` mangles a Swift String bridged to NSString here — early reports
/// printed "\u{...}ݕ\u{...}E" for every id. Pad text columns by hand.
func eagerPad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

/// Appends a line to a report file and stdout. Written incrementally because a whisper context
/// teardown can abort the process on exit, discarding anything still buffered in stdout.
func eagerAppend(_ line: String, to url: URL) {
    print(line)
    let payload = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: payload)
    } else {
        try? payload.write(to: url)
    }
}
