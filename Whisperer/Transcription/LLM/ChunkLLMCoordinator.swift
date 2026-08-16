//
//  ChunkLLMCoordinator.swift
//  Whisperer
//
//  Per-chunk LLM correction during streaming transcription. Corrections run during audio
//  collection windows so the queue is drained (or nearly so) by the time the user releases the key.
//
//  Chunks are corrected **concurrently**, not one after another. They used to be chained — each
//  enqueue awaited the previous — but the only thing the chain provided was the previous chunk's
//  corrected tail, and nothing read it: `AppState.applyLLMPostProcessing` checked
//  `contextTail != nil` to switch on fragment mode and dropped the string. Every chunk is a
//  self-contained prompt with the same system prefix, and `repairSeams` is an order-independent
//  pass over the two arrays afterwards. So the chain cost latency and bought nothing — and it
//  actively prevented the batching it now enables: `BatchedLLMScheduler` can only coalesce
//  requests that are in flight at the same moment.
//
//  Results are written into an index-keyed array rather than appended, because "concurrent" and
//  "append" together would order the output by completion time, which is roughly length order.
//

import Foundation

@MainActor
final class ChunkLLMCoordinator {

    /// Corrected output per chunk, in chunk order. Slots are nil until their correction returns,
    /// so this is only complete after `drain()`.
    private var results: [String?] = []

    /// One task per chunk. Held so `reset()` can cancel them and `drain()` can await them.
    private var tasks: [Task<Void, Never>] = []

    // Raw whisper text for each chunk — used by seam repair to distinguish
    // LLM-added punctuation/capitalization from what whisper originally produced.
    private(set) var rawChunks: [String] = []

    /// Corrections that have come back so far, in chunk order, skipping the ones still running.
    /// Kept for callers that only want to know whether anything has been corrected.
    var correctedChunks: [String] { results.compactMap { $0 } }

    /// Whether any chunk has been enqueued this session. The stop path used to ask
    /// `!correctedChunks.isEmpty`, which was equivalent only while corrections were serial and had
    /// therefore all finished by then. With concurrent corrections that question is answered "no"
    /// while a whole session's work is still in flight, and the drain would be skipped.
    var hasChunks: Bool { !rawChunks.isEmpty }

    // Injected correction function. `fragment` is true for every mid-stream chunk; it selects the
    // fragment-mode system prompt, which is all the old `contextTail` string ever did.
    // Production: AppState.applyLLMPostProcessing(_:fragment:)
    // Tests: any mock closure.
    var corrector: ((_ text: String, _ fragment: Bool) async -> String)?

    // MARK: - Public API

    /// Enqueue `chunkText` for correction. Returns immediately; correction runs asynchronously and
    /// concurrently with any other chunk still being corrected.
    func enqueue(chunkText: String) {
        guard let corrector else { return }
        let index = rawChunks.count
        rawChunks.append(chunkText)                     // store raw before async correction
        results.append(nil)
        tasks.append(Task { [weak self] in
            let result = await corrector(chunkText, true)
            guard let self, index < self.results.count else { return }
            self.results[index] = result
        })
    }

    /// Await all pending corrections, apply seam repair, then return the joined result.
    func drain() async -> String {
        for task in tasks { await task.value }
        // A cancelled or failed slot falls back to the raw chunk rather than to nothing: dropping a
        // slot here would silently delete that part of the user's dictation.
        let corrected = results.enumerated().map { index, value in value ?? rawChunks[index] }
        let repaired = repairSeams(corrected: corrected, raw: rawChunks)
        return repaired.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Clear all state for the next recording session.
    func reset() {
        for task in tasks { task.cancel() }
        tasks = []
        results = []
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
