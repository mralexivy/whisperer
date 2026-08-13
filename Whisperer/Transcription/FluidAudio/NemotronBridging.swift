//
//  NemotronBridging.swift
//  Whisperer
//
//  Protocol allowing StreamingTranscriber to hold either NemotronBridge or
//  NemotronHebrewBridge without a concrete type dependency.
//

#if canImport(FluidAudio)
import Foundation

protocol NemotronBridging: AnyObject {
    /// The language code this bridge would force for `language`, and whether the loaded model
    /// actually has a prompt for it.
    ///
    /// `nil` means nothing is forced — auto mode, or the model isn't loaded yet — so there is
    /// nothing that can silently degrade. `isSupported == false` means `beginSession` will ask
    /// for a language the model has never heard of and get the default "auto" prompt back
    /// without raising anything: the caller has to report that itself.
    func forcedLanguageSupport(for language: TranscriptionLanguage) async -> (code: String, isSupported: Bool)?

    func beginSession(language: TranscriptionLanguage) async
    func setPreviewCallback(_ callback: @escaping @Sendable (String) -> Void) async
    func feed(samples: [Float]) async
    func endSession() async -> String
}
#endif
