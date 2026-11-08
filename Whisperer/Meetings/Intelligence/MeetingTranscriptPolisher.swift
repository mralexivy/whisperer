//
//  MeetingTranscriptPolisher.swift
//  Whisperer
//
//  "Polish with <AI>": a connected LLM cleans up a finished meeting transcript — misheard
//  words, punctuation, casing, fillers and false starts — segment by segment.
//
//  Guardrails, because a transcript is a record of what was said:
//  - Every segment keeps its id, speaker and timestamps; only `text` changes.
//  - A rewrite is accepted only if it stays close to the original: not empty, between 40%
//    and 150% of the original length, and in the same script (a Hebrew card must come back
//    in Hebrew). Anything else keeps the original text.
//  - The original is kept in `rawText`, so the whole pass can be undone.
//  - Long meetings go in chunks of ~120 cards so no single request is huge.
//

import Foundation

nonisolated enum MeetingTranscriptPolisher {

    static let schema = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["segments"],
      "properties": {
        "segments": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["id", "text"],
            "properties": { "id": { "type": "integer" }, "text": { "type": "string" } }
          }
        }
      }
    }
    """

    static func instructions(languageName: String?) -> String {
        let language = languageName.map { "The meeting is in \($0). Keep every segment in its own language — never translate." }
            ?? "Keep every segment in its own language — never translate."
        return """
        You clean up a speech-to-text meeting transcript. Each input line is `id | speaker | text`.

        For every line, return its id and the cleaned text:
        - fix misheard words when the context makes the intended word clear,
        - fix punctuation and capitalization,
        - remove filler words (um, uh, like as filler) and false starts.
        Never add information, summarize, merge or split lines, or change what was said.
        If a line is already clean, return it unchanged. Return every id exactly once.
        \(language)
        Reply with one JSON object matching the schema, and nothing else.
        """
    }

    struct Chunk: Equatable { var indices: [Int] }

    /// Splits card indices into chunks of at most `maxCards` cards and ~`maxChars` characters.
    static func chunks(for segments: [MeetingSegment], maxCards: Int = 120, maxChars: Int = 24_000) -> [Chunk] {
        var result: [Chunk] = []
        var current: [Int] = []
        var chars = 0
        for (i, segment) in segments.enumerated() {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if !current.isEmpty && (current.count >= maxCards || chars + text.count > maxChars) {
                result.append(Chunk(indices: current))
                current = []
                chars = 0
            }
            current.append(i)
            chars += text.count
        }
        if !current.isEmpty { result.append(Chunk(indices: current)) }
        return result
    }

    static func input(for chunk: Chunk, in segments: [MeetingSegment]) -> String {
        chunk.indices.map { i in
            let s = segments[i]
            let oneLine = s.text.replacingOccurrences(of: "\n", with: " ")
            return "\(i) | \(s.speakerName) | \(oneLine)"
        }.joined(separator: "\n")
    }

    /// Parses `{"segments":[{"id":3,"text":"…"}]}` (lenient about surrounding chatter).
    static func parse(_ reply: String) -> [Int: String] {
        for candidate in MeetingNotesSchema.jsonObjectCandidates(in: reply) {
            guard let data = candidate.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["segments"] as? [[String: Any]] else { continue }
            var out: [Int: String] = [:]
            for item in items {
                let id = (item["id"] as? Int) ?? (item["id"] as? String).flatMap(Int.init)
                if let id, let text = item["text"] as? String { out[id] = text }
            }
            if !out.isEmpty { return out }
        }
        return [:]
    }

    /// Whether `polished` is an acceptable rewrite of `original`.
    static func accept(original: String, polished: String) -> Bool {
        let o = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return false }
        guard o.count >= 12 else { return p.count <= max(o.count * 2, 24) }
        let ratio = Double(p.count) / Double(o.count)
        guard ratio >= 0.4 && ratio <= 1.5 else { return false }
        return scripts(o) == scripts(p) || scripts(o).isSubset(of: scripts(p))
    }

    enum Script: Hashable { case latin, hebrew, arabic, cyrillic, cjk }

    static func scripts(_ text: String) -> Set<Script> {
        var counts: [Script: Int] = [:]
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let script: Script?
            switch v {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: script = .latin
            case 0x0590...0x05FF: script = .hebrew
            case 0x0600...0x06FF, 0x0750...0x077F: script = .arabic
            case 0x0400...0x04FF: script = .cyrillic
            case 0x3040...0x30FF, 0x4E00...0x9FFF, 0xAC00...0xD7AF: script = .cjk
            default: script = nil
            }
            if let script { counts[script, default: 0] += 1 }
        }
        // A script counts only if it is a real share of the letters, not one stray word.
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return [] }
        return Set(counts.filter { Double($0.value) / Double(total) >= 0.2 }.keys)
    }

    struct Outcome: Equatable {
        var segments: [MeetingSegment]
        var changed: Int
        var rejected: Int
    }

    /// Applies accepted rewrites. The original text goes to `rawText` (kept from an earlier
    /// pass if there was one) so `undo` can restore exactly what the recognizer produced.
    static func apply(_ rewrites: [Int: String], to segments: [MeetingSegment]) -> Outcome {
        var out = segments
        var changed = 0
        var rejected = 0
        for (i, text) in rewrites where out.indices.contains(i) {
            let original = out[i].text
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned != original.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            guard accept(original: original, polished: cleaned) else { rejected += 1; continue }
            if out[i].rawText == nil { out[i].rawText = original }
            out[i].text = cleaned
            changed += 1
        }
        return Outcome(segments: out, changed: changed, rejected: rejected)
    }

    /// Restores every polished card's original text.
    static func undo(_ segments: [MeetingSegment]) -> [MeetingSegment] {
        segments.map { s in
            guard let raw = s.rawText else { return s }
            var copy = s
            copy.text = raw
            copy.rawText = nil
            return copy
        }
    }

    /// Chunks in flight at once. Each request is several seconds of model latency, so a long
    /// meeting goes about three times faster; more would just queue at the provider.
    static let maxConcurrentChunks = 3

    /// Runs the whole pass. `onProgress` gets (chunks done, chunks total). Chunks are sent in
    /// parallel (they don't overlap) and applied in order.
    ///
    /// `@concurrent`: chunking, prompt building and the final apply walk the whole transcript;
    /// the caller (`TranscriptPolishController`) is on the main actor, which a plain
    /// `nonisolated async` would inherit.
    @concurrent
    static func polish(_ segments: [MeetingSegment], with provider: any MeetingIntelligenceProvider,
                       languageName: String?,
                       onProgress: @escaping @Sendable (Int, Int) -> Void) async throws -> Outcome {
        let plan = chunks(for: segments)
        let prompt = instructions(languageName: languageName)
        onProgress(0, plan.count)
        var rewrites: [Int: String] = [:]
        try await withThrowingTaskGroup(of: [Int: String].self) { group in
            var next = 0
            var done = 0
            func launch() {
                guard next < plan.count else { return }
                let chunk = plan[next]
                let text = input(for: chunk, in: segments)
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    let reply = try await provider.complete(instructions: prompt, input: text, jsonSchema: schema)
                    let parsed = parse(reply).filter { chunk.indices.contains($0.key) }
                    if parsed.isEmpty { throw MeetingAIProviderError.schemaMismatch(raw: String(reply.prefix(500))) }
                    return parsed
                }
            }
            for _ in 0..<min(maxConcurrentChunks, plan.count) { launch() }
            while let result = try await group.next() {
                rewrites.merge(result) { _, new in new }
                done += 1
                onProgress(done, plan.count)
                launch()
            }
        }
        return apply(rewrites, to: segments)
    }
}
