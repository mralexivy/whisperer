//
//  WhisperLangDetector.swift
//  Whisperer
//
//  Language detection wrapper over whisper.cpp's whisper_lang_auto_detect
//

import Foundation
import QuartzCore  // CACurrentMediaTime

/// Error thrown when detector initialization fails
enum LangDetectorError: Error, LocalizedError {
    case modelLoadFailed
    case modelNotMultilingual

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed:
            return "Failed to load language detector model"
        case .modelNotMultilingual:
            return "Language detector requires a multilingual model"
        }
    }
}

/// Thin wrapper over whisper.cpp's whisper_lang_auto_detect.
/// Lifecycle managed exclusively by ModelPool — no other type creates or holds this.
final class WhisperLangDetector {
    private var ctx: OpaquePointer?
    private let ctxLock: SafeLock
    private let threads: Int32 = 2  // Lightweight — don't compete with transcription
    private var isShuttingDown = false

    init(modelPath: URL) throws {
        self.ctxLock = SafeLock(defaultTimeout: 5.0)

        var cparams = whisper_context_default_params()
        cparams.use_gpu = true

        ctx = whisper_init_from_file_with_params(modelPath.path, cparams)

        // GPU fallback
        if ctx == nil {
            Logger.warning("Detector GPU init failed, retrying CPU-only", subsystem: .transcription)
            cparams.use_gpu = false
            cparams.flash_attn = false
            ctx = whisper_init_from_file_with_params(modelPath.path, cparams)
        }

        guard ctx != nil else {
            throw LangDetectorError.modelLoadFailed
        }

        // Detector requires a multilingual model
        guard whisper_is_multilingual(ctx!) == 1 else {
            whisper_free(ctx!)
            ctx = nil
            throw LangDetectorError.modelNotMultilingual
        }

        Logger.info("WhisperLangDetector initialized (GPU: \(cparams.use_gpu))", subsystem: .transcription)
    }

    deinit {
        isShuttingDown = true
        do {
            try ctxLock.withLock(timeout: 2.0) { [self] in
                if let ctx = ctx {
                    whisper_free(ctx)
                    Logger.debug("Detector context freed", subsystem: .transcription)
                }
            }
        } catch {
            // Force cleanup
            if let ctx = ctx {
                whisper_free(ctx)
                Logger.warning("Forced detector context cleanup without lock", subsystem: .transcription)
            }
        }
    }

    /// Returns probabilities for all whisper languages, or nil on failure.
    func detect(samples: [Float]) -> [String: Float]? {
        guard !isShuttingDown else { return nil }
        guard !samples.isEmpty else { return nil }

        do {
            let result: [String: Float]? = try ctxLock.withLock(timeout: 5.0) { [self] in
                guard let ctx = ctx else { return [:] }

                let startTime = CACurrentMediaTime()

                // Convert PCM to mel spectrogram
                let melResult = samples.withUnsafeBufferPointer { ptr -> Int32 in
                    whisper_pcm_to_mel(ctx, ptr.baseAddress, Int32(ptr.count), threads)
                }
                guard melResult == 0 else {
                    Logger.error("whisper_pcm_to_mel failed with code \(melResult)", subsystem: .transcription)
                    return [:]
                }

                // Run auto-detection
                let maxId = Int(whisper_lang_max_id())
                var probs = [Float](repeating: 0, count: maxId + 1)

                let topId = probs.withUnsafeMutableBufferPointer { p -> Int32 in
                    whisper_lang_auto_detect(ctx, 0, threads, p.baseAddress)
                }
                guard topId >= 0 else {
                    Logger.error("whisper_lang_auto_detect failed with code \(topId)", subsystem: .transcription)
                    return [:]
                }

                // Map indices to language codes
                var result: [String: Float] = [:]
                for i in 0...maxId {
                    if let langStr = whisper_lang_str(Int32(i)) {
                        let code = String(cString: langStr)
                        let prob = probs[i]
                        if prob > 0.001 {  // Skip near-zero probabilities
                            result[code] = prob
                        }
                    }
                }

                let elapsed = (CACurrentMediaTime() - startTime) * 1000
                if let topLang = whisper_lang_str(topId) {
                    Logger.debug("Detection: top=\(String(cString: topLang)) (p=\(String(format: "%.3f", probs[Int(topId)]))), \(String(format: "%.1f", elapsed))ms", subsystem: .transcription)
                }

                return result
            }
            return result?.isEmpty == true ? nil : result
        } catch SafeLockError.timeout {
            Logger.error("Detector lock timeout", subsystem: .transcription)
            return nil
        } catch {
            Logger.error("Detector error: \(error.localizedDescription)", subsystem: .transcription)
            return nil
        }
    }

    func prepareForShutdown() {
        isShuttingDown = true
    }

    func isContextHealthy() -> Bool {
        guard !isShuttingDown else { return false }
        do {
            return try ctxLock.withLock(timeout: 1.0) { [self] in
                ctx != nil
            }
        } catch {
            return false
        }
    }
}
