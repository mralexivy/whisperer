//
//  VADSegmenter.swift
//  Whisperer
//
//  VAD-based audio chunking for single-pass transcription pipeline.
//  Scans audio with SileroVAD, merges speech segments into bounded chunks,
//  and emits them for sequential transcription.
//

import Foundation

class VADSegmenter {

    struct AudioChunk {
        let startSample: Int          // absolute index in full recording
        let endSample: Int
        let samples: [Float]
        let overlapPrefixSamples: Int // leading samples that overlap with previous chunk
    }

    private let vad: SileroVAD?
    private let sampleRate: Double = 16000.0

    // Chunk size parameters (informed by benchmark: ~730ms encoder cost per chunk)
    let targetChunkDuration: Double       // target seconds per chunk
    let minChunkDuration: Double = 1.0    // minimum seconds to bother transcribing
    let silenceForFinalization: Double     // silence gap to finalize a chunk
    let overlapDuration: Double = 0.3     // overlap between chunks for context

    // Force-split threshold: never exceed this even in continuous speech
    let maxChunkDuration: Double = 30.0

    init(
        vad: SileroVAD?,
        targetChunkDuration: Double = 20.0,
        silenceForFinalization: Double = 0.8
    ) {
        self.vad = vad
        self.targetChunkDuration = targetChunkDuration
        self.silenceForFinalization = silenceForFinalization
    }

    // MARK: - Scan & Emit Chunks

    /// Scan new audio for speech segments and emit finalized chunks.
    ///
    /// - Parameters:
    ///   - allSamples: The full recording buffer
    ///   - fromIndex: Start scanning from this sample index (skip already-scanned audio)
    ///   - lastTranscribedIndex: Last sample that was already transcribed
    /// - Returns: Finalized chunks ready for transcription, and the new scan index
    func scanAndEmitChunks(
        allSamples: [Float],
        fromIndex: Int,
        lastTranscribedIndex: Int
    ) -> (chunks: [AudioChunk], newScanIndex: Int) {
        let totalSamples = allSamples.count

        guard totalSamples > fromIndex else {
            return (chunks: [], newScanIndex: fromIndex)
        }

        // If no VAD available, fall back to time-based chunking
        guard let vad = vad else {
            return timeBasedChunking(
                allSamples: allSamples,
                fromIndex: fromIndex,
                lastTranscribedIndex: lastTranscribedIndex
            )
        }

        // Run VAD on new audio
        let newAudio = Array(allSamples[fromIndex...])
        let segments = vad.detectSpeechSegments(samples: newAudio)

        guard !segments.isEmpty else {
            // No speech found — check if there's enough silence to finalize pending audio
            let silenceDuration = Double(totalSamples - lastTranscribedIndex) / sampleRate
            let audioSinceLastTranscribed = Double(totalSamples - lastTranscribedIndex) / sampleRate

            // If we have untranscribed audio AND enough trailing silence, emit it
            if audioSinceLastTranscribed > minChunkDuration && silenceDuration > silenceForFinalization {
                let chunk = makeChunk(
                    allSamples: allSamples,
                    startSample: lastTranscribedIndex,
                    endSample: totalSamples
                )
                return (chunks: [chunk], newScanIndex: totalSamples)
            }

            return (chunks: [], newScanIndex: totalSamples)
        }

        // Convert VAD segments to absolute sample indices
        var absoluteSegments = segments.map { seg -> (start: Int, end: Int) in
            (start: fromIndex + seg.startSample, end: fromIndex + seg.endSample)
        }

        // Merge segments separated by less than silenceForFinalization
        absoluteSegments = mergeCloseSegments(absoluteSegments)

        // Build chunks from merged segments
        var chunks: [AudioChunk] = []
        var chunkStart = lastTranscribedIndex
        var newScanIndex = fromIndex

        for (idx, seg) in absoluteSegments.enumerated() {
            let segEnd = min(seg.end, totalSamples)

            // Check if this segment ends a chunk (followed by silence)
            let silenceAfter: Double
            if idx == absoluteSegments.count - 1 {
                // Last segment: check silence to end of audio
                silenceAfter = Double(totalSamples - segEnd) / sampleRate
            } else {
                // Check gap to next segment
                silenceAfter = Double(absoluteSegments[idx + 1].start - segEnd) / sampleRate
            }

            let chunkDuration = Double(segEnd - chunkStart) / sampleRate

            // Finalize chunk when:
            // 1. Followed by enough silence AND chunk has enough content
            // 2. Chunk exceeds max duration (force split)
            let shouldFinalize = (silenceAfter >= silenceForFinalization && chunkDuration >= minChunkDuration)
                || chunkDuration >= maxChunkDuration

            if shouldFinalize {
                let chunk = makeChunk(
                    allSamples: allSamples,
                    startSample: chunkStart,
                    endSample: segEnd
                )
                chunks.append(chunk)
                chunkStart = segEnd
                newScanIndex = segEnd
            }
        }

        // Update scan index to end of processed audio
        if newScanIndex < totalSamples {
            newScanIndex = totalSamples
        }

        return (chunks: chunks, newScanIndex: newScanIndex)
    }

    // MARK: - Finalize Tail

    /// Create a chunk from remaining untranscribed audio (called on stop).
    func finalizeTail(allSamples: [Float], lastTranscribedIndex: Int) -> AudioChunk? {
        let remaining = allSamples.count - lastTranscribedIndex
        let minSamples = Int(minChunkDuration * sampleRate)

        guard remaining >= minSamples else { return nil }

        return makeChunk(
            allSamples: allSamples,
            startSample: lastTranscribedIndex,
            endSample: allSamples.count
        )
    }

    // MARK: - Helpers

    private func makeChunk(allSamples: [Float], startSample: Int, endSample: Int) -> AudioChunk {
        let overlapSamples = Int(overlapDuration * sampleRate)
        let actualStart = max(0, startSample - overlapSamples)
        let overlapPrefix = startSample - actualStart

        let samples = Array(allSamples[actualStart..<endSample])

        return AudioChunk(
            startSample: startSample,
            endSample: endSample,
            samples: samples,
            overlapPrefixSamples: overlapPrefix
        )
    }

    /// Merge segments separated by less than silenceForFinalization
    private func mergeCloseSegments(_ segments: [(start: Int, end: Int)]) -> [(start: Int, end: Int)] {
        guard !segments.isEmpty else { return [] }

        var merged: [(start: Int, end: Int)] = [segments[0]]
        let minGapSamples = Int(silenceForFinalization * sampleRate)

        for i in 1..<segments.count {
            let gap = segments[i].start - merged[merged.count - 1].end
            if gap < minGapSamples {
                // Merge: extend previous segment to include this one
                merged[merged.count - 1] = (start: merged[merged.count - 1].start, end: segments[i].end)
            } else {
                merged.append(segments[i])
            }
        }

        return merged
    }

    /// Fallback: time-based chunking when VAD is unavailable
    private func timeBasedChunking(
        allSamples: [Float],
        fromIndex: Int,
        lastTranscribedIndex: Int
    ) -> (chunks: [AudioChunk], newScanIndex: Int) {
        let chunkSamples = Int(targetChunkDuration * sampleRate)
        var chunks: [AudioChunk] = []
        var offset = lastTranscribedIndex

        while offset + chunkSamples <= allSamples.count {
            let chunk = makeChunk(
                allSamples: allSamples,
                startSample: offset,
                endSample: offset + chunkSamples
            )
            chunks.append(chunk)
            offset += chunkSamples
        }

        return (chunks: chunks, newScanIndex: allSamples.count)
    }

    /// Deduplicate overlapping text between consecutive chunks
    static func deduplicateOverlap(previousText: String, newText: String) -> String {
        guard !previousText.isEmpty, !newText.isEmpty else { return newText }

        let prevWords = previousText.split(separator: " ").map(String.init)
        let newWords = newText.split(separator: " ").map(String.init)

        guard !prevWords.isEmpty, !newWords.isEmpty else { return newText }

        let maxOverlapWords = min(5, prevWords.count, newWords.count)

        for overlapLen in stride(from: maxOverlapWords, through: 1, by: -1) {
            let prevTail = prevWords.suffix(overlapLen).map { $0.lowercased() }
            let newHead = newWords.prefix(overlapLen).map { $0.lowercased() }

            if prevTail == newHead {
                let remaining = newWords.dropFirst(overlapLen)
                return remaining.joined(separator: " ")
            }
        }

        return newText
    }
}
