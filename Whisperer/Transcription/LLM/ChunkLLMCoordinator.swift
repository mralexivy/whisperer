//
//  ChunkLLMCoordinator.swift
//  Whisperer
//
//  Serial queue for per-chunk LLM correction during streaming transcription.
//  Corrections run during audio collection windows so the queue is drained
//  (or nearly so) by the time the user releases the key.
//

import Foundation

@MainActor
final class ChunkLLMCoordinator {

    // Ordered corrected outputs — one entry per chunk (including tail).
    private(set) var correctedChunks: [String] = []

    // Raw whisper text for each chunk — used by seam repair to distinguish
    // LLM-added punctuation/capitalization from what whisper originally produced.
    private(set) var rawChunks: [String] = []

    // Tail of the serial task chain. Each new enqueue waits for the previous.
    private var pendingTask: Task<Void, Never>?

    // Injected correction function.
    // Production: AppState.applyLLMPostProcessing(_:contextTail:)
    // Tests: any mock closure.
    var corrector: ((_ text: String, _ contextTail: String?) async -> String)?

    // MARK: - Public API

    /// Enqueue `chunkText` for correction. Returns immediately; correction runs asynchronously.
    func enqueue(chunkText: String) {
        guard let corrector else { return }
        rawChunks.append(chunkText)                     // store raw before async correction
        let prev = pendingTask
        pendingTask = Task { [weak self] in
            await prev?.value                           // enforce serial ordering
            guard let self else { return }
            let ctx = self.correctedChunks.last.map { String($0.suffix(200)) }  // 200 chars = full sentence context
            let result = await corrector(chunkText, ctx)
            self.correctedChunks.append(result)
        }
    }

    /// Await all pending corrections, apply seam repair, then return the joined result.
    func drain() async -> String {
        await pendingTask?.value
        let repaired = repairSeams(corrected: correctedChunks, raw: rawChunks)
        return repaired.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Clear all state for the next recording session.
    func reset() {
        pendingTask?.cancel()
        pendingTask = nil
        correctedChunks = []
        rawChunks = []
    }

    // MARK: - Seam Repair

    /// Fix boundary artifacts at each chunk join point without an LLM call.
    /// Two repairs per seam:
    /// 1. Terminal punct: remove LLM-added trailing .!? when the next chunk continues lowercase.
    /// 2. Capitalization: lowercase the first word of a chunk when whisper had it lowercase
    ///    and it's not a proper noun.
    private func repairSeams(corrected: [String], raw: [String]) -> [String] {
        guard corrected.count > 1, corrected.count == raw.count else { return corrected }
        var result = corrected
        for i in 0..<(result.count - 1) {
            // ── Terminal punct repair ────────────────────────────────────────────────
            // If LLM added trailing .!? (not in raw) and the next chunk starts lowercase
            // → the period is spurious; strip it.
            let rawEndsWithPunct = raw[i].last.map { ".!?".contains($0) } ?? false
            let corrEndsWithPunct = result[i].last.map { ".!?".contains($0) } ?? false
            let nextStartsLower = result[i + 1].first?.isLowercase ?? false
            if corrEndsWithPunct && !rawEndsWithPunct && nextStartsLower {
                result[i] = String(result[i].dropLast())
                    .trimmingCharacters(in: .whitespaces)
            }

            // ── Capitalization repair ────────────────────────────────────────────────
            // If LLM capitalized the first word of chunk[i+1] but whisper had it lowercase,
            // lowercase it — unless it's a proper noun (appears capitalized mid-sentence
            // elsewhere in the raw chunk, i.e. whisper itself capitalized it there).
            let rawWords = raw[i + 1].components(separatedBy: " ")
            let corrWords = result[i + 1].components(separatedBy: " ")
            guard let rawFirstWord = rawWords.first, let corrFirstWord = corrWords.first,
                  let rawFirst = rawFirstWord.first, rawFirst.isLowercase,
                  let corrFirst = corrFirstWord.first, corrFirst.isUppercase else { continue }

            let lowerFirst = corrFirstWord.lowercased()
            let appearsCapMidSentence = rawWords.dropFirst()
                .contains { $0.lowercased() == lowerFirst && $0.first?.isUppercase == true }
            if !appearsCapMidSentence {
                let lowered = corrFirstWord.prefix(1).lowercased() + corrFirstWord.dropFirst()
                let rest = corrWords.dropFirst().joined(separator: " ")
                result[i + 1] = rest.isEmpty ? lowered : lowered + " " + rest
            }
        }
        return result
    }
}
