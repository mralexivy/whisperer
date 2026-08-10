//
//  MeetingRAGEngine.swift
//  Whisperer
//
//  Wax-based semantic indexing and retrieval for meeting transcripts.
//  One .wax file per meeting UUID, stored alongside audio in the Meetings dir.
//

import Foundation
import Wax
import WaxVectorSearchMiniLM

// MARK: - Chunk value type

struct RAGChunk: Codable, Equatable {
    let text: String
    let startTimestamp: Double
    let endTimestamp: Double
    let speakers: [String]
    var score: Float

    var formattedStart: String {
        let s = Int(startTimestamp)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var speakersLabel: String {
        speakers.isEmpty ? "Speaker" : speakers.joined(separator: ", ")
    }
}

// MARK: - Engine

actor MeetingRAGEngine {
    static let shared = MeetingRAGEngine()

    // Cache open Memory handles so we don't reopen on every search
    private var openMemories: [UUID: Memory] = [:]

    private static var meetingsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Whisperer/Meetings", isDirectory: true)
    }

    private init() {}

    // MARK: - Public API

    /// Synchronous existence check — no async needed by callers.
    nonisolated func isIndexed(_ meetingID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: waxURL(for: meetingID).path)
    }

    /// Build or rebuild the vector index for a meeting.
    func index(meetingID: UUID, segments: [MeetingSegment]) async throws {
        guard !segments.isEmpty else { return }

        let url = waxURL(for: meetingID)

        // Close and evict any cached handle for this meeting before deleting
        if let existing = openMemories[meetingID] {
            try? await existing.close()
            openMemories[meetingID] = nil
        }
        try? FileManager.default.removeItem(at: url)

        let memory = try await Memory(
            at: url,
            builtInEmbedding: .miniLM
        )

        let chunks = makeChunks(from: segments)
        for chunk in chunks {
            let metadata: [String: String] = [
                "start":    String(chunk.startTimestamp),
                "end":      String(chunk.endTimestamp),
                "speakers": chunk.speakers.joined(separator: ",")
            ]
            try await memory.save(chunk.text, metadata: metadata)
        }

        try await memory.flush()
        openMemories[meetingID] = memory

        Logger.info("Meeting \(meetingID) indexed: \(chunks.count) chunks", subsystem: .transcription)
    }

    /// Retrieve the most semantically relevant chunks for a question.
    func retrieve(question: String, meetingID: UUID, limit: Int = 8) async throws -> [RAGChunk] {
        let memory = try await openOrLoad(meetingID: meetingID)

        var opts = Memory.SearchOptions.default
        opts.topK = limit

        let results = try await memory.search(question, options: opts)

        return results.items.map { item in
            let start   = Double(item.metadata["start"] ?? "0") ?? 0
            let end     = Double(item.metadata["end"]   ?? "0") ?? 0
            let speakerList = (item.metadata["speakers"] ?? "")
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return RAGChunk(
                text:           item.text,
                startTimestamp: start,
                endTimestamp:   end,
                speakers:       speakerList,
                score:          item.score
            )
        }
    }

    /// Remove the vector index for a meeting (called on meeting delete).
    func deleteIndex(_ meetingID: UUID) async {
        if let mem = openMemories[meetingID] {
            try? await mem.close()
            openMemories[meetingID] = nil
        }
        try? FileManager.default.removeItem(at: waxURL(for: meetingID))
    }

    // MARK: - Private

    private func openOrLoad(meetingID: UUID) async throws -> Memory {
        if let cached = openMemories[meetingID] { return cached }
        let memory = try await Memory(at: waxURL(for: meetingID), builtInEmbedding: .miniLM)
        openMemories[meetingID] = memory
        return memory
    }

    nonisolated private func waxURL(for meetingID: UUID) -> URL {
        Self.meetingsDir.appendingPathComponent("\(meetingID).wax")
    }

    /// Groups consecutive segments into ≤60-second semantic blocks.
    /// The last segment of each chunk is carried into the next (boundary overlap).
    private func makeChunks(from segments: [MeetingSegment]) -> [RAGChunk] {
        guard !segments.isEmpty else { return [] }

        let windowSeconds: Double = 60
        var chunks: [RAGChunk] = []

        var texts:   [String] = []
        var speakers: Set<String> = []
        var windowStart = segments[0].timestamp
        var windowEnd   = segments[0].endTimestamp
        var lastSeg: MeetingSegment? = nil

        func flush() {
            guard !texts.isEmpty else { return }
            chunks.append(RAGChunk(
                text:           texts.joined(separator: " "),
                startTimestamp: windowStart,
                endTimestamp:   windowEnd,
                speakers:       Array(speakers).sorted(),
                score:          0
            ))
        }

        for seg in segments {
            if seg.timestamp - windowStart > windowSeconds, !texts.isEmpty {
                flush()
                // Overlap: restart with the last segment of the previous chunk
                texts    = lastSeg.map { [$0.text] } ?? []
                speakers = lastSeg.map { [$0.speakerName] } ?? []
                windowStart = lastSeg?.timestamp ?? seg.timestamp
                windowEnd   = lastSeg?.endTimestamp ?? seg.timestamp
            }
            texts.append(seg.text)
            speakers.insert(seg.speakerName)
            windowEnd = seg.endTimestamp
            lastSeg   = seg
        }

        flush()
        return chunks
    }
}
