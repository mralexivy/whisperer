//
//  LanguageProbeBenchmarkTests.swift
//  WhispererTests
//
//  Gate for the built-in engine's language probe (`LanguageProbe`: restricted, silence-calibrated
//  language ID on the user's main engine): accuracy of the session rule on the first seconds of
//  speech, on FLEURS clips and on real microphone recordings. Slow and opt-in.
//
//  2026-11-04: a Whisper base on the ANE scored 89/90 on FLEURS but called the user's own English
//  and Russian Hebrew at p ≥ 0.8 — the reason the probe runs on V3. `testRealRecordings` exists so
//  that check is repeated on real audio, not only on read speech.
//

import XCTest
@testable import whisperer

final class LanguageProbeBenchmarkTests: XCTestCase {

    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let allowed: [TranscriptionLanguage] = [.english, .hebrew, .russian]

    private static var probe: LanguageProbe?

    /// The production probe on Qwen3-ASR, the user's main engine. Kept for the process.
    private static var qwen3Bridge: Qwen3ASRBridge?

    private func loadProbe() async throws -> LanguageProbe {
        if let probe = Self.probe { return probe }
        guard Qwen3ASRBridge.isModelCached() else { throw XCTSkip("Qwen3-ASR not downloaded") }
        if Self.qwen3Bridge == nil { Self.qwen3Bridge = try Qwen3ASRBridge.loadFromCache() }
        let probe = LanguageProbe { LanguageProbeBenchmarkTests.qwen3Bridge.map { .qwen3($0) } }
        Self.probe = probe
        return probe
    }

    private struct Clip { let language: TranscriptionLanguage; let audio: URL }

    private func clips(perLanguage: Int) throws -> [Clip] {
        var result: [Clip] = []
        for language in Self.allowed {
            let manifest = Self.repo.appendingPathComponent("Tools/omni-eval/manifests/\(language.rawValue).jsonl")
            guard let text = try? String(contentsOf: manifest, encoding: .utf8) else {
                throw XCTSkip("FLEURS manifest missing: \(manifest.path)")
            }
            for line in text.split(separator: "\n").prefix(perLanguage) {
                guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let path = object["audio"] as? String else { continue }
                result.append(Clip(language: language, audio: URL(fileURLWithPath: path)))
            }
        }
        return result
    }

    /// Real recordings: 16 kHz WAVs named `<lang>_*.wav` in `LANG_PROBE_RECORDINGS`, and
    /// `<n>_<start>_<lang>.wav` in `LANG_PROBE_RECORDINGS2`.
    private func recordings() throws -> [Clip] {
        let env = ProcessInfo.processInfo.environment
        var result: [Clip] = []
        if let dir = env["LANG_PROBE_RECORDINGS"] {
            for name in try FileManager.default.contentsOfDirectory(atPath: dir).sorted() where name.hasSuffix(".wav") {
                if let code = name.split(separator: "_").first, let language = TranscriptionLanguage(rawValue: String(code)) {
                    result.append(Clip(language: language, audio: URL(fileURLWithPath: dir).appendingPathComponent(name)))
                }
            }
        }
        if let dir = env["LANG_PROBE_RECORDINGS2"] {
            for name in try FileManager.default.contentsOfDirectory(atPath: dir).sorted() where name.hasSuffix(".wav") {
                let parts = name.dropLast(4).split(separator: "_")
                if parts.count == 3, let language = TranscriptionLanguage(rawValue: String(parts[2])) {
                    result.append(Clip(language: language, audio: URL(fileURLWithPath: dir).appendingPathComponent(name)))
                }
            }
        }
        return result
    }

    /// Drop everything before the first 20 ms frame whose RMS reaches 10% of the clip's loudest.
    private static func trimLeadingSilence(_ samples: [Float]) -> [Float] {
        let frame = 320
        var rms: [Float] = []
        var index = 0
        while index + frame <= samples.count {
            var sum: Float = 0
            for value in samples[index..<index + frame] { sum += value * value }
            rms.append((sum / Float(frame)).squareRoot())
            index += frame
        }
        guard let loudest = rms.max(), loudest > 0,
              let first = rms.firstIndex(where: { $0 >= loudest * 0.1 }) else { return samples }
        return Array(samples[(first * frame)...])
    }

    /// The session rule `SystemLivePreviewBridge` uses: commit at the early checkpoint when
    /// confident, else take the late answer.
    private func runRule(_ clips: [Clip], name: String) async throws {
        let probe = try await loadProbe()
        let early = await probe.earliestSeconds() ?? SystemLivePreviewBridge.earlyProbeSeconds, late = SystemLivePreviewBridge.lateProbeSeconds
        var correct = 0, earlyCommits = 0, earlyWrong = 0
        var latencies: [Double] = []
        var wrong: [String] = []
        for clip in clips {
            let samples = Self.trimLeadingSilence(try loadAudioSamples(from: clip.audio))
            let start = CFAbsoluteTimeGetCurrent()
            guard let first = await probe.identify(samples: Array(samples.prefix(Int(early * 16_000))), allowed: Self.allowed) else {
                XCTFail("probe returned nil"); return
            }
            latencies.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            var decided = first.language
            let confident = first.probability >= SystemLivePreviewBridge.confidentProbability
            if confident {
                earlyCommits += 1
                if first.language != clip.language { earlyWrong += 1 }
            }
            // Unsure: the late answer stands. Confident: the late re-check overturns it only
            // when it is confident too.
            if let second = await probe.identify(samples: Array(samples.prefix(Int(late * 16_000))), allowed: Self.allowed),
               !confident || second.probability >= SystemLivePreviewBridge.confidentProbability {
                decided = second.language
            }
            if decided == clip.language { correct += 1 }
            else { wrong.append("\(clip.audio.lastPathComponent) \(clip.language.rawValue)→\(decided.rawValue) p=\(String(format: "%.2f", first.probability))") }
        }
        latencies.sort()
        print(String(format: "[LangProbe] Qwen3 rule %@: %d/%d correct | early commits %d (wrong at 1 s %d) | median %.0fms | wrong: %@",
                     name, correct, clips.count, earlyCommits, earlyWrong,
                     latencies.isEmpty ? 0 : latencies[latencies.count / 2], wrong.joined(separator: ", ")))
        XCTAssertGreaterThanOrEqual(Double(correct), Double(clips.count) * 0.95, "final language wrong too often")
    }

    /// Kept alive for the process (MLX buffers; see CLAUDE.md on deallocation in tests).
    private static var qwen3: Qwen3ASREngine?

    /// Qwen3-ASR as the language probe: restricted name-token logits after `language`, on the
    /// same windows and rule as the V3 probe. λ = silence-calibration strength.
    func testQwen3LanguageID() async throws {
        guard Qwen3ASREngine.isModelCached() else { throw XCTSkip("Qwen3-ASR not downloaded") }
        if Self.qwen3 == nil { Self.qwen3 = try Qwen3ASREngine.load() }
        let engine = try XCTUnwrap(Self.qwen3)
        let codes = Self.allowed.map(\.rawValue)
        var clips = try clips(perLanguage: 30).map { ("FLEURS", $0) }
        clips += try recordings().map { ("real", $0) }
        let silence = try XCTUnwrap(engine.languageLogits(samples: [Float](repeating: 0, count: 16_000), codes: codes))
        let windows = [1.0, 2.0, 3.0]
        var table: [[[Float]]] = []
        var latencies: [Double] = []
        for (_, clip) in clips {
            let samples = Self.trimLeadingSilence(try loadAudioSamples(from: clip.audio))
            var row: [[Float]] = []
            for seconds in windows {
                let start = CFAbsoluteTimeGetCurrent()
                let logits = engine.languageLogits(samples: Array(samples.prefix(Int(seconds * 16_000))), codes: codes) ?? [:]
                latencies.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                row.append(codes.map { logits[$0] ?? -100 })
            }
            table.append(row)
        }
        latencies.sort()
        print(String(format: "[Qwen3LID] median %.0f ms per window", latencies[latencies.count / 2]))
        for lambda: Float in [0, 0.5, 1] {
            func decide(_ logits: [Float]) -> (TranscriptionLanguage, Float) {
                let v = zip(logits, codes).map { $0 - lambda * (silence[$1] ?? 0) }
                let peak = v.max() ?? 0
                let e = v.map { expf($0 - peak) }
                let sum = e.reduce(0, +)
                let best = e.indices.max { e[$0] < e[$1] } ?? 0
                return (Self.allowed[best], e[best] / sum)
            }
            for subset in ["real", "FLEURS"] {
                var correct = 0, total = 0, confidentWrong = 0, time = 0.0
                var single = [0, 0, 0], wrong: [String] = []
                for ((set, clip), row) in zip(clips, table) where set == subset {
                    total += 1
                    let d = row.map(decide)
                    for (i, w) in d.enumerated() {
                        if w.0 == clip.language { single[i] += 1 } else if w.1 >= 0.8 { confidentWrong += 1 }
                    }
                    var decided = d[2].0
                    if let i = [0, 1].first(where: { d[$0].1 >= 0.8 }) {
                        decided = (d[2].0 != d[i].0 && d[2].1 >= 0.8) ? d[2].0 : d[i].0
                        time += Double(i + 1)
                    } else { time += 3 }
                    if decided == clip.language { correct += 1 } else { wrong.append("\(clip.audio.lastPathComponent):\(clip.language.rawValue)→\(decided.rawValue)") }
                    if subset == "real" && lambda == 0.5 {
                        print("[Qwen3LID]   \(clip.audio.lastPathComponent) (\(clip.language.rawValue)) " + d.enumerated().map { String(format: "%.0fs %@ %.2f", windows[$0.offset], $0.element.0.rawValue, $0.element.1) }.joined(separator: "  "))
                    }
                }
                print(String(format: "[Qwen3LID] λ=%.1f %@: single 1s %d 2s %d 3s %d /%d | rule %d/%d, decided %.2fs avg, confident-wrong windows %d | wrong: %@",
                             lambda, subset, single[0], single[1], single[2], total, correct, total, time / Double(max(total, 1)), confidentWrong, wrong.joined(separator: ",")))
            }
        }
    }

    /// Where the live bridge starts its probe window: `SystemLivePreviewBridge`'s onset rule
    /// (20 ms frames, noise floor from the first 10, 100 ms back-off).
    private static func bridgeOnset(_ samples: [Float]) -> Int {
        let frame = 320
        var rms: [Float] = []
        var index = 0
        while index + frame <= samples.count {
            var sum: Float = 0
            for value in samples[index..<index + frame] { sum += value * value }
            let value = (sum / Float(frame)).squareRoot()
            rms.append(value)
            let sorted = rms.prefix(10).sorted()
            let floor = min(sorted[sorted.count / 2], 0.01)
            if rms.count > 3, value > max(0.004, floor * 3) { return max(0, index - 1_600) }
            index += frame
        }
        return 0
    }

    /// Per real recording: Qwen3 restricted scores for windows starting at the bridge's onset
    /// and at the trimmed start, at 1.0 / 1.5 / 2.0 s.
    func testQwen3WindowSensitivity() async throws {
        let probe = try await loadProbe()
        for clip in try recordings() {
            let samples = try loadAudioSamples(from: clip.audio)
            let trimmedStart = samples.count - Self.trimLeadingSilence(samples).count
            for (label, start) in [("bridge", Self.bridgeOnset(samples)), ("trim", trimmedStart)] {
                var line = "[Qwen3Win] \(clip.audio.lastPathComponent) (\(clip.language.rawValue)) \(label)@\(String(format: "%.2f", Double(start) / 16_000))s"
                for seconds in [1.0, 1.5, 2.0] {
                    let end = min(samples.count, start + Int(seconds * 16_000))
                    let r = await probe.identify(samples: Array(samples[start..<end]), allowed: Self.allowed)
                    line += String(format: "  %.1fs %@ %.2f", seconds, r?.language.rawValue ?? "?", r?.probability ?? 0)
                }
                print(line)
            }
        }
    }

    func testDecisionRuleFLEURS() async throws {
        try await runRule(try clips(perLanguage: 30), name: "FLEURS")
    }

    func testRealRecordings() async throws {
        let clips = try recordings()
        guard !clips.isEmpty else { throw XCTSkip("set TEST_RUNNER_LANG_PROBE_RECORDINGS") }
        try await runRule(clips, name: "real")
    }
}
