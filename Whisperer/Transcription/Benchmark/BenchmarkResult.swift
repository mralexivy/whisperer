//
//  BenchmarkResult.swift
//  Whisperer
//
//  Data model for transcription benchmark results
//

import Foundation

struct BenchmarkResult: Identifiable {
    let id: UUID
    let timestamp: Date
    let backendType: BackendType
    let modelName: String

    // Timing
    let totalLatencyMs: Double
    let audioDurationSeconds: Double
    let sampleCount: Int

    // Performance ratios
    var realTimeFactor: Double {
        guard audioDurationSeconds > 0 else { return 0 }
        return (totalLatencyMs / 1000.0) / audioDurationSeconds
    }

    // Output
    let wordCount: Int
    let transcribedText: String

    // Resource usage
    let peakMemoryMB: Double
    let baselineMemoryMB: Double
    var memoryDeltaMB: Double { peakMemoryMB - baselineMemoryMB }
}

enum BenchmarkDuration: String, CaseIterable, Identifiable {
    case fiveSeconds = "5s"
    case tenSeconds = "10s"
    case thirtySeconds = "30s"
    case sixtySeconds = "60s"

    var id: String { rawValue }

    var seconds: Double {
        switch self {
        case .fiveSeconds: return 5.0
        case .tenSeconds: return 10.0
        case .thirtySeconds: return 30.0
        case .sixtySeconds: return 60.0
        }
    }

    var sampleCount: Int {
        Int(seconds * 16000.0)
    }
}
