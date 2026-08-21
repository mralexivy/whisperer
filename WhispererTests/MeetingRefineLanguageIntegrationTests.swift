//
//  MeetingRefineLanguageIntegrationTests.swift
//  WhispererTests
//
//  The end-to-end claim, on real meeting audio: the refine pass **corrects** the transcript, it
//  does not translate it.
//
//  That distinction is the whole bug. Whisper handed a wrong forced language code does not fail —
//  it emits fluent text in the language it was told, so a Hebrew meeting decoded as English comes
//  back as plausible English prose. Nothing about the text looks broken; only its language is
//  wrong. Character-count plausibility (`MeetingTranscriptRefiner.isPlausible`) waves it straight
//  through, which is exactly how it shipped.
//
//  So the assertion is on the *language of the output*, checked two ways:
//    - script family, which settles he→en and ru→en outright, and
//    - `NLLanguageRecognizer`, which covers the same-script pairs (en/nl/de) script cannot.
//
//  ### Why this drives the decode directly rather than calling `MeetingTranscriptRefiner.run`
//  `run` persists: it writes `MeetingEntity.language`, rewrites `segmentsJSON` and posts
//  `.meetingSegmentsDidRefine`. Pointed at the loader's fixtures — which are the user's actual
//  meetings, not a copy — a test run would edit real recordings. This exercises the same three
//  steps in the same order (plan windows → timeline → decode each window in its span's language)
//  against the same bridge, and writes nothing.
//
//  Opt-in, like the timeline accuracy suite (the `TEST_RUNNER_` prefix is required — xcodebuild
//  does not forward the invoking shell's environment):
//    TEST_RUNNER_MEETING_LANG_TESTS=1 xcodebuild test-without-building … \
//      -only-testing:WhispererTests/MeetingRefineLanguageIntegrationTests
//

import NaturalLanguage
import XCTest
@testable import whisperer

final class MeetingRefineLanguageIntegrationTests: XCTestCase {

    private static var sharedCoarse: WhisperBridge?
    private static var sharedLarge: WhisperBridge?
    private static var allFixtures: [MeetingFixture]?

    /// Windows decoded per meeting. A full pass over an 80-minute meeting is minutes of large-model
    /// decode; the failure this catches is systematic, so a spread of windows finds it just as well.
    private static let windowsPerMeeting = 6
    /// Long meetings first, and few of them — this suite is about depth, not coverage.
    private static let meetingsToCheck = 3

    override class func setUp() {
        super.setUp()
        if allFixtures == nil {
            allFixtures = HistoryTestLoader.loadMeetingFixtures(maxCount: 60,
                                                               order: HistoryTestLoader.longestMeetingsFirst)
        }
    }

    override class func tearDown() {
        sharedLarge?.prepareForShutdown()
        sharedCoarse?.prepareForShutdown()
        super.tearDown()
    }

    // MARK: - Setup

    private var goldURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("TestData/meeting-language-gold.json")
    }

    private func labelledFixtures() throws -> [(MeetingFixture, String, URL)] {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MEETING_LANG_TESTS"] == "1",
                          "Set MEETING_LANG_TESTS=1 to run the refine language suite (decodes real audio)")

        guard let data = try? Data(contentsOf: goldURL) else {
            throw XCTSkip("No meeting-language-gold.json — run testDumpGoldSkeleton and label it")
        }
        let gold = try JSONDecoder().decode(MeetingLanguageGold.self, from: data)

        let pairs = (Self.allFixtures ?? []).compactMap { fixture -> (MeetingFixture, String, URL)? in
            guard let expected = gold[fixture.id]?.expected,
                  let audioURL = fixture.audioURL,
                  fixture.durationSec > 0, !fixture.segments.isEmpty else { return nil }
            return (fixture, expected, audioURL)
        }
        if pairs.isEmpty { throw XCTSkip("No labelled meetings with audio to refine") }
        return pairs
    }

    private func bridges() throws -> (coarse: WhisperBridge, large: WhisperBridge) {
        let tinyPath = ModelDownloader.shared.modelPath(for: .tiny)
        guard FileManager.default.fileExists(atPath: tinyPath.path) else {
            throw XCTSkip("ggml-tiny.bin not downloaded — the coarse detector is unavailable")
        }
        let coarse = try Self.sharedCoarse ?? WhisperBridge(modelPath: tinyPath, useGPU: false)
        Self.sharedCoarse = coarse
        let large = try Self.sharedLarge ?? loadWhisperBridge()
        Self.sharedLarge = large
        return (coarse, large)
    }

    // MARK: - The test

    @MainActor
    func testRefinedWindowsAreCorrectedNotTranslated() async throws {
        let fixtures = try labelledFixtures().prefix(Self.meetingsToCheck)
        let (coarse, large) = try bridges()

        var checked = 0
        var wrongLanguage: [String] = []

        for (fixture, expected, audioURL) in fixtures {
            let timeline = await MeetingLanguageScanner.scan(
                audioURL: audioURL,
                duration: fixture.durationSec,
                coarse: { samples in coarse.detectLanguage(samples: samples) },
                confirm: { samples in large.detectLanguage(samples: samples) },
                transcript: fixture.segments.map(\.text).joined(separator: " ")
            )

            // The mechanism has to have made the right call before the decode can be judged: a
            // window decoded in the wrong language is *expected* to come out translated. Failing
            // here rather than below keeps the two failures distinguishable.
            XCTAssertEqual(timeline.dominant.rawValue, expected,
                           "\(fixture.id.prefix(8)): timeline picked the wrong language, \(timeline.logDescription)")

            let windows = MeetingRefineWindow.plan(fixture.segments)
            for window in Self.spread(windows, count: Self.windowsPerMeeting) {
                let language = timeline.language(at: (window.start + window.end) / 2)
                guard language != .auto else { continue }

                let samples = SessionStorage.readFloat32Window(
                    from: audioURL,
                    startSample: Int(window.start * 16000),
                    endSample: Int((window.end * 16000).rounded(.up))
                )
                guard samples.count >= 16000 else { continue }

                let decoded = large.transcribeTimestamped(samples: samples, initialPrompt: nil,
                                                          language: language)
                    .map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard decoded.count >= 20 else { continue }
                checked += 1

                if let verdict = Self.languageMismatch(in: decoded, expected: expected) {
                    wrongLanguage.append("\(fixture.id.prefix(8)) @\(Int(window.start))s: \(verdict) — “\(decoded.prefix(80))”")
                }
            }
        }

        try XCTSkipIf(checked == 0, "No window produced enough text to judge")
        print("Checked \(checked) refined windows across \(fixtures.count) meeting(s)")
        XCTAssertTrue(wrongLanguage.isEmpty,
                      "Refined text is not in the meeting's language:\n" + wrongLanguage.joined(separator: "\n"))
    }

    // MARK: - Judging

    /// nil when `text` is in `expected`; otherwise a short reason. Script first, because it is
    /// near-certain where it applies; `NLLanguageRecognizer` only where script cannot decide.
    private static func languageMismatch(in text: String, expected: String) -> String? {
        guard let language = TranscriptionLanguage(rawValue: expected) else { return nil }

        let shares = ScriptAnalyzer.scriptShares(in: text)
        guard let dominantScript = shares.max(by: { $0.value < $1.value })?.key else { return nil }

        let expectedScripts = Set(scriptFamilies(writing: language))
        if !expectedScripts.isEmpty && !expectedScripts.contains(dominantScript) {
            return "written in \(dominantScript.rawValue), expected \(expectedScripts.map(\.rawValue).sorted().joined(separator: "/"))"
        }

        // Same-script confusions (en/nl/de) survive the check above untouched, and they are the
        // ones the audio detector is weakest on. Only consulted when the recognizer is confident:
        // it is unreliable on short, punctuation-free ASR output.
        guard dominantScript == .latin else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        guard let (top, probability) = hypotheses.max(by: { $0.value < $1.value }), probability >= 0.9 else {
            return nil
        }
        return top.rawValue.hasPrefix(expected) ? nil
            : "reads as \(top.rawValue) (p=\(String(format: "%.2f", probability))), expected \(expected)"
    }

    /// Which scripts `language` is written in, from the analyzer's own table — so the test and the
    /// veto it mirrors can never drift apart.
    private static func scriptFamilies(writing language: TranscriptionLanguage) -> [ScriptFamily] {
        let families: [ScriptFamily] = [.latin, .cyrillic, .hebrew, .arabic, .devanagari, .thai,
                                        .georgian, .armenian, .greek, .hiragana, .katakana,
                                        .hangul, .cjk]
        return families.filter { ScriptAnalyzer.languages(for: $0).contains(language) }
    }

    /// `count` windows spread evenly across the meeting rather than the first `count` — a
    /// translation that starts halfway through is precisely the case the old first-window rule
    /// produced, and a prefix sample would miss it.
    private static func spread(_ windows: [MeetingRefineWindow], count: Int) -> [MeetingRefineWindow] {
        guard windows.count > count, count > 0 else { return windows }
        let stride = Double(windows.count) / Double(count)
        return (0..<count).map { windows[min(windows.count - 1, Int(Double($0) * stride))] }
    }
}
