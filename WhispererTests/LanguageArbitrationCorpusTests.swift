//
//  LanguageArbitrationCorpusTests.swift
//  WhispererTests
//
//  Opt-in corpus measurement (slow — loads whisper V3 and Qwen3-ASR, decodes ~60 recordings).
//  Run with: TEST_RUNNER_WHISPERER_LANG_CORPUS=1 xcodebuild test … -only-testing:WhispererTests/LanguageArbitrationCorpusTests
//
//  Question it answers: on this user's history, does comparing whisper's average log-probability
//  for an en-forced vs ru-forced decode of the probe window pick the right language more often
//  than whisper's language-ID probe? Ground truth is Qwen3-ASR's language header on the full
//  recording, which is not whisper-derived.
//

import XCTest
@testable import whisperer

final class LanguageArbitrationCorpusTests: XCTestCase {

    func testDualDecodeVersusProbeOnHistory() throws {
        guard ProcessInfo.processInfo.environment["WHISPERER_LANG_CORPUS"] == "1" else {
            throw XCTSkip("opt-in: set TEST_RUNNER_WHISPERER_LANG_CORPUS=1")
        }
        guard Qwen3ASRBridge.isModelCached() else { throw XCTSkip("Qwen3-ASR oracle not downloaded") }
        let qwen = try Qwen3ASRBridge.loadFromCache()
        let path = ModelDownloader.shared.modelPath(for: .largeTurboQ5)
        guard FileManager.default.fileExists(atPath: path.path) else { throw XCTSkip("V3 missing") }
        let whisper = try WhisperBridge(modelPath: path)
        let vad = loadVAD()

        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 400)
            .filter { $0.audioURL != nil && $0.durationSec >= 6 }
        // Balance: every stored-ru fixture (the confusable ones) plus as many stored-en.
        let ru = fixtures.filter { $0.language == "ru" }.prefix(40)
        let en = fixtures.filter { $0.language == "en" }.prefix(max(20, ru.count))
        var rows: [String] = []
        var probeRight = 0, dualRight = 0, n = 0
        var ambiguous = 0, ambiguousProbeRight = 0, ambiguousDualRight = 0

        for fixture in Array(ru) + Array(en) {
            guard let samples = try? loadAudioSamples(from: fixture.audioURL!) else { continue }
            qwen.resetAbort()
            _ = qwen.transcribe(samples: samples, initialPrompt: nil, language: .auto,
                                singleSegment: false, maxTokens: 0)
            guard let truth = qwen.lastDetectedLanguage, truth == "en" || truth == "ru" else { continue }

            // Probe window: first 10 s of voiced audio, as the live probe uses.
            var window = samples
            if let vad {
                var voiced: [Float] = []
                for seg in vad.detectSpeechSegments(samples: samples) {
                    voiced += samples[min(seg.startSample, samples.count)..<min(seg.endSample, samples.count)]
                    if voiced.count >= 160_000 { break }
                }
                if voiced.count >= 16_000 { window = voiced }
            }
            window = Array(window.prefix(160_000))

            guard let probs = whisper.detectLanguage(samples: window) else { continue }
            let pEn = probs["en"] ?? 0, pRu = probs["ru"] ?? 0
            let probeLang = pEn >= pRu ? "en" : "ru"
            let probeTop = max(pEn, pRu) / max(pEn + pRu, 1e-6)

            func logProb(_ lang: TranscriptionLanguage) -> Float {
                let done = DispatchSemaphore(value: 0)
                var lp: Float = -99
                whisper.transcribeStreamingAsync(samples: window, language: lang, initialPrompt: nil) { r in
                    lp = r?.averageLogProbability ?? -99
                    done.signal()
                }
                done.wait()
                return lp
            }
            let lpEn = logProb(.english), lpRu = logProb(.russian)
            let dualLang = lpEn >= lpRu ? "en" : "ru"

            n += 1
            if probeLang == truth { probeRight += 1 }
            if dualLang == truth { dualRight += 1 }
            let rawTop = max(pEn, pRu)
            if rawTop < 0.85 {
                ambiguous += 1
                if probeLang == truth { ambiguousProbeRight += 1 }
                if dualLang == truth { ambiguousDualRight += 1 }
            }
            rows.append(String(format: "%@ stored=%@ truth=%@ | probe %@ en=%.3f ru=%.3f (norm %.2f) | dual %@ lpEn=%.3f lpRu=%.3f Δ=%.3f",
                               probeLang == truth && dualLang == truth ? "  " : "!!",
                               fixture.language, truth, probeLang, pEn, pRu, probeTop,
                               dualLang, lpEn, lpRu, lpEn - lpRu))
        }
        print("LANGCORPUS rows:\n" + rows.joined(separator: "\n"))
        print("LANGCORPUS n=\(n) probe=\(probeRight) dual=\(dualRight) | ambiguous(p<0.85)=\(ambiguous) probe=\(ambiguousProbeRight) dual=\(ambiguousDualRight)")
        XCTAssertGreaterThan(n, 0)
    }
}
