//
//  DictationProgressiveTests.swift
//  WhispererTests
//
//  Progressive dictation, end to end: is the text inserted at key release the same text one
//  whole-recording decode would give, and is it ready at once?
//
//  That is the design of the eager stream — decode while the user speaks so release costs
//  nothing — and the 2026-11-11 benchmark found it was not true: on the same clips the streamed
//  final scored 23.6 % WER against 7.7 % for one whole decode by the same model.
//
//  Each recording is played at 1x through the app's own `StreamingTranscriber` on the resident
//  whisper.cpp bridge (Whisperer V3 q5_0), routed as `AppState` routes it: one language → no
//  routers; several → LanguageRouter + ModelRouter with the whisper.cpp `.auto` fallback profile.
//  The key is released `releaseDelay` after the last sample, as a user releases it, not seconds
//  later. Then the same bridge decodes the whole recording once — the reference the stream has to
//  match, and the release latency the stream has to beat.
//
//  Per recording: dropped / added / changed words against the whole decode (alignment), adjacent
//  duplicate runs, WER against the human transcript where there is one (FLEURS), release-to-text
//  latency, whole-decode time.
//
//  Corpora (opt-in, real time, real model):
//    TEST_RUNNER_DICTATION_PROGRESSIVE=history,fleurs,long   any subset
//    TEST_RUNNER_DICTATION_MODE=pinned|auto                  default pinned
//    TEST_RUNNER_DICTATION_ARM=eager|vad                     eager word stream, or pause-cut chunks
//    TEST_RUNNER_DICTATION_FLEURS_PER_LANG=20
//    TEST_RUNNER_DICTATION_HISTORY_PER_BUCKET=8              recordings per length bucket
//    TEST_RUNNER_DICTATION_ONLY=he-1876,016f                 id prefixes, to trace single recordings
//  Writes Tools/omni-eval/results/dictation-<mode>-<tag>.jsonl; TEST_RUNNER_DICTATION_TAG names it.
//

import XCTest
@testable import whisperer

@MainActor
final class DictationProgressiveTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []
    private static let evalDir = URL(fileURLWithPath: "/Users/alexivy/ai/whisperer/Tools/omni-eval")
    /// How long after the last spoken sample the key is released.
    static let releaseDelay: Double = 0.3

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    struct Item {
        let id: String
        let corpus: String
        let lang: TranscriptionLanguage
        let samples: [Float]
        let human: String?
    }

    // MARK: - Entry

    func testProgressiveDictationMatchesWholeDecode() async throws {
        guard let corpora = env["DICTATION_PROGRESSIVE"]?.split(separator: ",").map(String.init) else {
            throw XCTSkip("set TEST_RUNNER_DICTATION_PROGRESSIVE=history,fleurs,long")
        }
        let pinned = (env["DICTATION_MODE"] ?? "pinned") == "pinned"
        let tag = env["DICTATION_TAG"] ?? "run"
        let out = Self.evalDir.appendingPathComponent("results/dictation-\(pinned ? "pinned" : "auto")-\(tag).jsonl")
        try? FileManager.default.removeItem(at: out)

        let bridge = try loadWhisperBridge()
        Self.keepAlive.append(bridge)
        _ = bridge.transcribe(samples: [Float](repeating: 0.01, count: 16_000), language: .english)

        var items: [Item] = []
        if corpora.contains("history") { items += historyItems() }
        if corpora.contains("fleurs") { items += fleursItems(perLanguage: Int(env["DICTATION_FLEURS_PER_LANG"] ?? "20") ?? 20) }
        if corpora.contains("long") { items += longItems() }
        if let only = env["DICTATION_ONLY"]?.split(separator: ",").map({ String($0).lowercased() }), !only.isEmpty {
            items = items.filter { item in only.contains { item.id.lowercased().hasPrefix($0) } }
        }
        try XCTSkipIf(items.isEmpty, "no recordings")
        print("[Dictation] \(items.count) recordings, \(pinned ? "pinned" : "auto"), release +\(Self.releaseDelay)s")

        var rows: [Row] = []
        for item in items {
            let row = await run(item, bridge: bridge, pinned: pinned)
            rows.append(row)
            append(row.json, to: out)
            print(String(format: "[Dictation] %@ %@ %4.1fs  vs whole: drop %d add %d sub %d (%.1f%%)  dup %d  release %4.0fms  whole %4.0fms%@",
                         row.corpus, row.id, row.seconds, row.dropped, row.added, row.changed, row.damage * 100,
                         row.duplicateRuns, row.releaseMs, row.wholeMs,
                         row.humanWER.map { String(format: "  human WER stream %.0f%% / whole %.0f%%", $0 * 100, (row.wholeHumanWER ?? 0) * 100) } ?? ""))
        }
        summarize(rows)
    }

    // MARK: - One recording

    struct Row {
        let id: String, corpus: String, lang: String, seconds: Double
        let stream: String, whole: String, human: String?
        let dropped: Int, added: Int, changed: Int, wholeWords: Int
        let duplicateRuns: Int
        let releaseMs: Double, wholeMs: Double
        let humanWER: Double?, wholeHumanWER: Double?
        var damage: Double { Double(dropped + added + changed) / Double(max(wholeWords, 1)) }
        var json: [String: Any] {
            var j: [String: Any] = ["id": id, "corpus": corpus, "lang": lang, "seconds": seconds, "stream": stream,
                                    "whole": whole, "dropped": dropped, "added": added, "changed": changed,
                                    "wholeWords": wholeWords, "duplicateRuns": duplicateRuns,
                                    "releaseMs": releaseMs, "wholeMs": wholeMs]
            if let human { j["human"] = human }
            if let humanWER { j["humanWER"] = humanWER }
            if let wholeHumanWER { j["wholeHumanWER"] = wholeHumanWER }
            return j
        }
    }

    private func run(_ item: Item, bridge: WhisperBridge, pinned: Bool) async -> Row {
        let language = pinned ? item.lang : .auto
        let profile = ModelProfile(model: .largeTurboQ5, backend: .whisperCpp, language: .auto, isSpecialized: false)
        let pool = ModelPool()
        try? pool.loadFallback(profile: profile, backend: bridge)
        let transcriber = StreamingTranscriber(
            backend: bridge, vad: loadVAD(), language: language, initialPrompt: nil,
            fillerWordRemovalEnabled: false, modelPool: pool,
            languageRouter: pinned ? nil : LanguageRouter(allowed: [.english, .russian, .hebrew], primary: nil),
            modelRouter: pinned ? nil : ModelRouter(languageModelMap: [:], fallbackProfile: profile),
            eagerStreamOverride: (env["DICTATION_ARM"] ?? "eager") == "eager")
        Self.keepAlive += [pool, transcriber]
        let chunks = EagerChunkCollector()
        transcriber.onChunkCompleted = { chunks.record($0) }
        bridge.resetAbort()
        transcriber.start { _ in }

        let began = Date()
        let step = 1_365
        var offset = 0
        while offset < item.samples.count {
            let end = min(offset + step, item.samples.count)
            transcriber.addSamples(Array(item.samples[offset..<end]))
            offset = end
            let due = Double(offset) / 16_000 - Date().timeIntervalSince(began)
            if due > 0 { try? await Task.sleep(nanoseconds: UInt64(due * 1e9)) }
        }
        try? await Task.sleep(nanoseconds: UInt64(Self.releaseDelay * 1e9))
        let releaseAt = Date()
        let stream = await transcriber.stopAsync()
        let releaseMs = Date().timeIntervalSince(releaseAt) * 1000
        if env["DICTATION_ONLY"]?.isEmpty == false {
            for c in chunks.recorded() {
                print(String(format: "[Dictation]   chunk %.2f-%.2f  %@", c.start, c.end, c.text))
            }
        }

        let wholeStart = Date()
        let samples = item.samples
        let whole = await Task.detached { bridge.transcribe(samples: samples, language: language) }.value
        let wholeMs = Date().timeIntervalSince(wholeStart) * 1000

        let diff = Self.alignmentCounts(reference: Self.words(whole), hypothesis: Self.words(stream))
        return Row(id: String(item.id.prefix(12)), corpus: item.corpus, lang: item.lang.rawValue,
                   seconds: Double(item.samples.count) / 16_000,
                   stream: stream, whole: whole, human: item.human,
                   dropped: diff.deleted, added: diff.inserted, changed: diff.substituted,
                   wholeWords: Self.words(whole).count,
                   duplicateRuns: eagerAdjacentDuplicateRuns(in: stream).count,
                   releaseMs: releaseMs, wholeMs: wholeMs,
                   humanWER: item.human.map { wordErrorRate(stream, reference: $0) },
                   wholeHumanWER: item.human.map { wordErrorRate(whole, reference: $0) })
    }

    // MARK: - Corpora

    private func historyItems() -> [Item] {
        // The whole decode below is the reference, so no golden entry is needed.
        let n = Int(env["DICTATION_HISTORY_PER_BUCKET"] ?? "8") ?? 8
        let (fixtures, _) = loadEagerCorpus(perBucket: ["short": n, "medium": n, "long": n, "very-long": n],
                                            isEligible: { _ in true })
        return fixtures.compactMap { fixture, samples in
            let lang = TranscriptionLanguage(rawValue: fixture.language) ?? .english
            return Item(id: fixture.id, corpus: "history", lang: lang == .auto ? .english : lang, samples: samples, human: nil)
        }
    }

    private func manifest(_ lang: String) -> [(id: String, audio: String, ref: String)] {
        let url = Self.evalDir.appendingPathComponent("manifests/\(lang).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["id"] as? String, let audio = row["audio"] as? String,
                  let ref = row["ref"] as? String else { return nil }
            return (id, audio, ref)
        }
    }

    private func fleursItems(perLanguage n: Int) -> [Item] {
        ["he", "ru", "en"].flatMap { lang -> [Item] in
            manifest(lang).prefix(n).compactMap { clip in
                guard let samples = try? loadAudioSamples(from: URL(fileURLWithPath: clip.audio)) else { return nil }
                return Item(id: clip.id, corpus: "fleurs", lang: TranscriptionLanguage(rawValue: lang) ?? .english,
                            samples: samples, human: clip.ref)
            }
        }
    }

    /// 45 s dictations: FLEURS sentences of one language joined with 0.6 s pauses — longer than
    /// any single clip, the length where windowing and commits actually happen.
    private func longItems() -> [Item] {
        ["he", "ru", "en"].flatMap { lang -> [Item] in
            let clips = Array(manifest(lang).dropFirst(40))
            var items: [Item] = []
            var index = 0
            for k in 0..<3 {
                var samples: [Float] = []
                var refs: [String] = []
                while Double(samples.count) / 16_000 < 45, index < clips.count {
                    if let s = try? loadAudioSamples(from: URL(fileURLWithPath: clips[index].audio)) {
                        samples += s + [Float](repeating: 0, count: 9_600)
                        refs.append(clips[index].ref)
                    }
                    index += 1
                }
                if !samples.isEmpty {
                    items.append(Item(id: "\(lang)-long\(k)", corpus: "long", lang: TranscriptionLanguage(rawValue: lang) ?? .english,
                                      samples: samples, human: refs.joined(separator: " ")))
                }
            }
            return items
        }
    }

    // MARK: - Scoring

    nonisolated static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Levenshtein alignment counts: words of `reference` missing from `hypothesis` (dropped),
    /// extra words in `hypothesis` (added — duplicates land here), and substitutions.
    nonisolated static func alignmentCounts(reference r: [String], hypothesis h: [String]) -> (deleted: Int, inserted: Int, substituted: Int) {
        let n = r.count, m = h.count
        if n == 0 { return (0, m, 0) }
        if m == 0 { return (n, 0, 0) }
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        for i in 1...n { for j in 1...m {
            d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + (r[i-1] == h[j-1] ? 0 : 1))
        } }
        var i = n, j = m, del = 0, ins = 0, sub = 0
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i-1][j-1] + (r[i-1] == h[j-1] ? 0 : 1) {
                if r[i-1] != h[j-1] { sub += 1 }
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i-1][j] + 1 { del += 1; i -= 1 }
            else { ins += 1; j -= 1 }
        }
        return (del, ins, sub)
    }

    private func summarize(_ rows: [Row]) {
        func pct(_ v: [Double], _ p: Double) -> Double {
            let s = v.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(p * Double(s.count - 1)))]
        }
        for corpus in Set(rows.map(\.corpus)).sorted() {
            let rs = rows.filter { $0.corpus == corpus }
            let whole = rs.reduce(0) { $0 + $1.wholeWords }
            let dropped = rs.reduce(0) { $0 + $1.dropped }, added = rs.reduce(0) { $0 + $1.added }, changed = rs.reduce(0) { $0 + $1.changed }
            let identical = rs.filter { $0.dropped + $0.added + $0.changed == 0 }.count
            print(String(format: "[Dictation] SUMMARY %@ n=%d  vs whole decode: dropped %.1f%%  added %.1f%%  changed %.1f%%  identical %d/%d  dup runs %d  release p50 %.0f / p95 %.0f ms  whole-decode p50 %.0f ms",
                         corpus, rs.count, 100 * Double(dropped) / Double(max(whole, 1)), 100 * Double(added) / Double(max(whole, 1)),
                         100 * Double(changed) / Double(max(whole, 1)), identical, rs.count, rs.reduce(0) { $0 + $1.duplicateRuns },
                         pct(rs.map(\.releaseMs), 0.5), pct(rs.map(\.releaseMs), 0.95), pct(rs.map(\.wholeMs), 0.5)))
            let human = rs.compactMap(\.humanWER), wholeHuman = rs.compactMap(\.wholeHumanWER)
            if !human.isEmpty {
                print(String(format: "[Dictation] SUMMARY %@ human WER: stream %.1f%%  whole %.1f%%", corpus,
                             100 * human.reduce(0, +) / Double(human.count), 100 * wholeHuman.reduce(0, +) / Double(wholeHuman.count)))
            }
        }
    }

    private func append(_ row: [String: Any], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: row), let line = String(data: data, encoding: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close() }
        else { try? (line + "\n").write(to: url, atomically: true, encoding: .utf8) }
    }
}
