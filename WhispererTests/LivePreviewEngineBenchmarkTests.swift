//
//  LivePreviewEngineBenchmarkTests.swift
//  WhispererTests
//
//  Apple dictation (the live preview today) against WhisperKit base / small as a streaming preview,
//  on the same audio, scored by Tools/omni-eval's own scripts. Opt-in, real models, slow.
//
//    TEST_RUNNER_PREVIEW_BENCH=acc|rt|edge
//    TEST_RUNNER_PREVIEW_ENGINES=apple-pin,apple-auto,wk-base-pin,wk-base-auto,wk-small-pin,wk-small-auto
//    TEST_RUNNER_PREVIEW_SETS=he,ru,en,cs,noisy        (acc only; default he,ru,en)
//    TEST_RUNNER_PREVIEW_LOAD=v3                        (rt: keep whisper.cpp V3 decoding meanwhile)
//    TEST_RUNNER_PREVIEW_TAG=idle                       (rt: results/rt-<engine>-<tag>.jsonl)
//
//  WhisperKit streaming is its own `AudioStreamTranscriber` loop, re-implemented here on samples we
//  feed (the class opens its own microphone): every second of new audio, decode from the end of the
//  last confirmed segment; all but the last two segments are confirmed. Apple is the app's
//  `SystemLivePreviewBridge`, pinned (one locale) or auto (Apple language ID + turn probes).
//
//  Writes: hyp/<engine>.jsonl (score.py), results/rt-<engine>-<tag>.jsonl (stream_events_report.py),
//  results/load-<engine>-<tag>.jsonl (main-engine decode times), results/edge-<engine>.jsonl.
//

#if canImport(WhisperKit)
import XCTest
import AVFoundation
import CoreML
import WhisperKit
@testable import whisperer

@MainActor
final class LivePreviewEngineBenchmarkTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []
    private static let evalDir = URL(fileURLWithPath: "/Users/alexivy/ai/whisperer/Tools/omni-eval")
    private static let modelBase = URL(fileURLWithPath: "/Users/alexivy/ai/omni-bench-models/whisperkit")
    private static let rtClips = ["he-1689", "he-1805", "he-1749", "he-1995", "he-1678", "he-1859",
                                  "ru-1962", "ru-1882", "ru-1973", "ru-1816", "ru-1773", "ru-1892",
                                  "en-1761", "en-1828", "en-1671", "en-1704", "en-1685", "en-1811"]

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    // MARK: - Entry

    func testPreviewEngines() async throws {
        guard let mode = env["PREVIEW_BENCH"] else { throw XCTSkip("set TEST_RUNNER_PREVIEW_BENCH") }
        let engines = (env["PREVIEW_ENGINES"] ?? "apple-pin,wk-base-pin").split(separator: ",").map(String.init)
        // Auto sessions start in the last language used; start every one in English so the
        // comparison does not depend on what ran before (it is the user's default, put back after).
        let key = SystemLivePreviewBridge.lastLanguageKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        for engine in engines {
            switch mode {
            case "acc": try await accuracy(engine: engine)
            case "rt": try await realTime(engine: engine, tag: env["PREVIEW_TAG"] ?? "idle")
            case "edge": try await edgeCases(engine: engine)
            default: XCTFail("unknown mode \(mode)")
            }
        }
    }

    // MARK: - Data

    struct Clip { let id: String; let lang: String; let audio: String; let ref: String; let extra: [String: Any] }

    private func manifest(_ name: String) -> [Clip] {
        let dir = name == "noisy" ? "manifests_hard" : "manifests"
        let url = Self.evalDir.appendingPathComponent("\(dir)/\(name).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["id"] as? String, let lang = row["lang"] as? String,
                  let audio = row["audio"] as? String, let ref = row["ref"] as? String else { return nil }
            return Clip(id: id, lang: lang, audio: audio, ref: ref, extra: row)
        }
    }

    private func append(_ row: [String: Any], to relative: String) {
        let url = Self.evalDir.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: row), var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func reset(_ relative: String) {
        try? FileManager.default.removeItem(at: Self.evalDir.appendingPathComponent(relative))
    }

    // MARK: - Engines

    private struct EngineSpec {
        let name: String
        let family: String        // apple | wk
        let variant: String?      // openai_whisper-base | openai_whisper-small
        let pinned: Bool
    }

    private func spec(_ name: String) -> EngineSpec {
        let pinned = name.hasSuffix("-pin")
        if name.hasPrefix("apple") { return EngineSpec(name: name, family: "apple", variant: nil, pinned: pinned) }
        // whisper.cpp large-v3 turbo q5_0 on Metal — the app's own main model, streaming through the
        // app's own eager word stream (StreamingTranscriber), not a reimplementation.
        if name.hasPrefix("cpp") { return EngineSpec(name: name, family: "cpp", variant: nil, pinned: pinned) }
        // The app's own WhisperKit path: WhisperKitBridge (large-v3 turbo, the app's variant) through
        // StreamingTranscriber's eager stream — what Whisperer runs when WhisperKit is the engine.
        // "wkapp547": the same path on openai_whisper-large-v3-v20240930_547MB, the WhisperKit build
        // closest in size to whisper.cpp's q5_0 (550 vs 574 MB, ~5.4 vs ~5.7 bits per weight).
        if name.hasPrefix("wkapp547") { return EngineSpec(name: name, family: "wkapp", variant: "openai_whisper-large-v3-v20240930_547MB", pinned: pinned) }
        if name.hasPrefix("wkapp") { return EngineSpec(name: name, family: "wkapp", variant: nil, pinned: pinned) }
        let size = name.split(separator: "-")[1]
        // "v3turbo": the large-v3 turbo build the app ships as its WhisperKit main engine.
        let variant = size == "v3turbo" ? WhisperKitBridge.modelVariant : "openai_whisper-\(size)"
        return EngineSpec(name: name, family: "wk", variant: variant, pinned: pinned)
    }

    private static var loadedKits: [String: WhisperKit] = [:]

    /// One WhisperKit instance, one call at a time — what the app's `WhisperKitRuntime` actor does.
    /// The meeting preview and a dictation's final decode queue behind each other on it.
    actor SharedKit {
        let kit: WhisperKit
        init(_ kit: WhisperKit) { self.kit = kit }
        func transcribe(_ audio: [Float], _ options: DecodingOptions) async -> [TranscriptionResult] {
            (try? await kit.transcribe(audioArray: audio, decodeOptions: options)) ?? []
        }
    }
    private static var shared: [String: SharedKit] = [:]
    private func sharedKit(_ variant: String) async throws -> SharedKit {
        if let s = Self.shared[variant] { return s }
        let s = SharedKit(try await whisperKit(variant).0)
        Self.shared[variant] = s
        return s
    }
    private static var cppBridge: WhisperBridge?
    private static var wkBridges: [String: WhisperKitBridge] = [:]
    /// The variant the current engine runs; nil for the app's own (`WhisperKitBridge.modelVariant`).
    private var wkAppVariant: String?

    private func whisperKitApp() async throws -> WhisperKitBridge {
        let variant = wkAppVariant ?? WhisperKitBridge.modelVariant
        if let bridge = Self.wkBridges[variant] { return bridge }
        // Downloaded like every other benchmark model; a no-op once on disk.
        let folder = try await WhisperKit.download(variant: variant, downloadBase: Self.modelBase)
        let key = "whisperKitModelFolder"
        let saved = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(folder.path, forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let bridge = try await WhisperKitBridge.loadFromCache()
        _ = await bridge.transcribeDirectAsync(samples: [Float](repeating: 0.01, count: 32_000), initialPrompt: nil, language: .english)
        Self.wkBridges[variant] = bridge
        Self.keepAlive.append(bridge)
        print("[PreviewBench] app WhisperKit path on \(variant)")
        return bridge
    }

    private func whisperCpp() throws -> WhisperBridge {
        if let bridge = Self.cppBridge { return bridge }
        let bridge = try loadWhisperBridge()   // largeTurboQ5 first
        _ = bridge.transcribe(samples: [Float](repeating: 0.01, count: 16_000), language: .english)
        Self.cppBridge = bridge
        Self.keepAlive.append(bridge)
        return bridge
    }

    private func whisperKit(_ variant: String) async throws -> (WhisperKit, Double) {
        if let kit = Self.loadedKits[variant] { return (kit, 0) }
        let started = Date()
        let folder = try await WhisperKit.download(variant: variant, downloadBase: Self.modelBase)
        let downloaded = Date()
        // Mel on the CPU, encoder and decoder on the Neural Engine: nothing on the GPU, where the
        // main whisper.cpp engine runs.
        let compute = ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuAndNeuralEngine,
                                          textDecoderCompute: .cpuAndNeuralEngine)
        let kit = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, computeOptions: compute,
                                                        verbose: false, logLevel: .error, prewarm: true, load: true, download: false))
        // First real decode compiles the ANE plans; keep it out of every measurement.
        _ = try? await kit.transcribe(audioArray: [Float](repeating: 0.01, count: 32_000), decodeOptions: DecodingOptions(language: "en"))
        Self.loadedKits[variant] = kit
        let load = Date().timeIntervalSince(downloaded)
        print("[PreviewBench] \(variant) ready: download/check \(String(format: "%.1f", downloaded.timeIntervalSince(started)))s, load+warm \(String(format: "%.1f", load))s")
        return (kit, load)
    }

    private func wkOptions(lang: String, pinned: Bool, clip: Float? = nil) -> DecodingOptions {
        var options = DecodingOptions(language: pinned ? lang : nil, temperature: 0, temperatureFallbackCount: 3,
                                      usePrefillPrompt: pinned, detectLanguage: !pinned, skipSpecialTokens: true,
                                      withoutTimestamps: false, wordTimestamps: false)
        if let clip { options.clipTimestamps = [clip] }
        return options
    }

    private func appleBridge(lang: String, pinned: Bool) async -> SystemLivePreviewBridge {
        let languages: [TranscriptionLanguage] = pinned ? [TranscriptionLanguage(rawValue: lang) ?? .english]
                                                        : [.english, .russian, .hebrew]
        let bridge = SystemLivePreviewBridge(preferredLanguages: languages)
        if !pinned {
            UserDefaults.standard.set("en", forKey: SystemLivePreviewBridge.lastLanguageKey)
            await bridge.setLanguageProbe(LanguageProbe { .apple })
        }
        await bridge.prepare()
        Self.keepAlive.append(bridge)
        return bridge
    }

    /// Whisper's non-speech tags ("[BLANK_AUDIO]", "(music)") — the app strips them before display.
    nonisolated static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Accuracy (offline, whole clip)

    private func accuracy(engine name: String) async throws {
        let s = spec(name)
        wkAppVariant = s.family == "wkapp" ? s.variant : nil
        let sets = (env["PREVIEW_SETS"] ?? "he,ru,en").split(separator: ",").map(String.init)
        // TEST_RUNNER_PREVIEW_SUFFIX writes to hyp/<engine><suffix>.jsonl, so a rerun of one set
        // does not erase the engine's other results.
        let out = "hyp/\(name)\(env["PREVIEW_SUFFIX"] ?? "").jsonl"
        reset(out)
        if let variant = s.variant { _ = try await whisperKit(variant) }   // load outside the timing
        if s.family == "cpp" { _ = try whisperCpp() }
        if s.family == "wkapp" { _ = try await whisperKitApp() }
        for set in sets {
            var clips = manifest(set)
            // 90 of 270: every third sentence, in all three noise conditions (the manifest lists
            // each sentence's conditions together, so every third *row* was one condition only).
            if set == "noisy" { clips = Array(clips.enumerated().filter { ($0.offset / 3) % 3 == 0 }.map(\.element)) }
            if let limit = env["PREVIEW_LIMIT"].flatMap(Int.init) { clips = Array(clips.prefix(limit)) }
            for clip in clips {
                guard let samples = try? loadAudioSamples(from: URL(fileURLWithPath: clip.audio)) else { continue }
                let seconds = Double(samples.count) / 16_000
                let started = Date()
                var text = ""
                var detected: String?
                if s.family == "wkapp" {
                    let bridge = try await whisperKitApp()
                    let pinnedLang = s.pinned && clip.lang != "cs"
                    bridge.beginSession()
                    text = Self.clean(await bridge.transcribeDirectAsync(
                        samples: samples, initialPrompt: nil,
                        language: pinnedLang ? (TranscriptionLanguage(rawValue: clip.lang) ?? .english) : .auto))
                } else if s.family == "cpp" {
                    let bridge = try whisperCpp()
                    let pinnedLang = s.pinned && clip.lang != "cs"
                    let language = pinnedLang ? (TranscriptionLanguage(rawValue: clip.lang) ?? .english) : .auto
                    text = Self.clean(await Task.detached { bridge.transcribe(samples: samples, language: language) }.value)
                } else if s.family == "wk", let variant = s.variant {
                    let (kit, _) = try await whisperKit(variant)
                    let options = wkOptions(lang: clip.lang == "cs" ? "he" : clip.lang, pinned: s.pinned && clip.lang != "cs")
                    // As the app decodes since 2026-11-11: one second of trailing silence, so WhisperKit's
                    // 1 s end-of-clip guard does not swallow short speech.
                    let results = (try? await kit.transcribe(audioArray: samples + [Float](repeating: 0, count: 16_000),
                                                             decodeOptions: options)) ?? []
                    text = Self.clean(results.map(\.text).joined(separator: " "))
                    detected = results.first?.language
                } else {
                    let bridge = await appleBridge(lang: clip.lang == "cs" ? "he" : clip.lang, pinned: s.pinned && clip.lang != "cs")
                    await bridge.beginSession(language: s.pinned && clip.lang != "cs" ? (TranscriptionLanguage(rawValue: clip.lang) ?? .english) : .auto)
                    var offset = 0
                    while offset < samples.count {
                        let end = min(offset + 1_600, samples.count)
                        await bridge.feed(samples: Array(samples[offset..<end]))
                        offset = end
                    }
                    // Fed faster than real time, the clip ended before the language probe had
                    // answered, so every auto session stayed in its start language. Give the
                    // probe (and its replay) the time it has in a live session.
                    if !(s.pinned && clip.lang != "cs") { try? await Task.sleep(nanoseconds: 3_000_000_000) }
                    detected = await bridge.streamingLanguage()?.rawValue
                    text = await bridge.endSession()
                }
                let elapsed = Date().timeIntervalSince(started)
                var row: [String: Any] = ["id": clip.id, "lang": set == "noisy" ? clip.lang : clip.lang, "text": text, "ok": true,
                                          "rtf": elapsed / max(seconds, 0.1), "detected": detected ?? "", "set": set]
                if let cond = clip.extra["cond"] { row["cond"] = cond }
                append(row, to: out)
            }
            print("[PreviewBench] \(name) \(set): \(clips.count) clips")
        }
    }

    // MARK: - Real time (1x playback)

    private final class Feed: @unchecked Sendable {
        let lock = NSLock()
        var samples: [Float] = []
        var done = false
        func add(_ s: [Float]) { lock.lock(); samples += s; lock.unlock() }
        func snapshot() -> ([Float], Bool) { lock.lock(); defer { lock.unlock() }; return (samples, done) }
        func finish() { lock.lock(); done = true; lock.unlock() }
    }

    private final class Events: @unchecked Sendable {
        let lock = NSLock()
        var rows: [[String: Any]] = []
        func add(_ r: [String: Any]) { lock.lock(); rows.append(r); lock.unlock() }
        var all: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return rows }
    }

    /// Plays `samples` at 1x into `feed`, calling `sink` with each 85 ms buffer.
    nonisolated private static func play(_ samples: [Float], into feed: Feed, began: Date,
                                         sink: (@Sendable ([Float]) async -> Void)? = nil) async {
        let step = 1_365
        var offset = 0
        while offset < samples.count {
            let end = min(offset + step, samples.count)
            let chunk = Array(samples[offset..<end])
            feed.add(chunk)
            await sink?(chunk)
            offset = end
            let due = Double(offset) / 16_000 - Date().timeIntervalSince(began)
            if due > 0 { try? await Task.sleep(nanoseconds: UInt64(due * 1e9)) }
        }
        feed.finish()
    }

    /// One clip through one engine at 1x. Returns (events, final text, final wall).
    private func stream(_ s: EngineSpec, samples: [Float], lang: String) async throws -> ([[String: Any]], String, Double) {
        let feed = Feed()
        let events = Events()
        if s.family == "cpp" || s.family == "wkapp" {
            let bridge: TranscriptionBackend
            let backendType: BackendType
            if s.family == "wkapp" {
                let wk = try await whisperKitApp()
                wk.beginSession()   // as AppState does, before the transcriber exists
                bridge = wk
                backendType = .whisperKit
            } else {
                bridge = try whisperCpp()
                backendType = .whisperCpp
            }
            // Exactly as AppState builds it (LanguageRoutingConfig): one language → no routers, the
            // transcriber simply starts in that language; several → LanguageRouter plus a ModelRouter
            // whose fallback profile is whisper.cpp at `.auto` (`buildFallbackProfile`), for every
            // backend. A one-language router here dropped words and invented "Продолжение следует".
            _ = backendType
            let language = s.pinned ? (TranscriptionLanguage(rawValue: lang) ?? .english) : .auto
            let profile = ModelProfile(model: .largeTurboQ5, backend: .whisperCpp, language: .auto, isSpecialized: false)
            let pool = ModelPool()
            try? pool.loadFallback(profile: profile, backend: bridge)
            let transcriber = StreamingTranscriber(
                backend: bridge, vad: loadVAD(), language: language, initialPrompt: nil,
                fillerWordRemovalEnabled: false, modelPool: pool,
                languageRouter: s.pinned ? nil : LanguageRouter(allowed: [.english, .russian, .hebrew], primary: nil),
                modelRouter: s.pinned ? nil : ModelRouter(languageModelMap: [:], fallbackProfile: profile),
                // AppState.livePreviewBridge(for:): WhisperKit is its own preview bridge — without it
                // StreamingTranscriber never schedules a live pass (only the stop decode ran);
                // whisper.cpp needs none, its eager stream is the preview.
                previewBridge: s.family == "wkapp" ? bridge : nil)
            Self.keepAlive += [pool, transcriber]
            applyEagerSweep(to: transcriber)
            let fed = Feed()
            let began = Date()
            transcriber.start { text in
                let covered = Double(fed.snapshot().0.count) / 16_000
                events.add(["wall": Date().timeIntervalSince(began), "covered": covered,
                            "text": Self.clean(text), "compute": 0.0])
            }
            await Self.play(samples, into: feed, began: began) { chunk in
                fed.add(chunk)
                transcriber.addSamples(chunk)
            }
            let final = await transcriber.stopAsync()
            return (events.all, Self.clean(final), Date().timeIntervalSince(began))
        }
        if s.family == "wk", let variant = s.variant {
            let shared = try await sharedKit(variant)
            let began = Date()
            let player = Task.detached(priority: .userInitiated) { await Self.play(samples, into: feed, began: began) }
            var lastSize = 0
            var confirmedEnd: Float = 0
            var confirmed: [String] = []
            var unconfirmed = ""
            func pass(_ buffer: [Float], final: Bool) async {
                let t0 = Date()
                let options = wkOptions(lang: lang, pinned: s.pinned, clip: confirmedEnd)
                // The final pass gets the app's trailing second of silence (see WhisperKitBridge
                // .padForWindowClip); live passes keep WhisperKit's guard against the growing edge.
                let audio = final ? buffer + [Float](repeating: 0, count: 16_000) : buffer
                let results = await shared.transcribe(audio, options)
                let segments = results.flatMap(\.segments)
                if segments.count > 2 {
                    let confirm = segments.prefix(segments.count - 2)
                    if let last = confirm.last, last.end > confirmedEnd {
                        confirmedEnd = last.end
                        confirmed += confirm.map { $0.text.trimmingCharacters(in: .whitespaces) }
                    }
                    unconfirmed = segments.suffix(2).map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                } else {
                    unconfirmed = segments.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                }
                let text = Self.clean((confirmed + [unconfirmed]).filter { !$0.isEmpty }.joined(separator: " "))
                events.add(["wall": Date().timeIntervalSince(began), "covered": Double(buffer.count) / 16_000,
                            "text": text, "compute": Date().timeIntervalSince(t0),
                            "lang_detected": results.first?.language ?? ""])
            }
            while true {
                let (buffer, done) = feed.snapshot()
                if buffer.count - lastSize >= 16_000 || (done && buffer.count > lastSize) {
                    lastSize = buffer.count
                    await pass(buffer, final: done)
                    if done { break }
                } else if done {
                    break
                } else {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            await player.value
            let last = events.all.last
            return (events.all, last?["text"] as? String ?? "", Date().timeIntervalSince(began))
        } else {
            let bridge = await appleBridge(lang: lang, pinned: s.pinned)
            let began = Date()
            await bridge.beginSession(language: s.pinned ? (TranscriptionLanguage(rawValue: lang) ?? .english) : .auto)
            let fed = Feed()
            await bridge.setPreviewCallback { text in
                let covered = Double(fed.snapshot().0.count) / 16_000
                events.add(["wall": Date().timeIntervalSince(began), "covered": covered, "text": text, "compute": 0.0])
            }
            await Self.play(samples, into: feed, began: began) { chunk in
                fed.add(chunk)
                await bridge.feed(samples: chunk)
            }
            let final = await bridge.endSession()
            return (events.all, final, Date().timeIntervalSince(began))
        }
    }

    private func realTime(engine name: String, tag: String) async throws {
        let s = spec(name)
        wkAppVariant = s.family == "wkapp" ? s.variant : nil
        let all = manifest("he") + manifest("ru") + manifest("en")
        let clips = Self.rtClips.compactMap { id in all.first { $0.id == id } }
        reset("results/rt-\(name)-\(tag).jsonl")
        reset("results/load-\(name)-\(tag).jsonl")
        let load = env["PREVIEW_LOAD"] == "v3" ? try startMainEngineLoad(tag: "\(name)-\(tag)")
            : (env["PREVIEW_LOAD"] == "same" ? try await startSameEngineDictations(spec: s, tag: "\(name)-\(tag)") : nil)
        let energyBefore = EnergyMonitor.readTask()
        let speechBefore = Self.speechServiceCPUSeconds()
        let wallBefore = Date()
        for clip in clips {
            let samples = try loadAudioSamples(from: URL(fileURLWithPath: clip.audio))
            let (events, final, finalWall) = try await stream(s, samples: samples, lang: clip.lang)
            append(["engine": name, "lang": clip.lang, "id": clip.id, "ref": clip.ref, "seconds": Double(samples.count) / 16_000,
                    "clip_end_wall": Double(samples.count) / 16_000, "final_text": final, "final_wall": finalWall,
                    "events": events], to: "results/rt-\(name)-\(tag).jsonl")
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        load?.stop()
        await load?.task.value
        if let a = energyBefore, let b = EnergyMonitor.readTask() {
            let wall = Date().timeIntervalSince(wallBefore)
            append(["engine": name, "tag": tag, "wall": wall, "joules": Double(b.energy - a.energy) / 1e9,
                    "gpu_s": Double(b.gpu - a.gpu) / 1e9, "speechd_cpu_s": Self.speechServiceCPUSeconds() - speechBefore],
                   to: "results/energy-\(tag).jsonl")
        }
    }

    /// TEST_RUNNER_PREVIEW_EAGER="single=0.85,commit=3,window=8,boundary=1,anchor=2": one point
    /// of the live-speed sweep; unspecified keys keep `EagerStreamEngine.Config.default`.
    private func applyEagerSweep(to transcriber: StreamingTranscriber) {
        guard let spec = env["PREVIEW_EAGER"], !spec.isEmpty else { return }
        var values: [String: Double] = [:]
        for part in spec.split(separator: ",") {
            let kv = part.split(separator: "=")
            if kv.count == 2, let v = Double(kv[1]) { values[String(kv[0])] = v }
        }
        let d = EagerStreamEngine.Config.default
        var config = EagerStreamEngine.Config(
            boundaryWordCount: values["boundary"].map(Int.init) ?? d.boundaryWordCount,
            singlePassThreshold: values["single"].map(Float.init) ?? d.singlePassThreshold,
            softCommitSamples: values["commit"].map { Int($0 * 16_000) } ?? d.softCommitSamples,
            requiredAnchor: values["anchor"].map(Int.init) ?? d.requiredAnchor,
            maxRetraction: d.maxRetraction,
            skipsAnchorCheckAfterBoundaryMove: d.skipsAnchorCheckAfterBoundaryMove,
            suppressesRepetitionLoops: d.suppressesRepetitionLoops,
            boundaryTrailSamples: d.boundaryTrailSamples)
        if values["hold"] == 0 { config.holdsWholePass = false }
        if values["nolock"] == 1 { config.confirmsWithoutLanguageLock = true }
        if let guardSeconds = values["guard"] { config.timeGuardSeconds = guardSeconds }
        transcriber.eagerConfigOverride = config
        if values["prompt"] == 0 { transcriber.eagerUsesPreviousTextPrompt = false }
        if let window = values["window"] { transcriber.eagerMaxWindowSeconds = window }
        print("[PreviewBench] eager sweep point: \(spec)")
    }

    // MARK: - Main engine under load

    private final class MainLoad: @unchecked Sendable {
        let lock = NSLock()
        var stopped = false
        var task: Task<Void, Never>!
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    }

    /// whisper.cpp V3 on Metal decoding a 15 s English+Hebrew clip back to back — the final decode a
    /// dictation runs at release, or a meeting's processing — with every decode time logged.
    private func startMainEngineLoad(tag: String) throws -> MainLoad {
        let whisper = try loadWhisperBridge()
        Self.keepAlive.append(whisper)
        let clipA = manifest("en").first { $0.id == "en-1761" }!
        let clipB = manifest("he").first { $0.id == "he-1689" }!
        let samples = Array((try loadAudioSamples(from: URL(fileURLWithPath: clipA.audio))
                             + loadAudioSamples(from: URL(fileURLWithPath: clipB.audio))).prefix(16_000 * 15))
        _ = whisper.transcribe(samples: samples, initialPrompt: nil, language: .auto)
        let load = MainLoad()
        let file = Self.evalDir.appendingPathComponent("results/load-\(tag).jsonl")
        load.task = Task.detached(priority: .userInitiated) {
            while !load.isStopped {
                let t0 = Date()
                _ = whisper.transcribe(samples: samples, initialPrompt: nil, language: .auto)
                let row = "{\"decode_s\": \(Date().timeIntervalSince(t0)), \"audio_s\": 15}\n"
                if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(Data(row.utf8)); try? h.close() }
                else { try? row.write(to: file, atomically: true, encoding: .utf8) }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        return load
    }

    /// Dictation-sized final decodes (a 6 s utterance, as at key release) on the **same** WhisperKit
    /// instance the preview streams on, every 4 s — the single-engine case: one model serving both
    /// the meeting's live text and a dictation made during it.
    private func startSameEngineDictations(spec: EngineSpec, tag: String) async throws -> MainLoad {
        // The very instance the preview streams on: whisper.cpp's WhisperBridge (SafeLock
        // serializes), the app's WhisperKitBridge (its runtime actor serializes), or the raw kit.
        var shared: SharedKit?
        if spec.family == "wk", let variant = spec.variant { shared = try await sharedKit(variant) }
        let bridge = spec.family == "cpp" ? try whisperCpp() : nil
        let wkApp = spec.family == "wkapp" ? try await whisperKitApp() : nil
        let clip = manifest("en").first { $0.id == "en-1761" }!
        let utterance = Array(try loadAudioSamples(from: URL(fileURLWithPath: clip.audio)).prefix(16_000 * 6))
            + [Float](repeating: 0, count: 16_000)
        let options = wkOptions(lang: "en", pinned: true)
        let load = MainLoad()
        let file = Self.evalDir.appendingPathComponent("results/load-\(tag).jsonl")
        try? FileManager.default.removeItem(at: file)
        load.task = Task.detached(priority: .userInitiated) {
            while !load.isStopped {
                let t0 = Date()
                if let shared { _ = await shared.transcribe(utterance, options) }
                else if let wkApp { _ = await wkApp.transcribeDirectAsync(samples: utterance, initialPrompt: nil, language: .english) }
                else if let bridge { _ = await Task.detached { bridge.transcribe(samples: utterance, language: .english) }.value }
                let row = "{\"decode_s\": \(Date().timeIntervalSince(t0)), \"audio_s\": 6}\n"
                if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(Data(row.utf8)); try? h.close() }
                else { try? row.write(to: file, atomically: true, encoding: .utf8) }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        return load
    }

    /// The same dictation decode with nothing else on the instance — the baseline for the above.
    func testSameEngineDictationAlone() async throws {
        guard env["PREVIEW_BENCH"] == "same-alone", let engine = env["PREVIEW_VARIANT"] else {
            throw XCTSkip("set TEST_RUNNER_PREVIEW_BENCH=same-alone and TEST_RUNNER_PREVIEW_VARIANT=cpp|<WhisperKit variant>")
        }
        wkAppVariant = spec(engine).family == "wkapp" ? spec(engine).variant : nil
        let load = try await startSameEngineDictations(spec: spec(engine), tag: "same-alone-\(engine)")
        try await Task.sleep(nanoseconds: 90_000_000_000)
        load.stop()
        await load.task.value
    }

    /// Main-engine decode times with nothing else running, for the contention baseline.
    func testMainEngineAlone() async throws {
        guard env["PREVIEW_BENCH"] == "alone" else { throw XCTSkip("set TEST_RUNNER_PREVIEW_BENCH=alone") }
        reset("results/load-alone.jsonl")
        let load = try startMainEngineLoad(tag: "alone")
        try await Task.sleep(nanoseconds: 120_000_000_000)
        load.stop()
        await load.task.value
    }

    /// CPU seconds used so far by Apple's out-of-process speech recognizers (Apple's preview runs there,
    /// not in Whisperer, so the app's own energy counter misses it).
    nonisolated private static func speechServiceCPUSeconds() -> Double {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-o", "time=,comm="]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var total = 0.0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n")
        where line.localizedCaseInsensitiveContains("speech") || line.localizedCaseInsensitiveContains("SpeechRecognition") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard let time = parts.first else { continue }
            let fields = time.split(separator: ":").compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
            total += fields.reversed().enumerated().reduce(0) { $0 + $1.element * pow(60, Double($1.offset)) }
        }
        return total
    }

    // MARK: - Edge cases

    private func edgeCases(engine name: String) async throws {
        let s = spec(name)
        wkAppVariant = s.family == "wkapp" ? s.variant : nil
        reset("results/edge-\(name).jsonl")
        var cases: [(id: String, kind: String, lang: String, samples: [Float], ref: String)] = []
        let testData = URL(fileURLWithPath: "/Users/alexivy/ai/whisperer/WhispererTests/TestData")
        for i in 1...4 {
            if let silence = try? loadAudioSamples(from: testData.appendingPathComponent("silence-\(i).wav")) {
                cases.append(("silence-\(i)", "silence", "en", silence, ""))
            }
        }
        let all = manifest("he") + manifest("ru") + manifest("en")
        for id in ["he-1689", "ru-1962", "en-1761"] {
            guard let clip = all.first(where: { $0.id == id }),
                  let samples = try? loadAudioSamples(from: URL(fileURLWithPath: clip.audio)) else { continue }
            cases.append(("\(id)-quiet", "quiet -26 dB", clip.lang, samples.map { $0 * 0.05 }, clip.ref))
        }
        let shortDir = URL(fileURLWithPath: env["PREVIEW_SHORT_DIR"] ?? "/private/tmp/preview-short")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: shortDir.path) {
            for file in names.sorted() where file.hasSuffix(".wav") {
                let parts = file.dropLast(4).split(separator: "_", maxSplits: 2)
                guard parts.count == 3, let samples = try? loadAudioSamples(from: shortDir.appendingPathComponent(file)) else { continue }
                let ref = (try? String(contentsOf: shortDir.appendingPathComponent(file.replacingOccurrences(of: ".wav", with: ".txt")), encoding: .utf8)) ?? ""
                cases.append(("short-\(file)", "short", String(parts[1]), samples, ref))
            }
        }
        if let mixedPath = env["PREVIEW_MIXED"], let mixed = try? loadAudioSamples(from: URL(fileURLWithPath: mixedPath)) {
            cases.append(("switching-he-en-ru-he-en", "switching", "he", mixed, ""))
        }
        for c in cases {
            // Language-switching audio is only meaningful for engines that may change language.
            if c.kind == "switching" && s.pinned { continue }
            let (events, final, finalWall) = try await stream(s, samples: c.samples, lang: c.lang)
            append(["engine": name, "id": c.id, "kind": c.kind, "lang": c.lang, "ref": c.ref,
                    "seconds": Double(c.samples.count) / 16_000, "final_text": final, "final_wall": finalWall,
                    "events": events], to: "results/edge-\(name).jsonl")
            print("[PreviewBench] edge \(name) \(c.id): \(final.prefix(80))")
        }
    }
}
#endif
