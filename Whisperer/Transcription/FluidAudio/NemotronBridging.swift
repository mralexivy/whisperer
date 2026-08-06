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
    func beginSession(language: TranscriptionLanguage) async
    func setPreviewCallback(_ callback: @escaping @Sendable (String) -> Void) async
    func feed(samples: [Float]) async
    func endSession() async -> String
}
#endif
