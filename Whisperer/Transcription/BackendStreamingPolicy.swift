//
//  BackendStreamingPolicy.swift
//  Whisperer
//
//  Value type carrying streaming-pipeline capabilities for a TranscriptionBackend.
//  Computed from immutable bridge config — never stored as a var.
//

import Foundation

/// Describes how a `TranscriptionBackend` participates in the streaming pipeline.
///
/// Each field replaces a concrete type check (`is WhisperBridge`, `is WhisperKitBridge`, etc.)
/// in `StreamingTranscriber`. The struct is pure data — no inheritance, no shared state.
/// Bridges return it from a computed var so it is always derived from immutable config.
struct BackendStreamingPolicy {
    /// True if the backend drives the eager word-by-word stream (whisper.cpp with flag on).
    /// When true, `StreamingTranscriber` creates an `EagerStreamEngine` and skips VAD chunking.
    let supportsEagerWordStream: Bool

    /// True if the backend always needs an `EagerStreamEngine` regardless of the
    /// `whisperCppEagerStreaming` user default (e.g., WhisperKit's batch-timestamped pass).
    let requiresEagerEngine: Bool

    /// True if the backend's streaming mode is already the committed decode path, so
    /// scheduling a second VAD-chunked pass would duplicate work and stall live preview.
    let suppressesVADChunking: Bool

    /// Maximum VAD chunk duration in seconds. Shorter values force more frequent commits,
    /// which keeps Core ML inference latency within a render-loop budget.
    let maxVADChunkDuration: TimeInterval

    /// How long the preview loop sleeps between passes (seconds).
    /// Lower values give more responsive live text at the cost of more inference calls.
    let previewPollInterval: TimeInterval

    /// True if the preview bridge runs on its own dedicated queue and can overlap with
    /// committed-chunk decodes (e.g., FluidAudio triple-manager).
    /// False means preview blocks during active chunk transcription to avoid contention.
    let previewSharesDecodeQueue: Bool

    /// True if preview and committed-chunk decodes must be serialised through a shared
    /// inference lock (e.g., WhisperKit's single Core ML runtime).
    let serializesInferenceWithPreview: Bool
}
