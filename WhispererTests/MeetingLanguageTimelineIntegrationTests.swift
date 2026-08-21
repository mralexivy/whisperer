//
//  MeetingLanguageTimelineIntegrationTests.swift
//  WhispererTests
//
//  Accuracy of the meeting language mechanism over the app's own recording history.
//
//  `MeetingLanguageTimelineTests` proves the maths — that a lone mis-detected probe cannot flip
//  a Viterbi path and that a sustained stretch can. It cannot say whether detection is *right*
//  on real audio, which is the only claim that matters: the shipped bug was a correct decision
//  procedure fed one bad window. So the accuracy number is measured against real meetings,
//  hand-labelled once in `TestData/meeting-language-gold.json`.
//
//  Bucketed by duration and reported separately, because the failure modes differ: short
//  meetings starve the detector, long ones are where one early mistake costs the most and where
//  the probe budget has to hold.
//
//  Opt-in. These decode real audio with real models and never run in a default pass:
//    TEST_RUNNER_MEETING_LANG_TESTS=1 xcodebuild test-without-building … \
//      -only-testing:WhispererTests/MeetingLanguageTimelineIntegrationTests
//  The `TEST_RUNNER_` prefix is required and is stripped before the test process sees it —
//  xcodebuild does not forward the invoking shell's environment, so a bare `MEETING_LANG_TESTS=1`
//  silently skips every test in this file.
//
//  Regenerate the labelling skeleton with:
//    TEST_RUNNER_MEETING_LANG_DUMP=1 … -only-testing:…/testDumpGoldSkeleton
//
//  Every test skips cleanly when the database, the audio or the models are absent.
//

import XCTest
@testable import whisperer

// MARK: - Gold file

/// Hand-labelled ground truth, keyed by the `hex(ZID)` the loader reports.
/// `expected == nil` means "not labelled yet" — those meetings are counted and skipped rather
/// than scored, so a partially-labelled file still produces an honest number.
struct MeetingLanguageGold: Codable {
    struct Span: Codable {
        let start: Double
        let end: Double
        let language: String
    }

    struct Entry: Codable {
        let id: String
        var title: String?
        var durationSec: Double?
        /// Whisper code of the language the meeting is *mostly* in, or nil when unlabelled.
        var expected: String?
        /// Only for genuinely code-switched meetings. Absent means "single language throughout",
        /// which is what the false-switch count is measured against.
        var spans: [Span]?
        /// How far a span boundary may sit from the truth. Defaults to `defaultToleranceSec`.
        var toleranceSec: Double?
        /// Transcript excerpt, written by the dump so the file can be labelled at a glance.
        var excerpt: String?
        var note: String?
    }

    var meetings: [Entry]

    static let defaultToleranceSec: Double = 45

    subscript(id: String) -> Entry? { meetings.first { $0.id == id } }
}

// MARK: - Tests

final class MeetingLanguageTimelineIntegrationTests: XCTestCase {

    // Bridges are shared and deliberately never torn down mid-suite: freeing a Metal context
    // between tests is the documented crash-on-exit path in this project's other integration
    // suites, and reloading the large model per test would dominate the runtime.
    private static var sharedCoarse: WhisperBridge?
    private static var sharedConfirm: WhisperBridge?
    private static var allFixtures: [MeetingFixture]?

    override class func setUp() {
        super.setUp()
        if allFixtures == nil {
            // Longest first: the language mechanism's hard cases are long meetings, and
            // newest-first at a small limit never reaches one.
            allFixtures = HistoryTestLoader.loadMeetingFixtures(maxCount: 60,
                                                               order: HistoryTestLoader.longestMeetingsFirst)
        }
    }

    override class func tearDown() {
        sharedConfirm?.prepareForShutdown()
        sharedCoarse?.prepareForShutdown()
        super.tearDown()
    }

    // MARK: - Fixtures and models

    private var goldURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("TestData/meeting-language-gold.json")
    }

    private func fixturesWithAudio() throws -> [MeetingFixture] {
        let all = (Self.allFixtures ?? []).filter { $0.audioURL != nil && $0.durationSec > 0 }
        if all.isEmpty {
            throw XCTSkip("No meetings with audio in the history database — record a meeting first")
        }
        return all
    }

    private func gold() throws -> MeetingLanguageGold {
        guard let data = try? Data(contentsOf: goldURL) else {
            throw XCTSkip("No meeting-language-gold.json — run testDumpGoldSkeleton and label it")
        }
        return try JSONDecoder().decode(MeetingLanguageGold.self, from: data)
    }

    private func requireOptIn() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MEETING_LANG_TESTS"] == "1",
                          "Set MEETING_LANG_TESTS=1 to run the language accuracy suite (decodes real audio)")
    }

    /// The tiny CPU-only bridge, the same one `ModelPool.previewBridge` hands the scanner in
    /// production. CPU-only is not a test convenience — GPU here contends with the large model.
    private func coarseBridge() throws -> WhisperBridge {
        if let bridge = Self.sharedCoarse { return bridge }
        let path = ModelDownloader.shared.modelPath(for: .tiny)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("ggml-tiny.bin not downloaded — the coarse detector is unavailable")
        }
        let bridge = try WhisperBridge(modelPath: path, useGPU: false)
        Self.sharedCoarse = bridge
        return bridge
    }

    private func confirmBridge() throws -> WhisperBridge {
        if let bridge = Self.sharedConfirm { return bridge }
        let bridge = try loadWhisperBridge()
        Self.sharedConfirm = bridge
        return bridge
    }

    private func detectors() throws -> (coarse: MeetingLanguageScanner.Detector,
                                        confirm: MeetingLanguageScanner.Detector) {
        let tiny = try coarseBridge()
        let large = try confirmBridge()
        return ({ samples in tiny.detectLanguage(samples: samples) },
                { samples in large.detectLanguage(samples: samples) })
    }

    // MARK: - Dump: the labelling skeleton

    /// Writes the skeleton the gold file is hand-labelled from, preserving any labels already in
    /// it. This is the one step a machine cannot do: the excerpt tells a human what language the
    /// meeting is in; nothing in the database does, since `ZLANGUAGE` is the "auto" this whole
    /// change exists to replace.
    func testDumpGoldSkeleton() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MEETING_LANG_DUMP"] == "1",
                          "Set MEETING_LANG_DUMP=1 to regenerate the gold skeleton")

        let fixtures = try fixturesWithAudio()
        let existing = (try? gold())?.meetings.reduce(into: [String: MeetingLanguageGold.Entry]()) {
            $0[$1.id] = $1
        } ?? [:]

        let entries = fixtures.map { fixture -> MeetingLanguageGold.Entry in
            var entry = existing[fixture.id] ?? MeetingLanguageGold.Entry(id: fixture.id)
            entry.title = fixture.title
            entry.durationSec = (fixture.durationSec * 10).rounded() / 10
            entry.excerpt = Self.excerpt(of: fixture)
            return entry
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(MeetingLanguageGold(meetings: entries)).write(to: goldURL)

        let labelled = entries.filter { $0.expected != nil }.count
        print("Wrote \(entries.count) meetings to \(goldURL.path) — \(labelled) already labelled")
        for entry in entries where entry.expected == nil {
            print("  [\(entry.id.prefix(8))] \(Int(entry.durationSec ?? 0))s  \(entry.title ?? "")  \(entry.excerpt ?? "")")
        }
    }

    /// Text from the *start*, the *middle* and the *end*, not the first 200 characters. A meeting
    /// that switches language does it in the middle, and a leading-only excerpt would be labelled
    /// single-language — writing the very error the spans exist to catch straight into the gold.
    private static func excerpt(of fixture: MeetingFixture) -> String {
        let texts = fixture.segments.map(\.text).filter { !$0.isEmpty }
        guard !texts.isEmpty else { return "" }
        let picks = [0, texts.count / 2, texts.count - 1].reduce(into: [Int]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        return picks.map { String(texts[$0].prefix(90)) }.joined(separator: " … ")
    }

    // MARK: - Accuracy

    @MainActor
    func testDominantLanguageAccuracyByBucket() async throws {
        try requireOptIn()
        let fixtures = try fixturesWithAudio()
        let gold = try gold()
        let (coarse, confirm) = try detectors()

        var results: [Result] = []
        for fixture in fixtures {
            guard let entry = gold[fixture.id], let expected = entry.expected,
                  let audioURL = fixture.audioURL else { continue }
            results.append(await measure(fixture, audioURL: audioURL, expected: expected,
                                         entry: entry, coarse: coarse, confirm: confirm))
        }

        try XCTSkipIf(results.isEmpty,
                      "No labelled meetings — fill in `expected` in meeting-language-gold.json")

        report(results)

        // Per-bucket assertions. The buckets are reported separately but asserted together at the
        // same bar: a mechanism that is only accurate on long meetings does not fix the bug the
        // user reported, which showed up on both.
        for bucket in ["short", "medium", "long"] {
            let inBucket = results.filter { $0.bucket == bucket }
            guard !inBucket.isEmpty else { continue }
            let correct = inBucket.filter(\.dominantCorrect).count
            let accuracy = Double(correct) / Double(inBucket.count)
            XCTAssertGreaterThanOrEqual(accuracy, 0.9,
                "\(bucket): dominant language correct on only \(correct)/\(inBucket.count) meetings — "
                + inBucket.filter { !$0.dominantCorrect }
                    .map { "\($0.id.prefix(8)) expected \($0.expected) got \($0.actual)" }
                    .joined(separator: "; "))
        }

        // The borrowing bug, stated as a number: a meeting labelled single-language must come back
        // as exactly one span. Scattered English words inside Hebrew produced spurious switches,
        // and every spurious switch re-decodes a stretch of audio in the wrong language.
        let falseSwitches = results.filter { $0.expectedSingleLanguage && $0.spanCount > 1 }
        XCTAssertTrue(falseSwitches.isEmpty,
            "Spurious language switches on single-language meetings: "
            + falseSwitches.map { "\($0.id.prefix(8)) → \($0.spanCount) spans" }.joined(separator: ", "))

        // Abstention is the designed-for failure: below the margin the timeline says `.auto` and
        // the refiner falls back to per-window detection, which degrades rather than translating.
        // It is still a failure, so it is bounded.
        let abstained = results.filter { $0.actual == "auto" }
        XCTAssertLessThanOrEqual(Double(abstained.count) / Double(results.count), 0.2,
            "Abstained on \(abstained.count)/\(results.count) meetings — the detector is not deciding")
    }

    /// Boundary accuracy for the meetings that genuinely switch language. Skips entirely when the
    /// gold has no multilingual entries rather than pretending to a number it cannot compute.
    @MainActor
    func testSpanBoundariesOnMultilingualMeetings() async throws {
        try requireOptIn()
        let fixtures = try fixturesWithAudio()
        let gold = try gold()
        let (coarse, confirm) = try detectors()

        var scored = 0
        for fixture in fixtures {
            guard let entry = gold[fixture.id], let expectedSpans = entry.spans, expectedSpans.count > 1,
                  let audioURL = fixture.audioURL else { continue }
            scored += 1

            let timeline = await scan(fixture, audioURL: audioURL, coarse: coarse, confirm: confirm)
            let tolerance = entry.toleranceSec ?? MeetingLanguageGold.defaultToleranceSec

            XCTAssertEqual(timeline.spans.count, expectedSpans.count,
                           "\(fixture.id.prefix(8)): \(timeline.logDescription)")

            for (actual, expected) in zip(timeline.spans, expectedSpans) {
                XCTAssertEqual(actual.language.rawValue, expected.language,
                               "\(fixture.id.prefix(8)): span at \(Int(expected.start))s")
                XCTAssertLessThanOrEqual(abs(actual.end - expected.end), tolerance,
                    "\(fixture.id.prefix(8)): boundary at \(Int(actual.end))s, expected \(Int(expected.end))s "
                    + "(±\(Int(tolerance))s)")
            }
        }

        try XCTSkipIf(scored == 0, "No multilingual meetings labelled with spans in the gold file")
    }

    /// The fix has to beat what it replaced, or the number proves nothing. The baseline is the
    /// shipped rule verbatim: detect on the first window, force it on the whole meeting.
    @MainActor
    func testBeatsFirstWindowBaseline() async throws {
        try requireOptIn()
        let fixtures = try fixturesWithAudio()
        let gold = try gold()
        let (coarse, confirm) = try detectors()

        var timelineCorrect = 0
        var baselineCorrect = 0
        var scored = 0

        for fixture in fixtures {
            guard let entry = gold[fixture.id], let expected = entry.expected,
                  let audioURL = fixture.audioURL else { continue }
            scored += 1

            let timeline = await scan(fixture, audioURL: audioURL, coarse: coarse, confirm: confirm)
            if timeline.dominant.rawValue == expected { timelineCorrect += 1 }

            if await firstWindowLanguage(audioURL: audioURL, detect: confirm) == expected {
                baselineCorrect += 1
            }
        }

        try XCTSkipIf(scored == 0, "No labelled meetings to compare against the baseline")

        print("Baseline (window #1): \(baselineCorrect)/\(scored) — timeline: \(timelineCorrect)/\(scored)")
        XCTAssertGreaterThanOrEqual(timelineCorrect, baselineCorrect,
            "The timeline is no better than the first-window rule it replaced")
    }

    /// Efficiency, asserted rather than merely printed: the scan runs before every refine pass,
    /// so a regression here is felt on every meeting. A single-language hour-long meeting should
    /// stay in the low tens of tiny-model probes.
    @MainActor
    func testScanStaysWithinProbeBudget() async throws {
        try requireOptIn()
        let fixtures = try fixturesWithAudio()
        let (coarse, confirm) = try detectors()

        guard let longest = fixtures.max(by: { $0.durationSec < $1.durationSec }),
              let audioURL = longest.audioURL else {
            throw XCTSkip("No meeting audio available")
        }

        let started = Date()
        let timeline = await scan(longest, audioURL: audioURL, coarse: coarse, confirm: confirm)
        let elapsed = Date().timeIntervalSince(started)

        print(String(format: "Scan of %.0fs meeting: %d probes in %.1fs",
                     longest.durationSec, timeline.probeCount, elapsed))

        // maxProbes (40) + bisection at disagreements. A count far above the grid means the
        // refinement is firing everywhere, which is the signature of a detector that never settles.
        XCTAssertLessThanOrEqual(timeline.probeCount, 80,
                                 "Probe count blew past the coarse grid: \(timeline.logDescription)")
    }

    // MARK: - Harness

    private struct Result {
        let id: String
        let bucket: String
        let durationSec: Double
        let expected: String
        let actual: String
        let confidence: Float
        let spanCount: Int
        let probeCount: Int
        let elapsed: TimeInterval
        let expectedSingleLanguage: Bool

        var dominantCorrect: Bool { actual == expected }
    }

    @MainActor
    private func measure(_ fixture: MeetingFixture, audioURL: URL, expected: String,
                         entry: MeetingLanguageGold.Entry,
                         coarse: @escaping MeetingLanguageScanner.Detector,
                         confirm: @escaping MeetingLanguageScanner.Detector) async -> Result {
        let started = Date()
        let timeline = await scan(fixture, audioURL: audioURL, coarse: coarse, confirm: confirm)
        return Result(
            id: fixture.id,
            bucket: fixture.durationBucket,
            durationSec: fixture.durationSec,
            expected: expected,
            actual: timeline.dominant.rawValue,
            confidence: timeline.dominantConfidence,
            spanCount: timeline.spans.count,
            probeCount: timeline.probeCount,
            elapsed: Date().timeIntervalSince(started),
            expectedSingleLanguage: (entry.spans?.count ?? 1) <= 1
        )
    }

    /// Mirrors `MeetingTranscriptRefiner.buildTimeline`: same transcript, same detector roles.
    /// `allowedLanguages` is left empty on purpose — the shortlist is a crutch the mechanism
    /// should not need, and most users leave routing off.
    @MainActor
    private func scan(_ fixture: MeetingFixture, audioURL: URL,
                      coarse: @escaping MeetingLanguageScanner.Detector,
                      confirm: @escaping MeetingLanguageScanner.Detector) async -> MeetingLanguageTimeline {
        await MeetingLanguageScanner.scan(
            audioURL: audioURL,
            duration: fixture.durationSec,
            coarse: coarse,
            confirm: confirm,
            transcript: fixture.segments.map(\.text).joined(separator: " ")
        )
    }

    /// The rule this change deleted: one detection on the opening window, forced everywhere.
    private func firstWindowLanguage(audioURL: URL, detect: MeetingLanguageScanner.Detector) async -> String? {
        let samples = SessionStorage.readFloat32Window(from: audioURL, startSample: 0,
                                                       endSample: Int(30 * 16000))
        guard samples.count > 16000, let distribution = await detect(samples) else { return nil }
        return distribution.max { $0.value < $1.value }?.key
    }

    private func report(_ results: [Result]) {
        print("\n=== Meeting language accuracy ===")
        print("bucket  id        dur    expected  got       conf  spans  probes  sec")
        for result in results.sorted(by: { $0.durationSec > $1.durationSec }) {
            print(String(format: "%-7@ %-9@ %5.0f  %-9@ %-9@ %.2f  %5d  %6d  %.1f",
                         result.bucket as NSString, String(result.id.prefix(8)) as NSString,
                         result.durationSec, result.expected as NSString, result.actual as NSString,
                         result.confidence, result.spanCount, result.probeCount, result.elapsed)
                  + (result.dominantCorrect ? "" : "   ← WRONG"))
        }
        for bucket in ["short", "medium", "long"] {
            let inBucket = results.filter { $0.bucket == bucket }
            guard !inBucket.isEmpty else { continue }
            let correct = inBucket.filter(\.dominantCorrect).count
            print(String(format: "%-7@ %d/%d correct", bucket as NSString, correct, inBucket.count))
        }
    }
}
