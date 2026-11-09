//
//  MeetingLiveReplayTests.swift
//  WhispererTests
//
//  Replays a real meeting recording through the live pipeline the app runs in a meeting — the
//  eager whisper stream on V3, Apple dictation driving the live text, and the language probe on
//  the same V3 bridge — fed at real time, and prints what the live bubble showed every 2 s.
//
//  The 2026-11-09 Hebrew meeting (88 s of continuous Hebrew) showed one paragraph live: Apple
//  started in he-IL, the eager ratchet then pinned English, and Apple streamed en-US for 30 s.
//
//  Opt-in, real models, real time:
//    TEST_RUNNER_MEETING_REPLAY=/path/to/meeting.wav \
//    TEST_RUNNER_MEETING_REPLAY_LANG=he  xcodebuild test … -only-testing:WhispererTests/MeetingLiveReplayTests
//  With TEST_RUNNER_MEETING_REPLAY_CALL=/path/to/call.wav the far end goes through the app's own
//  `SystemAudioMixer` on the speakers route, as the meeting recorder does.
//

import XCTest
@testable import whisperer

@MainActor
final class MeetingLiveReplayTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var committed = ""
        var live = ""
        func set(committed value: String) { lock.lock(); committed = value; lock.unlock() }
        func set(live value: String) { lock.lock(); live = value; lock.unlock() }
        func read() -> (String, String) { lock.lock(); defer { lock.unlock() }; return (committed, live) }
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func scriptShare(_ text: String, _ language: TranscriptionLanguage) -> Double {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return 0 }
        let range: ClosedRange<UnicodeScalar>
        switch language {
        case .hebrew: range = "\u{0590}"..."\u{05FF}"
        case .russian: range = "\u{0400}"..."\u{04FF}"
        default: range = "A"..."z"
        }
        return Double(letters.filter { range.contains($0) }.count) / Double(letters.count)
    }

    func testReplayMeetingLiveText() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MEETING_REPLAY"] else { throw XCTSkip("set TEST_RUNNER_MEETING_REPLAY") }
        let expected = TranscriptionLanguage(rawValue: env["MEETING_REPLAY_LANG"] ?? "he") ?? .hebrew
        let start = TranscriptionLanguage(rawValue: env["MEETING_REPLAY_START"] ?? expected.rawValue) ?? expected
        var samples = try loadAudioSamples(from: URL(fileURLWithPath: path))
        if let callPath = env["MEETING_REPLAY_CALL"] {
            let call = try loadAudioSamples(from: URL(fileURLWithPath: callPath))
            let mixer = SystemAudioMixer()
            mixer.mode = CallAudioOutputRoute.speakers.farEndMode
            var mixed: [Float] = []
            var offset = 0
            while offset < samples.count {
                let end = min(offset + 1_600, samples.count)
                if offset < call.count { mixer.append(Array(call[offset..<min(end, call.count)])) }
                mixed += mixer.mix(mic: Array(samples[offset..<end]))
                offset = end
            }
            samples = mixed
        }

        let whisper = try loadWhisperBridge()
        _ = whisper.transcribe(samples: [Float](repeating: 0, count: 16_000), initialPrompt: nil, language: .auto)
        let profile = ModelProfile(model: .largeTurboQ5, backend: .whisperCpp, language: .auto, isSpecialized: false)
        let pool = ModelPool()
        try? pool.loadFallback(profile: profile, backend: whisper)
        let languages: [TranscriptionLanguage] = [.english, .russian, .hebrew]

        let key = SystemLivePreviewBridge.lastLanguageKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(start.rawValue, forKey: key)

        let apple = SystemLivePreviewBridge(preferredLanguages: languages)
        let probe = LanguageProbe { .whisper(whisper) }
        await apple.setLanguageProbe(probe)
        await apple.prepare()
        let box = Box()
        await apple.setStableTextCallback { box.set(committed: $0) }

        let transcriber = StreamingTranscriber(
            backend: whisper, vad: loadVAD(), language: .auto, initialPrompt: nil,
            fillerWordRemovalEnabled: false, modelPool: pool,
            languageRouter: LanguageRouter(allowed: languages, primary: nil),
            modelRouter: ModelRouter(languageModelMap: [:], fallbackProfile: profile),
            nemotronBridge: apple, nemotronPreviewOnly: true)
        transcriber.onPreviewTail = { box.set(live: $0) }
        // As the app runs a meeting whose cards Apple dictation writes.
        transcriber.liveEngineWritesMeeting = env["MEETING_REPLAY_WHISPER"] != "1"
        transcriber.start { _ in }
        Self.keepAlive += [whisper, pool, transcriber]

        let energyBefore = EnergyMonitor.readTask()
        let began = Date()
        let feeder = Task.detached(priority: .userInitiated) {
            let step = 1_365
            var offset = 0
            while offset < samples.count {
                let end = min(offset + step, samples.count)
                transcriber.addSamples(Array(samples[offset..<end]))
                offset = end
                let due = Double(offset) / 16_000 - Date().timeIntervalSince(began)
                if due > 0 { Thread.sleep(forTimeInterval: due) }
            }
        }

        struct Snapshot { let t: Double; let language: String; let committed: Int; let shown: Int; let share: Double; let tail: String }
        var snapshots: [Snapshot] = []
        let audioSeconds = Double(samples.count) / 16_000
        var next = 2.0
        while Date().timeIntervalSince(began) < audioSeconds + 0.5 {
            try await Task.sleep(for: .milliseconds(100))
            let t = Date().timeIntervalSince(began)
            guard t >= next else { continue }
            next += 2
            let (committed, live) = box.read()
            let lang = await apple.streamingLanguage()?.rawValue ?? "-"
            let shownText = live.isEmpty ? committed : live
            let tail = Self.words(shownText).suffix(6).joined(separator: " ")
            let snap = Snapshot(t: t, language: lang, committed: Self.words(committed).count,
                                shown: Self.words(shownText).count, share: Self.scriptShare(shownText, expected), tail: tail)
            snapshots.append(snap)
            print(String(format: "[MeetingReplay] %5.1fs  apple=%@  committed=%3d  shown=%3d  %@=%3.0f%%  …%@",
                         snap.t, snap.language, snap.committed, snap.shown, expected.rawValue, snap.share * 100, snap.tail))
        }
        await feeder.value
        let stopStarted = Date()
        _ = await transcriber.stopAsync()
        let stopSeconds = Date().timeIntervalSince(stopStarted)
        if let a = energyBefore, let b = EnergyMonitor.readTask() {
            let wall = Date().timeIntervalSince(began)
            print(String(format: "[MeetingReplay] ENERGY GPU %.1fs of %.0fs wall (%.0f%%), %.0f J (%.1f W avg), stop %.1fs",
                         Double(b.gpu - a.gpu) / 1e9, wall, Double(b.gpu - a.gpu) / 1e9 / wall * 100,
                         Double(b.energy - a.energy) / 1e9, Double(b.energy - a.energy) / 1e9 / wall, stopSeconds))
        }

        // The score that matters to the user: for how much of the meeting was the live text in
        // the right language and still growing.
        let rightLanguage = snapshots.filter { $0.language == expected.rawValue }.count
        let stalls = zip(snapshots, snapshots.dropFirst()).filter { $1.shown <= $0.shown }.count
        let (committed, _) = box.read()
        print(String(format: "[MeetingReplay] SUMMARY right-language %d/%d snapshots, stalled %d, committed %d words in %.0fs",
                     rightLanguage, snapshots.count, stalls, Self.words(committed).count, audioSeconds))

        XCTAssertGreaterThanOrEqual(Double(rightLanguage) / Double(max(snapshots.count, 1)), 0.9,
                                    "Apple dictation streamed the wrong language for too much of the meeting")
        XCTAssertGreaterThan(Self.scriptShare(committed, expected), 0.9, "committed text is not \(expected.rawValue)")
        // Continuous speech: about 2 words a second should reach the cards.
        XCTAssertGreaterThan(Double(Self.words(committed).count), audioSeconds * 1.0,
                             "too few words committed for continuous speech")
    }
}
