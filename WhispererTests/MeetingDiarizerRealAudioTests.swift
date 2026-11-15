//
//  MeetingDiarizerRealAudioTests.swift
//  WhispererTests
//
//  Runs the Nemotron-3 diarizer over a real meeting recording and prints who spoke when. Opt-in:
//
//    TEST_RUNNER_DIARIZE_WAV=/path/to/16k-mono.wav  xcodebuild test … -only-testing:WhispererTests/MeetingDiarizerRealAudioTests
//

import XCTest
import AVFoundation
@testable import whisperer

#if canImport(FluidAudio)
import FluidAudio

final class MeetingDiarizerRealAudioTests: XCTestCase {

    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    func testPrintWhoSpokeWhen() async throws {
        guard let path = ProcessInfo.processInfo.environment["DIARIZE_WAV"] else { throw XCTSkip("set TEST_RUNNER_DIARIZE_WAV") }
        try XCTSkipUnless(MeetingDiarizerService.isModelCached(), "Nemotron-3 model not cached")
        let config = MeetingDiarizerService.config
        let models = try await Nemotron3Models.loadFromHuggingFace(config: config, cacheDirectory: MeetingDiarizerService.modelsRoot())
        let diarizer = Nemotron3Diarizer(config: config, models: models)
        let audio = try samples(URL(fileURLWithPath: path))
        print("DIAR audio \(audio.count / 16_000)s")
        let (probabilities, frames) = try diarizer.processComplete(audio)
        let segments = Nemotron3Diarizer.segments(probabilities: probabilities, frameCount: frames)
        var totals: [Int: Float] = [:]
        for s in segments { totals[s.speakerIndex, default: 0] += s.endSeconds - s.startSeconds }
        print("DIAR segments=\(segments.count) speakers=\(totals.keys.sorted()) totals=\(totals.sorted { $0.key < $1.key }.map { "s\($0.key)=\(Int($0.value))s" })")
        for s in segments.prefix(80) { print(String(format: "DIAR s%d %.1f–%.1f", s.speakerIndex, s.startSeconds, s.endSeconds)) }
        // Peak probability per slot over the whole recording.
        let slots = config.numSpeakers
        var peak = [Float](repeating: 0, count: slots), active = [Int](repeating: 0, count: slots)
        for f in 0..<frames { for k in 0..<slots { let p = probabilities[f * slots + k]; peak[k] = max(peak[k], p); if p > 0.5 { active[k] += 1 } } }
        // How strongly does each slot respond, per 10 s window? (peak probability and frames above 0.2 / 0.5)
        for w in stride(from: 0, to: frames, by: 1000) {
            var line = String(format: "DIAR win %3ds:", w / 100)
            for k in 0..<min(slots, 3) {
                var pk: Float = 0, a2 = 0, a5 = 0
                for f in w..<min(frames, w + 1000) { let p = probabilities[f * slots + k]; pk = max(pk, p); if p > 0.2 { a2 += 1 }; if p > 0.5 { a5 += 1 } }
                line += String(format: "  s%d peak %.2f >0.2:%3d >0.5:%3d", k, pk, a2, a5)
            }
            print(line)
        }
        print("DIAR slot peaks=\(peak.map { String(format: "%.2f", $0) }) frames>0.5=\(active)")
    }
}
#endif
