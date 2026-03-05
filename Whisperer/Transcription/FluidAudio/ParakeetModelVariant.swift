//
//  ParakeetModelVariant.swift
//  Whisperer
//
//  Parakeet TDT model variants for FluidAudio ASR backend
//

import Foundation

enum ParakeetModelVariant: String, CaseIterable, Identifiable {
    case v2 = "v2"
    case v3 = "v3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .v2: return "Parakeet v2 (English)"
        case .v3: return "Parakeet v3 (Multilingual)"
        }
    }

    var languageDescription: String {
        switch self {
        case .v2: return "English only — highest recall"
        case .v3: return "25 European languages"
        }
    }

    var sizeDescription: String {
        switch self {
        case .v2: return "~250 MB"
        case .v3: return "~250 MB"
        }
    }
}
