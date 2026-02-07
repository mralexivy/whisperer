//
//  SileroVAD.swift
//  Whisperer
//
//  Swift wrapper for whisper.cpp Silero VAD integration
//  Provides voice activity detection to segment audio into speech regions
//

import Foundation

enum VADError: Error, LocalizedError {
    case modelLoadFailed
    case detectionFailed

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed:
            return "Failed to load Silero VAD model"
        case .detectionFailed:
            return "Voice activity detection failed"
        }
    }
}

/// Represents a detected speech segment with start and end times in seconds
struct SpeechSegment {
    let startTime: Float  // Start time in seconds
    let endTime: Float    // End time in seconds

    var duration: Float {
        return endTime - startTime
    }

    /// Convert time to sample index at 16kHz
    var startSample: Int {
        return Int(startTime * 16000)
    }

    var endSample: Int {
        return Int(endTime * 16000)
    }
}

/// Swift wrapper for Silero VAD using whisper.cpp's built-in VAD support
class SileroVAD {
    private var vadCtx: OpaquePointer?
    private let modelPath: URL
    private let queue = DispatchQueue(label: "silero.vad", qos: .userInteractive)
    private let ctxLock = NSLock()

    // VAD parameters - very sensitive for dictation (strongly prefer false positives over missing speech)
    var threshold: Float = 0.15                   // Speech probability threshold (very low = very sensitive)
    var minSpeechDurationMs: Int32 = 50           // Minimum speech duration to be considered valid
    var minSilenceDurationMs: Int32 = 300         // Minimum silence to split segments
    var maxSpeechDurationS: Float = 30.0          // Maximum speech segment before forcing split
    var speechPadMs: Int32 = 100                  // Padding around speech segments (more generous)
    var samplesOverlap: Float = 0.1               // Overlap between segments in seconds

    init(modelPath: URL) throws {
        self.modelPath = modelPath

        // Verify model file exists before attempting to load
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            print("❌ VAD model file does not exist at: \(modelPath.path)")
            throw VADError.modelLoadFailed
        }

        // Check file size to ensure it's not corrupted
        if let attributes = try? FileManager.default.attributesOfItem(atPath: modelPath.path),
           let fileSize = attributes[.size] as? Int64 {
            print("📦 VAD model file size: \(String(format: "%.2f", Double(fileSize) / 1024.0 / 1024.0)) MB")
            // Silero VAD is ~0.88MB, so anything under 500KB is suspicious
            if fileSize < 500_000 {
                print("⚠️ VAD model file seems too small, might be corrupted")
            }
        }

        try loadModel()
    }

    private static var backendsLoaded = false

    private func loadModel() throws {
        print("🔄 Loading Silero VAD from: \(modelPath.path)")

        // Load GGML backends (required before loading any models)
        // This is thread-safe and idempotent
        if !SileroVAD.backendsLoaded {
            print("🔧 Loading GGML backends...")
            ggml_backend_load_all()
            SileroVAD.backendsLoaded = true
            print("✅ GGML backends loaded")
        }

        var params = whisper_vad_default_context_params()
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        // Use CPU only for VAD - Whisper already uses the GPU/Metal backend
        // Using GPU for VAD causes Metal backend conflicts
        params.use_gpu = false

        // Attempt to initialize VAD context
        vadCtx = whisper_vad_init_from_file_with_params(
            modelPath.path,
            params
        )

        guard vadCtx != nil else {
            print("❌ whisper_vad_init_from_file_with_params returned NULL")
            print("   This likely means:")
            print("   1. VAD support not compiled in whisper.cpp")
            print("   2. Model file is corrupted")
            print("   3. Model format is incompatible")
            throw VADError.modelLoadFailed
        }

        print("✅ Silero VAD model loaded: \(modelPath.lastPathComponent)")
    }

    /// Detect speech segments in audio samples
    /// - Parameter samples: Audio samples in float32 format at 16kHz
    /// - Returns: Array of speech segments with start/end times
    func detectSpeechSegments(samples: [Float]) -> [SpeechSegment] {
        ctxLock.lock()
        defer { ctxLock.unlock() }

        guard let vadCtx = vadCtx else {
            print("VAD context is nil, cannot detect speech")
            return []
        }

        guard !samples.isEmpty else { return [] }

        // Run speech detection on samples
        let success = samples.withUnsafeBufferPointer { ptr -> Bool in
            return whisper_vad_detect_speech(vadCtx, ptr.baseAddress, Int32(samples.count))
        }

        guard success else {
            print("Failed to detect speech in audio")
            return []
        }

        // Get speech segments from detection results
        var vadParams = whisper_vad_default_params()
        vadParams.threshold = threshold
        vadParams.min_speech_duration_ms = minSpeechDurationMs
        vadParams.min_silence_duration_ms = minSilenceDurationMs
        vadParams.max_speech_duration_s = maxSpeechDurationS
        vadParams.speech_pad_ms = speechPadMs
        vadParams.samples_overlap = samplesOverlap

        guard let segments = whisper_vad_segments_from_probs(vadCtx, vadParams) else {
            print("Failed to get VAD segments")
            return []
        }
        defer { whisper_vad_free_segments(segments) }

        var result: [SpeechSegment] = []
        let count = whisper_vad_segments_n_segments(segments)

        for i in 0..<count {
            let t0 = whisper_vad_segments_get_segment_t0(segments, Int32(i))
            let t1 = whisper_vad_segments_get_segment_t1(segments, Int32(i))
            result.append(SpeechSegment(startTime: t0, endTime: t1))
        }

        return result
    }

    /// Check if audio samples contain speech
    /// - Parameter samples: Audio samples at 16kHz
    /// - Returns: True if speech is detected
    func containsSpeech(samples: [Float]) -> Bool {
        let segments = detectSpeechSegments(samples: samples)
        return !segments.isEmpty
    }

    /// Detect speech asynchronously
    func detectSpeechAsync(samples: [Float], completion: @escaping ([SpeechSegment]) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let segments = self.detectSpeechSegments(samples: samples)
            completion(segments)
        }
    }

    /// Get speech probabilities for the last detection
    /// Returns raw probability values for each frame
    func getSpeechProbabilities() -> [Float]? {
        ctxLock.lock()
        defer { ctxLock.unlock() }

        guard let vadCtx = vadCtx else { return nil }

        let count = whisper_vad_n_probs(vadCtx)
        guard count > 0,
              let probsPtr = whisper_vad_probs(vadCtx) else {
            return nil
        }

        return Array(UnsafeBufferPointer(start: probsPtr, count: Int(count)))
    }

    deinit {
        ctxLock.lock()
        defer { ctxLock.unlock() }

        if let vadCtx = vadCtx {
            whisper_vad_free(vadCtx)
            print("Silero VAD context freed")
        }
    }
}

// MARK: - Real-time VAD for streaming

/// Real-time VAD processor for streaming audio
/// Accumulates audio and detects when speech starts/ends
class StreamingVAD {
    private let vad: SileroVAD
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()

    // State tracking
    private var isSpeaking = false
    private var silenceFrames = 0
    private let silenceThreshold = 10  // Number of silence frames before considering speech ended

    // Callbacks
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (([Float]) -> Void)?  // Returns the speech audio

    init(vad: SileroVAD) {
        self.vad = vad
    }

    /// Add audio samples for real-time VAD processing
    /// - Parameter samples: Audio samples at 16kHz
    func addSamples(_ samples: [Float]) {
        bufferLock.lock()
        audioBuffer.append(contentsOf: samples)

        // Process every ~0.5 seconds (8000 samples at 16kHz)
        if audioBuffer.count >= 8000 {
            let chunk = Array(audioBuffer.suffix(8000))
            bufferLock.unlock()

            processChunk(chunk)
        } else {
            bufferLock.unlock()
        }
    }

    private func processChunk(_ chunk: [Float]) {
        let hasSpeech = vad.containsSpeech(samples: chunk)

        if hasSpeech && !isSpeaking {
            // Speech started
            isSpeaking = true
            silenceFrames = 0
            onSpeechStart?()
        } else if !hasSpeech && isSpeaking {
            // Potential speech end
            silenceFrames += 1
            if silenceFrames >= silenceThreshold {
                // Speech ended
                isSpeaking = false
                bufferLock.lock()
                let speechAudio = audioBuffer
                audioBuffer.removeAll()
                bufferLock.unlock()
                onSpeechEnd?(speechAudio)
            }
        } else if hasSpeech {
            // Reset silence counter during speech
            silenceFrames = 0
        }
    }

    /// Reset the streaming VAD state
    func reset() {
        bufferLock.lock()
        audioBuffer.removeAll()
        bufferLock.unlock()
        isSpeaking = false
        silenceFrames = 0
    }

    /// Get current speech state (thread-safe)
    var isCurrentlySpeaking: Bool {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return isSpeaking
    }
}
