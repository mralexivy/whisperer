//
//  TestPrompts.swift
//  WhispererTests
//
//  Shared prompt plumbing for LLM tests: reproduces the framing `AppState` applies
//  to an AIMode before handing it to LLMPostProcessor.
//

import Foundation
@testable import whisperer

enum TestPrompts {

    /// Splits an `AIMode.prompt` the way the production caller does: everything before
    /// the `[INPUT]` marker becomes the system prompt, the transcript is re-wrapped in
    /// the delimiters as the user message. Benchmarking a mode without this framing
    /// would measure a prompt the app never sends.
    static func split(_ mode: AIMode, text: String) -> (system: String, user: String) {
        let parts = mode.prompt.components(separatedBy: "{transcript}")
        var sys = parts[0]
        if let r = sys.range(of: "[INPUT]", options: .backwards) { sys = String(sys[..<r.lowerBound]) }
        sys = sys.trimmingCharacters(in: .whitespacesAndNewlines)
        return (sys, "[INPUT]\n\(text)\n[/INPUT]")
    }

    /// Built-in mode by display name. Traps rather than falling back, because a silent
    /// substitution would report a benchmark for the wrong mode.
    static func mode(named name: String) -> AIMode {
        guard let mode = AIMode.builtInModes.first(where: { $0.name == name }) else {
            fatalError("No built-in AIMode named \"\(name)\"")
        }
        return mode
    }
}

// MARK: - Benchmark table

/// One generation, measured. `wallMs` is end-to-end around `process()` — it includes
/// prefill, decode, and the actor hops the app also pays; `prefillMs`/`decodeMs` come
/// from `LLMGenerationStats` and split that total by where the time went.
struct BenchRow {
    let workload: String
    let model: String
    let caseName: String
    let promptTokens: Int
    let genTokens: Int
    let prefillMs: Double
    let decodeMs: Double
    let wallMs: Double
    let acceptRate: Double?
    let qualityOK: Bool
    let note: String

    var tokensPerSecond: Double { decodeMs > 0 ? Double(genTokens) / (decodeMs / 1000) : 0 }
}

enum BenchTable {

    /// Prints the per-case table plus a per-model roll-up. `print` rather than `Logger`
    /// on purpose: this is test output, and the app's Logger filters `.debug` in Release.
    static func report(_ workload: String, rows: [BenchRow]) {
        let rows = rows.filter { $0.workload == workload }
        guard !rows.isEmpty else {
            print("\n=== \(workload.uppercased()): no rows recorded ===\n")
            return
        }

        print("\n=== \(workload.uppercased()) — per case ===")
        print("| model | case | promptTok | genTok | prefill ms | decode ms | tok/s | wall ms | accept% | quality |")
        print("|---|---|---:|---:|---:|---:|---:|---:|---:|---|")
        for r in rows {
            let accept = r.acceptRate.map { String(format: "%.0f%%", $0 * 100) } ?? "–"
            print("| \(r.model) | \(r.caseName) | \(r.promptTokens) | \(r.genTokens) "
                + "| \(fmt(r.prefillMs)) | \(fmt(r.decodeMs)) | \(String(format: "%.1f", r.tokensPerSecond)) "
                + "| \(fmt(r.wallMs)) | \(accept) | \(r.qualityOK ? "ok" : "FAIL \(r.note)") |")
        }

        print("\n=== \(workload.uppercased()) — per model ===")
        print("| model | cases | quality pass | median tok/s | total wall s | worst case wall ms |")
        print("|---|---:|---:|---:|---:|---:|")
        for model in orderedModels(rows) {
            let m = rows.filter { $0.model == model }
            let tps = median(m.map(\.tokensPerSecond))
            let wall = m.reduce(0) { $0 + $1.wallMs }
            let worst = m.map(\.wallMs).max() ?? 0
            print("| \(model) | \(m.count) | \(m.filter(\.qualityOK).count)/\(m.count) "
                + "| \(String(format: "%.1f", tps)) | \(String(format: "%.1f", wall / 1000)) | \(fmt(worst)) |")
        }
        print("")
    }

    /// Quality gate first, then wall-clock — a fast model that fails the structural
    /// assertions is out, because malformed output is discarded downstream anyway.
    static func winner(_ workload: String, rows all: [BenchRow]) -> String? {
        let rows = all.filter { $0.workload == workload }
        let models = orderedModels(rows)
        let qualified = models.filter { model in
            let m = rows.filter { $0.model == model }
            return !m.isEmpty && m.allSatisfy(\.qualityOK)
        }
        let pool = qualified.isEmpty ? models : qualified
        return pool.min { a, b in
            rows.filter { $0.model == a }.reduce(0) { $0 + $1.wallMs }
                < rows.filter { $0.model == b }.reduce(0) { $0 + $1.wallMs }
        }
    }

    // MARK: - Private

    /// First-seen order, so the table reads in the sequence the models were run
    /// rather than alphabetically.
    private static func orderedModels(_ rows: [BenchRow]) -> [String] {
        var seen = Set<String>()
        return rows.map(\.model).filter { seen.insert($0).inserted }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private static func fmt(_ ms: Double) -> String { String(format: "%.0f", ms) }
}
