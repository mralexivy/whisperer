//
//  ChunkCorpus.swift
//  WhispererTests
//
//  Loader for `Tools/llm-eval/chunk-corpus.json` — real chunk spans from a real streaming decode,
//  written by `PolishChunkCorpusDumpTests`.
//
//  This is the only source of chunk timings any test has. The history stores chunk texts and
//  discards `start`/`end` (`HistoryManager.appendChunk`), so without this file every benchmark is
//  stuck on `polish(text:)` with an empty pause map, and `SentenceTerminator`'s interior rule —
//  the class that dominates the shipping pipeline — cannot fire at all.
//

import Foundation
@testable import whisperer

enum ChunkCorpus {

    struct Span: Decodable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    struct Record: Decodable {
        let id: String
        /// Script family of the stored transcript — `en` / `he` / `ru` / `mixed`. Never the
        /// history's `language` column, which is decoder state.
        let script: String
        let bucket: String
        let durationSec: Double
        let chunks: [Span]
        let storedTranscript: String
        /// Empty when only the authored gold covers this recording — see `hasAuthoredGold`. A row
        /// with neither reference cannot be scored and should not be in the file.
        let goldenTranscript: String
        let hasAuthoredGold: Bool

        /// The chunks as the polisher's own type, which is the whole point of the file.
        var polisherChunks: [DeterministicPolisher.Chunk] {
            chunks.map { DeterministicPolisher.Chunk(text: $0.text, start: $0.start, end: $0.end) }
        }

        /// Chunk joins — the positions the interior rule is asked about. One fewer than the chunks,
        /// and zero for a single-chunk recording, which contributes nothing to the interior class.
        var joins: Int { max(0, chunks.count - 1) }

        /// The silence at each join, in seconds. Negative values are possible in principle if the
        /// decoder ever emitted overlapping spans; `selftest.py` rejects a corpus containing any,
        /// so a negative reaching a metric here means the corpus was hand-edited.
        var pauses: [TimeInterval] {
            zip(chunks, chunks.dropFirst()).map { $1.start - $0.end }
        }
    }

    private struct Payload: Decodable {
        let records: [Record]
    }

    /// Empty when the file is absent — the caller skips rather than fails, so a machine that has
    /// never run the dump can still run the rest of the polish suites.
    static func records() -> [Record] {
        let url = AuthoredGold.evalDirectory.appendingPathComponent("chunk-corpus.json")
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return payload.records
    }
}
