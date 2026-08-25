//
//  MeetingLanguageScanner.swift
//  Whisperer
//
//  The I/O half of the meeting language decision: reads slices of the recording off disk and
//  runs the encoder-only detector over them, then hands the distributions to the pure
//  `MeetingLanguageTimelineBuilder`.
//
//  ### Why it can afford to do this
//  Language detection is *not* a decode. `WhisperBridge.detectLanguage(samples:)` runs
//  `whisper_pcm_to_mel` + `whisper_lang_auto_detect` and stops — one encoder pass, no decoder
//  loop, and it returns the full probability distribution rather than a single guess. Even with
//  the large Whisperer V3 bridge, one pass costs ~721 ms on Apple Silicon — acceptable over the
//  duration of the refine scan, which runs long after the meeting ends.
//
//  Still, encoder passes add up over a 60-minute meeting, so the scan is a coarse grid, refined
//  by bisection only where two adjacent probes disagree. A single-language meeting — the common
//  case — does zero refinement.
//

import Foundation

@MainActor
enum MeetingLanguageScanner {

    /// Runs one detection and returns whisper-code → probability, or nil if it failed.
    /// Async so the caller can serialise it through `ModelWorkQueue` when the detector is the
    /// shared large bridge; the tiny CPU bridge needs no such thing (its own `ctxLock` is enough).
    typealias Detector = (_ samples: [Float]) async -> [String: Float]?

    // MARK: - Tuning

    struct Plan {
        /// Audio handed to each probe. Whisper pads or trims to 30 s internally, so anything
        /// shorter buys nothing and anything longer is discarded.
        var probeDuration: Double = 30
        /// Ceiling on coarse-grid probes, whatever the meeting length. 40 tiny encoder passes is
        /// a few seconds; the refine pass that follows is minutes.
        var maxProbes: Int = 40
        /// Never sample denser than this on the coarse grid — adjacent probes would overlap.
        var minSpacing: Double = 30
        /// …nor sparser than this, so a two-minute stretch in another language cannot hide
        /// entirely between two probes.
        var maxSpacing: Double = 120
        /// Bisection depth per disagreeing pair. 2 levels puts a boundary inside a quarter of the
        /// grid spacing, which is already finer than the 30 s windows the refiner decodes in.
        var refinementDepth: Int = 2
        /// Re-probe with the large model when the tiny model's answer is this shaky, or when it
        /// claims a switch. Tiny picks *where* to look; large decides *what*.
        var confirmBelowConfidence: Float = 0.85
        var maxConfirmProbes: Int = 8
        /// A read shorter than this is silence or a seek past the end, not speech.
        var minProbeSamples: Int = Int(1.0 * 16000)

        static let `default` = Plan()

        /// Accuracy-first preset for the post-meeting refine scan. Uses V3 only (`confirm: nil`)
        /// so grid density — not model quality — controls cost. 20 probes over a 17-minute meeting
        /// ≈ 14 s of GPU; bisection still refines wherever adjacent probes disagree.
        static let accurate = Plan(maxProbes: 20, minSpacing: 45, maxSpacing: 120,
                                   refinementDepth: 2, maxConfirmProbes: 0)
    }

    private static let sampleRate = 16000.0

    // MARK: - Scan

    /// Build the meeting's language timeline from its audio.
    ///
    /// - Parameters:
    ///   - coarse: primary detector — Whisperer V3 (the resident bridge).
    ///   - confirm: optional second-pass detector for low-confidence windows.
    ///     Pass `nil` when using `Plan.accurate`, which relies on V3 alone.
    ///   - transcript: current text, for the script veto and the text prior. May be corrupt.
    ///   - nemotronTally: live per-chunk detections, free evidence that would otherwise be thrown away.
    static func scan(
        audioURL: URL,
        duration: Double,
        coarse: Detector,
        confirm: Detector? = nil,
        transcript: String = "",
        nemotronTally: [String: Int] = [:],
        allowedLanguages: [TranscriptionLanguage] = [],
        plan: Plan = .default,
        config: MeetingLanguageTimelineConfig = .default
    ) async -> MeetingLanguageTimeline {
        guard duration > 0, FileManager.default.fileExists(atPath: audioURL.path) else { return .empty }

        let started = Date()
        var probes: [MeetingLanguageProbe] = []
        for start in gridStarts(duration: duration, plan: plan) {
            if Task.isCancelled { break }
            if let probe = await probe(at: start, audioURL: audioURL, duration: duration,
                                       detect: coarse, plan: plan) {
                probes.append(probe)
            }
        }
        guard !probes.isEmpty else {
            Logger.warning("Language scan: no readable audio in \(audioURL.lastPathComponent)", subsystem: .transcription)
            return .empty
        }

        let allowedSet = allowedLanguages.count > 1 ? Set(allowedLanguages).subtracting([.auto]) : []
        probes = await refineBoundaries(in: probes, audioURL: audioURL, duration: duration,
                                        detect: coarse, allowed: allowedSet, plan: plan)

        var timeline = MeetingLanguageTimelineBuilder.build(
            probes: probes, transcript: transcript, nemotronTally: nemotronTally,
            allowedLanguages: allowedLanguages, duration: duration, config: config
        )

        if let confirm, needsConfirmation(timeline, plan: plan) {
            probes = await confirmProbes(probes, audioURL: audioURL, duration: duration,
                                         detect: confirm, allowed: allowedSet, timeline: timeline, plan: plan)
            timeline = MeetingLanguageTimelineBuilder.build(
                probes: probes, transcript: transcript, nemotronTally: nemotronTally,
                allowedLanguages: allowedLanguages, duration: duration, config: config
            )
        }

        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        Logger.info("Language scan: \(timeline.logDescription) in \(elapsed)ms", subsystem: .transcription)
        return timeline
    }

    // MARK: - Grid

    /// Evenly spaced probe start times covering the whole meeting.
    ///
    /// Spacing is derived from the duration so the probe *count* stays bounded — a 10-minute and
    /// a 2-hour meeting both cost about the same scan — while the clamps keep short meetings from
    /// being over-sampled and long ones from being sampled so sparsely that a real switch is missed.
    static func gridStarts(duration: Double, plan: Plan) -> [Double] {
        guard duration > 0 else { return [] }
        guard duration > plan.probeDuration else { return [0] }

        let ideal = duration / Double(plan.maxProbes)
        let spacing = min(max(ideal, plan.minSpacing), plan.maxSpacing)

        var starts: [Double] = []
        var cursor = 0.0
        while cursor < duration - 1 && starts.count < plan.maxProbes {
            starts.append(cursor)
            cursor += spacing
        }
        // Always sample the tail: the last grid point can sit a full spacing short of the end,
        // and a language change in the closing minutes is exactly as damaging as one at the start.
        if let last = starts.last, duration - last > plan.probeDuration * 1.5 {
            starts.append(max(0, duration - plan.probeDuration))
        }
        return starts
    }

    // MARK: - Probing

    private static func probe(
        at start: Double, audioURL: URL, duration: Double, detect: Detector, plan: Plan
    ) async -> MeetingLanguageProbe? {
        let end = min(start + plan.probeDuration, duration)
        guard end > start else { return nil }

        let startSample = Int(start * sampleRate)
        let endSample = Int((end * sampleRate).rounded(.up))
        let samples = await Task.detached(priority: .utility) {
            SessionStorage.readFloat32Window(from: audioURL, startSample: startSample, endSample: endSample)
        }.value
        guard samples.count >= plan.minProbeSamples else { return nil }

        guard let probabilities = await detect(samples), !probabilities.isEmpty else { return nil }
        return MeetingLanguageProbe(start: start, end: end, probabilities: probabilities)
    }

    /// Bisect between adjacent probes that disagree, so a switch boundary is located in
    /// O(log n) extra probes instead of by scanning every window. Agreement — the normal case —
    /// costs nothing.
    private static func refineBoundaries(
        in probes: [MeetingLanguageProbe], audioURL: URL, duration: Double,
        detect: Detector, allowed: Set<TranscriptionLanguage>, plan: Plan
    ) async -> [MeetingLanguageProbe] {
        guard probes.count > 1, plan.refinementDepth > 0 else { return probes }

        var working = probes
        for _ in 0..<plan.refinementDepth {
            var inserted: [MeetingLanguageProbe] = []
            for (left, right) in zip(working, working.dropFirst()) {
                if Task.isCancelled { break }
                guard argmax(left, allowed: allowed) != argmax(right, allowed: allowed) else { continue }
                let midpoint = (left.end + right.start) / 2 - plan.probeDuration / 2
                let clamped = min(max(0, midpoint), max(0, duration - 1))
                // Nothing left to split once the gap is narrower than a probe.
                guard clamped > left.start + 1, clamped < right.start - 1 else { continue }
                if let probe = await probe(at: clamped, audioURL: audioURL, duration: duration,
                                           detect: detect, plan: plan) {
                    inserted.append(probe)
                }
            }
            guard !inserted.isEmpty else { break }
            working = (working + inserted).sorted { $0.start < $1.start }
        }
        return working
    }

    /// Re-run the ambiguous probes through the accurate model and substitute its distributions.
    /// Chosen probes are those bordering a span boundary first, then the lowest-margin ones.
    private static func confirmProbes(
        _ probes: [MeetingLanguageProbe], audioURL: URL, duration: Double,
        detect: Detector, allowed: Set<TranscriptionLanguage>,
        timeline: MeetingLanguageTimeline, plan: Plan
    ) async -> [MeetingLanguageProbe] {
        let boundaries = timeline.spans.dropLast().map(\.end)
        let ranked = probes.indices.sorted { lhs, rhs in
            let lhsKey = (distanceToBoundary(probes[lhs], boundaries), margin(probes[lhs], allowed: allowed))
            let rhsKey = (distanceToBoundary(probes[rhs], boundaries), margin(probes[rhs], allowed: allowed))
            return lhsKey < rhsKey
        }

        var working = probes
        for index in ranked.prefix(plan.maxConfirmProbes) {
            if Task.isCancelled { break }
            if let confirmed = await probe(at: working[index].start, audioURL: audioURL,
                                           duration: duration, detect: detect, plan: plan) {
                working[index] = confirmed
            }
        }
        Logger.debug("Language scan: confirmed \(min(ranked.count, plan.maxConfirmProbes)) probe(s) with the accurate model", subsystem: .transcription)
        return working
    }

    private static func needsConfirmation(_ timeline: MeetingLanguageTimeline, plan: Plan) -> Bool {
        timeline.isEmpty
            || timeline.isMultilingual
            || timeline.dominant == .auto
            || timeline.dominantConfidence < plan.confirmBelowConfidence
    }

    // MARK: - Probe inspection

    private static func argmax(_ probe: MeetingLanguageProbe, allowed: Set<TranscriptionLanguage>) -> TranscriptionLanguage? {
        MeetingLanguageTimelineBuilder.normalize(probe.probabilities, allowed: allowed)
            .max { ($0.value, $0.key.rawValue) < ($1.value, $1.key.rawValue) }?.key
    }

    /// Gap between the top two languages — small means this probe is where the accurate model
    /// will earn its cost.
    private static func margin(_ probe: MeetingLanguageProbe, allowed: Set<TranscriptionLanguage>) -> Float {
        let sorted = MeetingLanguageTimelineBuilder.normalize(probe.probabilities, allowed: allowed)
            .values.sorted(by: >)
        guard sorted.count > 1 else { return sorted.first ?? 1 }
        return sorted[0] - sorted[1]
    }

    private static func distanceToBoundary(_ probe: MeetingLanguageProbe, _ boundaries: [Double]) -> Double {
        boundaries.map { abs($0 - probe.midpoint) }.min() ?? .greatestFiniteMagnitude
    }
}
