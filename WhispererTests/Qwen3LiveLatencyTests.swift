//
//  Qwen3LiveLatencyTests.swift
//  WhispererTests
//
//  Integration test for the live-preview latency work: feeds a real recording through
//  StreamingTranscriber at wall-clock pace and measures what the user actually experiences —
//  when the first word appears, how long the text stands still between updates, and how much
//  inference produced nothing new.
//
//  Deliberately measured from the preview *callback*, not from the engine's internal
//  enc/prefill/decode counters. The user does not wait on a decode, they wait on text changing
//  on screen, and the gap between those two is where several of the fixed bugs lived.
//
//  Skips when the model is not downloaded.
//

import XCTest
@testable import whisperer

final class Qwen3LiveLatencyTests: XCTestCase {

    // Process-lifetime: the model is ~2.5 GB and its Metal kernels compile once.
    private static var bridge: Qwen3ASRBridge?

    /// Long enough to force several VAD chunk commits, which is where the preview used to
    /// starve: at the old 15 s cap one commit blocked every poll for ~4 s.
    private static let clipSeconds = 40.0

    private static let recordingsDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Whisperer/Recordings")

    private func requireBridge() throws -> Qwen3ASRBridge {
        if let b = Self.bridge { return b }
        guard Qwen3ASRBridge.isModelCached() else {
            throw XCTSkip("Qwen3-ASR not downloaded at \(Qwen3ASREngine.modelDirectory().path)")
        }
        let b = try Qwen3ASRBridge.loadFromCache()
        Self.bridge = b
        return b
    }

    /// A real dictation, trimmed to `clipSeconds`. Picks the longest available recording so the
    /// clip is continuous speech rather than a short phrase padded with silence.
    private func clip() throws -> [Float] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.recordingsDir.path) else {
            throw XCTSkip("no recordings directory")
        }
        let wavs = names.filter { $0.hasSuffix(".wav") || $0.hasSuffix(".opus") }
        guard !wavs.isEmpty else { throw XCTSkip("no recordings present") }
        let largest = wavs
            .compactMap { name -> (String, Int)? in
                let url = Self.recordingsDir.appendingPathComponent(name)
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
                return size.map { (name, $0) }
            }
            .max { $0.1 < $1.1 }
        guard let largest else { throw XCTSkip("no sized recordings") }
        let samples = try loadAudioSamples(from: Self.recordingsDir.appendingPathComponent(largest.0))
        let wanted = Int(Self.clipSeconds * 16_000)
        guard samples.count >= wanted else {
            throw XCTSkip("longest recording \(largest.0) is shorter than \(Self.clipSeconds)s")
        }
        return Array(samples[0..<wanted])
    }

    /// Index of the first sample that is plausibly speech rather than room tone.
    ///
    /// Time-to-first-word has to be measured from here, not from the first sample. A real
    /// dictation opens with the gap between the key going down and the speaker starting, and
    /// this clip has about 1.2 s of it: the first three preview passes decode windows whose peak
    /// amplitude is 0.011-0.019, the model correctly answers `language None` with 3 tokens, and
    /// each costs about 170 ms. Charging that silence to the pipeline measured the recording,
    /// not the app — and it is the entire reason the earlier figure looked like 2.2 s when the
    /// passes themselves were finishing in under 200 ms.
    ///
    /// 0.05 is above this corpus's room tone and well below speech; the exact value does not
    /// matter much because the onset is sharp.
    private func speechOnsetIndex(_ samples: [Float], threshold: Float = 0.05) -> Int {
        // 20 ms frames: short enough to land on the onset, long enough that one stray sample
        // of electrical noise does not count as speech.
        let frame = 320
        var index = 0
        while index + frame <= samples.count {
            var peak: Float = 0
            for value in samples[index..<(index + frame)] { peak = max(peak, abs(value)) }
            if peak >= threshold { return index }
            index += frame
        }
        return 0
    }

    // MARK: - Measurement

    struct Trace {
        /// Seconds from the first audio sample to the first non-empty preview text.
        var timeToFirstWord: Double = .infinity
        /// Seconds from the feed starting to the first preview callback of any kind, empty
        /// included. This is first-pass cost and nothing else — no speech onset, no language
        /// gate, no agreement — so it isolates allocator/model warmth from everything that
        /// varies with what the speaker said.
        var timeToFirstCallback: Double = .infinity
        /// Wall-clock gaps between successive preview callbacks that changed the text.
        var updateGaps: [Double] = []
        /// Preview callbacks whose text was byte-identical to the one before.
        var repeatedUpdates = 0
        var totalUpdates = 0
        var stopLatency: Double = 0
        var finalText = ""

        var repeatRate: Double {
            totalUpdates == 0 ? 0 : Double(repeatedUpdates) / Double(totalUpdates)
        }

        func gap(percentile p: Double) -> Double {
            guard !updateGaps.isEmpty else { return 0 }
            let sorted = updateGaps.sorted()
            let index = min(sorted.count - 1, Int(Double(sorted.count) * p))
            return sorted[index]
        }

        /// Element-wise median across runs. Each statistic is taken independently — this is a
        /// summary for comparing builds, not a single representative run.
        static func median(of runs: [Trace]) -> Trace {
            precondition(!runs.isEmpty)
            func mid(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            var out = Trace()
            out.timeToFirstWord = mid(runs.map(\.timeToFirstWord))
            out.stopLatency = mid(runs.map(\.stopLatency))
            out.totalUpdates = Int(mid(runs.map { Double($0.totalUpdates) }))
            out.repeatedUpdates = Int(mid(runs.map { Double($0.repeatedUpdates) }))
            out.finalText = runs[0].finalText
            // Percentiles have to come from a per-run median of that percentile, not from the
            // pooled gaps: pooling would let one bad run's tail dominate the p99 of all three.
            out.updateGaps = runs.map { $0.gap(percentile: 0.5) }   // placeholder, see below
            out.medianP90 = mid(runs.map { $0.gap(percentile: 0.9) })
            out.medianP99 = mid(runs.map { $0.gap(percentile: 0.99) })
            out.medianMax = mid(runs.map { $0.updateGaps.max() ?? 0 })
            out.medianP50 = mid(runs.map { $0.gap(percentile: 0.5) })
            return out
        }

        /// Set only on a `median(of:)` result.
        var medianP50: Double?
        var medianP90: Double?
        var medianP99: Double?
        var medianMax: Double?

        var p50: Double { medianP50 ?? gap(percentile: 0.5) }
        var p90: Double { medianP90 ?? gap(percentile: 0.9) }
        var p99: Double { medianP99 ?? gap(percentile: 0.99) }
        var maxGap: Double { medianMax ?? (updateGaps.max() ?? 0) }

        func report(_ label: String) -> String {
            """
            \(label)
              time to first word : \(String(format: "%.2f", timeToFirstWord))s
              update gap p50/p90 : \(String(format: "%.2f", p50))s / \(String(format: "%.2f", p90))s
              update gap p99/max : \(String(format: "%.2f", p99))s / \(String(format: "%.2f", maxGap))s
              updates (repeated) : \(totalUpdates) (\(repeatedUpdates), \
            \(String(format: "%.0f", repeatRate * 100))%)
              stop latency       : \(String(format: "%.2f", stopLatency))s
            """
        }
    }

    /// Collector shared with the feeding task. `@unchecked Sendable` with an explicit lock
    /// because the preview callback and the test body touch it from different executors.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var lastText = ""
        private var lastAt: Date?
        private let startedAt: Date
        private let feedStartedAt: Date
        var trace = Trace()

        init(startedAt: Date, feedStartedAt: Date) {
            self.startedAt = startedAt
            self.feedStartedAt = feedStartedAt
        }

        func record(_ text: String) {
            lock.lock(); defer { lock.unlock() }
            let now = Date()
            trace.totalUpdates += 1
            if trace.timeToFirstCallback == .infinity {
                trace.timeToFirstCallback = now.timeIntervalSince(feedStartedAt)
            }
            guard !text.isEmpty else { return }
            if text == lastText {
                trace.repeatedUpdates += 1
                return
            }
            if trace.timeToFirstWord == .infinity {
                trace.timeToFirstWord = now.timeIntervalSince(startedAt)
            }
            if let lastAt { trace.updateGaps.append(now.timeIntervalSince(lastAt)) }
            lastAt = now
            lastText = text
        }

        func snapshot() -> Trace { lock.lock(); defer { lock.unlock() }; return trace }
    }

    /// Feeds `samples` at wall-clock real time and returns what the user would have seen.
    private func measure(_ bridge: Qwen3ASRBridge, samples: [Float],
                         speechOnsetSeconds: Double = 0) async -> Trace {
        bridge.resetAbort()
        let transcriber = StreamingTranscriber(
            backend: bridge, vad: loadVAD(), language: .auto, initialPrompt: nil,
            fillerWordRemovalEnabled: false, previewBridge: bridge)

        // Audio is fed at wall-clock rate, so the moment speech begins is the clip's own onset
        // offset after the feed starts. Measuring from there rather than from `start()` is what
        // makes time-to-first-word a property of the app instead of a property of the clip.
        let now = Date()
        let collector = Collector(startedAt: now.addingTimeInterval(speechOnsetSeconds),
                                  feedStartedAt: now)
        transcriber.start { text in collector.record(text) }

        // 100 ms of audio every 100 ms — the same cadence AudioRecorder delivers at.
        await Task.detached(priority: .userInitiated) {
            let step = 1_600
            for offset in stride(from: 0, to: samples.count, by: step) {
                transcriber.addSamples(Array(samples[offset..<min(offset + step, samples.count)]))
                Thread.sleep(forTimeInterval: 0.1)
            }
        }.value

        let t0 = CFAbsoluteTimeGetCurrent()
        let final = await transcriber.stopAsync()
        var trace = collector.snapshot()
        trace.stopLatency = CFAbsoluteTimeGetCurrent() - t0
        trace.finalText = final
        return trace
    }

    // MARK: - Tests

    /// Targets come from the seven-day log baseline this work was measured against:
    /// first word median 2.23 s, update gap p99 2.45 s, 42 % of passes identical to the previous.
    func testLivePreviewLatencyMeetsTargets() async throws {
        let bridge = try requireBridge()
        let samples = try clip()

        // Three runs, compared on the median. A single run is not evidence here: this decodes on
        // a shared GPU, and run-to-run spread on the same audio was measured at over a second on
        // time-to-first-word alone. Two consecutive single runs of the *same* build produced
        // 2.65 s and 3.79 s, which is wider than most of the differences being tested for.
        //
        // The first run also primes: it leaves the Metal kernels hot for these window shapes and
        // gives the confirmation gate a `_committedLanguageMemory` to seed from, which is the
        // steady state a returning user is in.
        let onset = Double(speechOnsetIndex(samples)) / 16_000
        print(String(format: "clip speech onset at %.2fs (leading silence excluded from TTFW)", onset))

        var runs: [Trace] = []
        for index in 0..<3 {
            let t = await measure(bridge, samples: samples, speechOnsetSeconds: onset)
            print(t.report("run \(index + 1)"))
            runs.append(t)
        }
        let trace = Trace.median(of: runs)
        print(trace.report("Qwen3 live latency — MEDIAN of 3 (\(Int(Self.clipSeconds))s clip)"))
        print("  final: \(trace.finalText.prefix(120))")

        XCTAssertFalse(trace.finalText.isEmpty, "the final decode produced nothing")
        XCTAssertGreaterThan(trace.totalUpdates, 8, "too few preview updates to judge cadence")

        // Baseline 2.23 s. Bounded by the never-retract invariant: the language-confirmation
        // gate and LocalAgreement-2 both still hold a word back until it is corroborated.
        XCTAssertLessThan(trace.timeToFirstWord, 1.6,
                          "first word too slow (baseline 2.23s)")

        // Gaps here are between *text changes*, so they carry two things the app does not
        // separate: how fast the pipeline turns audio into words, and how long the speaker took
        // to say the next one. Parsing the same session's log apart confirms the split —
        // pass-to-pass (what the app controls) runs p50 0.31s / p90 0.49s / max 0.81s, while
        // text-change runs p50 0.36s / p90 1.19s / max 2.28s. The p90 here is speech-bound and
        // no pipeline change can drive it under a second; the max is not, and it is the one the
        // "live text is stuck" reports were actually about.
        //
        // So p90 is asserted at a level that would catch a real regression without pretending
        // the app owns the speaker's pauses, and the freeze check carries the weight.
        XCTAssertLessThan(trace.p90, 1.5,
                          "text-change cadence regressed (baseline p90 1.34s, speech-bound)")
        XCTAssertLessThan(trace.maxGap, 2.5,
                          "preview starved — this is the 'stuck' symptom (baseline max 5.11s)")

        // Baseline 42 %. Every repeat is a full re-decode of a growing window that produced no
        // new text — the single largest source of wasted GPU on the live path.
        XCTAssertLessThan(trace.repeatRate, 0.25,
                          "too many passes produced no new text (baseline 42%)")

        // Fn-release to final text. Baseline p90 2.07 s.
        XCTAssertLessThan(trace.stopLatency, 2.0, "stop too slow")
    }

    /// Back-to-back dictations must all start warm.
    ///
    /// The regression this guards against shipped and was caught in real use: the buffer-cache
    /// trim was moved off the per-pass path (good) to the end of each recording (bad), which put
    /// the entire re-allocation on the *next* recording's first preview pass. Real-log evidence
    /// across 25 dictations: 22 first passes at ~170 ms and three at 1153/1315/1364 ms, with the
    /// slow ones showing `enc ~420ms prefill ~740ms` — allocator cold, not model cold. The user
    /// description was exactly "first time was delay and second it worked".
    ///
    /// Asserting on the *spread* rather than an absolute ceiling, because the absolute number is
    /// machine-dependent but "one of these is seven times the others" is not.
    func testConsecutiveDictationsAllStartWarm() async throws {
        let bridge = try requireBridge()
        let samples = try clip()
        let onset = Double(speechOnsetIndex(samples)) / 16_000
        // Short clips: this is about the cost of the *first* pass of each recording, and a long
        // clip only adds runtime. Each still ends with a `final` decode, which is what triggers
        // the release-and-rewarm path under test.
        let short = Array(samples[0..<Int((onset + 4.0) * 16_000)])

        _ = await measure(bridge, samples: short, speechOnsetSeconds: onset)   // prime

        var firstPass: [Double] = []
        for index in 0..<4 {
            let t = await measure(bridge, samples: short, speechOnsetSeconds: onset)
            print(String(format: "dictation %d: first pass %.0fms (first word %.2fs)",
                         index + 1, t.timeToFirstCallback * 1000, t.timeToFirstWord))
            firstPass.append(t.timeToFirstCallback)
        }

        // Compared as a *spread across later dictations*, not against an absolute ceiling.
        //
        // This figure is not pure first-pass cost: the preview skips windows that the VAD calls
        // silence, so it also carries the clip's leading silence, and the first recording of a
        // batch additionally pays whatever scheduling the harness itself is still settling. Both
        // inflate it by seconds and neither is the regression. What a cold allocator does is add
        // ~1.1 s to exactly one recording, and against the measured spread of later ones — 2682,
        // 2611, 2604 ms, a 78 ms band — that is unmissable.
        //
        // Index 0 is therefore excluded and reported only. The engine's own per-pass
        // `enc/prefill/decode` line in the log is the ground truth here: warm is 176-215 ms,
        // cold was 1153-1364 ms.
        let later = Array(firstPass.dropFirst())
        let spread = (later.max() ?? 0) - (later.min() ?? 0)
        print(String(format: "consecutive dictations: spread across later runs %.0fms", spread * 1000))
        XCTAssertLessThan(spread, 0.6,
                          "one dictation started with a cold allocator — the cache release is not "
                          + "re-warming (ms: \(firstPass.map { String(format: "%.0f", $0 * 1000) }))")
    }

    /// The two caps must stay *equal*, not merely both small.
    ///
    /// Qwen3 takes the `usesAgreement` branch in `StreamingTranscriber`, which accepts a pass
    /// only when its text is longer than what is already displayed. Below the chunk cap the
    /// preview window slides, the decoded text gets shorter, every pass is rejected, and the
    /// live text freezes until the next commit — measured as a ~2 s freeze per cycle at
    /// cap 6 / chunk 8. Above it the window never slides but each pass re-decodes more audio
    /// than the commit cadence requires. Equal is the only setting that is neither.
    func testStreamingPolicyCapsStayConsistent() throws {
        let policy = try requireBridge().streamingPolicy
        XCTAssertEqual(policy.previewWindowCap, policy.maxVADChunkDuration, accuracy: 0.001,
                       "unequal caps either freeze the preview (below) or over-decode (above)")
        XCTAssertLessThanOrEqual(policy.maxVADChunkDuration, 8.0,
                                 "pass cost is linear in window length; 8s decodes in ~700ms")
    }
}
