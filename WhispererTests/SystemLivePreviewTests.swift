//
//  SystemLivePreviewTests.swift
//  WhispererTests
//
//  The built-in engine (Apple dictation via `SystemLivePreviewBridge`) streaming real audio at
//  wall-clock rate, the way the microphone delivers it. Needs the en-US and he-IL dictation
//  assets installed on the Mac (System Settings › Keyboard › Dictation); skips otherwise.
//
//  Real time on purpose (transcription rule 10): fed faster than real time, a streaming engine
//  is measured against audio that does not exist yet and the latency numbers mean nothing.
//  ~25 s of wall clock in total.
//

import XCTest
@testable import whisperer

final class SystemLivePreviewTests: XCTestCase {

    private static let testData = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("TestData")

    /// What a stream produced, with timings relative to the first fed sample.
    private struct StreamRun {
        var partials: [(time: TimeInterval, text: String)] = []
        var final = ""
        var audioSeconds: TimeInterval = 0
        var endSessionSeconds: TimeInterval = 0
        var firstPartial: TimeInterval? { partials.first?.time }
    }

    private final class PartialLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(TimeInterval, String)] = []
        let start = Date()
        func append(_ text: String) {
            lock.lock(); defer { lock.unlock() }
            entries.append((Date().timeIntervalSince(start), text))
        }
        var all: [(TimeInterval, String)] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }
    }

    private func requireInstalled(_ language: TranscriptionLanguage) async throws {
        let status = await SystemLivePreviewBridge.status(for: language)
        guard status == .ready else {
            throw XCTSkip("Apple dictation not installed for \(language.rawValue) (\(status))")
        }
    }

    /// Feed `segments` in 100 ms buffers at real time; `between` runs after each segment but the
    /// last (used to pin a language mid-session).
    private func stream(
        _ bridge: SystemLivePreviewBridge,
        language: TranscriptionLanguage,
        segments: [[Float]],
        between: ((Int) async -> Void)? = nil
    ) async -> StreamRun {
        let log = PartialLog()
        await bridge.beginSession(language: language)
        await bridge.setPreviewCallback { log.append($0) }

        let step = 1_600  // 100 ms at 16 kHz
        var fed = 0
        for (index, samples) in segments.enumerated() {
            var offset = 0
            while offset < samples.count {
                let end = min(offset + step, samples.count)
                await bridge.feed(samples: Array(samples[offset..<end]))
                fed += end - offset
                offset = end
                // Sleep to the wall-clock position of the audio fed so far, not a fixed 100 ms,
                // so actor hops cannot make the feed drift slower than real time.
                let due = Double(fed) / 16_000 - Date().timeIntervalSince(log.start)
                if due > 0 { try? await Task.sleep(for: .seconds(due)) }
            }
            if index < segments.count - 1 { await between?(index) }
        }

        var run = StreamRun()
        run.audioSeconds = Date().timeIntervalSince(log.start)
        let stopStart = Date()
        run.final = await bridge.endSession()
        run.endSessionSeconds = Date().timeIntervalSince(stopStart)
        run.partials = log.all.map { (time: $0.0, text: $0.1) }
        return run
    }

    private func report(_ name: String, _ run: StreamRun) {
        print(String(format: "[SystemLivePreview] %@: audio %.2fs, first partial %.2fs, %d partials, endSession %.3fs",
                     name, run.audioSeconds, run.firstPartial ?? -1, run.partials.count, run.endSessionSeconds))
        print("[SystemLivePreview] \(name) final: \(run.final)")
    }

    // MARK: - Streaming

    func testEnglishStreamsWordByWord() async throws {
        try await requireInstalled(.english)
        let samples = try loadAudioSamples(from: Self.testData.appendingPathComponent("test-sentences-en.wav"))
        let bridge = SystemLivePreviewBridge(preferredLanguages: [.english])

        let run = await stream(bridge, language: .english, segments: [samples])
        report("en", run)

        XCTAssertGreaterThan(run.partials.count, 10, "live text must arrive word by word, not in one blob")
        XCTAssertLessThan(try XCTUnwrap(run.firstPartial), 2.5, "first words must appear within ~2 s")
        XCTAssertTrue(run.final.lowercased().contains("microphone"), "final: \(run.final)")
        XCTAssertLessThan(run.endSessionSeconds, 1.0, "stop must not wait on the engine")
    }

    func testHebrewStreamsWithoutDirectionMarks() async throws {
        try await requireInstalled(.hebrew)
        let samples = try loadAudioSamples(from: Self.testData.appendingPathComponent("hebrew_sample.wav"))
        let bridge = SystemLivePreviewBridge(preferredLanguages: [.hebrew])

        let run = await stream(bridge, language: .hebrew, segments: [samples])
        report("he", run)

        XCTAssertGreaterThan(run.partials.count, 5)
        XCTAssertTrue(run.final.contains("העברית"), "final: \(run.final)")
        for partial in run.partials {
            XCTAssertFalse(partial.text.contains("\u{200F}") || partial.text.contains("\u{200E}"),
                           "Apple's RTL marks must be stripped before the HUD sees them")
        }
    }

    /// Auto mode starts in the first installed preferred language and follows the arbiter's pin.
    /// The text decoded before the pin must survive the restart.
    func testPinLanguageRestartsAndKeepsText() async throws {
        try await requireInstalled(.english)
        try await requireInstalled(.hebrew)
        let english = try loadAudioSamples(from: Self.testData.appendingPathComponent("test-sentences-en.wav"))
        let hebrew = try loadAudioSamples(from: Self.testData.appendingPathComponent("hebrew_sample.wav"))
        let bridge = SystemLivePreviewBridge(preferredLanguages: [.english, .hebrew])
        // Auto mode starts in the last language, which the test host shares with the app.
        let key = SystemLivePreviewBridge.lastLanguageKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(TranscriptionLanguage.english.rawValue, forKey: key)

        let firstSentence = Array(english.prefix(16_000 * 6))
        let run = await stream(bridge, language: .auto, segments: [firstSentence, hebrew]) { _ in
            await bridge.pinLanguage("he")
        }
        report("auto en→he", run)

        XCTAssertTrue(run.final.lowercased().contains("record"), "English before the pin was lost: \(run.final)")
        XCTAssertTrue(run.final.contains("העברית"), "Hebrew after the pin missing: \(run.final)")
    }

    // MARK: - Language probe

    /// The production probe on Qwen3-ASR. Loaded once and kept for the process.
    private static var probe: LanguageProbe?
    private static var qwen3Bridge: Qwen3ASRBridge?

    private func loadProbe() async throws -> LanguageProbe {
        if let probe = Self.probe { return probe }
        guard Qwen3ASRBridge.isModelCached() else { throw XCTSkip("Qwen3-ASR not downloaded") }
        if Self.qwen3Bridge == nil { Self.qwen3Bridge = try Qwen3ASRBridge.loadFromCache() }
        let probe = LanguageProbe { SystemLivePreviewTests.qwen3Bridge.map { .qwen3($0) } }
        Self.probe = probe
        return probe
    }

    /// The 2026-11-04 failure: every session started in English, so Hebrew and Russian speech came
    /// out as English nonsense until a pin landed 9–10 s in. Starting in the wrong language on
    /// purpose, the probe must switch within ~2.5 s and the replay must leave no English behind.
    private func assertProbeRecovers(
        from wrongStart: TranscriptionLanguage,
        audio: URL,
        expect language: TranscriptionLanguage,
        script: ClosedRange<UnicodeScalar>,
        name: String
    ) async throws {
        try await requireInstalled(wrongStart)
        try await requireInstalled(language)
        let samples = try loadAudioSamples(from: audio)
        let probe = try await loadProbe()

        // The test host shares the app's defaults domain: restore what was there.
        let key = SystemLivePreviewBridge.lastLanguageKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(wrongStart.rawValue, forKey: key)

        let bridge = SystemLivePreviewBridge(preferredLanguages: [.english, .hebrew, .russian])
        await bridge.setLanguageProbe(probe)
        await bridge.prepare()  // the app does this at engine start, not inside a recording
        let run = await stream(bridge, language: .auto, segments: [samples])
        report(name, run)

        func inScript(_ text: String) -> Bool { text.unicodeScalars.contains { script.contains($0) } }
        let firstRight = run.partials.first { inScript($0.text) }?.time
        print(String(format: "[SystemLivePreview] %@: first %@ text at %.2fs", name, language.rawValue, firstRight ?? -1))
        XCTAssertNotNil(firstRight, "never switched to \(language.rawValue): \(run.final)")
        XCTAssertLessThan(firstRight ?? 99, 4.0, "switch must land within the first seconds of speech")
        XCTAssertTrue(inScript(run.final), "final: \(run.final)")
        // The replay drops the wrong-language text, so the transcript opens in the right script.
        // (Not "no Latin at all": a Russian clip about pH legitimately contains "PH".)
        let firstWord = SystemLivePreviewBridge.words(run.final).first ?? ""
        XCTAssertTrue(inScript(firstWord), "English from the wrong start survived the replay: \(run.final)")
    }

    func testProbeSwitchesEnglishStartToHebrew() async throws {
        try await assertProbeRecovers(
            from: .english, audio: Self.testData.appendingPathComponent("hebrew_sample.wav"),
            expect: .hebrew, script: "\u{0590}"..."\u{05FF}", name: "en-start → he")
    }

    func testProbeSwitchesEnglishStartToRussian() async throws {
        let clip = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/omni-eval/corpus/fleurs/ru_ru/test/14984289819244796218.wav")
        try await assertProbeRecovers(
            from: .english, audio: clip, expect: .russian,
            script: "\u{0400}"..."\u{04FF}", name: "en-start → ru")
    }

    // MARK: Real dictations that failed (2026-11-04)

    /// The user's own microphone dictations that showed the wrong language live, each started in
    /// the wrong language the way the failing session did. The ANE probe called both Russian
    /// ones Hebrew (p 0.99 / 0.97), and a Hebrew sticky start then carried into the next.
    private static func failed(_ name: String) -> URL {
        testData.appendingPathComponent("live-preview/\(name).wav")
    }
    private static let cyrillic: ClosedRange<UnicodeScalar> = "\u{0400}"..."\u{04FF}"
    private static let hebrewScript: ClosedRange<UnicodeScalar> = "\u{0590}"..."\u{05FF}"
    private static let latin: ClosedRange<UnicodeScalar> = "a"..."z"

    func testFailedRussianFromEnglishStart() async throws {
        try await assertProbeRecovers(from: .english, audio: Self.failed("ru_1922"), expect: .russian,
                                      script: Self.cyrillic, name: "real ru_1922 en-start")
    }

    func testFailedShortRussianFromHebrewStart() async throws {
        try await assertProbeRecovers(from: .hebrew, audio: Self.failed("ru_1923"), expect: .russian,
                                      script: Self.cyrillic, name: "real ru_1923 he-start")
    }

    func testRealHebrewFromRussianStart() async throws {
        try await assertProbeRecovers(from: .russian, audio: Self.failed("he_1922"), expect: .hebrew,
                                      script: Self.hebrewScript, name: "real he_1922 ru-start")
    }

    func testRealShortEnglishFromHebrewStart() async throws {
        try await assertProbeRecovers(from: .hebrew, audio: Self.failed("en_1922"), expect: .english,
                                      script: Self.latin, name: "real en_1922 he-start")
    }

    /// 2026-11-04, V3 fully calibrated: this English dictation scored ru 0.57 at 3 s, so Apple
    /// stayed in Russian and wrote "Let Me Tryin English First … how it can walk".
    func testRealEnglishFromRussianStart() async throws {
        try await assertProbeRecovers(from: .russian, audio: Self.failed("en_2121"), expect: .english,
                                      script: Self.latin, name: "real en_2121 ru-start")
    }

    func testRealHebrewFromEnglishStart() async throws {
        try await assertProbeRecovers(from: .english, audio: Self.failed("he_2121"), expect: .hebrew,
                                      script: Self.hebrewScript, name: "real he_2121 en-start")
    }

    /// Diagnostic: replay real dictations (`<n>_<start>_<lang>.wav` in `LIVE_PREVIEW_REPLAY`)
    /// exactly as the app streamed them and print what the HUD showed, to compare against the
    /// main engine's final text.
    func testReplayRecordings() async throws {
        guard let dir = ProcessInfo.processInfo.environment["LIVE_PREVIEW_REPLAY"] else {
            throw XCTSkip("set TEST_RUNNER_LIVE_PREVIEW_REPLAY")
        }
        let probe = try await loadProbe()
        let key = SystemLivePreviewBridge.lastLanguageKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        for name in try FileManager.default.contentsOfDirectory(atPath: dir).filter({ $0.hasSuffix(".wav") }).sorted() {
            let parts = name.dropLast(4).split(separator: "_")
            guard parts.count == 3 else { continue }
            UserDefaults.standard.set(String(parts[1]), forKey: key)
            let samples = try loadAudioSamples(from: URL(fileURLWithPath: dir).appendingPathComponent(name))
            let bridge = SystemLivePreviewBridge(preferredLanguages: [.english, .russian, .hebrew])
            await bridge.setLanguageProbe(probe)
            await bridge.prepare()
            let run = await stream(bridge, language: .auto, segments: [samples])
            print("[Replay] ===== \(name) =====")
            var last = ""
            for partial in run.partials where partial.text != last {
                print(String(format: "[Replay] %5.2fs %@", partial.time, partial.text))
                last = partial.text
            }
            print("[Replay] FINAL \(run.final)")
        }
    }

    /// Meetings feed the speaker coordinator only committed words: the stream must only grow,
    /// never rewrite a word, and end equal to the session's final text.
    func testStableTextOnlyGrows() async throws {
        try await requireInstalled(.english)
        let samples = try loadAudioSamples(from: Self.testData.appendingPathComponent("test-sentences-en.wav"))
        let bridge = SystemLivePreviewBridge(preferredLanguages: [.english])
        final class Log: @unchecked Sendable {
            let lock = NSLock(); var values: [String] = []
            func add(_ v: String) { lock.lock(); values.append(v); lock.unlock() }
        }
        let log = Log()
        await bridge.setStableTextCallback { log.add($0) }
        let run = await stream(bridge, language: .english, segments: [samples])

        let values = log.values
        XCTAssertGreaterThan(values.count, 3, "committed text must grow during the session, not only at the end")
        for (previous, next) in zip(values, values.dropFirst()) {
            let a = SystemLivePreviewBridge.words(previous), b = SystemLivePreviewBridge.words(next)
            XCTAssertGreaterThan(b.count, a.count)
            XCTAssertEqual(Array(b.prefix(a.count)), a, "a committed word changed")
        }
        // Same words; a committed word keeps the form it had when committed, so punctuation Apple
        // adds afterwards ("more" → "more.") is not in it.
        XCTAssertEqual(SystemLivePreviewBridge.words(values.last ?? "").count, SystemLivePreviewBridge.words(run.final).count)
        print("[SystemLivePreview] stable updates: \(values.count), mid-session sample: \(values[values.count / 2])")
    }

    // MARK: - Assets

    func testStatusResolvesBareLanguageCodes() async {
        // Raw values are bare ISO 639-1; Apple wants a region. `he` must find he-IL.
        let hebrew = await SystemLivePreviewBridge.locale(for: .hebrew)
        XCTAssertEqual(hebrew?.identifier(.bcp47), "he-IL")
        let russian = await SystemLivePreviewBridge.locale(for: .russian)
        XCTAssertEqual(russian?.identifier(.bcp47), "ru-RU")
        let auto = await SystemLivePreviewBridge.locale(for: .auto)
        XCTAssertNil(auto)
    }

    func testCleanStripsDirectionMarks() {
        XCTAssertEqual(SystemLivePreviewBridge.clean("\u{200F}שלום עולם "), "שלום עולם")
        XCTAssertEqual(SystemLivePreviewBridge.join("a", ""), "a")
        XCTAssertEqual(SystemLivePreviewBridge.join("a", "b"), "a b")
    }
}
