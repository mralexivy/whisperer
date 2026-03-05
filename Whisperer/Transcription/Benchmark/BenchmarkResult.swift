//
//  BenchmarkResult.swift
//  Whisperer
//
//  Data model for transcription backend benchmark results
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

struct BenchmarkComparison {
    let backendA: BackendType
    let backendB: BackendType
    let resultsA: [BenchmarkResult]
    let resultsB: [BenchmarkResult]

    var avgLatencyA: Double {
        guard !resultsA.isEmpty else { return 0 }
        return resultsA.map(\.totalLatencyMs).reduce(0, +) / Double(resultsA.count)
    }

    var avgLatencyB: Double {
        guard !resultsB.isEmpty else { return 0 }
        return resultsB.map(\.totalLatencyMs).reduce(0, +) / Double(resultsB.count)
    }

    var avgRTFA: Double {
        guard !resultsA.isEmpty else { return 0 }
        return resultsA.map(\.realTimeFactor).reduce(0, +) / Double(resultsA.count)
    }

    var avgRTFB: Double {
        guard !resultsB.isEmpty else { return 0 }
        return resultsB.map(\.realTimeFactor).reduce(0, +) / Double(resultsB.count)
    }

    var avgMemoryA: Double {
        guard !resultsA.isEmpty else { return 0 }
        return resultsA.map(\.memoryDeltaMB).reduce(0, +) / Double(resultsA.count)
    }

    var avgMemoryB: Double {
        guard !resultsB.isEmpty else { return 0 }
        return resultsB.map(\.memoryDeltaMB).reduce(0, +) / Double(resultsB.count)
    }

    var speedupRatio: Double {
        guard avgLatencyB > 0 else { return 0 }
        return avgLatencyA / avgLatencyB
    }

    var winner: BackendType {
        avgLatencyA <= avgLatencyB ? backendA : backendB
    }

    var winnerSpeedupText: String {
        let ratio = avgLatencyA <= avgLatencyB
            ? (avgLatencyB / avgLatencyA)
            : (avgLatencyA / avgLatencyB)
        return String(format: "%.1fx faster", ratio)
    }
}

enum BenchmarkAudioSource: String, CaseIterable, Identifiable {
    case recording = "Recording"
    case synthetic = "Synthetic"

    var id: String { rawValue }
}

struct BenchmarkRecording: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let displayName: String
    let duration: Double
    let date: Date?

    var formattedDuration: String {
        if duration < 60 {
            return String(format: "%.1fs", duration)
        } else {
            let mins = Int(duration) / 60
            let secs = Int(duration) % 60
            return "\(mins)m \(secs)s"
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: BenchmarkRecording, rhs: BenchmarkRecording) -> Bool {
        lhs.url == rhs.url
    }
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
