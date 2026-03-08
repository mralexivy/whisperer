//
//  ChunkSizeExperimentTests.swift
//  WhispererTests
//
//  Determines optimal chunk size for VAD-based chunked transcription.
//  Tests speed (RTF) and quality at different chunk durations.
//

import XCTest
@testable import whisperer

final class ChunkSizeExperimentTests: XCTestCase {

    // Shared bridge — avoids Metal dealloc race when WhisperBridge goes out of scope
    private static var _bridge: WhisperBridge?

    private func loadWhisperBridge() throws -> WhisperBridge {
        if let bridge = Self._bridge { return bridge }
        let models: [WhisperModel] = [.largeTurbo, .largeTurboQ5, .medium, .small, .base, .tiny]
        for model in models {
            let path = ModelDownloader.shared.modelPath(for: model)
            if FileManager.default.fileExists(atPath: path.path) {
                let bridge = try WhisperBridge(modelPath: path)
                Self._bridge = bridge
                return bridge
            }
        }
        throw XCTSkip("No whisper model downloaded")
    }

    private func timeMs(_ block: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    // MARK: - Chunk Size RTF Comparison

    /// Transcribe 30s of audio as a single chunk vs split into smaller chunks.
    /// Measures RTF and word count at each chunk size to find the sweet spot.
    func testChunkSizeRTF() throws {
        let bridge = try loadWhisperBridge()
        let fullSamples = BenchmarkUtilities.generateTestAudio(duration: .thirtySeconds)
        let sampleRate = 16000

        // Warmup
        _ = bridge.transcribe(
            samples: Array(fullSamples.prefix(16000)),
            initialPrompt: nil, language: .english,
            singleSegment: false, maxTokens: 0
        )

        let chunkDurations = [3.0, 5.0, 10.0, 15.0, 30.0]
        var summary = "=== Chunk Size RTF Results ===\n"

        for chunkDur in chunkDurations {
            let chunkSamples = Int(chunkDur * Double(sampleRate))
            var totalMs: Double = 0
            var totalWords = 0
            var chunkCount = 0
            var prevText = ""

            var offset = 0
            while offset < fullSamples.count {
                let end = min(offset + chunkSamples, fullSamples.count)
                let chunk = Array(fullSamples[offset..<end])
                let prompt = prevText.isEmpty ? nil : String(prevText.suffix(100))

                var text = ""
                let ms = timeMs {
                    text = bridge.transcribe(
                        samples: chunk,
                        initialPrompt: prompt,
                        language: .english,
                        singleSegment: false,
                        maxTokens: 0
                    )
                }

                totalMs += ms
                totalWords += text.split(separator: " ").count
                chunkCount += 1
                prevText = text
                offset = end
            }

            let rtf = (totalMs / 1000.0) / 30.0
            let line = "chunk=\(String(format: "%.0f", chunkDur))s: \(String(format: "%.0f", totalMs))ms total, RTF=\(String(format: "%.3f", rtf)), \(chunkCount) chunks, \(totalWords) words"
            summary += line + "\n"
            XCTAssertLessThan(rtf, 1.0, line)
        }

        let attachment = XCTAttachment(string: summary)
        attachment.name = "Chunk Size RTF Results"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Single Chunk Latency by Size

    /// Measures per-chunk transcription latency at different sizes.
    /// Key metric: how fast does ONE chunk process?
    func testSingleChunkLatency() throws {
        let bridge = try loadWhisperBridge()

        // Warmup
        let warmup = BenchmarkUtilities.generateTestAudio(duration: .fiveSeconds)
        _ = bridge.transcribe(
            samples: Array(warmup.prefix(16000)),
            initialPrompt: nil, language: .english,
            singleSegment: false, maxTokens: 0
        )

        let durations = [2.0, 3.0, 5.0, 10.0, 15.0, 20.0, 25.0, 30.0]
        var summary = "=== Single Chunk Latency Results ===\n"

        for dur in durations {
            let audio = generateAudio(seconds: dur)

            var text = ""
            let ms = timeMs {
                text = bridge.transcribe(
                    samples: audio,
                    initialPrompt: nil,
                    language: .english,
                    singleSegment: false,
                    maxTokens: 0
                )
            }

            let rtf = (ms / 1000.0) / dur
            let words = text.split(separator: " ").count
            let line = "\(String(format: "%.0f", dur))s chunk: \(String(format: "%.0f", ms))ms, RTF=\(String(format: "%.3f", rtf)), \(words) words"
            summary += line + "\n"
            XCTAssertLessThan(rtf, 1.0, line)
        }

        let attachment = XCTAttachment(string: summary)
        attachment.name = "Single Chunk Latency Results"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Real-Time Pipeline Simulation

    /// Simulates a real user recording: audio arrives in real-time, chunks are
    /// transcribed IN PARALLEL with recording. Measures what the user actually
    /// waits for after they stop speaking (only the tail chunk).
    ///
    /// Old pipeline (re-transcribe all): wait = transcribe(ALL_AUDIO)
    /// New pipeline (chunked):           wait = transcribe(TAIL_ONLY)
    ///
    /// For a 30s recording with 20s chunks:
    /// - Old: re-transcribes 30s of audio → ~750ms wait
    /// - But old did this every 1.5s during recording too, O(n²) total work
    /// - New: first 20s chunk transcribed WHILE recording, only ~10s tail on stop → ~730ms wait
    /// - Total work: 2 chunks × ~730ms = ~1460ms vs old's cumulative re-transcriptions
    func testRealTimeChunkedPipeline() throws {
        let bridge = try loadWhisperBridge()
        let sampleRate = 16000

        // Warmup
        _ = bridge.transcribe(
            samples: Array(generateAudio(seconds: 1.0).prefix(16000)),
            initialPrompt: nil, language: .english,
            singleSegment: false, maxTokens: 0
        )

        let recordingDuration = 30.0
        let fullAudio = generateAudio(seconds: recordingDuration)
        let chunkDuration = 20.0
        let chunkSamples = Int(chunkDuration * Double(sampleRate))

        var summary = "=== Real-Time Pipeline Simulation (\(Int(recordingDuration))s recording) ===\n"

        // --- Simulate NEW chunked pipeline ---
        // Chunk 1 (0-20s) transcribed while user is still talking (overlapped with recording)
        // When user stops at 30s, only tail (20-30s) needs processing
        let chunk1 = Array(fullAudio[0..<chunkSamples])
        let tailStart = chunkSamples
        let tail = Array(fullAudio[tailStart..<fullAudio.count])
        let tailDuration = Double(tail.count) / Double(sampleRate)

        // Time chunk1 (happens during recording — user doesn't wait for this)
        var chunk1Text = ""
        let chunk1Ms = timeMs {
            chunk1Text = bridge.transcribe(
                samples: chunk1, initialPrompt: nil,
                language: .english, singleSegment: false, maxTokens: 0
            )
        }

        // Time tail (this is what the user waits for on stop)
        let tailMs = timeMs {
            _ = bridge.transcribe(
                samples: tail,
                initialPrompt: chunk1Text.isEmpty ? nil : String(chunk1Text.suffix(100)),
                language: .english, singleSegment: false, maxTokens: 0
            )
        }

        summary += "NEW pipeline (chunked, parallel with recording):\n"
        summary += "  Chunk 1 (\(Int(chunkDuration))s): \(String(format: "%.0f", chunk1Ms))ms — transcribed DURING recording, user doesn't wait\n"
        summary += "  Tail (\(String(format: "%.0f", tailDuration))s): \(String(format: "%.0f", tailMs))ms — user waits for THIS only\n"
        summary += "  User wait on stop: \(String(format: "%.0f", tailMs))ms\n\n"

        // --- Simulate OLD pipeline for comparison ---
        // Old pipeline: on stop, re-transcribes ALL 30s of audio
        let oldMs = timeMs {
            _ = bridge.transcribe(
                samples: fullAudio, initialPrompt: nil,
                language: .english, singleSegment: false, maxTokens: 0
            )
        }

        // Old pipeline also did O(n²) work during recording:
        // At 1.5s intervals, it re-transcribed ALL accumulated audio
        // Simulate: transcribe at 5s, 10s, 15s, 20s, 25s, 30s (every 5s for speed)
        var oldTotalWorkMs: Double = 0
        let checkpoints = stride(from: 5, through: Int(recordingDuration), by: 5)
        for checkpoint in checkpoints {
            let partialAudio = Array(fullAudio[0..<(checkpoint * sampleRate)])
            let ms = timeMs {
                _ = bridge.transcribe(
                    samples: partialAudio, initialPrompt: nil,
                    language: .english, singleSegment: false, maxTokens: 0
                )
            }
            oldTotalWorkMs += ms
        }

        summary += "OLD pipeline (re-transcribe everything):\n"
        summary += "  Final re-transcription (all \(Int(recordingDuration))s): \(String(format: "%.0f", oldMs))ms — user waits for THIS\n"
        summary += "  Total GPU work during recording (sampled at 5s intervals): \(String(format: "%.0f", oldTotalWorkMs))ms\n"
        summary += "  (Real old pipeline re-transcribed every 1.5s — even more work)\n\n"

        summary += "COMPARISON:\n"
        summary += "  User wait on stop: NEW=\(String(format: "%.0f", tailMs))ms vs OLD=\(String(format: "%.0f", oldMs))ms\n"
        summary += "  Total GPU work: NEW=\(String(format: "%.0f", chunk1Ms + tailMs))ms (2 chunks) vs OLD=\(String(format: "%.0f", oldTotalWorkMs + oldMs))ms (repeated full passes)\n"

        let attachment = XCTAttachment(string: summary)
        attachment.name = "Real-Time Pipeline Simulation"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Surface results in test output
        XCTAssertLessThan(tailMs, 2000,
            "Tail transcription took \(String(format: "%.0f", tailMs))ms — should be < 2s for \(String(format: "%.0f", tailDuration))s of audio")
        // Force summary into assertion message so it's visible in xcodebuild output
        XCTAssertTrue(true, summary)
        try writeResultsFile(name: "pipeline-simulation", content: summary)
    }

    // MARK: - Quality: Chunked vs Single-Pass Output

    /// Transcribes the same audio as single-pass (30s) and chunked (20s chunks),
    /// then compares the output. Both should produce similar text.
    /// Uses real audio if available, falls back to synthetic.
    func testChunkedQualityMatchesSinglePass() throws {
        let bridge = try loadWhisperBridge()
        let sampleRate = 16000
        let chunkDuration = 20.0
        let chunkSamples = Int(chunkDuration * Double(sampleRate))

        // Warmup
        _ = bridge.transcribe(
            samples: Array(generateAudio(seconds: 1.0).prefix(16000)),
            initialPrompt: nil, language: .english,
            singleSegment: false, maxTokens: 0
        )

        // Try real audio first, fall back to synthetic
        let audio: [Float]
        let audioSource: String
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let recordingsDir = appSupport.appendingPathComponent("Whisperer/Recordings")
        if FileManager.default.fileExists(atPath: recordingsDir.path),
           let files = try? FileManager.default.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: nil),
           let wavFile = files.first(where: { $0.pathExtension.lowercased() == "wav" }),
           let realSamples = BenchmarkUtilities.loadSamplesFromRecording(at: wavFile),
           Double(realSamples.count) / Double(sampleRate) >= 25.0 {
            // Use up to 60s of real audio
            let maxSamples = 60 * sampleRate
            audio = realSamples.count > maxSamples ? Array(realSamples.prefix(maxSamples)) : realSamples
            audioSource = "real (\(wavFile.lastPathComponent))"
        } else {
            audio = generateAudio(seconds: 30.0)
            audioSource = "synthetic"
        }

        let audioDuration = Double(audio.count) / Double(sampleRate)
        var summary = "=== Quality: Chunked vs Single-Pass ===\n"
        summary += "Audio: \(audioSource), \(String(format: "%.1f", audioDuration))s\n\n"

        // --- Single-pass baseline ---
        let singlePassText = bridge.transcribe(
            samples: audio, initialPrompt: nil,
            language: .english, singleSegment: false, maxTokens: 0
        )

        // --- Chunked pipeline (simulating real pipeline behavior) ---
        var chunkedTexts: [String] = []
        var offset = 0
        while offset < audio.count {
            let end = min(offset + chunkSamples, audio.count)
            let chunk = Array(audio[offset..<end])
            let prompt = chunkedTexts.last.flatMap { $0.isEmpty ? nil : String($0.suffix(100)) }

            let text = bridge.transcribe(
                samples: chunk, initialPrompt: prompt,
                language: .english, singleSegment: false, maxTokens: 0
            )
            chunkedTexts.append(text)
            offset = end
        }

        // Stitch with deduplication (same as real pipeline)
        var stitchedText = ""
        for text in chunkedTexts {
            if stitchedText.isEmpty {
                stitchedText = text
            } else {
                let deduped = VADSegmenter.deduplicateOverlap(previousText: stitchedText, newText: text)
                if !deduped.isEmpty {
                    stitchedText += " " + deduped
                }
            }
        }

        summary += "Single-pass (\(chunkedTexts.count == 1 ? "same" : "baseline")):\n"
        summary += "  \"\(singlePassText.prefix(200))\"\n"
        summary += "  Words: \(singlePassText.split(separator: " ").count)\n\n"
        summary += "Chunked (\(chunkedTexts.count) chunks × \(Int(chunkDuration))s):\n"
        summary += "  \"\(stitchedText.prefix(200))\"\n"
        summary += "  Words: \(stitchedText.split(separator: " ").count)\n\n"

        // --- Compare quality ---
        let singleWords = Set(singlePassText.lowercased().split(separator: " ").map(String.init))
        let chunkedWords = Set(stitchedText.lowercased().split(separator: " ").map(String.init))

        // Word overlap: what fraction of single-pass words appear in chunked output
        let commonWords = singleWords.intersection(chunkedWords)
        let overlapRatio = singleWords.isEmpty ? 1.0 : Double(commonWords.count) / Double(singleWords.count)

        // Word count similarity: are they roughly the same length
        let singleCount = singlePassText.split(separator: " ").count
        let chunkedCount = stitchedText.split(separator: " ").count
        let countRatio = singleCount == 0 ? 1.0 : Double(chunkedCount) / Double(singleCount)

        summary += "QUALITY COMPARISON:\n"
        summary += "  Word overlap: \(String(format: "%.0f%%", overlapRatio * 100)) (\(commonWords.count)/\(singleWords.count) words match)\n"
        summary += "  Word count ratio: \(String(format: "%.2f", countRatio))x (single=\(singleCount), chunked=\(chunkedCount))\n"

        // Words only in one output (differences)
        let onlyInSingle = singleWords.subtracting(chunkedWords)
        let onlyInChunked = chunkedWords.subtracting(singleWords)
        if !onlyInSingle.isEmpty {
            summary += "  Only in single-pass: \(onlyInSingle.sorted().prefix(10).joined(separator: ", "))\n"
        }
        if !onlyInChunked.isEmpty {
            summary += "  Only in chunked: \(onlyInChunked.sorted().prefix(10).joined(separator: ", "))\n"
        }

        let attachment = XCTAttachment(string: summary)
        attachment.name = "Quality: Chunked vs Single-Pass"
        attachment.lifetime = .keepAlways
        add(attachment)
        try writeResultsFile(name: "quality-comparison", content: summary)

        // For real audio, word overlap should be high (>60%)
        // For synthetic audio (noise), both outputs may be empty or hallucinated — that's fine
        if audioSource.hasPrefix("real") {
            XCTAssertGreaterThan(overlapRatio, 0.6,
                "Chunked output should share >60% words with single-pass. Got \(String(format: "%.0f%%", overlapRatio * 100))")
            XCTAssertGreaterThan(countRatio, 0.5, "Chunked should produce at least 50% as many words")
            XCTAssertLessThan(countRatio, 2.0, "Chunked should not produce >2x as many words (hallucination)")
        }
    }

    // MARK: - Quality with Real Audio Recordings

    /// Tests chunked vs single-pass quality using REAL speech recordings.
    /// Loads longest recordings from app history, transcribes both ways,
    /// compares word overlap and flags any quality loss.
    func testQualityWithRealRecordings() throws {
        let bridge = try loadWhisperBridge()
        let sampleRate = 16000
        let chunkDuration = 20.0
        let chunkSamples = Int(chunkDuration * Double(sampleRate))

        // Warmup
        _ = bridge.transcribe(
            samples: Array(generateAudio(seconds: 1.0).prefix(16000)),
            initialPrompt: nil, language: .english,
            singleSegment: false, maxTokens: 0
        )

        // Find recordings in both sandbox and non-sandbox locations
        let searchDirs = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/com.ivy.whisperer/Data/Library/Application Support/Whisperer/Recordings"),
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Whisperer/Recordings"),
        ]

        var wavFiles: [(url: URL, duration: Double)] = []
        for dir in searchDirs {
            guard FileManager.default.fileExists(atPath: dir.path),
                  let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension.lowercased() == "wav" {
                let name = file.lastPathComponent
                if name.contains("BLANK") { continue }
                guard let samples = BenchmarkUtilities.loadSamplesFromRecording(at: file) else { continue }
                let dur = Double(samples.count) / Double(sampleRate)
                if dur >= 10.0 {
                    wavFiles.append((url: file, duration: dur))
                }
            }
        }

        // Sort by duration descending, take top 5
        wavFiles.sort { $0.duration > $1.duration }
        let testFiles = Array(wavFiles.prefix(5))

        guard !testFiles.isEmpty else {
            throw XCTSkip("No real recordings >= 10s found")
        }

        var summary = "=== Quality: Chunked vs Single-Pass (Real Audio) ===\n"
        summary += "Chunk size: \(Int(chunkDuration))s\n"
        summary += "Testing \(testFiles.count) recordings\n\n"

        var allOverlaps: [Double] = []

        for (idx, file) in testFiles.enumerated() {
            guard let samples = BenchmarkUtilities.loadSamplesFromRecording(at: file.url) else { continue }
            let name = file.url.lastPathComponent
            summary += "--- Recording \(idx + 1): \(name) (\(String(format: "%.1f", file.duration))s) ---\n"

            // Single-pass baseline
            let singleText = bridge.transcribe(
                samples: samples, initialPrompt: nil,
                language: .english, singleSegment: false, maxTokens: 0
            )

            // Chunked pipeline
            var chunkedTexts: [String] = []
            var offset = 0
            while offset < samples.count {
                let end = min(offset + chunkSamples, samples.count)
                let chunk = Array(samples[offset..<end])
                let prompt = chunkedTexts.last.flatMap { $0.isEmpty ? nil : String($0.suffix(100)) }
                let text = bridge.transcribe(
                    samples: chunk, initialPrompt: prompt,
                    language: .english, singleSegment: false, maxTokens: 0
                )
                chunkedTexts.append(text)
                offset = end
            }

            // Stitch with deduplication
            var stitchedText = ""
            for text in chunkedTexts {
                if stitchedText.isEmpty {
                    stitchedText = text
                } else {
                    let deduped = VADSegmenter.deduplicateOverlap(previousText: stitchedText, newText: text)
                    if !deduped.isEmpty {
                        stitchedText += " " + deduped
                    }
                }
            }

            // Compare
            let singleWords = Set(singleText.lowercased().split(separator: " ").map(String.init))
            let chunkedWords = Set(stitchedText.lowercased().split(separator: " ").map(String.init))
            let commonWords = singleWords.intersection(chunkedWords)
            let overlap = singleWords.isEmpty ? 1.0 : Double(commonWords.count) / Double(singleWords.count)
            allOverlaps.append(overlap)

            let singleCount = singleText.split(separator: " ").count
            let chunkedCount = stitchedText.split(separator: " ").count

            summary += "  Single-pass: \"\(singleText.prefix(120))...\"\n"
            summary += "  Chunked (\(chunkedTexts.count) chunks): \"\(stitchedText.prefix(120))...\"\n"
            summary += "  Word overlap: \(String(format: "%.0f%%", overlap * 100)) (\(commonWords.count)/\(singleWords.count))"
            summary += " | Words: single=\(singleCount), chunked=\(chunkedCount)\n"

            let onlyInSingle = singleWords.subtracting(chunkedWords)
            let onlyInChunked = chunkedWords.subtracting(singleWords)
            if !onlyInSingle.isEmpty {
                summary += "  Lost words: \(onlyInSingle.sorted().prefix(8).joined(separator: ", "))\n"
            }
            if !onlyInChunked.isEmpty {
                summary += "  Extra words: \(onlyInChunked.sorted().prefix(8).joined(separator: ", "))\n"
            }
            summary += "\n"
        }

        let avgOverlap = allOverlaps.isEmpty ? 0 : allOverlaps.reduce(0, +) / Double(allOverlaps.count)
        let minOverlap = allOverlaps.min() ?? 0
        summary += "=== SUMMARY ===\n"
        summary += "Average word overlap: \(String(format: "%.0f%%", avgOverlap * 100))\n"
        summary += "Minimum word overlap: \(String(format: "%.0f%%", minOverlap * 100))\n"
        summary += "Recordings tested: \(testFiles.count)\n"

        let attachment = XCTAttachment(string: summary)
        attachment.name = "Quality: Real Audio Recordings"
        attachment.lifetime = .keepAlways
        add(attachment)
        try writeResultsFile(name: "quality-real-audio", content: summary)

        // Average overlap should be > 60% across all recordings
        XCTAssertGreaterThan(avgOverlap, 0.6,
            "Average word overlap \(String(format: "%.0f%%", avgOverlap * 100)) should be > 60%")
        // No recording should drop below 40%
        XCTAssertGreaterThan(minOverlap, 0.4,
            "Minimum word overlap \(String(format: "%.0f%%", minOverlap * 100)) should be > 40%")
    }

    // MARK: - Scaling: Old vs New at Different Recording Lengths

    /// Shows how OLD (re-transcribe all) scales vs NEW (chunked) at increasing durations.
    /// OLD: total work grows O(n²) because each cycle re-transcribes everything.
    /// NEW: total work grows O(n) because each chunk is transcribed once.
    func testScalingOldVsNew() throws {
        let bridge = try loadWhisperBridge()
        let sampleRate = 16000

        // Warmup
        _ = bridge.transcribe(
            samples: Array(generateAudio(seconds: 1.0).prefix(16000)),
            initialPrompt: nil, language: .english,
            singleSegment: false, maxTokens: 0
        )

        let durations = [10.0, 20.0, 30.0, 60.0]
        let chunkSize = 20.0
        var summary = "=== Scaling: Old vs New Pipeline ===\n"
        summary += "Chunk size: \(Int(chunkSize))s\n\n"

        for dur in durations {
            let audio = generateAudio(seconds: dur)

            // NEW pipeline: count of chunks × per-chunk cost
            let numChunks = Int(ceil(dur / chunkSize))
            // Only measure one chunk (they all cost ~same due to fixed encoder)
            let oneChunk = Array(audio.prefix(Int(chunkSize * Double(sampleRate))))
            let oneChunkMs = timeMs {
                _ = bridge.transcribe(
                    samples: oneChunk, initialPrompt: nil,
                    language: .english, singleSegment: false, maxTokens: 0
                )
            }
            let newTotalMs = oneChunkMs * Double(numChunks)
            // User wait = just the tail chunk
            let newWaitMs = oneChunkMs

            // OLD pipeline: simulated re-transcription at intervals
            // Each cycle transcribes ALL audio accumulated so far
            // Cost per cycle ≈ same (~730ms) but in reality grows with audio length
            let fullPassMs = timeMs {
                _ = bridge.transcribe(
                    samples: audio, initialPrompt: nil,
                    language: .english, singleSegment: false, maxTokens: 0
                )
            }
            let numCycles = Int(dur / 1.5) // old pipeline ran every 1.5s
            // Old total work = numCycles × fullPassCost (approximation — each cycle processed more audio)
            let oldTotalMs = fullPassMs * Double(numCycles)

            let line = "\(Int(dur))s recording: NEW=\(numChunks) chunks, \(String(format: "%.0f", newTotalMs))ms total work, \(String(format: "%.0f", newWaitMs))ms wait | OLD=\(numCycles) cycles × full pass, ~\(String(format: "%.0f", oldTotalMs))ms total work, \(String(format: "%.0f", fullPassMs))ms wait"
            summary += line + "\n"
        }

        summary += "\nKey insight: NEW total work = O(n), OLD total work = O(n²)\n"
        summary += "NEW wait on stop = 1 chunk (~730ms), OLD wait = 1 full pass (~730ms for short, grows for long)\n"
        summary += "But OLD burns GPU continuously during recording, causing lock contention and timeouts\n"

        let attachment = XCTAttachment(string: summary)
        attachment.name = "Scaling: Old vs New Pipeline"
        attachment.lifetime = .keepAlways
        add(attachment)
        try writeResultsFile(name: "scaling-comparison", content: summary)
    }

    // MARK: - Hallucination Check by Chunk Size

    /// Shorter chunks may produce more hallucinations on synthetic audio.
    /// Count hallucination patterns at each chunk size.
    func testHallucinationByChunkSize() throws {
        let bridge = try loadWhisperBridge()

        let chunkDurations = [3.0, 5.0, 10.0, 30.0]
        let hallucinationPatterns = [
            "thank you", "thanks for watching", "subscribe",
            "like and subscribe", "please subscribe",
            "thank you for listening", "see you next time",
        ]
        var summary = "=== Hallucination Results ===\n"

        for dur in chunkDurations {
            let audio = generateAudio(seconds: dur)
            let text = bridge.transcribe(
                samples: audio,
                initialPrompt: nil,
                language: .english,
                singleSegment: false,
                maxTokens: 0
            ).lowercased()

            let hallucinationCount = hallucinationPatterns.filter { text.contains($0) }.count
            let line = "\(String(format: "%.0f", dur))s chunk: \(hallucinationCount) hallucinations in '\(text.prefix(100))'"
            summary += line + "\n"
            XCTAssertLessThanOrEqual(hallucinationCount, 1, line)
        }

        let attachment = XCTAttachment(string: summary)
        attachment.name = "Hallucination Results"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Real Audio Quality (if available)

    /// If a real WAV recording exists, transcribe it at different chunk sizes
    /// and compare output against the full-recording baseline.
    func testChunkQualityWithRealAudio() throws {
        let bridge = try loadWhisperBridge()
        let sampleRate = 16000

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let recordingsDir = appSupport.appendingPathComponent("Whisperer/Recordings")
        guard FileManager.default.fileExists(atPath: recordingsDir.path),
              let files = try? FileManager.default.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: nil),
              let wavFile = files.first(where: { $0.pathExtension.lowercased() == "wav" }),
              let samples = BenchmarkUtilities.loadSamplesFromRecording(at: wavFile) else {
            throw XCTSkip("No real WAV recording available")
        }

        let audioDuration = Double(samples.count) / Double(sampleRate)
        guard audioDuration >= 10.0 else {
            throw XCTSkip("Recording too short (\(String(format: "%.1f", audioDuration))s), need >= 10s")
        }

        let baseline = bridge.transcribe(
            samples: samples,
            initialPrompt: nil,
            language: .english,
            singleSegment: false,
            maxTokens: 0
        )
        let baselineWords = Set(baseline.lowercased().split(separator: " ").map(String.init))

        let chunkDurations = [5.0, 10.0, 15.0]

        for chunkDur in chunkDurations {
            let chunkSize = Int(chunkDur * Double(sampleRate))
            var allText = ""
            var prevText = ""
            var offset = 0

            while offset < samples.count {
                let end = min(offset + chunkSize, samples.count)
                let chunk = Array(samples[offset..<end])
                let prompt = prevText.isEmpty ? nil : String(prevText.suffix(100))

                let text = bridge.transcribe(
                    samples: chunk,
                    initialPrompt: prompt,
                    language: .english,
                    singleSegment: false,
                    maxTokens: 0
                )

                if !allText.isEmpty && !text.isEmpty { allText += " " }
                allText += text
                prevText = text
                offset = end
            }

            let chunkedWords = Set(allText.lowercased().split(separator: " ").map(String.init))
            let commonWords = baselineWords.intersection(chunkedWords)
            let wordOverlap = baselineWords.isEmpty ? 0 : Double(commonWords.count) / Double(baselineWords.count)

            XCTAssertGreaterThan(wordOverlap, 0.5,
                "\(String(format: "%.0f", chunkDur))s chunks: \(String(format: "%.0f%%", wordOverlap * 100)) word overlap with baseline (\(chunkedWords.count) vs \(baselineWords.count) words)")
        }
    }

    // MARK: - Helpers

    private func writeResultsFile(name: String, content: String) throws {
        // Try multiple locations — tests may be sandboxed
        let candidates = [
            URL(fileURLWithPath: "/Users/alexanderi/Downloads/whisperer/\(name).txt"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("\(name).txt"),
            FileManager.default.temporaryDirectory.appendingPathComponent("\(name).txt"),
        ]
        for url in candidates {
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                return
            } catch {
                continue
            }
        }
    }

    private func generateAudio(seconds: Double) -> [Float] {
        let sampleRate = 16000.0
        let count = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        let frequencies: [(freq: Double, amp: Float)] = [
            (250.0, 0.3), (500.0, 0.25), (1000.0, 0.15),
            (1500.0, 0.1), (2500.0, 0.05),
        ]
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let envelope = Float(0.5 + 0.5 * sin(2.0 * .pi * 4.0 * t))
            var sample: Float = 0
            for f in frequencies {
                sample += f.amp * Float(sin(2.0 * .pi * f.freq * t))
            }
            samples[i] = sample * envelope * 0.3 + Float.random(in: -0.02...0.02)
        }
        return samples
    }
}
