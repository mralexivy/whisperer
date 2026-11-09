//
//  AppleLanguageID.swift
//  Whisperer
//
//  Spoken-language identification with Apple's own dictation models: the same few seconds are
//  transcribed once per candidate locale, and the locale whose words Apple is most confident in
//  is the language. No Whisper, no GPU — Apple's models run in its speech service.
//
//  Measured 2026-11-09 on 3 s windows (the user's 9 dictations, 24 FLEURS he/ru/en clips with
//  speech, and a far-field Hebrew TV recording): 33/33 right, against 28/33 for Whisper V3 on the
//  same windows; ~0.67 s per 3-locale probe, all of it CPU in the speech service, against 0.71 s
//  of GPU for V3. Both mistakes, on near-silent clips, had a best confidence ≤ 0.30 and a lead
//  over the runner-up ≤ 0.18; on every clip with speech the lead was larger, so the lead is the
//  probability: p = 0.5 + lead (≥ 0.85 counts as confident, ≥ 0.95 as sure).
//
//  Apple's text language ID (NLLanguageRecognizer) is not a substitute: a recognizer in the
//  wrong locale writes plausible text in *its* language, and the text ID found the true
//  language for 7 of 46 windows.
//

import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
nonisolated enum AppleLanguageID {

    /// Mean word confidence per language for `samples` (16 kHz mono). Languages Apple has no
    /// installed model for are left out.
    static func confidences(samples: [Float], languages: [TranscriptionLanguage]) async -> [TranscriptionLanguage: Double] {
        var out: [TranscriptionLanguage: Double] = [:]
        for language in languages {
            guard let locale = await SystemLivePreviewBridge.locale(for: language),
                  await SystemLivePreviewBridge.status(for: language) == .ready,
                  let confidence = await confidence(samples: samples, locale: locale) else { continue }
            out[language] = confidence
        }
        return out
    }

    /// Confidence in the language a session is already in at or above which it is confirmed
    /// without trying the others. The highest any wrong locale scored in the benchmark was 0.54;
    /// the right one reached 0.65 on 22 of 33 windows, so most re-checks cost one pass, not three.
    static let confirmCurrentConfidence = 0.65

    /// The probability the probe reports for the most confident language: its lead over the
    /// runner-up, offset so the existing thresholds (0.85 confident, 0.95 sure) keep their meaning.
    static func probabilities(from confidences: [TranscriptionLanguage: Double]) -> [TranscriptionLanguage: Float] {
        let ranked = confidences.sorted { $0.value > $1.value }
        guard let best = ranked.first else { return [:] }
        let lead = best.value - (ranked.dropFirst().first?.value ?? 0)
        let p = best.value >= 0.4 ? Float(min(1, 0.5 + lead)) : 0.5
        var out: [TranscriptionLanguage: Float] = [best.key: p]
        let rest = ranked.dropFirst()
        let restSum = rest.reduce(0) { $0 + $1.value }
        for (language, value) in rest {
            out[language] = restSum > 0 ? Float(value / restSum) * (1 - p) : (1 - p) / Float(max(rest.count, 1))
        }
        return out
    }

    private static func confidence(samples: [Float], locale: Locale) async -> Double? {
        let module = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [],
                                          reportingOptions: [], attributeOptions: [.transcriptionConfidence])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
              let buffer = convert(samples, to: format) else { return nil }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module])
        let collect = Task { () -> (Double, Double) in
            var weighted = 0.0, characters = 0.0
            do {
                for try await result in module.results {
                    for run in result.text.runs {
                        guard let value = run.transcriptionConfidence else { continue }
                        let count = Double(result.text[run.range].characters.count)
                        weighted += value * count
                        characters += count
                    }
                }
            } catch {}
            return (weighted, characters)
        }
        do {
            try await analyzer.start(inputSequence: stream)
            continuation.yield(AnalyzerInput(buffer: buffer))
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            continuation.finish()
            collect.cancel()
            return nil
        }
        let (weighted, characters) = await collect.value
        return characters > 0 ? weighted / characters : 0
    }

    private static func convert(_ samples: [Float], to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(Double(samples.count) * format.sampleRate / 16_000) + 32)
        else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}
