//
//  EngineMatrixBenchmarkTests.swift
//  WhispererTests
//
//  One benchmark, every shipped engine, the same clips: runs the app's own bridges (not a CLI
//  with the same weights) over the FLEURS he/ru/en manifests in `Tools/omni-eval/manifests`,
//  language `.auto` (real dictation never gets told the language), and writes score.py-format
//  hypotheses to `Tools/omni-eval/hyp/app-<engine>.jsonl`. Resumable: finished clip ids are skipped.
//  Score with `python3 Tools/omni-eval/score.py app-whisper-q5 app-ivrit ...` (see `matrix.py`).
//
//  SLOW AND OPT-IN. Scope every run to one test:
//    xcodebuild test -project Whisperer.xcodeproj -scheme whisperer -configuration Debug \
//      -destination "platform=macOS" -only-testing:WhispererTests/EngineMatrixBenchmarkTests/testWhisperQ5
//

#if canImport(FluidAudio)
import XCTest
import AVFoundation
@testable import whisperer

final class EngineMatrixBenchmarkTests: XCTestCase {

    private static let evalDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tools/omni-eval")

    private struct Clip { let id: String; let lang: String; let audio: String; let seconds: Double }

    private func manifest(_ langs: [String]) throws -> [Clip] {
        var clips: [Clip] = []
        for lang in langs {
            let url = Self.evalDir.appendingPathComponent("manifests/\(lang).jsonl")
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") {
                guard let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let id = o["id"] as? String, let audio = o["audio"] as? String else { continue }
                clips.append(Clip(id: id, lang: lang, audio: audio, seconds: (o["seconds"] as? Double) ?? 0))
            }
        }
        guard !clips.isEmpty else { throw XCTSkip("no FLEURS manifest — run Tools/omni-eval/build_manifest.py") }
        return clips
    }

    private func samples(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let n = AVAudioFrameCount(file.length)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n),
              (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData else { return nil }
        let mono = Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
        let rate = file.processingFormat.sampleRate
        guard rate != 16_000 else { return mono }
        let outLen = Int(Double(mono.count) * 16_000 / rate)
        return (0..<outLen).map { i in
            let p = Double(i) * rate / 16_000
            let j = Int(p), f = Float(p - Double(j))
            return mono[j] * (1 - f) + mono[min(j + 1, mono.count - 1)] * f
        }
    }

    /// Runs `decode` over every clip not yet in `hyp/<key>.jsonl` and appends one record per clip.
    private func run(key: String, langs: [String], decode: ([Float]) async -> (text: String, detected: String?)) async throws {
        let out = Self.evalDir.appendingPathComponent("hyp/\(key).jsonl")
        let done: Set<String> = {
            guard let t = try? String(contentsOf: out, encoding: .utf8) else { return [] }
            return Set(t.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["id"] as? String
            })
        }()
        if !FileManager.default.fileExists(atPath: out.path) {
            FileManager.default.createFile(atPath: out.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        try handle.seekToEnd()

        for clip in try manifest(langs) where !done.contains(clip.id) {
            guard let s = samples(clip.audio) else { continue }
            let t0 = CFAbsoluteTimeGetCurrent()
            let r = await decode(s)
            let wall = CFAbsoluteTimeGetCurrent() - t0
            let dur = clip.seconds > 0 ? clip.seconds : Double(s.count) / 16_000
            var rec: [String: Any] = ["id": clip.id, "lang": clip.lang, "engine": key, "ok": true,
                                      "text": r.text, "rtf": wall / dur, "wall": wall, "seconds": dur]
            if let d = r.detected { rec["detected"] = d }
            let data = try JSONSerialization.data(withJSONObject: rec, options: [])
            handle.write(data); handle.write(Data("\n".utf8))
        }
    }

    // MARK: - Hard sets (noisy dictation, meeting chunks) — built by Tools/omni-eval/build_hard.py

    private enum Engine: String, CaseIterable {
        case whisperQ5 = "app-whisper-q5", whisperQ8 = "app-whisper-q8", ivrit = "app-ivrit"
        case qwen3 = "app-qwen3", parakeet = "app-parakeet-v3"

        /// Languages worth decoding: Parakeet has no Hebrew, and ivrit only makes sense once the
        /// language is known to be Hebrew (it transliterates everything else), so it sees `he`
        /// and the mixed meeting that shows why a Hebrew-only model cannot be the default.
        func handles(_ lang: String) -> Bool {
            switch self {
            case .parakeet: return lang == "ru" || lang == "en"
            case .ivrit: return lang == "he" || lang == "mixed"
            default: return true
            }
        }
    }

    private func decoder(for engine: Engine) async throws -> ([Float]) async -> (text: String, detected: String?) {
        switch engine {
        case .whisperQ5, .ivrit:
            let model: WhisperModel = engine == .ivrit ? .ivritLargeTurbo : .largeTurboQ5
            let path = ModelDownloader.shared.modelPath(for: model)
            guard FileManager.default.fileExists(atPath: path.path) else { throw XCTSkip("\(model) not downloaded") }
            let b = try WhisperBridge(modelPath: path, useGPU: true)
            return { s in (b.transcribe(samples: s, initialPrompt: nil, language: .auto, singleSegment: false, maxTokens: 0), b.lastDetectedLanguage) }
        case .whisperQ8:
            let path = URL(fileURLWithPath: NSHomeDirectory() + "/ai/omni-bench-models/whisper/ggml-large-v3-turbo-q8_0.bin")
            guard FileManager.default.fileExists(atPath: path.path) else { throw XCTSkip("q8_0 model not downloaded") }
            let b = try WhisperBridge(modelPath: path, useGPU: true)
            return { s in (b.transcribe(samples: s, initialPrompt: nil, language: .auto, singleSegment: false, maxTokens: 0), b.lastDetectedLanguage) }
        case .qwen3:
            guard Qwen3ASRBridge.isModelCached() else { throw XCTSkip("Qwen3-ASR not downloaded") }
            let b = try Qwen3ASRBridge.loadFromCache()
            return { s in
                b.resetAbort()
                return (b.transcribe(samples: s, initialPrompt: nil, language: .auto, singleSegment: false, maxTokens: 0), b.lastDetectedLanguage)
            }
        case .parakeet:
            guard FluidAudioBridge.isModelCached(variant: .v3) else { throw XCTSkip("Parakeet v3 not downloaded") }
            let b = try await FluidAudioBridge.loadFromCache(variant: .v3)
            return { s in (b.transcribe(samples: s, initialPrompt: nil, language: .auto, singleSegment: false, maxTokens: 0), nil) }
        }
    }

    /// `set` is "noisy" or "meeting"; records land in `hyp/<engine>-<set>.jsonl` with the manifest's
    /// extra fields (cond, meeting, order) carried through so the scorer can group them.
    private func runHard(_ engine: Engine, set: String) async throws {
        let file = set == "noisy" ? "noisy.jsonl" : "meeting_chunks.jsonl"
        let url = Self.evalDir.appendingPathComponent("manifests_hard/\(file)")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("run Tools/omni-eval/build_hard.py first")
        }
        let decode = try await decoder(for: engine)
        let out = Self.evalDir.appendingPathComponent("hyp/\(engine.rawValue)-\(set).jsonl")
        let done: Set<String> = {
            guard let t = try? String(contentsOf: out, encoding: .utf8) else { return [] }
            return Set(t.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["id"] as? String
            })
        }()
        if !FileManager.default.fileExists(atPath: out.path) { FileManager.default.createFile(atPath: out.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for line in text.split(separator: "\n") {
            guard let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = o["id"] as? String, let lang = o["lang"] as? String, let audio = o["audio"] as? String,
                  engine.handles(lang), !done.contains(id), let s = samples(audio) else { continue }
            let t0 = CFAbsoluteTimeGetCurrent()
            let r = await decode(s)
            let wall = CFAbsoluteTimeGetCurrent() - t0
            var rec: [String: Any] = ["id": id, "lang": lang, "engine": engine.rawValue, "ok": true, "text": r.text,
                                      "wall": wall, "seconds": Double(s.count) / 16_000, "rtf": wall / (Double(s.count) / 16_000)]
            for k in ["cond", "meeting", "order", "base"] { if let v = o[k] { rec[k] = v } }
            if let d = r.detected { rec["detected"] = d }
            handle.write(try JSONSerialization.data(withJSONObject: rec, options: []))
            handle.write(Data("\n".utf8))
        }
    }

    func testNoisyWhisperQ5() async throws { try await runHard(.whisperQ5, set: "noisy") }
    func testNoisyWhisperQ8() async throws { try await runHard(.whisperQ8, set: "noisy") }
    func testNoisyIvrit() async throws { try await runHard(.ivrit, set: "noisy") }
    func testNoisyQwen3() async throws { try await runHard(.qwen3, set: "noisy") }
    func testNoisyParakeet() async throws { try await runHard(.parakeet, set: "noisy") }
    func testMeetingWhisperQ5() async throws { try await runHard(.whisperQ5, set: "meeting") }
    func testMeetingWhisperQ8() async throws { try await runHard(.whisperQ8, set: "meeting") }
    func testMeetingIvrit() async throws { try await runHard(.ivrit, set: "meeting") }
    func testMeetingQwen3() async throws { try await runHard(.qwen3, set: "meeting") }
    func testMeetingParakeet() async throws { try await runHard(.parakeet, set: "meeting") }

    // MARK: - Engines (app bridges, language .auto)

    func testWhisperQ5() async throws {
        let path = ModelDownloader.shared.modelPath(for: .largeTurboQ5)
        guard FileManager.default.fileExists(atPath: path.path) else { throw XCTSkip("largeTurboQ5 not downloaded") }
        let b = try WhisperBridge(modelPath: path, useGPU: true)
        try await run(key: "app-whisper-q5", langs: ["he", "ru", "en"]) { s in
            let t = b.transcribe(samples: s, initialPrompt: nil, language: .auto, singleSegment: false, maxTokens: 0)
            return (t, b.lastDetectedLanguage)
        }
    }

    /// Not a shipped model: large-v3-turbo at Q8_0, run through the same `WhisperBridge` as the
    /// Q5 default to isolate what the extra quantization bits buy. The file is not in the app's
    /// model list, so it is read from `~/ai/omni-bench-models/whisper`.
    func testWhisperQ8() async throws {
        let path = URL(fileURLWithPath: NSHomeDirectory() + "/ai/omni-bench-models/whisper/ggml-large-v3-turbo-q8_0.bin")
        guard FileManager.default.fileExists(atPath: path.path) else { throw XCTSkip("q8_0 model not downloaded") }
        let b = try WhisperBridge(modelPath: path, useGPU: true)
        try await run(key: "app-whisper-q8", langs: ["he", "ru", "en"]) { s in
            let t = b.transcribe(samples: s, initialPrompt: nil, language: .auto, singleSegment: false, maxTokens: 0)
            return (t, b.lastDetectedLanguage)
        }
    }

    func testIvrit() async throws {
        let path = ModelDownloader.shared.modelPath(for: .ivritLargeTurbo)
        guard FileManager.default.fileExists(atPath: path.path) else { throw XCTSkip("ivrit model not downloaded") }
        let b = try WhisperBridge(modelPath: path, useGPU: true)
        try await run(key: "app-ivrit", langs: ["he", "ru", "en"]) { s in
            let t = b.transcribe(samples: s, initialPrompt: nil, language: .auto, singleSegment: false, maxTokens: 0)
            return (t, b.lastDetectedLanguage)
        }
    }

    func testQwen3() async throws {
        if !Qwen3ASRBridge.isModelCached() { try await Qwen3ASRBridge.download { _ in } }
        guard Qwen3ASRBridge.isModelCached() else { throw XCTSkip("Qwen3-ASR not downloaded") }
        let b = try Qwen3ASRBridge.loadFromCache()
        try await run(key: "app-qwen3", langs: ["he", "ru", "en"]) { s in
            b.resetAbort()
            let t = b.transcribe(samples: s, initialPrompt: nil, language: .auto, singleSegment: false, maxTokens: 0)
            return (t, b.lastDetectedLanguage)
        }
    }

    /// Parakeet v3 covers 25 European languages; Hebrew is not one, so it is run on ru/en only.
    func testParakeetV3() async throws {
        if !FluidAudioBridge.isModelCached(variant: .v3) { try await FluidAudioBridge.downloadModel(variant: .v3) }
        guard FluidAudioBridge.isModelCached(variant: .v3) else { throw XCTSkip("Parakeet v3 not downloaded") }
        let b = try await FluidAudioBridge.loadFromCache(variant: .v3)
        try await run(key: "app-parakeet-v3", langs: ["ru", "en"]) { s in
            (b.transcribe(samples: s, initialPrompt: nil, language: .auto, singleSegment: false, maxTokens: 0), nil)
        }
    }
}
#endif
