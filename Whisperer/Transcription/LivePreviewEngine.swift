//
//  LivePreviewEngine.swift
//  Whisperer
//
//  A push-based streaming engine `StreamingTranscriber` feeds audio into and reads accumulated
//  partials from. The built-in engine (`SystemLivePreviewBridge`, Apple Dictation) drives the
//  dictation HUD and the meeting live transcript through it; `NemotronBridge` and
//  `NemotronHebrewBridge` conform so they can still run as the user's own engine.
//

import Foundation

/// `nonisolated`: every conformer is an actor. Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// the protocol would otherwise be inferred `@MainActor`, which actors cannot conform to (an error
/// in the test target, where `StopPathDataLossTests` conforms a test actor).
// `Sendable`: every conformer is an actor (`NemotronBridge`, `SystemLivePreviewBridge`), and the
// engine is captured by the `@Sendable` partial callbacks that drive it.
nonisolated protocol LivePreviewEngine: AnyObject, Sendable {
    /// The language code this engine would force for `language`, and whether it actually has a
    /// model for it.
    ///
    /// `nil` means nothing is forced — auto mode, or the model isn't loaded yet — so there is
    /// nothing that can silently degrade. `isSupported == false` means `beginSession` will ask
    /// for a language the model has never heard of and run unconditioned without raising
    /// anything: the caller has to report that itself.
    func forcedLanguageSupport(for language: TranscriptionLanguage) async -> (code: String, isSupported: Bool)?

    func beginSession(language: TranscriptionLanguage) async
    /// Receives the session's **accumulated** text on every update, never a delta.
    func setPreviewCallback(_ callback: @escaping @Sendable (String) -> Void) async
    func feed(samples: [Float]) async
    func endSession() async -> String

    /// The model's own guess for the audio it has heard so far, or nil before it has one (or when
    /// the engine cannot detect language at all).
    func detectedLanguageCode() async -> String?

    /// Stop re-deciding the language and hold this one.
    ///
    /// In auto mode the caller learns the language from the evidence the whole process has
    /// (`LiveLanguageArbiter`) and pushes it here. Mid-session and reversible: the caller unpins
    /// by passing nil.
    func pinLanguage(_ code: String?) async

    /// Whether the session `beginSession` opened is actually producing text. False when the engine
    /// could not start — e.g. Apple dictation with no assets for the session's language — and the
    /// caller must then show its own engine's preview instead of an empty "Listening…".
    func isStreaming() async -> Bool

    /// The language this session needed but could not stream in, for telling the user and
    /// installing it. Nil when nothing is missing.
    func unavailableLanguage() async -> TranscriptionLanguage?
}

extension LivePreviewEngine {
    /// Model-backed engines (Nemotron) stream whenever they are loaded, in every language.
    func isStreaming() async -> Bool { true }
    func unavailableLanguage() async -> TranscriptionLanguage? { nil }
}
