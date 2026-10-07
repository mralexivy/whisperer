//
//  MeetingCoordinatorFeed.swift
//  Whisperer
//
//  Names which `StreamingTranscriber` callback carries the accumulated transcript for a given
//  meeting backend.
//
//  `MeetingSpeakerCoordinator` takes the **full transcript so far** and diffs it. Hand it a
//  per-chunk delta and it does not degrade gracefully: it rejects the input, the pending queue
//  is destroyed, and the live tail blanks (observed ~148× in one 4.5-minute Hebrew session,
//  2026-09-07). Three backends reach the coordinator by three different routes, and the routing
//  used to be inferred inline from `inAppBackend == .whisperCpp`, which is exactly the kind of
//  implicit rule that acquires a wrong case when a fourth backend arrives. Naming the cases
//  makes a new backend a compile-time question.
//

import Foundation

/// Which callback delivers the growing accumulated transcript during a meeting.
enum MeetingCoordinatorFeed: Equatable {

    /// `onPreviewTail` carries the whole transcript so far.
    ///
    /// Nemotron accumulates internally: each partial is the full session, not a window. Used
    /// both when Nemotron is the final decoder's preview and on the whisper.cpp + Nemotron
    /// preview-only path, where whisper's chunk commits are deltas and must be ignored.
    case accumulatedPartials

    /// `onChunkCompleted` carries the whole transcript, once, at `finish()`.
    ///
    /// The Nemotron-final-decoder path. Routing the final decode through the coordinator means
    /// the attributed tail gets the higher-quality pass rather than the live partials.
    case accumulatedFinal

    /// `onTranscription` carries committed text plus the live preview tail.
    ///
    /// Qwen3's own callbacks are both unsuitable — the preview tail is window-local and the
    /// chunk callback is a delta — but `StreamingTranscriber` already joins them into the
    /// display string. That string is accumulated by construction and only needs a monotonicity
    /// filter, which `MeetingTranscriptAccumulator` applies.
    case transcriberAccumulated

    /// The feed for a backend, or nil when the backend cannot drive speaker attribution at all
    /// and the meeting should fall back to unattributed live text.
    ///
    /// - Parameters:
    ///   - inAppBackend: `AppState.effectiveInAppBackend` — the backend the recording actually
    ///     decodes through, which during a meeting may be a borrowed bridge rather than the
    ///     user's dictation choice.
    ///   - previewOwnsNemotron: true when Nemotron was loaded purely to preview alongside
    ///     whisper.cpp. Without it, whisper.cpp has no accumulated source at all.
    init?(inAppBackend: BackendType, previewOwnsNemotron: Bool) {
        switch inAppBackend {
        case .nemotron, .nemotronHebrew:
            self = .accumulatedFinal
        case .qwen3asr:
            self = .transcriberAccumulated
        case .whisperCpp:
            guard previewOwnsNemotron else { return nil }
            self = .accumulatedPartials
        case .parakeet, .speechAnalyzer, .whisperKit:
            return nil
        }
    }
}
