//
//  WhisperBridge.swift
//  Whisperer
//
//  Swift wrapper for whisper.cpp C library
//

import Foundation

enum WhisperError: Error, LocalizedError {
    case modelLoadFailed
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed:
            return "Failed to load Whisper model"
        case .transcriptionFailed:
            return "Transcription failed"
        }
    }
}

class WhisperBridge {
    private var ctx: OpaquePointer?
    private let modelPath: URL
    private let queue = DispatchQueue(label: "whisper.transcribe", qos: .userInteractive)
    private let ctxLock = NSLock()

    init(modelPath: URL) throws {
        self.modelPath = modelPath
        try loadModel()
    }

    private func loadModel() throws {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        cparams.flash_attn = true

        ctx = whisper_init_from_file_with_params(
            modelPath.path,
            cparams
        )

        guard ctx != nil else {
            throw WhisperError.modelLoadFailed
        }

        print("Whisper model loaded: \(modelPath.lastPathComponent)")
    }

    /// Transcribe audio samples (16kHz mono float32)
    /// - Parameters:
    ///   - samples: Audio samples in float32 format at 16kHz
    ///   - initialPrompt: Optional context from previous transcription to improve continuity
    /// - Returns: Transcribed text
    func transcribe(samples: [Float], initialPrompt: String? = nil) -> String {
        ctxLock.lock()
        defer { ctxLock.unlock() }

        guard let ctx = ctx else {
            print("⚠️ Whisper context is nil, cannot transcribe")
            return ""
        }
        guard !samples.isEmpty else { return "" }

        var wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        wparams.print_progress = false
        wparams.print_special = false
        wparams.print_realtime = false
        wparams.print_timestamps = false
        wparams.single_segment = false  // Allow multiple segments for full transcription
        wparams.no_timestamps = true
        wparams.n_threads = Int32(ProcessInfo.processInfo.activeProcessorCount)

        // Set language to NULL for auto-detection
        wparams.language = nil

        // Context carrying: use previous transcription as prompt for better continuity
        if let prompt = initialPrompt, !prompt.isEmpty {
            wparams.no_context = false  // Enable context usage
            // Note: initial_prompt is a C string pointer that must remain valid during transcription
            // We use withCString to ensure proper memory management
        } else {
            wparams.no_context = true
        }

        // Perform transcription, handling initial_prompt if provided
        let result: Int32
        if let prompt = initialPrompt, !prompt.isEmpty {
            result = prompt.withCString { promptPtr in
                wparams.initial_prompt = promptPtr
                return samples.withUnsafeBufferPointer { ptr -> Int32 in
                    return whisper_full(ctx, wparams, ptr.baseAddress, Int32(samples.count))
                }
            }
        } else {
            result = samples.withUnsafeBufferPointer { ptr -> Int32 in
                return whisper_full(ctx, wparams, ptr.baseAddress, Int32(samples.count))
            }
        }

        if result != 0 {
            print("Whisper transcription failed with code: \(result)")
            return ""
        }

        var text = ""
        let nSegments = whisper_full_n_segments(ctx)
        for i in 0..<nSegments {
            if let segmentText = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: segmentText)
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transcribe asynchronously with optional context prompt
    /// - Parameters:
    ///   - samples: Audio samples in float32 format at 16kHz
    ///   - initialPrompt: Optional context from previous transcription
    ///   - completion: Called on background queue with transcription result
    func transcribeAsync(samples: [Float], initialPrompt: String? = nil, completion: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let text = self.transcribe(samples: samples, initialPrompt: initialPrompt)
            // Call completion directly on background queue to avoid blocking main thread
            completion(text)
        }
    }

    deinit {
        ctxLock.lock()
        defer { ctxLock.unlock() }

        if let ctx = ctx {
            whisper_free(ctx)
            print("Whisper context freed")
        }
    }
}
