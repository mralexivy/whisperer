//
//  ChunkStreamCorpus.swift
//  WhispererTests
//
//  Harvests, persists, and reloads the real VAD chunk streams that the batched-LLM work is
//  measured against.
//
//  Why this file exists at all: the batch scheduler can only batch what has already arrived.
//  If real chunks arrive 3s apart and a correction takes 0.7s, the queue never holds more than
//  one request and the streaming half of batching is worth exactly nothing. That is an empirical
//  question about this user's speech and this app's VAD, not something to reason about — so it is
//  measured from real recordings before the scheduler is designed, and the measurement is frozen
//  to JSON so that every later LLM benchmark runs on identical text without paying for whisper
//  again. A harvest is real-time (an hour of audio takes an hour); a reload is instant.
//

import Foundation
@testable import whisperer

// MARK: - Corpus model

/// One soft-committed chunk as the streaming transcriber actually emitted it.
struct ChunkArrival: Codable {
    let text: String
    /// Audio-time arrival: total audio received when this chunk committed
    /// (`TranscriptChunk.recordedDuration`). This is the number the scheduler is sized from,
    /// because it is a property of the speech and the VAD rather than of the machine that
    /// happened to run the harvest.
    let audioOffsetSec: Double
    /// Wall-clock arrival, measured from the first sample fed. Only kept so a harvest that fell
    /// behind real time can be spotted and thrown away — if this drifts far above
    /// `audioOffsetSec`, the decoder was not keeping up and the inter-arrival figures are the
    /// machine's, not the speaker's.
    let wallOffsetSec: Double
    /// The chunk's own span in the recording.
    let startSec: Double
    let endSec: Double
}

/// Every chunk one recording produced, in emission order.
struct ChunkStream: Codable {
    let recordingID: String
    let language: String
    let bucket: String
    let durationSec: Double
    let chunks: [ChunkArrival]

    /// Gaps between consecutive chunk arrivals, in audio time. Empty for a single-chunk stream —
    /// a recording that commits once has no inter-arrival and must not contribute a 0 to the
    /// distribution, which would drag the percentiles toward "always batchable".
    var interArrivalsSec: [Double] {
        guard chunks.count > 1 else { return [] }
        return (1 ..< chunks.count).map { chunks[$0].audioOffsetSec - chunks[$0 - 1].audioOffsetSec }
    }

    /// How far behind real time the harvest ran, in seconds, at the last chunk. A harvest whose
    /// lag grows without bound was fed faster than it could decode and is not usable.
    var maxFeedLagSec: Double {
        chunks.map { $0.wallOffsetSec - $0.audioOffsetSec }.max() ?? 0
    }
}

struct ChunkStreamCorpus: Codable {
    let streams: [ChunkStream]

    var allChunkTexts: [String] {
        streams.flatMap { $0.chunks.map(\.text) }
    }

    var allInterArrivalsSec: [Double] {
        streams.flatMap(\.interArrivalsSec)
    }
}

// MARK: - Persistence

extension ChunkStreamCorpus {

    /// `WhispererTests/TestData/chunk-stream-corpus.json`. `#filePath` is resolved at compile
    /// time, so this lands in the source tree rather than in whatever DerivedData directory
    /// Xcode picked, which is what makes the corpus committable.
    static var fileURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // Helpers/
            .deletingLastPathComponent()          // WhispererTests/
            .appendingPathComponent("TestData")
            .appendingPathComponent("chunk-stream-corpus.json")
    }

    static func loadPersisted() -> ChunkStreamCorpus? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ChunkStreamCorpus.self, from: data)
    }

    func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Self.fileURL)
    }
}

// MARK: - Statistics

/// Percentile over an unsorted sample, nearest-rank. Returns 0 for an empty sample rather than
/// trapping, because a bucket with no data is a normal outcome of a narrowed harvest.
func chunkPercentile(_ values: [Double], _ q: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[Int((Double(sorted.count - 1) * q).rounded())]
}

// MARK: - Harvest

/// Selects a corpus stratified by duration bucket *and* language.
///
/// `loadEagerCorpus` already stratifies by bucket, but it fills each bucket from the lowest ids
/// first, which on this history means a bucket can come out entirely English. Language matters
/// here for a reason specific to the LLM: chunk boundaries and chunk lengths differ by script,
/// and `docs/knowledge/llm/knowledge.md` records a Hebrew data-loss failure, so a corpus that
/// silently drops he and ru would let the batched path regress exactly where it is most fragile.
///
/// - Parameter perBucketLanguage: how many recordings to take per (bucket, language) pair.
/// - Parameter perBucket: hard cap on each bucket regardless of language spread.
func selectChunkStreamFixtures(
    perBucketLanguage: Int,
    perBucket: [String: Int]
) -> (fixtures: [EagerFixture], rejected: [String]) {
    let all = HistoryTestLoader.loadFixtures(maxCount: 3000)
        .filter { $0.audioURL != nil && !$0.transcript.trimmingCharacters(in: .whitespaces).isEmpty }

    var loaded: [EagerFixture] = []
    var rejected: [String] = []
    var bucketCounts: [String: Int] = [:]
    var pairCounts: [String: Int] = [:]

    // Stable order so two harvests of the same database pick the same recordings and their
    // chunk streams can be diffed.
    for fixture in all.sorted(by: { $0.id < $1.id }) {
        guard let url = fixture.audioURL,
              let samples = try? loadAudioSamples(from: url), !samples.isEmpty else { continue }

        let audioSec = Double(samples.count) / 16000
        // Same truncation guard as `loadEagerCorpus`, and for the same reason: a database row
        // that claims more speech than the .wav contains produces a chunk stream that stops
        // early, which would read here as "this speaker pauses for three minutes".
        guard audioSec >= min(fixture.durationSec * 0.9, fixture.durationSec - 0.5) else {
            rejected.append(String(format: "%@ db=%.1fs wav=%.1fs — audio shorter than the record claims",
                                   String(fixture.id.prefix(8)).lowercased(), fixture.durationSec, audioSec))
            continue
        }

        let corrected = RecordingFixture(
            id: fixture.id, durationSec: audioSec, transcript: fixture.transcript,
            aiEnhancedText: fixture.aiEnhancedText, aiModeName: fixture.aiModeName,
            language: fixture.language, audioURL: fixture.audioURL, wordCount: fixture.wordCount)

        let bucket = corrected.durationBucket
        let pair = "\(bucket)|\(corrected.language)"
        guard bucketCounts[bucket, default: 0] < (perBucket[bucket] ?? 0),
              pairCounts[pair, default: 0] < perBucketLanguage else { continue }
        bucketCounts[bucket] = bucketCounts[bucket, default: 0] + 1
        pairCounts[pair] = pairCounts[pair, default: 0] + 1
        loaded.append((corrected, samples))
    }

    let order = ["short": 0, "medium": 1, "long": 2, "very-long": 3]
    return (loaded.sorted { (order[$0.fixture.durationBucket] ?? 9, $0.fixture.id)
                         <  (order[$1.fixture.durationBucket] ?? 9, $1.fixture.id) }, rejected)
}

/// Thread-safe sink for `runEagerFixture(onChunkStamped:)`. The probe fires on the bridge queue.
final class ChunkArrivalCollector {
    private let lock = NSLock()
    private var arrivals: [ChunkArrival] = []

    func record(_ chunk: TranscriptChunk, wallOffset: Double) {
        lock.lock()
        arrivals.append(ChunkArrival(text: chunk.text,
                                     audioOffsetSec: chunk.recordedDuration,
                                     wallOffsetSec: wallOffset,
                                     startSec: chunk.start,
                                     endSec: chunk.end))
        lock.unlock()
    }

    func snapshot() -> [ChunkArrival] {
        lock.lock(); defer { lock.unlock() }
        return arrivals
    }
}

/// Replays one real recording at real time through the real streaming transcriber and returns
/// its chunk stream.
func harvestChunkStream(
    _ fixture: RecordingFixture,
    samples: [Float],
    bridge: WhisperBridge
) async -> ChunkStream {
    let collector = ChunkArrivalCollector()
    _ = await runEagerFixture(
        fixture, samples: samples, bridge: bridge,
        capSeconds: StreamingTranscriber.defaultEagerMaxWindowSeconds,
        onChunkStamped: { [collector] chunk, wall in collector.record(chunk, wallOffset: wall) })

    return ChunkStream(recordingID: String(fixture.id.prefix(8)).lowercased(),
                       language: fixture.language,
                       bucket: fixture.durationBucket,
                       durationSec: fixture.durationSec,
                       chunks: collector.snapshot())
}
